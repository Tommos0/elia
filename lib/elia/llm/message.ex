defmodule Elia.LLM.Message do
  @moduledoc """
  Provider-neutral conversation message.

  `content` is a list of blocks (plain maps):

    * `%{type: :text, text: binary}`
    * `%{type: :reasoning, text: binary}` - model reasoning / progress notes
    * `%{type: :tool_call, id: binary, name: binary, input: map}`
    * `%{type: :tool_result, tool_call_id: binary, content: binary, is_error: boolean}`
    * `%{type: :image, media_type: binary, data: binary, path: binary}` - a picture
      read from the chat's workspace as the request is built (VISION); the bytes
      are base64 and nothing of it is stored
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

  @doc """
  A user-role message that carries files (UPLOAD-10, UPLOAD-11).

  `attachments` are their paths relative to the chat's own workspace (UPLOAD-6),
  in the order they were attached. The message says what the user wrote and then
  the one line naming those paths (UPLOAD-10), and `meta` records them
  (UPLOAD-11) — a provider is never sent `meta` (LLM-5).
  """
  @spec user(binary(), [binary()]) :: t()
  def user(text, []), do: user(text)

  def user(text, attachments) when is_binary(text) and is_list(attachments) do
    line = %{type: :text, text: note_text(attachments), note: :uploads}

    content =
      case String.trim(text) do
        "" -> [line]
        _text -> [text(text), %{line | text: "\n\n" <> line.text}]
      end

    %__MODULE__{role: :user, content: content, meta: %{attachments: attachments}}
  end

  @doc """
  The files a message carries (UPLOAD-11), workspace-relative and in the order
  they were attached — `[]` for a message that carries none.
  """
  @spec attachments(t() | term()) :: [binary()]
  def attachments(%__MODULE__{meta: meta}) when is_map(meta) do
    Map.get(meta, :attachments) || []
  end

  def attachments(_message), do: []

  @doc """
  The text the user wrote (UPLOAD-12): a message's text without UPLOAD-10's line
  naming the files it carries, which is the harness's own.
  """
  @spec user_text(t()) :: binary()
  def user_text(%__MODULE__{content: content}) do
    content
    |> Enum.filter(&wrote?/1)
    |> Enum.map_join("", & &1.text)
  end

  defp wrote?(%{type: :text} = block), do: Map.get(block, :note) == nil
  defp wrote?(_block), do: false

  # UPLOAD-10: the line naming the paths, which is where the agent reads them.
  defp note_text(attachments), do: "[Uploaded files: #{Enum.join(attachments, ", ")}]"

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

  # SNAP-6: a tool may hand back facts about its call to save beside its result
  # — a `shell` call's snapshot pair — which the providers' encoders never send
  # (LLM-6, LLM-32), and a block saved without them reads as it always did.
  def tool_result(tool_call_id, content, is_error \\ false, facts \\ %{}) do
    # LLM-32: tools can return raw bytes, which can't be JSON-encoded.
    %{
      type: :tool_result,
      tool_call_id: tool_call_id,
      content: String.replace_invalid(content),
      is_error: is_error
    }
    |> Map.merge(Map.drop(facts, [:type, :tool_call_id, :content, :is_error]))
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
