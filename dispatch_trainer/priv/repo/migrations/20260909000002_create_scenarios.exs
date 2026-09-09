defmodule DispatchTrainer.Repo.Migrations.CreateScenarios do
  use Ecto.Migration

  def change do
    create table(:scenarios) do
      add :code, :string, null: false
      add :title, :string, null: false
      add :description, :text
      add :difficulty, :string, null: false, default: "standard"
      # 真实地址与同音干扰变体(学员不可见)
      add :true_address, :string
      add :address_variants, {:array, :string}, null: false, default: []
      add :caller_profile, :map, null: false, default: %{}
      add :background_audios, {:array, :map}, null: false, default: []
      add :info_releases, {:array, :map}, null: false, default: []
      add :branches, {:array, :map}, null: false, default: []
      add :hidden_conditions, {:array, :map}, null: false, default: []
      add :rubric_items, {:array, :map}, null: false, default: []
      add :rubric_version, :integer, null: false, default: 1
      add :published, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scenarios, [:code])
  end
end
