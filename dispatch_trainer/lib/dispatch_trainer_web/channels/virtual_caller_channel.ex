defmodule DispatchTrainerWeb.VirtualCallerChannel do
  @moduledoc """
  虚拟来电端频道。

  供自动化演练与测试使用: 以文本方式向虚拟来电者提问,
  依据已释放信息作答; 未释放信息表现为情绪化回避。
  """
  use Phoenix.Channel

  alias DispatchTrainer.{Accounts, Sessions, VirtualCaller}
  alias DispatchTrainer.Sessions.SessionServer

  @impl true
  def join("virtual_caller:" <> session_id, _payload, socket) do
    user = Accounts.get_user(socket.assigns.user_id)
    session = Sessions.get_session!(session_id)

    # 仅主持该会话的教员(或管理员)可驱动虚拟来电端
    if user && (user.id == session.instructor_id or Accounts.User.admin?(user)) do
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

  @impl true
  def handle_in("ask", %{"text" => text}, socket) do
    server = socket.assigns.server

    case SessionServer.trainee_question(server, text) do
      {:answer, utterance, release} ->
        {:reply, {:ok, %{type: "answer", utterance: utterance, info_key: release.key}}, socket}

      {:withheld, utterance, release} ->
        {:reply, {:ok, %{type: "withheld", utterance: utterance, info_key: release.key}}, socket}

      {:unknown, utterance, _} ->
        {:reply, {:ok, %{type: "unknown", utterance: utterance}}, socket}
    end
  end

  def handle_in("greeting", _payload, socket) do
    scenario = Sessions.get_session!(socket.assigns.session_id).scenario
    {:reply, {:ok, %{utterance: VirtualCaller.greeting(scenario)}}, socket}
  end

  def handle_in("trigger_branch", %{"key" => key}, socket) do
    case SessionServer.trigger_branch(socket.assigns.server, key, "instructor") do
      {:ok, branch} ->
        scenario = Sessions.get_session!(socket.assigns.session_id).scenario
        utterance = VirtualCaller.branch_utterance(scenario, branch)
        {:reply, {:ok, %{key: branch.key, utterance: utterance}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("interrupt", _payload, socket) do
    reply_result(SessionServer.interrupt(socket.assigns.server, "system"), socket)
  end

  def handle_in("resume", _payload, socket) do
    reply_result(SessionServer.resume(socket.assigns.server, "system"), socket)
  end

  def handle_in("end", _payload, socket) do
    case SessionServer.end_call(socket.assigns.server, "system") do
      {:ok, recording} -> {:reply, {:ok, %{recording_id: recording.id}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_info({:info_released, release}, socket) do
    push(socket, "info_released", %{"key" => release.key, "content" => release.content})
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp reply_result(:ok, socket), do: {:reply, :ok, socket}

  defp reply_result({:error, reason}, socket),
    do: {:reply, {:error, %{reason: to_string(reason)}}, socket}
end
