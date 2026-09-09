defmodule DispatchTrainer.Sessions.TimelineEvent do
  @moduledoc """
  会话时间线事件, 按真实时间记录。

  at_ms 为相对通话开始的单调毫秒偏移, wall_time 为墙上时钟,
  二者同时保存, 用于回放与评定核对。
  """
  use Ecto.Schema
  import Ecto.Changeset

  @actors ~w(trainee caller instructor system)
  @kinds ~w(question confirmation instruction info_release branch_trigger interrupt
            resume background_audio pii_mark note score system)

  schema "timeline_events" do
    belongs_to :session, DispatchTrainer.Sessions.Session

    field :at_ms, :integer
    field :wall_time, :utc_datetime_usec
    field :actor, :string
    field :kind, :string
    field :payload, :map, default: %{}

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def actors, do: @actors
  def kinds, do: @kinds

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:session_id, :at_ms, :wall_time, :actor, :kind, :payload])
    |> validate_required([:session_id, :at_ms, :wall_time, :actor, :kind])
    |> validate_inclusion(:actor, @actors)
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:at_ms, greater_than_or_equal_to: 0)
  end
end
