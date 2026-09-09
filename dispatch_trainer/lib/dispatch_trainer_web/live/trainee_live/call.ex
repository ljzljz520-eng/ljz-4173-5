defmodule DispatchTrainerWeb.TraineeLive.Call do
  @moduledoc """
  学员通话页。

  学员只能看到来电者公开信息与“已释放”的信息;
  场景隐藏条件、真实地址、分支脚本等绝不渲染到本页。
  """
  use DispatchTrainerWeb, :live_view

  alias DispatchTrainer.Sessions
  alias DispatchTrainer.Sessions.SessionServer

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    session = Sessions.get_session!(session_id)
    user = socket.assigns.current_user

    if user && user.id == session.trainee_id do
      {:ok, server} = SessionServer.ensure_started(session.id)
      if connected?(socket), do: Sessions.subscribe(session.id)

      {:ok,
       socket
       |> assign(:page_title, "接警演练")
       |> assign(:session, session)
       |> assign(:server, server)
       |> assign(:server_state, server_state(server))
       |> assign(:question, "")
       |> assign(:caller_lines, [])
       |> assign(:audio_token, audio_token(user))
       |> stream(:events, Sessions.list_events(session.id) |> Enum.reverse())}
    else
      {:ok,
       socket
       |> put_flash(:error, "无权进入该演练。")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("join", _params, socket) do
    :ok = SessionServer.join_call(socket.assigns.server)
    {:noreply, refresh(socket)}
  end

  def handle_event("ask", %{"question" => question}, socket) when question != "" do
    server = socket.assigns.server

    reply =
      case SessionServer.trainee_question(server, question) do
        {:answer, utterance, _release} -> utterance
        {:withheld, utterance, _release} -> utterance
        {:unknown, utterance, _} -> utterance
      end

    {:noreply,
     socket
     |> assign(:question, "")
     |> update(:caller_lines, fn lines -> Enum.take([reply | lines], 20) end)
     |> refresh()}
  end

  def handle_event("ask", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_address", %{"address" => address}, socket) do
    session = socket.assigns.session
    comparison = DispatchTrainer.Address.compare(session.scenario.true_address, address)

    {:ok, _} =
      SessionServer.log(socket.assigns.server, "trainee", "confirmation", %{
        "type" => "address",
        "heard" => address,
        "result" => to_string(comparison.result),
        "requires_readback" => DispatchTrainer.Address.requires_readback?(
          session.scenario.true_address,
          address
        )
      })

    notice =
      case comparison.result do
        :match -> "地址一致。"
        :homophone_conflict -> "存在同音字差异, 请与来电者逐字确认!"
        :mismatch -> "地址不一致, 请重新核对!"
      end

    {:noreply, socket |> put_flash(:info, notice) |> refresh()}
  end

  def handle_event("instruct", %{"instruction" => instruction}, socket) when instruction != "" do
    {:ok, _} =
      SessionServer.log(socket.assigns.server, "trainee", "instruction", %{"text" => instruction})

    {:noreply, refresh(socket)}
  end

  def handle_event("instruct", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:timeline_event, event}, socket) do
    {:noreply, socket |> stream_insert(:events, event, at: 0) |> refresh()}
  end

  def handle_info({:call_state, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:info_released, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh(socket) do
    session = Sessions.get_session!(socket.assigns.session.id)

    socket
    |> assign(:session, session)
    |> assign(:server_state, server_state(socket.assigns.server))
  end

  defp server_state(server) do
    if Process.alive?(server), do: SessionServer.state(server), else: nil
  end

  # 仅返回“已释放”的信息内容; 隐藏条件绝不出现在学员端
  defp released_infos(nil, _scenario), do: []

  defp released_infos(server_state, scenario) do
    scenario.info_releases
    |> Enum.filter(&MapSet.member?(server_state.released, &1.key))
    |> Enum.map(&%{label: &1.label, content: &1.content})
  end

  defp audio_token(user) do
    Phoenix.Token.sign(DispatchTrainerWeb.Endpoint, "user socket", user.id)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl px-4 py-6">
      <header class="mb-4">
        <h1 class="text-xl font-bold">接警演练 · {@session.scenario.title}</h1>
        <p class="text-sm text-zinc-500">
          状态: <span class="font-mono">{@session.status}</span>
          <span :if={@session.status == "interrupted"} class="ml-2 rounded bg-amber-100 px-2 py-0.5 text-amber-800">
            来电中断, 等待恢复…
          </span>
        </p>
      </header>

      <section class="border rounded p-4 mb-4">
        <h2 class="font-semibold mb-1">来电者</h2>
        <p class="text-sm">
          {@session.scenario.caller_profile.name}（{@session.scenario.caller_profile.role}）
        </p>
      </section>

      <section class="border rounded p-4 mb-4">
        <h2 class="font-semibold mb-2">已获知信息</h2>
        <ul class="list-disc pl-5 text-sm space-y-1">
          <li :for={info <- released_infos(@server_state, @session.scenario)}>
            <strong>{info.label}</strong>: {info.content}
          </li>
          <li :if={released_infos(@server_state, @session.scenario) == []} class="text-zinc-400 list-none">
            暂无可确认信息, 请主动询问来电者。
          </li>
        </ul>
      </section>

      <section class="border rounded p-4 mb-4">
        <h2 class="font-semibold mb-2">来电者回应</h2>
        <ul class="space-y-1 text-sm">
          <li :for={line <- @caller_lines}>{line}</li>
        </ul>
      </section>

      <section class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-4">
        <.form for={%{}} as={:ask} phx-submit="ask" class="border rounded p-4">
          <h2 class="font-semibold mb-2">向来电者提问</h2>
          <input
            type="text"
            name="question"
            value={@question}
            placeholder="例如: 病人现在还有意识吗?"
            class="w-full rounded border-zinc-300 text-sm"
          />
          <.button class="mt-2 w-full">提问</.button>
        </.form>

        <.form for={%{}} as={:confirm} phx-submit="confirm_address" class="border rounded p-4">
          <h2 class="font-semibold mb-2">地址复述确认</h2>
          <input
            type="text"
            name="address"
            placeholder="复述你听到的地址"
            class="w-full rounded border-zinc-300 text-sm"
          />
          <.button class="mt-2 w-full">确认地址</.button>
        </.form>
      </section>

      <section class="border rounded p-4 mb-4">
        <.form for={%{}} as={:instruct} phx-submit="instruct">
          <h2 class="font-semibold mb-2">到车前指导</h2>
          <input
            type="text"
            name="instruction"
            placeholder="给来电者的现场指导指令"
            class="w-full rounded border-zinc-300 text-sm"
          />
          <.button class="mt-2 w-full">下达指令</.button>
        </.form>
      </section>

      <section class="border rounded p-4 mb-4">
        <h2 class="font-semibold mb-2">通话时间线</h2>
        <ul id="trainee-timeline" phx-update="stream" class="space-y-1 text-xs max-h-48 overflow-y-auto">
          <li :for={{dom_id, event} <- @streams.events} id={dom_id}>
            <span class="font-mono text-zinc-400">{event.at_ms}ms</span>
            <span class="text-zinc-500">[{event.actor}]</span> {event.kind}
          </li>
        </ul>
      </section>

      <section
        id="opus-audio"
        phx-hook="OpusAudio"
        data-session-id={@session.id}
        data-token={@audio_token}
        class="border rounded p-4 text-sm text-zinc-500"
      >
        音频通道(Opus/WebSocket)由浏览器端钩子建立。
      </section>

      <.button :if={@session.status in ["scheduled", "ringing"]} phx-click="join" class="w-full">
        接听来电
      </.button>
    </div>
    """
  end

end
