defmodule Karutte.WebTransport.Session do
  @moduledoc """
  The L3 session runner: the GenServer that actually drives a `Karutte.WebTransport` module.

  It holds the control plane only (invariant: it never touches stream bytes). All it receives
  from the transport are `Karutte.QuicTransport` contract messages (`{:quic, ...}`, already
  through `normalize/1`). **So it does not depend on the transport**: on QUIC or on HTTP/2,
  this runner is the same code. That is the reward for separating the layers.

  What it handles:

    * `{:quic, :new_stream, ...}` → calls `handle_stream/3` and branches on the disposition
      - `{:handler, mod, arg}`: starts a `StreamServer` and hands ownership over
      - `{:inline, max}`: buffers through the `Inline` machine, then `handle_inline_stream/3` on FIN
      - `{:reset, code}`: not wanted, reset it
    * `{:quic, :datagram, ...}` → `handle_datagram/2` (off-axis; dropped if not implemented)
    * `{:quic, :closed, ...}` → end of life
    * anything else → `handle_info/2`

  Handoff ordering (closing the race window) follows the promise in
  `Karutte.WebTransport.Handoff`: drain what arrived early → hand it to the new owner →
  switch the transport's target with `control/2`.
  """

  use GenServer

  alias Karutte.{Inline, WebTransport.StreamServer}

  # The WebTransport application error code sent to the peer when a stream handler crashes.
  @stream_crash_code 0

  @typep st :: %{
           transport: module(),
           conn: term(),
           mod: module(),
           state: term(),
           inline: %{optional(term()) => Inline.t()},
           owners: %{optional(term()) => pid()}
         }

  @doc """
  Start the session. `opts`:
    * `:transport` — the `Karutte.QuicTransport` implementation
    * `:conn`      — the transport's connection handle
    * `:handler`   — the session module implementing `Karutte.WebTransport`
    * `:init_arg`  — first argument to `handler.init/2`
    * `:conn_info` — second argument to `handler.init/2` (default `%{}`)
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    # StreamServers are linked, but we trap exits so that one stream handler crashing does not
    # take the whole session down with it.
    Process.flag(:trap_exit, true)
    mod = Keyword.fetch!(opts, :handler)
    init_arg = Keyword.get(opts, :init_arg)
    conn_info = Keyword.get(opts, :conn_info, %{})

    case mod.init(init_arg, conn_info) do
      {:ok, state} ->
        {:ok,
         %{
           transport: Keyword.fetch!(opts, :transport),
           conn: Keyword.fetch!(opts, :conn),
           mod: mod,
           state: state,
           inline: %{},
           owners: %{}
         }}

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:quic, :new_stream, _conn, stream, dir}, s) do
    {disp, state} = s.mod.handle_stream(stream, dir, s.state)
    {:noreply, dispatch(disp, stream, %{s | state: state})}
  end

  # Bytes of a stream dispositioned inline (never handed off, so they arrive here).
  def handle_info({:quic, :data, stream, bin, meta}, s) when is_map_key(s.inline, stream) do
    fin? = Keyword.get(meta, :fin, false)

    case Inline.feed(s.inline[stream], {bin, fin?}) do
      {:cont, machine} ->
        {:noreply, put_in(s.inline[stream], machine)}

      {:done, full} ->
        state = call_optional(s.mod, :handle_inline_stream, [stream, full, s.state], s.state)
        {:noreply, %{s | state: state, inline: Map.delete(s.inline, stream)}}

      {:overflow, _max} ->
        s.transport.shutdown(stream, {:reset, 0})
        {:noreply, %{s | inline: Map.delete(s.inline, stream)}}
    end
  end

  def handle_info({:quic, :datagram, _conn, bin}, s) do
    state = call_optional(s.mod, :handle_datagram, [bin, s.state], s.state)
    {:noreply, %{s | state: state}}
  end

  def handle_info({:quic, :closed, _conn, reason}, s) do
    {:stop, {:shutdown, reason}, s}
  end

  # Branch on who exited:
  #   - a StreamServer (child): if abnormal, reset only that stream; the session lives on.
  #   - anything else (the parent Connection, say): fold the session too.
  def handle_info({:EXIT, pid, reason}, s) do
    case Enum.find(s.owners, fn {_stream, p} -> p == pid end) do
      {stream, _} ->
        case reason do
          :normal -> :ok
          {:shutdown, _} -> :ok
          _ -> s.transport.shutdown(stream, {:reset, @stream_crash_code})
        end

        {:noreply, %{s | owners: Map.delete(s.owners, stream)}}

      nil ->
        {:stop, reason, s}
    end
  end

  def handle_info(msg, s) do
    if function_exported?(s.mod, :handle_info, 2) do
      case s.mod.handle_info(msg, s.state) do
        {:ok, state} -> {:noreply, %{s | state: state}}
        {:stop, reason, state} -> {:stop, reason, %{s | state: state}}
      end
    else
      {:noreply, s}
    end
  end

  @impl true
  def terminate(reason, s) do
    if function_exported?(s.mod, :terminate, 2), do: s.mod.terminate(reason, s.state)
    :ok
  end

  # --- Disposition branches ---

  @spec dispatch(Karutte.WebTransport.disposition(), term(), st()) :: st()
  defp dispatch({:handler, smod, arg}, stream, s) do
    {:ok, pid} =
      StreamServer.start_link(
        transport: s.transport,
        stream: stream,
        handler: smod,
        init_arg: arg
      )

    # Closing the handoff race window is the transport's job (control/2). Where the early bytes
    # live differs per transport (quicer: the NIF buffer; H3: the Connection's per-stream
    # buffer), so control takes on "early bytes → handoff_done → live, to pid, in that order".
    :ok = s.transport.control(stream, pid)
    put_in(s.owners[stream], pid)
  end

  defp dispatch({:inline, max}, stream, s), do: put_in(s.inline[stream], Inline.new(max))

  defp dispatch({:reset, code}, stream, s) do
    s.transport.shutdown(stream, {:reset, code})
    s
  end

  # Optional callback: without an implementation, state passes through untouched
  # (datagrams are dropped, inline streams discarded).
  defp call_optional(mod, fun, args, default_state) do
    if function_exported?(mod, fun, length(args)) do
      {:ok, state} = apply(mod, fun, args)
      state
    else
      default_state
    end
  end
end
