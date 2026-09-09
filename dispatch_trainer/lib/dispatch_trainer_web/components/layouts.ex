defmodule DispatchTrainerWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use DispatchTrainerWeb, :controller` and
  `use DispatchTrainerWeb, :live_view`.
  """
  use DispatchTrainerWeb, :html

  embed_templates "layouts/*"

  defp role_label("trainee"), do: "学员"
  defp role_label("instructor"), do: "教员"
  defp role_label("admin"), do: "管理员"
  defp role_label(other), do: other
end
