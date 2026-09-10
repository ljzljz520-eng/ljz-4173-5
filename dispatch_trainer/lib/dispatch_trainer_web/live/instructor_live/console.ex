defmodule DispatchTrainerWeb.InstructorLive.Console do
  @moduledoc """
  教员控制台。

  实时展示通话状态与时间线(提问/确认/指令/释放/中断),
  提供信息释放、分支触发、来电中断/恢复、背景声控制,
  通话结束后依据评分标准逐项评分。隐藏条件仅在此页可见。
  """
  use DispatchTrainerWeb, :live_view

  alias DispatchTrainer.{Accounts, Evaluations, Sessions}
  alias DispatchTrainer.Sessions.{Session, SessionServer}

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    session = Sessions.get_session!(session_id)
    user = socket.assigns.current_user

    if owns_session?(user, session) do
      {:ok, server} = SessionServer.ensure_started(session.id)

      if connected?(socket), do: Sessions.subscribe(session.id)

      events = Sessions.list_events(session.id)
      evaluation = Evaluations.get_evaluation_for_session(session.id)

      socket =
        socket
        |> assign(:page_title, "演练控制台 ##{session.id}")
        |> assign(:session, session)
        |> assign(:scenario, session.scenario)
        |> assign(:server, server)
        |> assign(:server_state, server_state(server))
        |> assign(:evaluation, evaluation)
        |> assign(:score_form, to_form(%{}, as: :scores))
        |> stream(:events, Enum.reverse(events))

      if connected?(socket) and session.status in ["active", "interrupted"] do
        :timer.send_interval(1000, self(), :tick)
      end

      {:ok, socket}
    else
      socket =
        socket
        |> put_flash(:error, "无权操作该演练会话。")
        |> redirect(to: ~p"/instructor")

      {:ok, socket}
    end
  end

  # 仅主持教员本人或管理员可查看/操作会话
  defp owns_session?(%Accounts.User{id: id}, %Session{instructor_id: id}), do: true
  defp owns_session?(%Accounts.User{} = user, %Session{}), do: Accounts.User.admin?(user)

  # ---- 控制事件 ----

  @impl true
  def handle_event("join_call", _params, socket) do
    :ok = SessionServer.join_call(socket.assigns.server)
    {:noreply, refresh(socket)}
  end

  def handle_event("release_info", %{"key" => key}, socket) do
    case SessionServer.release_info(socket.assigns.server, key) do
      {:ok, _} -> {:noreply, refresh(socket)}
      {:error, :already_released} -> {:noreply, put_flash(socket, :info, "该信息已释放")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "释放失败")}
    end
  end

  def handle_event("trigger_branch", %{"key" => key}, socket) do
    case SessionServer.trigger_branch(socket.assigns.server, key) do
      {:ok, _} -> {:noreply, refresh(socket)}
      {:error, :already_triggered} -> {:noreply, put_flash(socket, :info, "分支已触发过")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "触发失败")}
    end
  end

  def handle_event("interrupt", _params, socket) do
    SessionServer.interrupt(socket.assigns.server)
    {:noreply, refresh(socket)}
  end

  def handle_event("resume", _params, socket) do
    SessionServer.resume(socket.assigns.server)
    {:noreply, refresh(socket)}
  end

  def handle_event("end_call", _params, socket) do
    case SessionServer.end_call(socket.assigns.server) do
      {:ok, _recording} -> {:noreply, refresh(socket)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("background_audio", %{"key" => key}, socket) do
    case SessionServer.play_background(socket.assigns.server, key) do
      {:ok, _audio} -> {:noreply, refresh(socket)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "背景声播放失败")}
    end
  end

  def handle_event("mark_pii", %{"label" => label}, socket) do
    at = elapsed(socket.assigns.session)

    {:ok, _} =
      Sessions.log_event(socket.assigns.session, "instructor", "pii_mark", %{
        "label" => label,
        "start_ms" => max(at - 5_000, 0),
        "end_ms" => at
      }, at)

    {:noreply, put_flash(socket, :info, "已标记敏感片段")}
  end

  def handle_event("save_scores", %{"scores" => scores} = params, socket) do
    instructor = socket.assigns.current_user
    session = socket.assigns.session
    notes = params["notes"]

    case Evaluations.score_session(instructor, session, scores, notes) do
      {:ok, evaluation} ->
        {:noreply,
         socket
         |> assign(:evaluation, evaluation)
         |> put_flash(:info, "评分已保存")}

      {:error, {:invalid_scores, messages}} ->
        {:noreply, put_flash(socket, :error, Enum.join(messages, "；"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "保存失败")}
    end
  end

  # ---- 实时推送 ----

  @impl true
  def handle_info({:timeline_event, event}, socket) do
    {:noreply, stream_insert(socket, :events, event, at: 0)}
  end

  def handle_info({:call_state, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:info_released, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:branch_triggered, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info(:tick, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh(socket) do
    session = Sessions.get_session!(socket.assigns.session.id)

    socket
    |> assign(:session, session)
    |> assign(:server_state, server_state(socket.assigns.server))
    |> assign(:evaluation, Evaluations.get_evaluation_for_session(session.id))
  end

  defp server_state(server) do
    if Process.alive?(server), do: SessionServer.state(server), else: nil
  end

  defp elapsed(%{started_at: nil}), do: 0

  defp elapsed(%{started_at: started}) do
    max(DateTime.diff(DateTime.utc_now(), started, :millisecond), 0)
  end

  defp released?(nil, _key), do: false
  defp released?(state, key), do: MapSet.member?(state.released, key)

  defp triggered?(nil, _key), do: false
  defp triggered?(state, key), do: MapSet.member?(state.triggered, key)

  defp format_ms(nil), do: "--:--"

  defp format_ms(ms) when is_integer(ms) do
    minutes = div(ms, 60_000)
    seconds = div(rem(ms, 60_000), 1000)
    :io_lib.format("~2..0B:~2..0B", [minutes, seconds]) |> IO.iodata_to_binary()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl px-4 py-6">
      <header class="flex items-center justify-between mb-4">
        <div>
          <h1 class="text-xl font-bold">演练控制台 · {@scenario.title}</h1>
          <p class="text-sm text-zinc-500">
            学员: {@session.trainee.display_name || @session.trainee.username} ·
            状态: <span class="font-mono">{@session.status}</span> ·
            用时: <span class="font-mono">{format_ms(@server_state && @server_state.elapsed_ms)}</span> ·
            中断: {@session.interrupt_count} 次
          </p>
        </div>
        <div class="space-x-2">
          <.button :if={@session.status in ["scheduled", "ringing"]} phx-click="join_call">接通</.button>
          <.button :if={@session.status == "active"} phx-click="interrupt" class="bg-amber-600">来电中断</.button>
          <.button :if={@session.status == "interrupted"} phx-click="resume" class="bg-green-600">恢复通话</.button>
          <.button :if={@session.status in ["active", "interrupted"]} phx-click="end_call" class="bg-red-600">
            结束通话
          </.button>
        </div>
      </header>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <div class="space-y-6">
          <section class="border rounded p-4">
            <h2 class="font-semibold mb-2">来电者</h2>
            <p class="text-sm">
              {@scenario.caller_profile.name}（{@scenario.caller_profile.role}）·
              情绪: {@scenario.caller_profile.emotion_level}
            </p>
            <p class="text-sm text-zinc-500">真实地址(学员不可见): {@scenario.true_address}</p>
          </section>

          <section class="border rounded p-4 bg-amber-50">
            <h2 class="font-semibold mb-2">隐藏条件(仅教员)</h2>
            <ul class="list-disc pl-5 text-sm space-y-1">
              <li :for={condition <- @scenario.hidden_conditions}>
                <strong>{condition.label}</strong> — {condition.detail}
              </li>
            </ul>
          </section>

          <section class="border rounded p-4">
            <h2 class="font-semibold mb-2">信息释放</h2>
            <ul class="space-y-2">
              <li :for={release <- @scenario.info_releases} class="flex items-center justify-between text-sm">
                <span>
                  {release.label}
                  <span class="text-xs text-zinc-400">
                    ({release.trigger_type})
                  </span>
                </span>
                <span :if={released?(@server_state, release.key)} class="text-green-600 text-xs">已释放</span>
                <button
                  :if={not released?(@server_state, release.key)}
                  phx-click="release_info"
                  phx-value-key={release.key}
                  class="rounded bg-indigo-600 px-2 py-1 text-white text-xs"
                >
                  释放
                </button>
              </li>
            </ul>
          </section>

          <section class="border rounded p-4">
            <h2 class="font-semibold mb-2">病情分支</h2>
            <ul class="space-y-2">
              <li :for={branch <- @scenario.branches} class="flex items-center justify-between text-sm">
                <span>{branch.label}</span>
                <span :if={triggered?(@server_state, branch.key) and not branch.repeatable} class="text-green-600 text-xs">
                  已触发
                </span>
                <button
                  :if={branch.repeatable or not triggered?(@server_state, branch.key)}
                  phx-click="trigger_branch"
                  phx-value-key={branch.key}
                  class="rounded bg-rose-600 px-2 py-1 text-white text-xs"
                >
                  触发
                </button>
              </li>
            </ul>
          </section>

          <section class="border rounded p-4">
            <h2 class="font-semibold mb-2">背景声</h2>
            <div class="flex flex-wrap gap-2">
              <button
                :for={audio <- @scenario.background_audios}
                phx-click="background_audio"
                phx-value-key={audio.key}
                class="rounded border px-2 py-1 text-xs"
              >
                {audio.label}
              </button>
            </div>
            <div class="mt-3">
              <button phx-click="mark_pii" phx-value-label="address" class="rounded border px-2 py-1 text-xs">
                标记敏感片段(地址)
              </button>
            </div>
          </section>
        </div>

        <div class="lg:col-span-2 space-y-6">
          <section class="border rounded p-4">
            <h2 class="font-semibold mb-2">实时时间线</h2>
            <ul id="timeline" phx-update="stream" class="space-y-1 text-sm max-h-96 overflow-y-auto">
              <li :for={{dom_id, event} <- @streams.events} id={dom_id} class="flex gap-2">
                <span class="font-mono text-zinc-400 w-14 shrink-0">{format_ms(event.at_ms)}</span>
                <span class="w-20 shrink-0 text-zinc-500">{event.actor}</span>
                <span>
                  <span class="font-medium">{event.kind}</span>
                  <span class="text-zinc-600"> {inspect_payload(event.payload)}</span>
                </span>
              </li>
            </ul>
          </section>

          <section :if={@session.status == "ended"} class="border rounded p-4">
            <h2 class="font-semibold mb-2">
              逐项评分(标准版本 v{@scenario.rubric_version})
            </h2>
            <.form for={@score_form} phx-submit="save_scores" class="space-y-3">
              <div :for={item <- @scenario.rubric_items} class="border-b pb-3">
                <div class="flex items-center justify-between">
                  <label class="text-sm font-medium">
                    {item.description}
                    <span class="text-xs text-zinc-400">
                      [{item.category}] 满分 {item.max_points}{item.required && " · 必评"}
                    </span>
                  </label>
                  <input
                    type="number"
                    name={"scores[#{item.key}][score]"}
                    min="0"
                    max={item.max_points}
                    value={current_score(@evaluation, item.key)}
                    class="w-20 rounded border-zinc-300 text-sm"
                  />
                </div>
                <input
                  type="text"
                  name={"scores[#{item.key}][comment]"}
                  placeholder="评语"
                  value={current_comment(@evaluation, item.key)}
                  class="mt-1 w-full rounded border-zinc-300 text-sm"
                />
              </div>
              <input type="text" name="notes" placeholder="总评" class="w-full rounded border-zinc-300 text-sm" />
              <.button>保存评分</.button>
              <p :if={@evaluation} class="text-sm text-zinc-600">
                当前总分: {@evaluation.total_score}/{@evaluation.max_score} ·
                {if @evaluation.passed, do: "通过", else: "未通过"}
              </p>
            </.form>
          </section>
        </div>
      </div>
    </div>
    """
  end

  defp inspect_payload(payload) when map_size(payload) == 0, do: ""
  defp inspect_payload(payload), do: Jason.encode!(payload)

  defp current_score(nil, _key), do: nil

  defp current_score(evaluation, key) do
    case Enum.find(evaluation.items, &(&1["key"] == key)) do
      nil -> nil
      item -> item["score"]
    end
  end

  defp current_comment(nil, _key), do: nil

  defp current_comment(evaluation, key) do
    case Enum.find(evaluation.items, &(&1["key"] == key)) do
      nil -> nil
      item -> item["comment"]
    end
  end
end
