defmodule DispatchTrainer.Audio.PacketTest do
  use ExUnit.Case, async: true

  alias DispatchTrainer.Audio.Packet

  test "编码/解码往返一致" do
    packet = %Packet{seq: 42, sent_at_ms: 1_234, payload: <<1, 2, 3, 4>>}
    assert {:ok, decoded} = Packet.decode(Packet.encode(packet))
    assert decoded == packet
  end

  test "非法帧被拒绝" do
    assert {:error, :bad_frame} = Packet.decode(<<0, 1, 2, 3>>)
    assert {:error, :bad_frame} = Packet.decode(<<>>)
  end
end
