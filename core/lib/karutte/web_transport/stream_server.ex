defmodule Karutte.WebTransport.StreamServer do
  @moduledoc """
  The L4 stream runner: the GenServer that drives a `Karutte.WebTransport.Stream` module.
  One stream = one process (the sole owner of the transport's affine stream handle).

  This too is transport-independent. It receives contract messages (`{:quic, :data, ...}`),
  calls `handle_in/2` / `handle_fin/1`, and translates the returned `ret` into transport
  operations:

      {:ok, state, demand}         → set_active(demand)
      {:push, data, state, demand} → send(data); set_active(demand)
      {:push_fin, data, state}     → send(data, fin: true)
      {:close_write, state}        → shutdown(:write)
      {:reset, code, state}        → shutdown({:reset, code}); stop
      {:stop, reason, state}       → stop

  `demand` (`active:`) is the only per-stream window knob, AXIS 2 (MAX_STREAM_DATA). It
  appears nowhere else.

  ## Handoff ordering

  `start_link` blocks in `init`, so waiting for the handoff there would deadlock with the
  session (which calls `complete/2` only after `start_link` returns). So `init` only runs
  `mod.init/2` to get the initial state and initial demand, and **does not activate**.
  Waiting for the handoff, replaying the early bytes, and activating all happen in
  `handle_continue`. That keeps the straight line "drain → hand over → replay → activate".
  """

  use GenServer

  alias Karutte.WebTransport.Handoff

  @typep st :: %{
           transport: module(),
           stream: term(),
           mod: module(),
           state: term(),
           demand: keyword()
         }

  @doc """
  Start the runner. `opts`:
    * `:transport` — the transport module
    * `:stream`    — the transport's stream handle
    * `:handler`   — a module implementing `Karutte.WebTransport.Stream`
    * `:init_arg`  — second argument to `handler.init/2`
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    transport = Keyword.fetch!(opts, :transport)
    stream = Keyword.fetch!(opts, :stream)
    mod = Keyword.fetch!(opts, :handler)
    init_arg = Keyword.get(opts, :init_arg)

    s = %{transport: transport, stream: stream, mod: mod, state: nil, demand: []}
    # Take state and initial demand from init's ret, but hold off activating until after handoff.
    {s, action} = absorb(mod.init(stream, init_arg), s, _activate? = false)

    case action do
      :cont -> {:ok, s, {:continue, :handoff}}
      {:stop, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:handoff, s) do
    case Handoff.wait(s.stream) do
      {:ok, buffered} ->
        # Replay the early bytes through handle_in in order (still not activating). Stop on a terminal ret.
        result =
          Enum.reduce_while(buffered, {s, :cont}, fn {bin, meta}, {acc, :cont} ->
            case feed(bin, meta, acc, false) do
              {acc2, :cont} -> {:cont, {acc2, :cont}}
              stop -> {:halt, stop}
            end
          end)

        case result do
          # Activate for the first time here (the demand settled by init and the replay goes to the transport).
          {s, :cont} ->
            activate(s)
            {:noreply, s}

          {s, {:stop, reason}} ->
            {:stop, reason, s}
        end

      {:error, :handoff_timeout} ->
        {:stop, :handoff_timeout, s}
    end
  end

  @impl true
  def handle_info({:quic, :data, stream, bin, meta}, %{stream: stream} = s) do
    case feed(bin, meta, s, true) do
      {s, :cont} -> {:noreply, s}
      {s, {:stop, reason}} -> {:stop, reason, s}
    end
  end

  def handle_info({:quic, :reset, stream, code}, %{stream: stream} = s) do
    {:stop, {:shutdown, {:reset, code}}, s}
  end

  def handle_info({:quic, :closed, stream, reason}, %{stream: stream} = s) do
    {:stop, {:shutdown, reason}, s}
  end

  def handle_info(msg, s) do
    if function_exported?(s.mod, :handle_info, 2) do
      drive(s.mod.handle_info(msg, s.state), s, true)
    else
      {:noreply, s}
    end
  end

  @impl true
  def terminate(reason, s) do
    if function_exported?(s.mod, :terminate, 2), do: s.mod.terminate(reason, s.state)
    :ok
  end

  # Run data (and the FIN in meta) through handle_in → handle_fin and translate the ret.
  # Terminal actions are passed on, never swallowed. Demand goes to the transport immediately
  # only when activate? is true (false during handoff, where it is held).
  defp feed(bin, meta, s, activate?) do
    step1 =
      if bin == <<>>,
        do: {s, :cont},
        else: absorb(s.mod.handle_in(bin, s.state), s, activate?)

    fin? = Keyword.get(meta, :fin, false)

    case step1 do
      {s, :cont} when fin? ->
        if function_exported?(s.mod, :handle_fin, 1),
          do: absorb(s.mod.handle_fin(s.state), s, activate?),
          else: {s, :cont}

      other ->
        other
    end
  end

  # Thin wrapper for paths that need a GenServer return value (handle_info).
  defp drive(ret, s, activate?) do
    case absorb(ret, s, activate?) do
      {s, :cont} -> {:noreply, s}
      {s, {:stop, reason}} -> {:stop, reason, s}
    end
  end

  # Interpret a ret: perform side effects, update state/demand. Returns {state, :cont | {:stop, reason}}.
  @spec absorb(Karutte.WebTransport.Stream.ret(), st(), boolean()) :: {st(), :cont | {:stop, term()}}
  defp absorb({:ok, state, demand}, s, activate?),
    do: {set_demand(%{s | state: state}, demand, activate?), :cont}

  defp absorb({:push, data, state, demand}, s, activate?) do
    s.transport.send(s.stream, data)
    {set_demand(%{s | state: state}, demand, activate?), :cont}
  end

  defp absorb({:push_fin, data, state}, s, _activate?) do
    s.transport.send(s.stream, data, fin: true)
    {%{s | state: state}, :cont}
  end

  defp absorb({:close_write, state}, s, _activate?) do
    s.transport.shutdown(s.stream, :write)
    {%{s | state: state}, :cont}
  end

  defp absorb({:reset, code, state}, s, _activate?) do
    s.transport.shutdown(s.stream, {:reset, code})
    {%{s | state: state}, {:stop, {:shutdown, {:reset, code}}}}
  end

  defp absorb({:stop, reason, state}, s, _activate?), do: {%{s | state: state}, {:stop, reason}}

  # Hold the demand (during handoff) or apply it to the transport right away.
  defp set_demand(s, demand, true) do
    activate(%{s | demand: demand})
    %{s | demand: demand}
  end

  defp set_demand(s, demand, false), do: %{s | demand: demand}

  defp activate(%{demand: demand} = s) do
    case Keyword.fetch(demand, :active) do
      {:ok, active} -> s.transport.set_active(s.stream, active)
      :error -> :ok
    end
  end
end
