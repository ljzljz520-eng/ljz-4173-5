defmodule DispatchTrainer.Sessions do
  @moduledoc "演练会话上下文: 会话生命周期与真实时间事件记录。"
  import Ecto.Query
  alias DispatchTrainer.Repo
  alias DispatchTrainer.Sessions.{Session, TimelineEvent}

  @pubsub DispatchTrainer.PubSub

  # ---- 会话 ----

  def list_sessions(filters \\ []) do
    Session
    |> maybe_filter(:trainee_id, filters[:trainee_id])
    |> maybe_filter(:instructor_id, filters[:instructor_id])
    |> maybe_filter(:status, filters[:status])
    |> order_by([s], desc: s.id)
    |> preload([:scenario, :trainee, :instructor])
    |> Repo.all()
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, field, value), do: where(query, [s], field(s, ^field) == ^value)

  def get_session!(id) do
    Session
    |> Repo.get!(id)
    |> Repo.preload([:scenario, :trainee, :instructor])
  end

  def create_session(attrs) do
    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

  def update_session(%Session{} = session, attrs) do
    session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  # ---- 时间线事件 ----

  @doc "按真实时间记录事件: at_ms 由调用方(通常为 SessionServer)基于单调时钟给出。"
  def log_event(%Session{id: session_id}, actor, kind, payload \\ %{}, at_ms) do
    %TimelineEvent{}
    |> TimelineEvent.changeset(%{
      session_id: session_id,
      actor: to_string(actor),
      kind: to_string(kind),
      payload: payload,
      at_ms: at_ms,
      wall_time: DateTime.utc_now()
    })
    |> Repo.insert()
    |> case do
      {:ok, event} ->
        broadcast(session_id, {:timeline_event, event})
        {:ok, event}

      error ->
        error
    end
  end

  def list_events(session_id) do
    Repo.all(
      from e in TimelineEvent,
        where: e.session_id == ^session_id,
        order_by: [asc: e.at_ms, asc: e.id]
    )
  end

  # ---- 订阅 ----

  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(session_id))
  end

  def broadcast(session_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, topic(session_id), message)
  end

  defp topic(session_id), do: "session:#{session_id}"
end
