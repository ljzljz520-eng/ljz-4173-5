defmodule DispatchTrainer.Sessions.SessionServer do
  @moduledoc """
  单个演练会话的实时进程。

  职责:
    * 通话状态机(active / interrupted / ended)
    * 信息逐步释放(手动 / 定时 / 提问触发), 释放幂等
    * 病情分支触发, 默认不可重复(重复触发幂等, 不产生重复效果)
    * 来电中断与恢复: 中断期间拒绝音频写入, 状态与已释放信息保留
    * 音频包经抖动缓冲重排后写入录音
    * 所有事件按真实时间(单调毫秒 + 墙上时钟)落库并广播
  """

  use GenServer, restart: :temporary

  alias DispatchTrainer.{Sessions, Recordings, VirtualCaller}
  alias DispatchTrainer.Audio.{JitterBuffer, Opus, Packet}
  alias DispatchTrainer.Sessions.Session

  defstruct session: nil,
            scenario: nil,
            call_state: :scheduled,
            started_mono: nil,
            interrupted_mono: nil,
            released: MapSet.new(),
            triggered: MapSet.new(),
            timers: %{},
            jitter: nil,
            rec_packets: [],
            rec_bytes: 0

  # ---------- 客户端 API ----------

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  defp via(session_id), do: {:via, Registry, {DispatchTrainer.SessionRegistry, session_id}}

  @doc "确保会话进程已启动, 返回 {:ok, pid}。"
  def ensure_started(session_id) do
    case Registry.lookup(DispatchTrainer.SessionRegistry, session_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(
          DispatchTrainer.SessionSupervisor,
          {__MODULE__, session_id}
        )
    end
  end

  @doc "加入通话(幂等): 首次加入时开始计时并调度定时释放。"
  def join_call(pid), do: GenServer.call(pid, :join_call)

  @doc "释放指定信息(幂等)。"
  def release_info(pid, key, actor \\ "instructor"),
    do: GenServer.call(pid, {:release_info, key, actor})

  @doc "触发病情分支; 不可重复分支重复触发返回 {:error, :already_triggered}。"
  def trigger_branch(pid, key, actor \\ "instructor"),
    do: GenServer.call(pid, {:trigger_branch, key, actor})

  @doc "来电中断。"
  def interrupt(pid, actor \\ "system"), do: GenServer.call(pid, {:interrupt, actor})

  @doc "中断恢复。"
  def resume(pid, actor \\ "system"), do: GenServer.call(pid, {:resume, actor})

  @doc "结束通话并定稿录音。"
  def end_call(pid, actor \\ "system"), do: GenServer.call(pid, {:end_call, actor})

  @doc "学员记录提问/确认/指令事件; 提问会触发匹配的信息释放并返回虚拟来电者应答。"
  def trainee_event(pid, kind, payload) when kind in ~w(confirmation instruction) do
    GenServer.call(pid, {:trainee_event, kind, payload})
  end

  @doc "记录一条时间线事件(提问/确认/指令/备注)。"
  def log(pid, actor, kind, payload) when kind in ~w(question confirmation instruction note) do
    GenServer.call(pid, {:log, actor, kind, payload})
  end

  @doc "学员向虚拟来电者提问: 记录事件、触发问题类信息释放, 返回来电者应答。"
  def trainee_question(pid, text), do: GenServer.call(pid, {:trainee_question, text})

  @doc "接收一路音频包(经抖动缓冲)。通话非 active 状态时拒绝。"
  def audio_packet(pid, %Packet{} = packet), do: GenServer.call(pid, {:audio_packet, packet})

  @doc "标记录音敏感时间段(用于脱敏导出)。"
  def mark_pii(pid, label, start_ms, end_ms, actor \\ "instructor"),
    do: GenServer.call(pid, {:mark_pii, label, start_ms, end_ms, actor})

  @doc "当前状态快照(供控制台与测试)。"
  def state(pid), do: GenServer.call(pid, :state)

  # ---------- 服务端 ----------

  @impl true
  def init(session_id) do
    session = Sessions.get_session!(session_id)

    state = %__MODULE__{
      session: session,
      scenario: session.scenario,
      call_state: String.to_existing_atom(session.status),
      jitter: JitterBuffer.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:join_call, _from, %{call_state: cs} = state)
      when cs in [:scheduled, :ringing] do
    now_mono = System.monotonic_time(:millisecond)

    {:ok, session} =
      Sessions.update_session(state.session, %{
        status: "active",
        started_at: DateTime.utc_now()
      })

    state = %{state | session: session, call_state: :active, started_mono: now_mono}

    {:ok, _} = log_event(state, "system", "system", %{"event" => "call_started"})
    state = schedule_timed_releases(state)
    state = schedule_background_audios(state)
    state = release_initial(state)

    broadcast(state, {:call_state, :active})
    {:reply, :ok, state}
  end

  def handle_call(:join_call, _from, state), do: {:reply, :ok, state}

  def handle_call({:release_info, key, actor}, _from, state) do
    case do_release(state, key, actor) do
      {:ok, release, state} -> {:reply, {:ok, release}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:trigger_branch, key, actor}, _from, state) do
    branch = find_branch(state, key)

    cond do
      branch == nil ->
        {:reply, {:error, :unknown_branch}, state}

      MapSet.member?(state.triggered, key) and not branch.repeatable ->
        # 重复触发幂等: 不重复记录事件、不重复施加效果
        {:reply, {:error, :already_triggered}, state}

      true ->
        state = %{state | triggered: MapSet.put(state.triggered, key)}

        {:ok, _} =
          log_event(state, actor, "branch_trigger", %{
            "key" => branch.key,
            "label" => branch.label,
            "emotion_effect" => branch.emotion_effect
          })

        state =
          if branch.reveal_content do
            case do_release_virtual(state, branch.key, branch.label, branch.reveal_content, actor) do
              {:ok, _release, state} -> state
              {:error, _reason, state} -> state
            end
          else
            state
          end

        broadcast(state, {:branch_triggered, branch})
        {:reply, {:ok, branch}, state}
    end
  end

  def handle_call({:interrupt, actor}, _from, %{call_state: :active} = state) do
    {:ok, session} =
      Sessions.update_session(state.session, %{
        status: "interrupted",
        interrupt_count: state.session.interrupt_count + 1
      })

    state = %{
      state
      | session: session,
        call_state: :interrupted,
        interrupted_mono: System.monotonic_time(:millisecond)
    }

    {:ok, _} = log_event(state, actor, "interrupt", %{"count" => session.interrupt_count})
    broadcast(state, {:call_state, :interrupted})
    {:reply, :ok, state}
  end

  def handle_call({:interrupt, _actor}, _from, state),
    do: {:reply, {:error, :not_active}, state}

  def handle_call({:resume, actor}, _from, %{call_state: :interrupted} = state) do
    duration = System.monotonic_time(:millisecond) - state.interrupted_mono
    {:ok, session} = Sessions.update_session(state.session, %{status: "active"})
    state = %{state | session: session, call_state: :active, interrupted_mono: nil}

    {:ok, _} = log_event(state, actor, "resume", %{"interrupted_ms" => duration})
    broadcast(state, {:call_state, :active})
    {:reply, :ok, state}
  end

  def handle_call({:resume, _actor}, _from, state), do: {:reply, {:error, :not_interrupted}, state}

  def handle_call({:trainee_event, kind, payload}, _from, state) do
    {:ok, event} = log_event(state, "trainee", kind, payload)
    {:reply, {:ok, event}, state}
  end

  def handle_call({:log, actor, kind, payload}, _from, state) do
    {:ok, event} = log_event(state, actor, kind, payload)
    {:reply, {:ok, event}, state}
  end

  def handle_call({:trainee_question, text}, _from, state) do
    {:ok, _event} = log_event(state, "trainee", "question", %{"text" => text})

    # 命中关键词的“提问触发”信息随即释放
    state =
      state.scenario.info_releases
      |> Enum.filter(&(&1.trigger_type == "question"))
      |> Enum.filter(&VirtualCaller.question_matches?(&1, text))
      |> Enum.reduce(state, fn release, acc ->
        case do_release(acc, release.key, "caller") do
          {:ok, _release, acc} -> acc
          {:error, _reason, acc} -> acc
        end
      end)

    reply = VirtualCaller.answer(state.scenario, state.released, text)
    {:reply, reply, state}
  end

  def handle_call({:audio_packet, packet}, _from, %{call_state: :active} = state) do
    case JitterBuffer.push(state.jitter, packet) do
      {:stored, jitter} ->
        {ordered, jitter} = JitterBuffer.drain(jitter)

        state = %{state | jitter: jitter}

        state =
          Enum.reduce(ordered, state, fn pkt, acc ->
            %{acc | rec_packets: [pkt.payload | acc.rec_packets]}
          end)

        {:reply, :ok, state}

      {_dropped, jitter} ->
        {:reply, :ok, %{state | jitter: jitter}}
    end
  end

  def handle_call({:audio_packet, _packet}, _from, state),
    do: {:reply, {:error, :not_active}, state}

  def handle_call({:mark_pii, label, start_ms, end_ms, actor}, _from, state) do
    {:ok, event} =
      log_event(state, actor, "pii_mark", %{
        "label" => label,
        "start_ms" => start_ms,
        "end_ms" => end_ms
      })

    {:reply, {:ok, event}, state}
  end

  def handle_call({:end_call, actor}, _from, %{call_state: cs} = state)
      when cs in [:active, :interrupted] do
    {:ok, session} =
      Sessions.update_session(state.session, %{status: "ended", ended_at: DateTime.utc_now()})

    state = %{state | session: session, call_state: :ended}
    state = cancel_timers(state)

    {:ok, _} = log_event(state, actor, "system", %{"event" => "call_ended"})

    {:ok, recording} = finalize_recording(state)

    broadcast(state, {:call_state, :ended})
    {:reply, {:ok, recording}, state}
  end

  def handle_call({:end_call, _actor}, _from, state), do: {:reply, {:error, :not_active}, state}

  def handle_call(:state, _from, state) do
    snapshot = %{
      session_id: state.session.id,
      call_state: state.call_state,
      released: state.released,
      triggered: state.triggered,
      elapsed_ms: elapsed_ms(state),
      interrupt_count: state.session.interrupt_count,
      buffered_packets: map_size(state.jitter.buffer),
      recorded_packets: length(state.rec_packets)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info({:timed_release, key}, state) do
    state =
      case do_release(state, key, "caller") do
        {:ok, _release, state} -> state
        {:error, _reason, state} -> state
      end

    {:noreply, %{state | timers: Map.delete(state.timers, key)}}
  end

  def handle_info({:background_audio, audio}, state) do
    if state.call_state == :active do
      {:ok, _} =
        log_event(state, "system", "background_audio", %{
          "key" => audio.key,
          "label" => audio.label,
          "duration_ms" => audio.duration_ms
        })

      broadcast(state, {:background_audio, audio})
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ---------- 内部 ----------

  defp log_event(state, actor, kind, payload) do
    Sessions.log_event(state.session, actor, kind, payload, elapsed_ms(state))
  end

  defp broadcast(state, message), do: Sessions.broadcast(state.session.id, message)

  defp elapsed_ms(%{started_mono: nil}), do: 0

  defp elapsed_ms(%{started_mono: started}) do
    max(System.monotonic_time(:millisecond) - started, 0)
  end

  defp find_release(state, key) do
    Enum.find(state.scenario.info_releases, &(&1.key == key))
  end

  defp find_branch(state, key) do
    Enum.find(state.scenario.branches, &(&1.key == key))
  end

  # 释放场景脚本中定义的信息
  defp do_release(state, key, actor) do
    case find_release(state, key) do
      nil -> {:error, :unknown_info, state}
      release -> do_release_info(state, release, actor)
    end
  end

  # 释放分支带来的临时信息(不在场景 info_releases 中)
  defp do_release_virtual(state, key, label, content, actor) do
    do_release_info(state, %{key: key, label: label, content: content}, actor)
  end

  defp do_release_info(state, release, actor) do
    if MapSet.member?(state.released, release.key) do
      {:error, :already_released, state}
    else
      state = %{state | released: MapSet.put(state.released, release.key)}

      {:ok, _} =
        log_event(state, actor, "info_release", %{
          "key" => release.key,
          "label" => release.label,
          "content" => release.content
        })

      broadcast(state, {:info_released, release})
      {:ok, release, state}
    end
  end

  defp schedule_timed_releases(state) do
    Enum.reduce(state.scenario.info_releases, state, fn release, acc ->
      if release.trigger_type == "time" do
        timer = Process.send_after(self(), {:timed_release, release.key}, release.trigger_after_ms)
        put_in(acc.timers[release.key], timer)
      else
        acc
      end
    end)
  end

  defp schedule_background_audios(state) do
    Enum.each(state.scenario.background_audios, fn audio ->
      Process.send_after(self(), {:background_audio, audio}, max(audio.start_at_ms, 0))
    end)

    state
  end

  defp release_initial(state) do
    Enum.reduce(state.scenario.info_releases, state, fn release, acc ->
      if release.initially_available do
        case do_release(acc, release.key, "caller") do
          {:ok, _release, acc} -> acc
          {:error, _reason, acc} -> acc
        end
      else
        acc
      end
    end)
  end

  defp cancel_timers(state) do
    Enum.each(state.timers, fn {_key, timer} -> Process.cancel_timer(timer) end)
    %{state | timers: %{}}
  end

  defp finalize_recording(state) do
    packets = Enum.reverse(state.rec_packets)
    duration_ms = packets |> Enum.map(&Opus.duration_ms/1) |> Enum.sum() |> round()

    pii_segments =
      state.session.id
      |> Sessions.list_events()
      |> Enum.filter(&(&1.kind == "pii_mark"))
      |> Enum.map(fn e ->
        %{
          "label" => e.payload["label"],
          "start_ms" => e.payload["start_ms"],
          "end_ms" => e.payload["end_ms"]
        }
      end)

    Recordings.finalize_recording(%Session{id: state.session.id}, packets, %{
      duration_ms: duration_ms,
      pii_segments: pii_segments
    })
  end
end
