defmodule Elia.Skill do
  @moduledoc """
  A skill bundles instructions for the model with the tools that carry them out.

  Skills come from two places:

    * built-in Elixir modules implementing this behaviour (listed in config)
    * folders under `skills/` loaded at runtime by `Elia.Skills.Folder`

  Both are turned into this struct by `Elia.Skills`.

      defmodule MySkill do
        @behaviour Elia.Skill
        def name, do: "my_skill"
        def description, do: "Does a thing"
        def instructions, do: "When asked to do the thing, use the `thing` tool."
        def tools, do: [%Elia.Tool{...}]
      end
  """

  @callback name() :: binary()
  @callback description() :: binary()
  @doc "Text appended to the system prompt while the skill is enabled."
  @callback instructions() :: binary()
  @callback tools() :: [Elia.Tool.t()]

  @type t :: %__MODULE__{
          name: binary(),
          description: binary(),
          instructions: binary(),
          tools: [Elia.Tool.t()],
          source: {:module, module()} | {:folder, binary()}
        }

  @enforce_keys [:name, :description]
  defstruct [:name, :description, :source, instructions: "", tools: []]

  def from_module(module) do
    %__MODULE__{
      name: module.name(),
      description: module.description(),
      instructions: module.instructions(),
      tools: module.tools(),
      source: {:module, module}
    }
  end
end
