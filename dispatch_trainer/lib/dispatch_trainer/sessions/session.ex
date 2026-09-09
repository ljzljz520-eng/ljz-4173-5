defmodule DispatchTrainer.Sessions.Session do
  @moduledoc """
  一次演练会话。状态机:
  scheduled → ringing → active ⇄ interrupted → ended | aborted
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(scheduled ringing active interrupted ended aborted)

  schema "sessions" do
    belongs_to :scenario, DispatchTrainer.Scenarios.Scenario
    belongs_to :trainee, DispatchTrainer.Accounts.User
    belongs_to :instructor, DispatchTrainer.Accounts.User

    field :status, :string, default: "scheduled"
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :interrupt_count, :integer, default: 0
    field :meta, :map, default: %{}

    has_many :timeline_events, DispatchTrainer.Sessions.TimelineEvent
    has_one :evaluation, DispatchTrainer.Evaluations.Evaluation
    has_one :recording, DispatchTrainer.Recordings.Recording

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :scenario_id,
      :trainee_id,
      :instructor_id,
      :status,
      :started_at,
      :ended_at,
      :interrupt_count,
      :meta
    ])
    |> validate_required([:scenario_id, :trainee_id, :instructor_id])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:scenario_id)
    |> foreign_key_constraint(:trainee_id)
    |> foreign_key_constraint(:instructor_id)
  end
end
