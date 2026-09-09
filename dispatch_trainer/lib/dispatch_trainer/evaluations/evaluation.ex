defmodule DispatchTrainer.Evaluations.Evaluation do
  @moduledoc """
  教员对一次会话的逐项评分。

  items 为评分时的标准快照(含 rubric_version), 场景标准
  后续修订不影响已完成的评定。
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "evaluations" do
    belongs_to :session, DispatchTrainer.Sessions.Session
    belongs_to :instructor, DispatchTrainer.Accounts.User

    field :rubric_version, :integer
    field :items, {:array, :map}, default: []
    field :total_score, :integer, default: 0
    field :max_score, :integer, default: 0
    field :passed, :boolean
    field :notes, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(evaluation, attrs) do
    evaluation
    |> cast(attrs, [
      :session_id,
      :instructor_id,
      :rubric_version,
      :items,
      :total_score,
      :max_score,
      :passed,
      :notes
    ])
    |> validate_required([:session_id, :instructor_id, :rubric_version, :items])
    |> unique_constraint(:session_id)
  end
end
