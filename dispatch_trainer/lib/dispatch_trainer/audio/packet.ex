defmodule DispatchTrainer.Audio.Packet do
  @moduledoc """
  WebSocket 二进制音频帧格式。

  布局: `magic(16) | version(8) | seq(32) | sent_at_ms(32) | opus_payload`
  序列号用于接收端抖动缓冲重排; 时间戳为发送端单调毫秒时钟。
  """

  @magic 0xD15C
  @version 1

  defstruct seq: 0, sent_at_ms: 0, payload: <<>>

  @type t :: %__MODULE__{seq: non_neg_integer, sent_at_ms: non_neg_integer, payload: binary}

  def encode(%__MODULE__{} = packet) do
    <<@magic::16, @version::8, packet.seq::32, packet.sent_at_ms::32, packet.payload::binary>>
  end

  def decode(<<@magic::16, @version::8, seq::32, sent_at_ms::32, payload::binary>>) do
    {:ok, %__MODULE__{seq: seq, sent_at_ms: sent_at_ms, payload: payload}}
  end

  def decode(_), do: {:error, :bad_frame}
end
