defmodule Karutte do
  @moduledoc """
  WebTransport を BEAM に素直に住まわせるための、層になった behaviour の素描。

  土台の見立て:

      WebTransport セッション ＝ Session × (Stream)* × Datagram-port
      （制御面 × ストリームたち × 軸の外のデータグラム）

  この積を、そのままプロセスの積に写す。要点は三つ:

    * セッションは **制御面だけ**（`Karutte.WebTransport`）。ストリームのバイトには触れない。
    * 1 ストリーム = 1 プロセス（`Karutte.WebTransport.Stream`）。affine リソースの所有者は一つ。
    * QUIC 層は一枚の差し替え口（`Karutte.QuicTransport`）の裏に隠す。

  背圧は三軸で、それぞれ別の場所に重ならず収まる:

      MAX_STREAMS      生成   <- Karutte.WebTransport.handle_stream/3 の処分速度（制御面）
      MAX_STREAM_DATA  転送   <- Karutte.WebTransport.Stream の demand（データ面）
      MAX_DATA         接続   <- transport が和から創発（API に現れない）
      datagram         軸の外 <- フロー制御なし。drop であってブロックではない。

  まだ spec の段。L1 は quicer に未接続。詳しくは README を。
  """
end
