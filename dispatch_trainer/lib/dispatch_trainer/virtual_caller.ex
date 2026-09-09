defmodule DispatchTrainer.VirtualCaller do
  @moduledoc """
  虚拟来电端。

  依据场景脚本与“当前已释放的信息”生成来电者应答:

    * 学员提问命中某条未释放信息的关键词时, 来电者因情绪
      干扰而含糊回避(信息不全), 不主动给出内容
    * 信息已释放后, 来电者按脚本内容作答
    * 所有应答均来自场景脚本, 系统不对自然语言做医疗结论
  """

  alias DispatchTrainer.Scenarios.Scenario
  alias DispatchTrainer.Scenarios.Scenario.InfoRelease

  @deflections [
    "我……我不知道，我脑子一片乱，你们快点来吧！",
    "什么？我听不清……他看起来很难受，快派车！",
    "我说不清楚……求求你们快一点！"
  ]

  @fallbacks [
    "我不知道该怎么说……你能直接告诉我该怎么做吗？",
    "我现在很慌，你能再问一遍吗？"
  ]

  @doc "开场白: 只包含 initially_available 的信息。"
  def greeting(%Scenario{} = scenario) do
    initial =
      scenario.info_releases
      |> Enum.filter(& &1.initially_available)
      |> Enum.map(& &1.content)

    profile = scenario.caller_profile

    base =
      case initial do
        [] -> "喂？是急救中心吗？快来人啊！"
        parts -> "喂？是急救中心吗？" <> Enum.join(parts, " ")
      end

    emotional_wrap(profile, base)
  end

  @doc """
  回答学员提问。

  返回:
    * `{:answer, text, release}` — 信息已释放, 按脚本作答
    * `{:withheld, text, release}` — 命中未释放信息, 情绪化回避
    * `{:unknown, text, nil}` — 未命中任何脚本信息
  """
  def answer(%Scenario{} = scenario, released_keys, question) do
    case find_matching_release(scenario.info_releases, question) do
      %InfoRelease{} = release ->
        if MapSet.member?(released_keys, release.key) do
          {:answer, emotional_wrap(scenario.caller_profile, release.content), release}
        else
          {:withheld, emotional_wrap(scenario.caller_profile, deflection(release.key)), release}
        end

      nil ->
        {:unknown, emotional_wrap(scenario.caller_profile, fallback(question)), nil}
    end
  end

  @doc "提问是否命中某条信息释放的关键词。"
  def question_matches?(%InfoRelease{keywords: keywords}, question) do
    q = normalize_text(question)

    Enum.any?(keywords, fn kw ->
      kw != "" and String.contains?(q, normalize_text(kw))
    end)
  end

  @doc "分支触发后来电者的表现文本(情绪效果 + 释放内容)。"
  def branch_utterance(%Scenario{} = scenario, branch) do
    parts =
      [branch.emotion_effect, branch.reveal_content]
      |> Enum.reject(&(&1 in [nil, ""]))

    emotional_wrap(scenario.caller_profile, Enum.join(parts, " "))
  end

  defp find_matching_release(info_releases, question) do
    Enum.find(info_releases, &question_matches?(&1, question))
  end

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[\s　，。、,.?!？！!]/u, "")
  end

  defp normalize_text(_), do: ""

  defp deflection(key) do
    Enum.at(@deflections, :erlang.phash2(key, length(@deflections)))
  end

  defp fallback(question) do
    Enum.at(@fallbacks, :erlang.phash2(question, length(@fallbacks)))
  end

  defp emotional_wrap(%{emotion_level: level}, text), do: emotional_wrap(level, text)
  defp emotional_wrap(%Scenario{caller_profile: profile}, text), do: emotional_wrap(profile, text)

  defp emotional_wrap(level, text) do
    case level do
      "calm" -> text
      "anxious" -> "（声音发颤）" <> text
      "panicked" -> "（带着哭腔、语速很快）" <> text
      "hysterical" -> "（尖叫、语无伦次）" <> text
      _ -> text
    end
  end
end
