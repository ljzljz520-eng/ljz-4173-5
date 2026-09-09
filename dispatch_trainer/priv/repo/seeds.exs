# 种子数据: 演示账号与一个完整的“胸痛来电”场景脚本。
alias DispatchTrainer.{Accounts, Scenarios}

defmodule Seed do
  def user(attrs) do
    case Accounts.get_user_by_username(attrs.username) do
      nil ->
        {:ok, user} = Accounts.register_user(attrs)
        user

      user ->
        user
    end
  end
end

_admin = Seed.user(%{username: "admin", password: "admin-pass-1", display_name: "系统管理员", role: "admin"})
instructor = Seed.user(%{username: "instructor", password: "teach-pass-1", display_name: "王教员", role: "instructor"})
_trainee = Seed.user(%{username: "trainee", password: "learn-pass-1", display_name: "李学员", role: "trainee"})

scenario_attrs = %{
    code: "chest-pain-001",
    title: "胸痛来电(信息不全 + 情绪干扰)",
    description: "家属代报胸痛, 情绪激动; 地址存在同音干扰, 病情可分支恶化。",
    difficulty: "standard",
    true_address: "滨河路128号3栋502室",
    address_variants: ["滨和路128号", "滨河路182号", "滨河路128号"],
    rubric_version: 1,
    caller_profile: %{
      name: "张女士",
      role: "家属",
      phone: "138****2201",
      emotion_level: "panicked",
      speech_style: "语速快、易打断",
      relationship: "患者女儿"
    },
    background_audios: [
      %{key: "crying", label: "背景哭声", start_at_ms: 8_000, duration_ms: 20_000, volume: 0.6},
      %{key: "street", label: "街道噪音", start_at_ms: 0, duration_ms: 0, volume: 0.3}
    ],
    info_releases: [
      %{
        key: "chief_complaint",
        label: "主诉",
        content: "我父亲胸口疼了快半小时, 出冷汗。",
        trigger_type: "manual",
        initially_available: true
      },
      %{
        key: "address",
        label: "事发地址",
        content: "滨河路128号3栋502室(“河”是河水的河)。",
        trigger_type: "question",
        keywords: ["地址", "在哪", "哪里", "位置", "什么地方"]
      },
      %{
        key: "patient_age",
        label: "患者年龄",
        content: "我父亲今年68岁。",
        trigger_type: "question",
        keywords: ["多大", "年龄", "几岁"]
      },
      %{
        key: "medical_history",
        label: "既往病史",
        content: "他有高血压, 去年查出过冠心病。",
        trigger_type: "question",
        keywords: ["病史", "以前", "慢性病", "高血压", "心脏"]
      },
      %{
        key: "consciousness",
        label: "意识状态",
        content: "人还清醒, 但是越来越没力气说话。",
        trigger_type: "time",
        trigger_after_ms: 45_000
      },
      %{
        key: "breathing",
        label: "呼吸状况",
        content: "呼吸有点急, 说胸口像被石头压着。",
        trigger_type: "manual"
      }
    ],
    branches: [
      %{
        key: "deterioration",
        label: "病情恶化: 呼吸困难加重",
        reveal_content: "他现在喘不上气了, 嘴唇发紫!",
        hidden_condition: "心源性休克前期表现, 考察危险识别与到车前指导调整。",
        emotion_effect: "hysterical",
        repeatable: false
      },
      %{
        key: "emotional_outburst",
        label: "情绪崩溃(可重复)",
        reveal_content: "你们到底还有多久到?! 我爸要是有事我跟你们没完!",
        hidden_condition: "情绪干扰升级, 考察沟通与信息确认稳定性。",
        emotion_effect: "hysterical",
        repeatable: true
      }
    ],
    hidden_conditions: [
      %{key: "hc1", label: "真实病情", detail: "急性心肌梗死高危, 需尽快到车。"},
      %{key: "hc2", label: "同音地址陷阱", detail: "学员易把“滨河路”听成“滨和路”, 必须逐字确认。"},
      %{key: "hc3", label: "家属隐瞒", detail: "家属起初不愿提患者有冠心病史, 需主动追问。"}
    ],
    rubric_items: [
      %{key: "confirm_address", category: "location", description: "完整复述并逐字确认事发地址", max_points: 20, required: true},
      %{key: "identify_danger", category: "danger", description: "识别高危胸痛信号并询问病史", max_points: 20, required: true},
      %{key: "pre_arrival_instruction", category: "instruction", description: "给出到车前指导(静卧、禁食水、开门接应)", max_points: 20, required: true},
      %{key: "info_verification", category: "location", description: "核实联系电话与患者基本信息", max_points: 10, required: false},
      %{key: "emotional_handling", category: "communication", description: "在情绪干扰下保持沟通清晰", max_points: 15, required: false},
      %{key: "timeline_accuracy", category: "communication", description: "关键信息确认顺序与时效", max_points: 15, required: false}
    ]
  }

_scenario =
  case DispatchTrainer.Repo.get_by(DispatchTrainer.Scenarios.Scenario, code: "chest-pain-001") do
    nil ->
      {:ok, scenario} = Scenarios.create_scenario(scenario_attrs)
      scenario

    scenario ->
      {:ok, scenario} = Scenarios.update_scenario(scenario, scenario_attrs)
      scenario
  end

IO.puts("seeded: users(admin/instructor/trainee) + scenario chest-pain-001 (#{instructor.username})")
