defmodule DispatchTrainer.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions) do
      add :scenario_id, references(:scenarios, on_delete: :restrict), null: false
      add :trainee_id, references(:users, on_delete: :restrict), null: false
      add :instructor_id, references(:users, on_delete: :restrict), null: false
      # scheduled | ringing | active | interrupted | ended | aborted
      add :status, :string, null: false, default: "scheduled"
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :interrupt_count, :integer, null: false, default: 0
      add :meta, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sessions, [:scenario_id])
    create index(:sessions, [:trainee_id])
    create index(:sessions, [:instructor_id])
    create index(:sessions, [:status])
  end
end
