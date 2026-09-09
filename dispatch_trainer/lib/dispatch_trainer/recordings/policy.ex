defmodule DispatchTrainer.Recordings.Policy do
  @moduledoc """
  录音访问策略(受限访问)。

    * 管理员: 可访问/导出全部录音
    * 教员: 仅本人主持的会话录音
    * 学员: 不可访问原始录音(含敏感信息), 仅可查看教员分享的脱敏导出
  """

  alias DispatchTrainer.Accounts.User
  alias DispatchTrainer.Recordings.Recording
  alias DispatchTrainer.Sessions.Session

  def can_access?(%User{role: "admin"}, %Recording{}, %Session{}), do: true

  def can_access?(%User{role: "instructor", id: id}, %Recording{}, %Session{instructor_id: id}),
    do: true

  def can_access?(%User{}, %Recording{}, %Session{}), do: false

  @doc "脱敏导出权限与原始访问权限一致。"
  def can_export?(user, recording, session), do: can_access?(user, recording, session)
end
