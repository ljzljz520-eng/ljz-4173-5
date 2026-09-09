defmodule DispatchTrainer.Audio.JitterBuffer do
  @moduledoc """
  抗抖动缓冲: 将乱序到达的音频包按序列号重排。

    * 重复包: 丢弃并计数
    * 过迟包(序号小于下一个待播放序号): 丢弃并计数
    * 空缺超过窗口: 跳到最小可用序号, 避免无限等待
  """

  alias DispatchTrainer.Audio.Packet

  defstruct window: 10,
            buffer: %{},
            next: nil,
            highest: nil,
            dropped_late: 0,
            dropped_dup: 0

  @type t :: %__MODULE__{}

  def new(opts \\ []) do
    window = Keyword.get(opts, :window, Application.get_env(:dispatch_trainer, :jitter_window, 10))
    %__MODULE__{window: window}
  end

  @doc "推入一个包, 返回 {:stored | :duplicate | :late, buffer}。"
  def push(%__MODULE__{next: nil} = jb, %Packet{seq: seq} = packet) do
    {:stored, %{jb | buffer: Map.put(jb.buffer, seq, packet), next: seq, highest: seq}}
  end

  def push(%__MODULE__{} = jb, %Packet{seq: seq} = packet) do
    cond do
      Map.has_key?(jb.buffer, seq) ->
        {:duplicate, %{jb | dropped_dup: jb.dropped_dup + 1}}

      seq < jb.next ->
        {:late, %{jb | dropped_late: jb.dropped_late + 1}}

      true ->
        {:stored,
         %{jb | buffer: Map.put(jb.buffer, seq, packet), highest: max(jb.highest, seq)}}
    end
  end

  @doc """
  弹出下一个按序包。

  下一个序号缺失且缓冲已满窗口时, 跳到最小可用序号(丢包跳过)。
  """
  def pop(%__MODULE__{next: nil} = jb), do: {:empty, jb}

  def pop(%__MODULE__{} = jb) do
    cond do
      Map.has_key?(jb.buffer, jb.next) ->
        take(jb, jb.next)

      map_size(jb.buffer) >= jb.window ->
        take(jb, jb.buffer |> Map.keys() |> Enum.min())

      true ->
        {:empty, jb}
    end
  end

  @doc "持续弹出所有当前可按序取出的包。"
  def drain(%__MODULE__{} = jb, acc \\ []) do
    case pop(jb) do
      {:ok, packet, jb} -> drain(jb, [packet | acc])
      {:empty, jb} -> {Enum.reverse(acc), jb}
    end
  end

  defp take(jb, seq) do
    packet = Map.fetch!(jb.buffer, seq)
    {:ok, packet, %{jb | buffer: Map.delete(jb.buffer, seq), next: seq + 1}}
  end
end
