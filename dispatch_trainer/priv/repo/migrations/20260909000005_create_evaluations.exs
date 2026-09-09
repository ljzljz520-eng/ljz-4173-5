defmodule DispatchTrainer.Repo.Migrations.CreateEvaluations do
  use Ecto.Migration

  def change do
    create table(:evaluations) do
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :instructor_id, references(:users, on_delete: :restrict), null: false
      # 评分所依据的评分标准版本(快照)
      add :rubric_version, :integer, null: false
      add :items, {:array, :map}, null: false, default: []
      add :total_score, :integer, null: false, default: 0
      add :max_score, :integer, null: false, default: 0
      add :passed, :boolean
      add :notes, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:evaluations, [:session_id])
    create index(:evaluations, [:instructor_id])
  end
end
