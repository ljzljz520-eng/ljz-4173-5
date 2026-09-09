defmodule DispatchTrainer.Audio.JitterBufferTest do
  @moduledoc "音频抖动: 乱序重排、重复丢弃、过迟丢弃、空缺跳帧。"
  use ExUnit.Case, async: true

  alias DispatchTrainer.Audio.{JitterBuffer, Packet}

  defp pkt(seq), do: %Packet{seq: seq, sent_at_ms: seq * 20, payload: <<seq>>}

  defp push_all(buffer, seqs) do
    Enum.reduce(seqs, buffer, fn seq, buf ->
      {:stored, buf} = JitterBuffer.push(buf, pkt(seq))
      buf
    end)
  end

  defp drain_seqs(buffer) do
    {packets, buffer} = JitterBuffer.drain(buffer)
    {Enum.map(packets, & &1.seq), buffer}
  end

  test "顺序到达直接按序输出" do
    buffer = push_all(JitterBuffer.new(), [0, 1, 2, 3])
    assert {[0, 1, 2, 3], _} = drain_seqs(buffer)
  end

  test "乱序到达被重排为按序输出" do
    buffer = push_all(JitterBuffer.new(), [0, 3, 1, 2])
    assert {[0, 1, 2, 3], _} = drain_seqs(buffer)
  end

  test "深度乱序(抖动)仍可完整重排" do
    buffer = push_all(JitterBuffer.new(window: 8), [10, 14, 12, 11, 13, 15])
    assert {[10, 11, 12, 13, 14, 15], _} = drain_seqs(buffer)
  end

  test "重复包被丢弃并计数" do
    buffer = JitterBuffer.new()
    {:stored, buffer} = JitterBuffer.push(buffer, pkt(0))
    assert {:duplicate, buffer} = JitterBuffer.push(buffer, pkt(0))
    assert buffer.dropped_dup == 1
    assert {[0], _} = drain_seqs(buffer)
  end

  test "过迟包(序号小于待播放序号)被丢弃并计数" do
    buffer = push_all(JitterBuffer.new(), [0, 1])
    assert {[0, 1], buffer} = drain_seqs(buffer)
    assert {:late, buffer} = JitterBuffer.push(buffer, pkt(0))
    assert {:late, buffer} = JitterBuffer.push(buffer, pkt(1))
    assert buffer.dropped_late == 2
  end

  test "空缺超过窗口时跳到最小可用序号, 不无限等待" do
    buffer = JitterBuffer.new(window: 3)
    {:stored, buffer} = JitterBuffer.push(buffer, pkt(0))
    assert {[0], buffer} = drain_seqs(buffer)

    # 1..4 丢失, 缓冲满窗口后跳到 5
    buffer = push_all(buffer, [5, 6, 7])
    assert {[5, 6, 7], _buffer} = drain_seqs(buffer)
  end

  test "空缺未超窗口时等待补包" do
    buffer = JitterBuffer.new(window: 5)
    {:stored, buffer} = JitterBuffer.push(buffer, pkt(0))
    assert {[0], buffer} = drain_seqs(buffer)

    {:stored, buffer} = JitterBuffer.push(buffer, pkt(2))
    # 序号 1 未到且缓冲未满窗口: 不输出
    assert {[], buffer} = drain_seqs(buffer)

    {:stored, buffer} = JitterBuffer.push(buffer, pkt(1))
    assert {[1, 2], _buffer} = drain_seqs(buffer)
  end

  test "编码帧经网络乱序后由缓冲恢复顺序(端到端)" do
    frames = for seq <- 0..9, do: Packet.encode(%Packet{seq: seq, sent_at_ms: seq * 20, payload: <<seq>>})
    shuffled = Enum.shuffle(frames)

    buffer =
      Enum.reduce(shuffled, JitterBuffer.new(), fn frame, buf ->
        {:ok, packet} = Packet.decode(frame)
        {_, buf} = JitterBuffer.push(buf, packet)
        buf
      end)

    {packets, _} = JitterBuffer.drain(buffer)
    assert Enum.map(packets, & &1.seq) == Enum.sort(Enum.map(packets, & &1.seq))
    assert Enum.uniq(Enum.map(packets, & &1.seq)) == Enum.map(packets, & &1.seq)
  end
end
