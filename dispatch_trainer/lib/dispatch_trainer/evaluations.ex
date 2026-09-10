defmodule DispatchTrainer.Evaluations do
  @moduledoc """
  评定上下文。

  评分完全由教员依据评分标准逐项录入; 系统不对自然语言
  内容自动给出医疗结论, 仅做分数汇总与通过判定。
  """
  import Ecto.Query
  alias DispatchTrainer.Repo
  alias DispatchTrainer.Accounts.User
  alias DispatchTrainer.Evaluations.Evaluation
  alias DispatchTrainer.Sessions.Session

  @pass_ratio 0.6

  def get_evaluation_for_session(session_id) do
    Repo.get_by(Evaluation, session_id: session_id)
  end

  def list_evaluations_for_instructor(instructor_id) do
    Repo.all(
      from e in Evaluation,
        where: e.instructor_id == ^instructor_id,
        order_by: [desc: e.id],
        preload: [:session]
    )
  end

  @doc """
  逐项评分。`scores` 形如:

      %{"confirm_address" => %{"score" => 8, "comment" => "复述完整"}, ...}

  校验: 每个评分项必须给出分数, 分数在 0..max_points 之间。
  通过条件: 所有必评(required)项得分大于 0, 且总分不低于满分 60%。
  """
  def score_session(%User{} = instructor, %Session{} = session, scores, notes \\ nil)
      when is_map(scores) do
    session = Repo.preload(session, :scenario)
    rubric = session.scenario.rubric_items

    with :ok <- authorize_instructor(instructor, session),
         :ok <- validate_scores(rubric, scores) do
      items =
        Enum.map(rubric, fn item ->
          entry = scores[item.key] || %{}

          %{
            "key" => item.key,
            "category" => item.category,
            "description" => item.description,
            "max_points" => item.max_points,
            "required" => item.required,
            "score" => to_score(entry["score"] || entry[:score]),
            "comment" => entry["comment"] || entry[:comment]
          }
        end)

      total = items |> Enum.map(& &1["score"]) |> Enum.sum()
      max_score = rubric |> Enum.map(& &1.max_points) |> Enum.sum()

      passed =
        Enum.all?(items, fn item ->
          not item["required"] or item["score"] > 0
        end) and total >= ceil(max_score * @pass_ratio)

      attrs = %{
        session_id: session.id,
        instructor_id: instructor.id,
        rubric_version: session.scenario.rubric_version,
        items: items,
        total_score: total,
        max_score: max_score,
        passed: passed,
        notes: notes
      }

      case get_evaluation_for_session(session.id) do
        nil ->
          %Evaluation{}
          |> Evaluation.changeset(attrs)
          |> Repo.insert()

        %Evaluation{} = existing ->
          existing
          |> Evaluation.changeset(attrs)
          |> Repo.update()
      end
      |> case do
        {:ok, _evaluation} = ok ->
          DispatchTrainer.Sessions.log_event(
            session,
            "instructor",
            "score",
            %{"total_score" => total, "max_score" => max_score, "passed" => passed},
            elapsed_ms(session)
          )

          ok

        error ->
          error
      end
    end
  end

  # 仅主持教员本人或管理员可为会话评分
  defp authorize_instructor(%User{id: id}, %Session{instructor_id: id}), do: :ok
  defp authorize_instructor(%User{role: "admin"}, %Session{}), do: :ok
  defp authorize_instructor(%User{}, %Session{}), do: {:error, :forbidden}

  defp validate_scores(rubric, scores) do
    errors =
      Enum.flat_map(rubric, fn item ->
        entry = scores[item.key]

        cond do
          entry == nil ->
            ["评分项 #{item.key} 缺少分数"]

          to_score(entry["score"] || entry[:score]) == nil ->
            ["评分项 #{item.key} 分数无效"]

          to_score(entry["score"] || entry[:score]) not in 0..item.max_points ->
            ["评分项 #{item.key} 分数须在 0..#{item.max_points} 之间"]

          true ->
            []
        end
      end)

    case errors do
      [] -> :ok
      _ -> {:error, {:invalid_scores, errors}}
    end
  end

  defp to_score(nil), do: nil
  defp to_score(v) when is_integer(v), do: v

  defp to_score(v) when is_binary(v) do
    case Integer.parse(v) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_score(_), do: nil

  defp elapsed_ms(%Session{started_at: nil}), do: 0

  defp elapsed_ms(%Session{started_at: started}) do
    max(DateTime.diff(DateTime.utc_now(), started, :millisecond), 0)
  end
end
