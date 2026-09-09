defmodule DispatchTrainer.EvaluationsTest do
  @moduledoc "评定: 教员依据标准版本逐项评分; 系统只汇总, 不做自动医疗结论。"
  use DispatchTrainer.DataCase, async: false

  import DispatchTrainer.SessionHelpers

  alias DispatchTrainer.Evaluations

  setup do
    session = session_fixture()
    session = DispatchTrainer.Sessions.get_session!(session.id)
    instructor = DispatchTrainer.Accounts.get_user!(session.instructor_id)
    %{session: session, instructor: instructor}
  end

  test "逐项评分成功并快照标准版本", %{session: session, instructor: instructor} do
    scores = %{
      "confirm_address" => %{"score" => 18, "comment" => "逐字复述"},
      "identify_danger" => %{"score" => 15},
      "instruct" => %{"score" => 12}
    }

    assert {:ok, evaluation} = Evaluations.score_session(instructor, session, scores, "总体良好")
    assert evaluation.rubric_version == session.scenario.rubric_version
    assert evaluation.total_score == 45
    assert evaluation.max_score == 60
    assert evaluation.passed
    assert length(evaluation.items) == 3

    item = Enum.find(evaluation.items, &(&1["key"] == "confirm_address"))
    assert item["score"] == 18
    assert item["comment"] == "逐字复述"
    assert item["category"] == "location"
  end

  test "缺少任一评分项被拒绝(必须逐项)", %{session: session, instructor: instructor} do
    scores = %{"confirm_address" => %{"score" => 10}}

    assert {:error, {:invalid_scores, messages}} =
             Evaluations.score_session(instructor, session, scores)

    assert Enum.any?(messages, &String.contains?(&1, "identify_danger"))
  end

  test "分数超出范围被拒绝", %{session: session, instructor: instructor} do
    scores = %{
      "confirm_address" => %{"score" => 99},
      "identify_danger" => %{"score" => 10},
      "instruct" => %{"score" => 5}
    }

    assert {:error, {:invalid_scores, messages}} =
             Evaluations.score_session(instructor, session, scores)

    assert Enum.any?(messages, &String.contains?(&1, "0..20"))
  end

  test "必评项为 0 则不通过", %{session: session, instructor: instructor} do
    scores = %{
      "confirm_address" => %{"score" => 0},
      "identify_danger" => %{"score" => 20},
      "instruct" => %{"score" => 20}
    }

    assert {:ok, evaluation} = Evaluations.score_session(instructor, session, scores)
    refute evaluation.passed
  end

  test "总分低于 60% 不通过", %{session: session, instructor: instructor} do
    scores = %{
      "confirm_address" => %{"score" => 10},
      "identify_danger" => %{"score" => 10},
      "instruct" => %{"score" => 5}
    }

    assert {:ok, evaluation} = Evaluations.score_session(instructor, session, scores)
    # 25/60 < 60%
    refute evaluation.passed
  end

  test "重复评分更新同一会话的评定", %{session: session, instructor: instructor} do
    scores = %{
      "confirm_address" => %{"score" => 10},
      "identify_danger" => %{"score" => 10},
      "instruct" => %{"score" => 10}
    }

    assert {:ok, first} = Evaluations.score_session(instructor, session, scores)

    updated_scores = put_in(scores, ["confirm_address", "score"], 20)
    assert {:ok, second} = Evaluations.score_session(instructor, session, updated_scores)
    assert second.id == first.id
    assert second.total_score == 40
  end

  test "评分完成后在时间线记录 score 事件", %{session: session, instructor: instructor} do
    scores = %{
      "confirm_address" => %{"score" => 20},
      "identify_danger" => %{"score" => 20},
      "instruct" => %{"score" => 20}
    }

    {:ok, _} = Evaluations.score_session(instructor, session, scores)

    events = DispatchTrainer.Sessions.list_events(session.id)
    assert Enum.any?(events, &(&1.kind == "score" and &1.payload["total_score"] == 60))
  end
end
