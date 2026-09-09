defmodule DispatchTrainer.Scenarios.Scenario do
  @moduledoc """
  演练场景脚本。

  包含: 来电者角色、逐步释放的信息、背景声、病情分支、
  隐藏条件(学员端不可见)与评分标准(带版本)。
  """
  use Ecto.Schema
  import Ecto.Changeset

  defmodule CallerProfile do
    @moduledoc "来电者角色设定。"
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :name, :string
      field :role, :string, default: "家属"
      field :phone, :string
      # calm | anxious | panicked | hysterical
      field :emotion_level, :string, default: "anxious"
      field :speech_style, :string, default: "normal"
      field :relationship, :string
    end

    def changeset(profile, attrs) do
      profile
      |> cast(attrs, [:name, :role, :phone, :emotion_level, :speech_style, :relationship])
      |> validate_inclusion(:emotion_level, ~w(calm anxious panicked hysterical))
    end
  end

  defmodule BackgroundAudio do
    @moduledoc "背景声: 在指定时间自动加入通话。"
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :key, :string
      field :label, :string
      field :start_at_ms, :integer, default: 0
      field :duration_ms, :integer, default: 0
      field :volume, :float, default: 1.0
    end

    def changeset(audio, attrs) do
      audio
      |> cast(attrs, [:key, :label, :start_at_ms, :duration_ms, :volume])
      |> validate_required([:key, :label])
      |> validate_number(:start_at_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule InfoRelease do
    @moduledoc """
    逐步释放的信息。释放方式:
      * `"manual"` — 教员手动释放
      * `"time"` — 通话开始后 trigger_after_ms 自动释放
      * `"question"` — 学员提问命中 keywords 时释放
    """
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :key, :string
      field :label, :string
      field :content, :string
      field :trigger_type, :string, default: "manual"
      field :trigger_after_ms, :integer, default: 0
      field :keywords, {:array, :string}, default: []
      field :initially_available, :boolean, default: false
    end

    def changeset(release, attrs) do
      release
      |> cast(attrs, [
        :key,
        :label,
        :content,
        :trigger_type,
        :trigger_after_ms,
        :keywords,
        :initially_available
      ])
      |> validate_required([:key, :label, :content, :trigger_type])
      |> validate_inclusion(:trigger_type, ~w(manual time question))
    end
  end

  defmodule Branch do
    @moduledoc """
    病情分支: 由教员触发, 改变来电表现并释放对应信息。
    默认不可重复触发(repeatable = false), 重复触发幂等。
    """
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :key, :string
      field :label, :string
      # 触发后向学员释放的病情变化描述
      field :reveal_content, :string
      # 关联的隐藏条件说明(仅教员可见)
      field :hidden_condition, :string
      field :emotion_effect, :string
      field :repeatable, :boolean, default: false
    end

    def changeset(branch, attrs) do
      branch
      |> cast(attrs, [:key, :label, :reveal_content, :hidden_condition, :emotion_effect, :repeatable])
      |> validate_required([:key, :label])
    end
  end

  defmodule HiddenCondition do
    @moduledoc "隐藏条件: 仅教员控制台可见, 学员端绝不渲染。"
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :key, :string
      field :label, :string
      field :detail, :string
    end

    def changeset(condition, attrs) do
      condition
      |> cast(attrs, [:key, :label, :detail])
      |> validate_required([:key, :label])
    end
  end

  defmodule RubricItem do
    @moduledoc "评分标准条目(属于某个 rubric_version)。"
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :key, :string
      # location | danger | instruction | communication
      field :category, :string
      field :description, :string
      field :max_points, :integer, default: 10
      field :required, :boolean, default: false
    end

    def changeset(item, attrs) do
      item
      |> cast(attrs, [:key, :category, :description, :max_points, :required])
      |> validate_required([:key, :category, :description])
      |> validate_inclusion(:category, ~w(location danger instruction communication))
      |> validate_number(:max_points, greater_than: 0)
    end
  end

  schema "scenarios" do
    field :code, :string
    field :title, :string
    field :description, :string
    field :difficulty, :string, default: "standard"
    field :true_address, :string
    field :address_variants, {:array, :string}, default: []
    field :rubric_version, :integer, default: 1
    field :published, :boolean, default: true

    embeds_one :caller_profile, CallerProfile, on_replace: :delete
    embeds_many :background_audios, BackgroundAudio, on_replace: :delete
    embeds_many :info_releases, InfoRelease, on_replace: :delete
    embeds_many :branches, Branch, on_replace: :delete
    embeds_many :hidden_conditions, HiddenCondition, on_replace: :delete
    embeds_many :rubric_items, RubricItem, on_replace: :delete

    has_many :sessions, DispatchTrainer.Sessions.Session

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(scenario, attrs) do
    scenario
    |> cast(attrs, [
      :code,
      :title,
      :description,
      :difficulty,
      :true_address,
      :address_variants,
      :rubric_version,
      :published
    ])
    |> validate_required([:code, :title])
    |> unique_constraint(:code)
    |> cast_embed(:caller_profile)
    |> cast_embed(:background_audios)
    |> cast_embed(:info_releases)
    |> cast_embed(:branches)
    |> cast_embed(:hidden_conditions)
    |> cast_embed(:rubric_items)
  end
end
