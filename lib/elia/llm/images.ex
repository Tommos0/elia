defmodule Elia.LLM.Images do
  @moduledoc """
  The images a request carries (`specs/image-input.md`).

  A file that a message's attachments name (UPLOAD-11) is read from the chat's
  workspace when the request is built (VISION-3) and becomes an `:image` content
  block (LLM-5) in that message's own turn (VISION-1). Nothing here is stored:
  the saved chat keeps the paths and no picture.

  An attachment is an image only when its extension names a format both APIs
  accept and its bytes are that format (VISION-2) — `.png`, `.jpg`, `.jpeg`,
  `.webp`, `.gif`, whatever the case of the extension. Only so much of a
  request's images is sent: 5 MB for one and 15 MB together, taken from the
  newest message first, so an old picture is dropped before the one the user
  just sent (VISION-6). Anything that can't be read — a path that leaves the
  workspace or goes through a symlink, a file that isn't there, isn't a regular
  file, is too large or doesn't begin with the format its extension names — is
  left out of the request rather than failing the turn (VISION-5).
  """

  alias Elia.LLM.Message

  # VISION-6
  @max_image_bytes 5 * 1024 * 1024
  @max_total_bytes 15 * 1024 * 1024

  @doc """
  The messages a request is given, with the images their attachments carry
  (VISION-1).

  `vision?` false leaves every message as it is, so a model that accepts no
  images is asked what it is asked today (VISION-4). Otherwise a message that
  carries an image attachment is given one `:image` block per image, after the
  blocks it already has and in the order the files were attached (VISION-1).
  """
  @spec attach([Message.t()], binary() | nil, boolean()) :: [Message.t()]
  def attach(messages, _workspace, false), do: messages

  def attach(messages, workspace, true) when is_list(messages) do
    taken = take(messages, workspace)

    messages
    |> Enum.with_index()
    |> Enum.map(fn {message, index} -> put_images(message, Map.get(taken, index, [])) end)
  end

  @doc """
  Whether an attachment names an image format by its extension (VISION-2),
  which is what the context estimate counts (VISION-10) without reading it.
  """
  @spec attachment?(binary()) :: boolean()
  def attachment?(path) when is_binary(path), do: media_type(path) != nil

  @doc "The media type a path's extension names, or `nil` (VISION-2)."
  @spec media_type(binary()) :: binary() | nil
  def media_type(path) when is_binary(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _other -> nil
    end
  end

  @doc """
  Reads one attachment (VISION-3): `{:ok, block}` when it is an image that can
  be sent, `:skip` when it is not one or cannot be read (VISION-2, VISION-5),
  and `{:error, :too_large}` when it is one but is over the bound for a single
  image or over `budget`, the room the request has left (VISION-6).
  """
  @spec load(binary() | nil, binary(), non_neg_integer()) ::
          {:ok, map()} | {:error, :too_large} | :skip
  def load(workspace, path, budget \\ @max_total_bytes)

  def load(workspace, path, budget) when is_binary(workspace) and is_binary(path) do
    with media when is_binary(media) <- media_type(path),
         {:ok, abs} <- Elia.Explorer.safe_path(path, workspace),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(abs),
         {:ok, data} when byte_size(data) == size <- File.read(abs),
         true <- signature?(media, data) do
      if size <= @max_image_bytes and size <= budget do
        {:ok, %{type: :image, media_type: media, data: Base.encode64(data), path: path}}
      else
        {:error, :too_large}
      end
    else
      _not_an_image -> :skip
    end
  end

  def load(_workspace, _path, _budget), do: :skip

  # VISION-6: the images of a request are bounded, and the newest message's are
  # taken first — the walk is from the end of the request view — so what the
  # user just sent is sent before a picture from earlier in the chat. A message
  # that keeps none of its images is left exactly as it is (VISION-5).
  defp take(messages, workspace) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.reduce({%{}, @max_total_bytes}, fn {message, index}, {taken, budget} ->
      {blocks, budget} =
        message
        |> Message.attachments()
        |> Enum.reduce({[], budget}, fn path, {blocks, budget} ->
          case load(workspace, path, budget) do
            {:ok, block} -> {[block | blocks], budget - byte_size(block.data)}
            _none -> {blocks, budget}
          end
        end)

      {if(blocks == [], do: taken, else: Map.put(taken, index, Enum.reverse(blocks))), budget}
    end)
    |> elem(0)
  end

  defp put_images(message, []), do: message

  defp put_images(%Message{content: content} = message, images),
    do: %{message | content: content ++ images}

  # VISION-2: the bytes must be the format the extension names, since a provider
  # is told the media type and would reject the mismatch as a broken request.
  defp signature?("image/png", <<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>), do: true
  defp signature?("image/jpeg", <<0xFF, 0xD8, 0xFF, _rest::binary>>), do: true
  defp signature?("image/gif", <<"GIF8", _rest::binary>>), do: true

  defp signature?("image/webp", <<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>),
    do: true

  defp signature?(_media_type, _data), do: false
end
