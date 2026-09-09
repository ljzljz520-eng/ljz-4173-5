defmodule DispatchTrainer.SessionHelpers do
  @moduledoc "测试辅助: 用户/场景/会话 fixtures 与等待工具。"
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias DispatchTrainer.{Accounts, Repo, Sessions}
  alias DispatchTrainer.Sessions.SessionServer

  @password "test-pass-123"

  def password, do: @password

  def user_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        username: "user-#{unique}",
        password: @password,
        display_name: "测试用户#{unique}",
        role: "trainee"
      } |> Map.merge(Enum.into(attrs, %{}), fn _k, v1, v2 -> if(v2 == nil, do: v1, else: v2) end))

    user
  end

  def instructor_fixture(attrs \\ %{}), do: user_fixture(Map.merge(%{role: "instructor"}, Map.new(attrs)))
  def admin_fixture(attrs \\ %{}), do: user_fixture(Map.merge(%{role: "admin"}, Map.new(attrs)))

  @doc "完整脚本场景: 含定时/提问/手动释放、可重复与不可重复分支、隐藏条件、评分项。"
  def scenario_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    base = %{
      code: "scenario-#{unique}",
      title: "测试场景#{unique}",
      true_address: "滨河路128号",
      address_variants: ["滨和路128号"],
      rubric_version: 1,
      caller_profile: %{name: "测试来电者", role: "家属", emotion_level: "panicked"},
      background_audios: [
        %{key: "crying", label: "哭声", start_at_ms: 50, duration_ms: 1000, volume: 0.5}
      ],
      info_releases: [
        %{key: "complaint", label: "主诉", content: "胸口疼", initially_available: true},
        %{
          key: "address",
          label: "地址",
          content: "滨河路128号",
          trigger_type: "question",
          keywords: ["地址", "哪里", "位置"]
        },
        %{
          key: "age",
          label: "年龄",
          content: "68岁",
          trigger_type: "time",
          trigger_after_ms: 60
        },
        %{
          key: "history",
          label: "病史",
          content: "有高血压病史",
          trigger_type: "manual",
          keywords: ["病史", "以前", "慢性病"]
        }
      ],
      branches: [
        %{
          key: "worse",
          label: "病情恶化",
          reveal_content: "喘不上气了",
          hidden_condition: "休克前期",
          emotion_effect: "hysterical",
          repeatable: false
        },
        %{
          key: "outburst",
          label: "情绪爆发",
          reveal_content: "你们快点!",
          emotion_effect: "hysterical",
          repeatable: true
        }
      ],
      hidden_conditions: [
        %{key: "hc1", label: "隐藏病情", detail: "心梗高危-绝密标记"}
      ],
      rubric_items: [
        %{key: "confirm_address", category: "location", description: "确认地址", max_points: 20, required: true},
        %{key: "identify_danger", category: "danger", description: "识别危险", max_points: 20, required: true},
        %{key: "instruct", category: "instruction", description: "到车前指导", max_points: 20, required: false}
      ]
    }

    {:ok, scenario} =
      DispatchTrainer.Scenarios.create_scenario(Map.merge(base, Map.new(attrs)))

    scenario
  end

  def session_fixture(attrs \\ %{}) do
    scenario = Map.get(attrs, :scenario) || scenario_fixture()
    trainee = Map.get(attrs, :trainee) || user_fixture()
    instructor = Map.get(attrs, :instructor) || instructor_fixture()

    {:ok, session} =
      Sessions.create_session(%{
        scenario_id: scenario.id,
        trainee_id: trainee.id,
        instructor_id: instructor.id
      })

    session
  end

  @doc "启动会话进程并注册退出清理。"
  def start_session_server!(session) do
    {:ok, pid} = SessionServer.ensure_started(session.id)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    end)

    pid
  end

  @doc "测试退出时停止所有会话进程, 避免定时器在沙箱回滚后访问数据库。"
  def stop_all_session_servers_on_exit do
    on_exit(fn ->
      DispatchTrainer.SessionRegistry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$2"]}])
      |> Enum.each(fn pid ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end
      end)
    end)
  end

  @doc "轮询直到 fun 返回真值或超时(默认 2s)。"
  def wait_until(fun, timeout \\ 2_000, interval \\ 10)

  def wait_until(fun, timeout, _interval) when timeout <= 0 do
    if fun.(), do: :ok, else: {:error, :timeout}
  end

  def wait_until(fun, timeout, interval) do
    if fun.() do
      :ok
    else
      Process.sleep(interval)
      wait_until(fun, timeout - interval, interval)
    end
  end

  def get_session!(id), do: Repo.get!(DispatchTrainer.Sessions.Session, id) |> Repo.preload(:scenario)
end
