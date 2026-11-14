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
      content: [text("[Elia harness] " <> String.replace_invalid(text))],
      meta: %{harness: true}
    }

  @doc """
  The moment the chat appended this message, as a `DateTime` in UTC, or `nil`
  for a message that carries none — one saved before stamps existed (MSGAT-3).
  """
  @spec at(t()) :: DateTime.t() | nil
  def at(%__MODULE__{meta: meta}), do: Map.get(meta, :at)

  @doc """
  Stamps the message with the moment it is appended to a chat's history, in its
  `meta`, which a provider is never sent (MSGAT-1, LLM-5). A message that already
  carries a stamp keeps it (MSGAT-2).
  """
  @spec stamp(t()) :: t()
  def stamp(%__MODULE__{meta: meta} = message) do
    case Map.get(meta, :at) do
      %DateTime{} -> message
      _none -> %{message | meta: Map.put(meta, :at, DateTime.utc_now())}
    end
  end

  def text(text), do: %{type: :text, text: text}

  def tool_result(tool_call_id, content, is_error \\ false) do
    # LLM-32: tools can return raw bytes, which can't be JSON-encoded.
    %{
      type: :tool_result,
      tool_call_id: tool_call_id,
      content: String.replace_invalid(content),
      is_error: is_error
    }
  end

  @doc "Replaces invalid UTF-8 in a message's text and tool results (STORE-13)."
  def scrub(%__MODULE__{content: content} = message),
    do: %{message | content: Enum.map(content, &scrub_block/1)}

  defp scrub_block(%{type: :text, text: text} = block),
    do: %{block | text: String.replace_invalid(text)}

  defp scrub_block(%{type: :tool_result, content: content} = block),
    do: %{block | content: String.replace_invalid(content)}

  defp scrub_block(block), do: block

  def tool_calls(%__MODULE__{content: content}),
    do: Enum.filter(content, &(&1.type == :tool_call))

  def text_content(%__MODULE__{content: content}) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end
end
