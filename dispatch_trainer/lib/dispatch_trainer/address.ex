defmodule DispatchTrainer.Address do
  @moduledoc """
  地址规范化与同音字比对。

  报警电话中, 学员听到的地址可能与真实地址同音不同字
  (如“滨河路”与“滨和路”)。系统比对学员复述的地址,
  发现同音冲突时要求逐字确认(phonetic read-back),
  仅提示确认需求, 不做任何医疗结论。
  """

  # 常见地址用字同音分组(每组内字互为同音字)。每个字只出现于一个分组。
  @homophone_groups [
    "滨彬宾斌", "河和何合荷", "路露陆录", "长常昌", "江疆姜将", "东冬栋",
    "新欣心信", "平萍坪", "山杉珊", "金津今巾", "阳洋杨扬", "南楠",
    "北贝倍", "海亥", "龙隆笼", "凤奉", "华花化画", "明鸣铭",
    "清青轻", "秀绣袖", "文闻纹", "武五伍", "中忠终钟", "兴星幸",
    "安岸按", "福富府", "建健剑", "民闽敏", "永勇涌", "泰太台",
    "古谷鼓", "林临邻", "石时实", "西溪希", "湖胡虎", "桥乔",
    "园圆源元", "城成诚程", "丰风峰枫", "云芸", "红洪宏虹", "白百柏",
    "黄皇", "周洲舟", "吴梧", "郑正政", "王汪", "李里理",
    "张章", "刘流柳", "陈沉", "马麻", "罗锣", "梁粮",
    "宋松", "唐塘", "韩寒", "高糕", "街阶", "巷向",
    "区曲", "县线", "镇振", "庄装", "湾弯", "道到",
    "岭领", "岗钢", "寺四", "观官", "庙妙", "塔獭"
  ]

  @homophone_index (
                     for {group, idx} <- Enum.with_index(@homophone_groups),
                         <<cp::utf8>> <- String.graphemes(group),
                         into: %{} do
                       {cp, idx}
                     end
                   )

  @doc "去除空白与常见标点, 统一全角数字为半角, 便于逐字比对。"
  def normalize(address) when is_binary(address) do
    address
    |> String.replace(~r/[\s　，。、,.\-·#()（）【】\[\]"'"]/u, "")
    |> String.replace(~r/[０-９]/u, fn <<c::utf8>> -> <<c - 0xFF10 + 0x30>> end)
  end

  def normalize(_), do: ""

  @doc """
  逐字比对真实地址与学员复述地址。

  返回 `%{result, conflicts, diffs}`:
    * `:match` — 完全一致
    * `:homophone_conflict` — 仅存在同音不同字, 需逐字确认
    * `:mismatch` — 存在发音不同的差异
  """
  def compare(expected, actual) do
    exp = expected |> normalize() |> String.graphemes()
    act = actual |> normalize() |> String.graphemes()
    len = max(length(exp), length(act))

    {conflicts, diffs} =
      0..(len - 1)//1
      |> Enum.reduce({[], []}, fn i, {conf, diff} ->
        e = Enum.at(exp, i)
        a = Enum.at(act, i)

        cond do
          e == a ->
            {conf, diff}

          e != nil and a != nil and homophone?(e, a) ->
            {[%{position: i, expected: e, actual: a} | conf], diff}

          true ->
            {conf, [%{position: i, expected: e, actual: a} | diff]}
        end
      end)

    conflicts = Enum.reverse(conflicts)
    diffs = Enum.reverse(diffs)

    result =
      cond do
        conflicts == [] and diffs == [] -> :match
        diffs == [] -> :homophone_conflict
        true -> :mismatch
      end

    %{result: result, conflicts: conflicts, diffs: diffs}
  end

  @doc "复述地址与真实地址存在同音不同字时, 必须逐字确认。"
  def requires_readback?(expected, actual) do
    compare(expected, actual).conflicts != []
  end

  @doc "两个汉字是否同音(属于同一同音分组)。"
  def homophone?(<<c1::utf8>>, <<c2::utf8>>) do
    k1 = Map.get(@homophone_index, c1)
    k2 = Map.get(@homophone_index, c2)
    k1 != nil and k1 == k2
  end

  def homophone?(_, _), do: false
end
