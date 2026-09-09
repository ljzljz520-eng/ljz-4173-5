defmodule DispatchTrainer.Scenarios do
  @moduledoc "场景脚本上下文。"
  import Ecto.Query
  alias DispatchTrainer.Repo
  alias DispatchTrainer.Scenarios.Scenario

  def list_scenarios do
    Repo.all(from s in Scenario, order_by: [asc: s.id])
  end

  def list_published_scenarios do
    Repo.all(from s in Scenario, where: s.published, order_by: [asc: s.id])
  end

  def get_scenario!(id), do: Repo.get!(Scenario, id)

  def create_scenario(attrs) do
    %Scenario{}
    |> Scenario.changeset(attrs)
    |> Repo.insert()
  end

  def update_scenario(%Scenario{} = scenario, attrs) do
    scenario
    |> Scenario.changeset(attrs)
    |> Repo.update()
  end

  def change_scenario(%Scenario{} = scenario, attrs \\ %{}) do
    Scenario.changeset(scenario, attrs)
  end
end
