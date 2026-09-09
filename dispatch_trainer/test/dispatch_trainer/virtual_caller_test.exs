defmodule DispatchTrainer.VirtualCallerTest do
  @moduledoc "虚拟来电端: 信息不全时情绪化回避, 已释放信息按脚本作答。"
  use ExUnit.Case, async: true

  alias DispatchTrainer.Scenarios.Scenario
  alias DispatchTrainer.VirtualCaller

  defp scenario do
    %Scenario{
      caller_profile: %Scenario.CallerProfile{name: "张女士", emotion_level: "panicked"},
      info_releases: [
        %Scenario.InfoRelease{key: "complaint", label: "主诉", content: "胸口疼", initially_available: true},
        %Scenario.InfoRelease{
          key: "address",
          label: "地址",
          content: "滨河路128号",
          trigger_type: "question",
          keywords: ["地址", "哪里"]
        },
        %Scenario.InfoRelease{
          key: "history",
          label: "病史",
          content: "有高血压",
          trigger_type: "question",
          keywords: ["病史", "高血压"]
        }
      ]
    }
  end

  test "开场白只包含初始可用信息" do
    greeting = VirtualCaller.greeting(scenario())
    assert greeting =~ "胸口疼"
    refute greeting =~ "滨河路"
    refute greeting =~ "高血压"
  end

  test "信息未释放时情绪化回避, 不泄露内容" do
    assert {:withheld, utterance, release} =
             VirtualCaller.answer(scenario(), MapSet.new(), "请问地址在哪里?")

    assert release.key == "address"
    refute utterance =~ "滨河路"
  end

  test "信息释放后按脚本作答" do
    released = MapSet.new(["address"])

    assert {:answer, utterance, _release} =
             VirtualCaller.answer(scenario(), released, "地址是哪里?")

    assert utterance =~ "滨河路128号"
  end

  test "未命中任何信息时给出通用求助回应" do
    assert {:unknown, utterance, nil} = VirtualCaller.answer(scenario(), MapSet.new(), "今天天气如何")
    assert is_binary(utterance)
  end

  test "情绪等级包装应答" do
    released = MapSet.new(["address"])
    {:answer, utterance, _} = VirtualCaller.answer(scenario(), released, "地址?")
    assert utterance =~ "哭腔"
  end

  test "关键词匹配忽略标点与空白" do
    release = %Scenario.InfoRelease{keywords: ["地址"]}
    assert VirtualCaller.question_matches?(release, "请 问 地 址？")
    refute VirtualCaller.question_matches?(release, "病人几岁了")
  end
end
