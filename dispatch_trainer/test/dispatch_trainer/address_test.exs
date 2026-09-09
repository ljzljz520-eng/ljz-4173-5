defmodule DispatchTrainer.AddressTest do
  @moduledoc "地址同音: 同音不同字必须触发逐字确认, 系统不做自动医疗结论。"
  use ExUnit.Case, async: true

  alias DispatchTrainer.Address

  describe "normalize/1" do
    test "去除空白与标点" do
      assert Address.normalize("滨河路 128 号，3栋") == "滨河路128号3栋"
    end

    test "全角数字转半角" do
      assert Address.normalize("滨河路１２８号") == "滨河路128号"
    end
  end

  describe "compare/2" do
    test "完全一致" do
      assert %{result: :match, conflicts: [], diffs: []} =
               Address.compare("滨河路128号", "滨河路128号")
    end

    test "同音不同字: 河/和 → 同音冲突" do
      assert %{result: :homophone_conflict, conflicts: [%{expected: "河", actual: "和"}]} =
               Address.compare("滨河路128号", "滨和路128号")
    end

    test "同音不同字: 江/疆 → 同音冲突" do
      assert %{result: :homophone_conflict} = Address.compare("长江路5号", "长疆路5号")
    end

    test "发音不同: 河/海 → 不匹配" do
      assert %{result: :mismatch, diffs: [%{expected: "河", actual: "海"}]} =
               Address.compare("滨河路", "滨海路")
    end

    test "门牌号数字不同 → 不匹配" do
      assert %{result: :mismatch} = Address.compare("滨河路128号", "滨河路182号")
    end

    test "长度不一致时缺失部分计为差异" do
      assert %{result: :mismatch, diffs: diffs} = Address.compare("滨河路128号", "滨河路12")
      assert Enum.any?(diffs, &(&1.actual == nil))
    end

    test "标点与空白差异不影响比对" do
      assert %{result: :match} = Address.compare("滨河路128号", "滨河路 128 号。")
    end
  end

  describe "requires_readback?/2" do
    test "同音冲突需要逐字确认" do
      assert Address.requires_readback?("滨河路128号", "滨和路128号")
      assert Address.requires_readback?("长江路", "长疆路")
    end

    test "完全一致不需要" do
      refute Address.requires_readback?("滨河路128号", "滨河路128号")
    end

    test "纯发音差异不属于同音确认问题" do
      refute Address.requires_readback?("滨河路", "滨海路")
    end
  end

  describe "homophone?/2" do
    test "同组字互为同音" do
      assert Address.homophone?("河", "和")
      assert Address.homophone?("江", "疆")
      assert Address.homophone?("路", "露")
    end

    test "不同组不算同音" do
      refute Address.homophone?("河", "海")
      refute Address.homophone?("河", "路")
    end
  end
end
