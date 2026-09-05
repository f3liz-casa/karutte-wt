defmodule Karutte do
  @moduledoc """
  WebTransport for the BEAM, as a small stack of layered behaviours.

  The model underneath everything:

      WebTransport session = Session × (Stream)* × Datagram-port
                             control plane × the streams × datagrams, off to the side

  That product is mapped straight onto a product of processes. Three rules follow:

    * The session is **control plane only** (`Karutte.WebTransport`). It never touches stream bytes.
    * One stream = one process (`Karutte.WebTransport.Stream`). An affine resource has exactly one owner.
    * The QUIC layer hides behind a single swappable interface (`Karutte.QuicTransport`).

  Backpressure has three axes, and each lives in its own place without overlapping the others:

      MAX_STREAMS      creation   <- how fast Karutte.WebTransport.handle_stream/3 returns a disposition (control plane)
      MAX_STREAM_DATA  transfer   <- the demand returned by Karutte.WebTransport.Stream (data plane)
      MAX_DATA         connection <- emerges from the transport as a sum (never appears in the API)
      datagram         off-axis   <- no flow control. Drop, never block.

  The real server is `Karutte.Http3.Server`, which runs this model on quicer and cowlib.
  See the README for a quick start and `docs/design.md` for the reasoning.
  """
end
