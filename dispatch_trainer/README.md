# DispatchTrainer — 急救调度培训演练平台

模拟报警电话训练系统: 学员在**信息不全**与**情绪干扰**下完成
**地点确认、危险识别、到车前指导**; 教员通过控制台实时释放信息、
触发病情分支、中断/恢复通话, 并依据标准版本**逐项评分**。

## 技术栈

- **Elixir / Phoenix 1.7 + LiveView** — 会话服务与教员控制台
- **PostgreSQL (Ecto)** — 场景脚本、会话、时间线事件、评定、录音元数据
- **Opus over WebSocket** — 通话音频经二进制帧传输(Phoenix Channel)
- **Ogg/Opus 封装** — 录音持久化与脱敏导出(纯 Elixir 实现)

## 快速开始

```bash
mix setup          # deps.get + ecto.create + migrate + seeds
mix phx.server     # http://localhost:4000
```

种子账号: `instructor / teach-pass-1`(教员)、`trainee / learn-pass-1`(学员)、
`admin / admin-pass-1`。种子场景 `chest-pain-001` 为完整胸痛来电脚本。

```bash
mix test           # 全部测试(含抖动/同音地址/来电中断/分支重复触发)
```

## 架构

```
lib/dispatch_trainer/
  accounts.ex              # 用户(trainee/instructor/admin), PBKDF2 口令
  address.ex               # 地址规范化与同音字比对 → 逐字确认提示
  audio/
    packet.ex              # WebSocket 二进制帧: magic|ver|seq|ts|opus (麦克风)
    caller_voice.ex        # 来电者“可听见语音”: 脚本→48k S16LE PCM 帧(情绪/节奏)
    jitter_buffer.ex       # 抗抖动: 重排/去重/丢过迟包/空缺跳帧
    opus.ex                # RFC6716 TOC 解析、静音帧(不解码内容)
    ogg.ex                 # Ogg 封装/解析(CRC32), 录音与导出载体
  scenarios.ex             # 场景脚本: 来电者角色/逐步释放/背景声/分支/隐藏条件/评分项
  sessions.ex              # 会话与真实时间时间线(at_ms + wall_time)
  sessions/session_server.ex  # 每会话 GenServer: 状态机/释放/分支/中断/录音
  virtual_caller.ex        # 虚拟来电端: 按已释放信息作答, 未释放则情绪化回避
  evaluations.ex           # 教员逐项评分(标准版本快照), 系统不做自动医疗结论
  recordings.ex + recordings/policy.ex  # 受限访问与脱敏导出(PII 段静音)
lib/dispatch_trainer_web/
  channels/call_channel.ex            # 通话频道(Opus 二进制帧 + 控制事件)
  channels/virtual_caller_channel.ex  # 虚拟来电端频道(自动化演练/测试)
  live/instructor_live/console.ex     # 教员控制台(隐藏条件仅此处可见)
  live/trainee_live/call.ex           # 学员通话页(绝不渲染隐藏条件)
  controllers/recording_controller.ex # 录音下载/脱敏导出(策略校验)
```

## 关键设计

### 信息逐步释放
`info_releases` 三种触发: `manual`(教员手动)、`time`(通话开始后 N ms)、
`question`(学员提问命中关键词)。学员端只见“已释放”内容。

### 隐藏条件
`hidden_conditions`、真实地址、分支脚本只在教员控制台渲染;
学员 LiveView 模板不含这些数据(有测试保证)。

### 分支重复触发幂等
不可重复分支第二次触发返回 `{:error, :already_triggered}`,
不重复写时间线、不重复施加效果; `repeatable: true` 的分支(如情绪爆发)可多次。

### 来电中断
`interrupt` 暂停通话: 音频写入被拒绝、已释放信息与分支状态保留;
`resume` 恢复并记录中断时长; 全部按真实时间(at_ms + wall_time)落时间线。

### 可听见的来电
来电者的开场白、手动/定时释放的信息、病情分支与学员提问回答, 均由
`Audio.CallerVoice` 把**脚本文本**合成为带语言节奏与情绪色彩的 48kHz
S16LE PCM(确定性、无外部依赖、不做语音识别/医疗判断), 在 `SessionServer`
内串行排队、按 20ms 帧实时推出; 浏览器端 `OpusAudio` 钩子用 Web Audio
FIFO 播放, 同时收到 `caller_speech` 文字字幕。麦克风对端仍走 Opus 帧。

### 角色与归属
学员加入自己的 `call:*` 频道后只能推送麦克风音频与自己的提问/确认/
指令日志; 中断/恢复/释放/分支/结束等**教员控制动作**一律拒绝。
会话控制台、虚拟来电端频道、评分均校验“主持教员本人或管理员”,
教员无法查看或操作不属于自己的会话。

### 地址同音确认
`Address.compare/2` 逐字比对真实地址与学员复述:
同音不同字(滨河路/滨和路)→ `homophone_conflict`, 必须逐字确认;
发音不同 → `mismatch`。系统只提示确认需求, 不做医疗结论。

### 录音受限与脱敏导出
`Recordings.Policy`: 仅主持教员与管理员可访问原始录音。
脱敏导出将 PII 时间段替换为 Opus 静音帧, 元数据剔除姓名/电话/地址。

### 评定
教员依据 `rubric_version` 逐项打分(每项 0..max, 必评项须 > 0,
总分 ≥ 60% 通过); 评定时快照标准, 后续修订不影响已评定结果。

## 测试覆盖(111 项)

- `audio/jitter_buffer_test.exs` — **音频抖动**: 乱序重排、重复/过迟丢弃、跳帧
- `audio/caller_voice_test.exs` — **来电语音**: 非静音 PCM 帧、情绪语速、背景声
- `address_test.exs` — **地址同音**: 同音冲突需逐字确认
- `sessions/session_server_test.exs` — **来电中断**恢复、**分支重复触发**幂等、真实时间时间线
- `recordings_test.exs` — 受限访问 + 脱敏导出(PII 段静音)
- `channels/*` — Opus 二进制帧、可听见的来电回答/背景声、学员越权控制拒绝、非主持教员拒绝
- `live/*` — 控制台操作、非主持教员重定向、学员端隐藏条件不可见、逐项评分
