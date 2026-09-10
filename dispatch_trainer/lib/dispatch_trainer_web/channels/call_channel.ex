defmodule DispatchTrainerWeb.CallChannel do
  @moduledoc """
  通话频道: Opus 音频经 WebSocket 二进制帧传输,
  控制消息(中断/恢复/释放/分支/结束)为 JSON 事件。
  """
  use Phoenix.Channel

  alias DispatchTrainer.{Accounts, Sessions}
  alias DispatchTrainer.Sessions.SessionServer
  alias DispatchTrainer.Audio.Packet

  @loggable_kinds ~w(question confirmation instruction)

  @impl true
  def join("call:" <> session_id, _payload, socket) do
    user = Accounts.get_user(socket.assigns.user_id)
    session = Sessions.get_session!(session_id)

    if authorized?(user, session) do
      {:ok, server} = SessionServer.ensure_started(session.id)
      :ok = SessionServer.join_call(server)
      Sessions.subscribe(session.id)

      {:ok,
       socket
       |> assign(:session_id, session.id)
       |> assign(:server, server)
       |> assign(:user, user)}
    else
      {:error, %{reason: "forbidden"}}
    end
  end

  # ---- 音频: Opus 二进制帧 ----

  @impl true
  def handle_in("audio", {:binary, data}, socket) do
    with {:ok, %Packet{} = packet} <- Packet.decode(data),
         :ok <- SessionServer.audio_packet(socket.assigns.server, packet) do
      # 转发给通话对端
      broadcast_from!(socket, "audio", {:binary, data})
      {:noreply, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  # ---- 控制事件 ----

  # 中断/恢复/释放/分支/结束均为“教员控制动作”, 学员加入通话后也无权执行

  def handle_in("interrupt", _payload, socket) do
    guard_instructor(socket, fn ->
      reply_result(SessionServer.interrupt(socket.assigns.server, actor(socket)), socket)
    end)
  end

  def handle_in("resume", _payload, socket) do
    guard_instructor(socket, fn ->
      reply_result(SessionServer.resume(socket.assigns.server, actor(socket)), socket)
    end)
  end

  def handle_in("release_info", %{"key" => key}, socket) do
    guard_instructor(socket, fn ->
      reply_result(SessionServer.release_info(socket.assigns.server, key, actor(socket)), socket)
    end)
  end

  def handle_in("trigger_branch", %{"key" => key}, socket) do
    guard_instructor(socket, fn ->
      reply_result(SessionServer.trigger_branch(socket.assigns.server, key, actor(socket)), socket)
    end)
  end

  def handle_in("log", %{"kind" => kind, "payload" => payload}, socket)
      when kind in @loggable_kinds do
    # 学员只能以 trainee 身份记录自己的提问/确认/指令, 无其他控制动作
    with :ok <- permit_log(socket, kind) do
      reply_result(SessionServer.log(socket.assigns.server, actor(socket), kind, payload), socket)
    else
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("log", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_kind"}}, socket}
  end

  def handle_in("end", _payload, socket) do
    guard_instructor(socket, fn ->
      case SessionServer.end_call(socket.assigns.server, actor(socket)) do
        {:ok, recording} -> {:reply, {:ok, %{recording_id: recording.id}}, socket}
        {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
      end
    end)
  end

  # ---- 会话广播 ----

  @impl true
  def handle_info({:timeline_event, event}, socket) do
    push(socket, "timeline_event", %{
      "id" => event.id,
      "at_ms" => event.at_ms,
      "actor" => event.actor,
      "kind" => event.kind,
      "payload" => event.payload
    })

    {:noreply, socket}
  end

  def handle_info({:call_state, call_state}, socket) do
    push(socket, "call_state", %{"state" => to_string(call_state)})
    {:noreply, socket}
  end

  def handle_info({:info_released, release}, socket) do
    push(socket, "info_released", %{"key" => release.key, "label" => release.label})
    {:noreply, socket}
  end

  def handle_info({:branch_triggered, branch}, socket) do
    push(socket, "branch_triggered", %{"key" => branch.key, "label" => branch.label})
    {:noreply, socket}
  end

  def handle_info({:background_audio, audio}, socket) do
    push(socket, "background_audio", %{"key" => audio.key, "label" => audio.label})
    {:noreply, socket}
  end

  # 来电者/背景声 PCM 帧, 以二进制推给浏览器播放(“听得见的来电”)
  def handle_info({:voice_frame, kind, frame, _meta}, socket) do
    push(socket, "audio", {:binary, frame})
    {:noreply, assign(socket, :last_voice_kind, kind)}
  end

  # 与语音同帧发出的文字字幕
  def handle_info({:caller_speech, kind, text}, socket) do
    push(socket, "caller_speech", %{"kind" => to_string(kind), "text" => text})
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp authorized?(nil, _session), do: false

  defp authorized?(user, session) do
    user.id == session.trainee_id or user.id == session.instructor_id or
      Accounts.User.admin?(user)
  end

  defp actor(socket), do: role_of(socket.assigns.user)

  defp role_of(%Accounts.User{role: "trainee"}), do: "trainee"
  defp role_of(%Accounts.User{role: role}) when role in ["instructor", "admin"], do: "instructor"

  # 仅主持教员/管理员可执行教员控制动作
  defp instructor?(%Accounts.User{} = user), do: Accounts.User.instructor?(user)

  defp guard_instructor(socket, fun) do
    if instructor?(socket.assigns.user) do
      fun.()
    else
      {:reply, {:error, %{reason: "forbidden_instructor_action"}}, socket}
    end
  end

  # 学员仅能记录自己的提问/确认/指令; 教员身份不受限
  defp permit_log(%{assigns: %{user: %Accounts.User{role: "trainee"}}}, _kind), do: :ok

  defp permit_log(%{assigns: %{user: %Accounts.User{} = user}}, _kind) do
    if Accounts.User.instructor?(user), do: :ok, else: {:error, "forbidden"}
  end

  defp reply_result(:ok, socket), do: {:reply, :ok, socket}
  defp reply_result({:ok, _result}, socket), do: {:reply, :ok, socket}

  defp reply_result({:error, reason}, socket),
    do: {:reply, {:error, %{reason: to_string(reason)}}, socket}
end
