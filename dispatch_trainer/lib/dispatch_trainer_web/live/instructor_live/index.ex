defmodule DispatchTrainerWeb.InstructorLive.Index do
  @moduledoc "教员首页: 场景与学员选择、会话发起、历史会话列表。"
  use DispatchTrainerWeb, :live_view

  alias DispatchTrainer.{Accounts, Scenarios, Sessions}

  @impl true
  def mount(_params, _session, socket) do
    instructor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "教员控制台")
     |> assign(:scenarios, Scenarios.list_published_scenarios())
     |> assign(:trainees, Accounts.list_trainees())
     |> assign(:sessions, Sessions.list_sessions(instructor_id: instructor.id))
     |> assign(:selected_scenario, nil)
     |> assign(:selected_trainee, nil)}
  end

  @impl true
  def handle_event("start_session", %{"scenario" => scenario_id, "trainee" => trainee_id}, socket) do
    instructor = socket.assigns.current_user

    case Sessions.create_session(%{
           scenario_id: scenario_id,
           trainee_id: trainee_id,
           instructor_id: instructor.id
         }) do
      {:ok, session} ->
        {:noreply, push_navigate(socket, to: ~p"/instructor/sessions/#{session.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "创建会话失败。")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl px-4 py-8">
      <h1 class="text-2xl font-bold mb-6">教员控制台</h1>

      <section class="mb-10">
        <h2 class="text-lg font-semibold mb-3">发起演练</h2>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div>
            <h3 class="font-medium mb-2">选择场景</h3>
            <ul class="space-y-2">
              <li :for={scenario <- @scenarios} class="border rounded p-3">
                <div class="font-semibold">{scenario.title}</div>
                <div class="text-sm text-zinc-500">{scenario.description}</div>
                <div class="text-xs text-zinc-400 mt-1">
                  评分标准 v{scenario.rubric_version} · 难度 {scenario.difficulty}
                </div>
              </li>
            </ul>
          </div>
          <div>
            <h3 class="font-medium mb-2">选择学员并发起</h3>
            <ul class="space-y-2">
              <li :for={trainee <- @trainees} class="border rounded p-3 flex items-center justify-between">
                <span>{trainee.display_name || trainee.username}</span>
                <span :for={scenario <- @scenarios}>
                  <button
                    :if={scenario == hd(@scenarios)}
                    phx-click="start_session"
                    phx-value-scenario={scenario.id}
                    phx-value-trainee={trainee.id}
                    class="rounded bg-indigo-600 px-3 py-1 text-white text-sm"
                  >
                    以「{scenario.title}」发起
                  </button>
                </span>
              </li>
            </ul>
          </div>
        </div>
      </section>

      <section>
        <h2 class="text-lg font-semibold mb-3">我的会话</h2>
        <table class="w-full text-sm">
          <thead>
            <tr class="text-left border-b">
              <th class="py-2">编号</th><th>场景</th><th>学员</th><th>状态</th><th>开始时间</th><th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={session <- @sessions} class="border-b">
              <td class="py-2">{session.id}</td>
              <td>{session.scenario.title}</td>
              <td>{session.trainee.display_name || session.trainee.username}</td>
              <td><.status_badge status={session.status} /></td>
              <td>{session.started_at && Calendar.strftime(session.started_at, "%H:%M:%S")}</td>
              <td>
                <.link navigate={~p"/instructor/sessions/#{session.id}"} class="text-indigo-600">
                  控制台
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-block rounded px-2 py-0.5 text-xs",
      @status == "active" && "bg-green-100 text-green-800",
      @status == "interrupted" && "bg-amber-100 text-amber-800",
      @status == "ended" && "bg-zinc-200 text-zinc-700",
      @status in ["scheduled", "ringing"] && "bg-blue-100 text-blue-800"
    ]}>
      {@status}
    </span>
    """
  end
end
