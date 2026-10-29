defmodule Elia.LLM.Message do
  @moduledoc """
  Provider-neutral conversation message.

  `content` is a list of blocks (plain maps):

    * `%{type: :text, text: binary}`
    * `%{type: :reasoning, text: binary}` - model reasoning / progress notes
    * `%{type: :tool_call, id: binary, name: binary, input: map}`
    * `%{type: :tool_result, tool_call_id: binary, content: binary, is_error: boolean}`
    * `%{type: :opaque}` - a provider-specific block with no neutral meaning

  Blocks produced by a provider may carry `raw: {provider_module, map}`, the
  block exactly as the provider returned it. Adapters must echo their own raw
  blocks back unchanged (some APIs verify that history is append-only) and
  should drop or translate raw blocks from other providers.

  `meta` holds harness bookkeeping that is never sent to a provider, e.g.
  `%{harness: true}` on user-role messages the harness wrote itself.
  """

  @type role :: :user | :assistant | :tool
  @type block :: map()
  @type t :: %__MODULE__{role: role(), content: [block()], meta: map()}

  @enforce_keys [:role, :content]
  defstruct [:role, :content, meta: %{}]

  def user(text) when is_binary(text), do: %__MODULE__{role: :user, content: [text(text)]}

  @doc "A user-role message written by the harness rather than the user."
  def harness(text),
    do: %__MODULE__{
      role: :user,
      content: [text("[Elia harness] " <> text)],
      meta: %{harness: true}
    }

  def text(text), do: %{type: :text, text: text}

  def tool_result(tool_call_id, content, is_error \\ false) do
    %{type: :tool_result, tool_call_id: tool_call_id, content: content, is_error: is_error}
  end

  def tool_calls(%__MODULE__{content: content}),
    do: Enum.filter(content, &(&1.type == :tool_call))

  def text_content(%__MODULE__{content: content}) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end
end
