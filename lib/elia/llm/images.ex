defmodule Elia.LLM.Images do
  @moduledoc """
  The pictures a request carries (`specs/image-input.md`).

  A picture reaches a model because the agent looked at one: a call records the
  path it read on its own tool result (VISION-12), and that file is read from the
  chat's workspace as the request is built (VISION-3) — becoming an `:image`
  content block (LLM-5) in that result's own turn (VISION-14) — and again at
  every step, so a result still in the request view keeps sending its picture
  (VISION-9). Nothing here is stored: the saved chat keeps the path a look
  recorded and no picture, and a message's attachments are only the paths they
  name (VISION-15).

  A file is an image only when its extension names a format both APIs accept and
  its bytes are that format (VISION-2) — `.png`, `.jpg`, `.jpeg`, `.webp`,
  `.gif`, whatever the case of the extension. Only so much of a request's
  pictures is sent: 5 MB for one picture and 15 MB together, taken from the
  newest message first, so an older picture is dropped before the one the agent
  has just looked at (VISION-6). Anything that can't be read — a path that
  leaves the workspace or goes through a symlink, a file that isn't there, isn't
  a regular file, is too large or doesn't begin with the format its extension
  names — is left out of the request rather than failing the turn (VISION-5).
  """

  alias Elia.LLM.Message

  # VISION-6: what one picture and one request of them may be.
  @max_image_bytes 5 * 1024 * 1024
  @max_total_bytes 15 * 1024 * 1024

  # The formats both APIs accept (VISION-2), by extension.
  @media_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".webp" => "image/webp",
    ".gif" => "image/gif"
  }

  @doc """
  The messages a request is given, with the pictures the tool results among them
  recorded a look at (VISION-14).

  `false` for `vision?` leaves every message exactly as it is, so a model that
  accepts no pictures is sent what it is sent today (VISION-4) — and a look on
  such a model is refused before any path is recorded (VISION-13). `workspace`
  is the tree the paths resolve in: the chat's own workspace (VISION-3).
  """
  @spec attach([Message.t()], String.t() | nil, boolean()) :: [Message.t()]
  def attach(messages, _workspace, false), do: messages

  def attach(messages, workspace, true) when is_list(messages) do
    taken = take(messages, workspace)

    messages
    |> Enum.with_index()
    |> Enum.map(fn {message, index} -> put_images(message, Map.get(taken, index, [])) end)
  end

  @doc "The media type a path's extension names, or `nil` (VISION-2)."
  @spec media_type(String.t() | term()) :: String.t() | nil
  def media_type(path) when is_binary(path),
    do: Map.get(@media_types, String.downcase(Path.extname(path)))

  def media_type(_path), do: nil

  @doc """
  The picture a tool result recorded a look at (VISION-12):
  `%{path: p, media_type: t, size: n}` — the path the call named and what reading
  it found — or `nil` for a result that looked at nothing.
  """
  @spec looked_at(map() | term()) :: map() | nil
  def looked_at(%{type: :tool_result, image: %{path: path} = image}) when is_binary(path),
    do: image

  def looked_at(_result), do: nil

  @doc """
  Reads one picture of `workspace` (VISION-3): `{:ok, block}` when it is an image
  that can be sent, and `{:error, reason}` otherwise, where `reason` says which
  it was — `:not_an_image` (VISION-2), `:forbidden`, `:not_found`, `:not_a_file`,
  `:unreadable` (VISION-5) or `:too_large` (VISION-6). `budget` is the room the
  request has left for pictures.

  The block is what a request carries and nothing else: the media type, the
  bytes in base64, and the path and size for the chat to render and count by.
  """
  @spec read(String.t() | nil, String.t(), pos_integer()) ::
          {:ok, map()} | {:error, atom()}
  def read(workspace, path, budget \\ @max_total_bytes)

  def read(workspace, path, budget) when is_binary(workspace) and is_binary(path) do
    with {:ok, media} <- image_type(path),
         {:ok, abs} <- file_path(path, workspace),
         {:ok, size} <- file_size(abs),
         {:ok, data} <- file_data(abs, size),
         :ok <- bytes(media, data) do
      if size <= @max_image_bytes and size <= budget do
        {:ok,
         %{type: :image, media_type: media, data: Base.encode64(data), path: path, size: size}}
      else
        {:error, :too_large}
      end
    end
  end

  def read(_workspace, _path, _budget), do: {:error, :not_found}

  @doc """
  The picture at `path` as a request's reader wants it: `{:ok, block}`,
  `:skip` for a path that isn't an image or can't be read (VISION-2, VISION-5),
  and `{:error, :too_large}` for one the request has no room for (VISION-6).
  """
  @spec load(String.t() | nil, String.t(), pos_integer()) ::
          {:ok, map()} | {:error, :too_large} | :skip
  def load(workspace, path, budget \\ @max_total_bytes) do
    case read(workspace, path, budget) do
      {:ok, block} -> {:ok, block}
      {:error, :too_large} -> {:error, :too_large}
      {:error, _reason} -> :skip
    end
  end

  # VISION-6, VISION-14: the pictures one request carries are the ones its own
  # tool results recorded (VISION-12), read here and bounded — walked from the
  # end of the request view, so the newest message's picture is taken before an
  # older one's and the one the agent has just looked at is the one that is sent.
  defp take(messages, workspace) do
    {taken, _budget} =
      messages
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.reduce({%{}, @max_total_bytes}, fn {message, index}, {taken, budget} ->
        case images_of(message, workspace, budget) do
          {[], budget} -> {taken, budget}
          {blocks, budget} -> {Map.put(taken, index, blocks), budget}
        end
      end)

    taken
  end

  defp images_of(%Message{content: content}, workspace, budget) when is_list(content) do
    {blocks, budget} =
      content
      |> Enum.filter(&looked_at/1)
      |> Enum.map(& &1.image)
      |> Enum.reduce({[], budget}, fn image, {blocks, budget} ->
        case load(workspace, image.path, budget) do
          {:ok, block} -> {[block | blocks], budget - block.size}
          _none -> {blocks, budget}
        end
      end)

    {Enum.reverse(blocks), budget}
  end

  defp images_of(_message, _workspace, budget), do: {[], budget}

  # VISION-14: a result that looked at something carries its picture itself, so
  # the request's own result keeps it (VISION-9) and no other message grows one.
  defp put_images(message, []), do: message

  defp put_images(%Message{content: content} = message, images) when is_list(content),
    do: %Message{message | content: content ++ images}

  defp put_images(message, _images), do: message

  defp image_type(path) do
    case media_type(path) do
      nil -> {:error, :not_an_image}
      media -> {:ok, media}
    end
  end

  defp file_path(path, workspace) do
    case Elia.Explorer.safe_path(path, workspace) do
      {:ok, abs} -> {:ok, abs}
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  defp file_size(abs) do
    case File.stat(abs) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      {:ok, _other} -> {:error, :not_a_file}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # A file that changed between the stat and the read is not the file the size
  # named, so it is left alone rather than sent half-read.
  defp file_data(abs, size) do
    case File.read(abs) do
      {:ok, data} when byte_size(data) == size -> {:ok, data}
      _none -> {:error, :unreadable}
    end
  end

  # VISION-2: the bytes have to be the format the extension names — a renamed
  # file is not an image.
  defp bytes(media, data) do
    if signature?(media, data), do: :ok, else: {:error, :not_an_image}
  end

  defp signature?("image/png", <<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>), do: true
  defp signature?("image/jpeg", <<0xFF, 0xD8, _rest::binary>>), do: true
  defp signature?("image/gif", <<"GIF8", _rest::binary>>), do: true

  defp signature?("image/webp", <<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>),
    do: true

  defp signature?(_media, _data), do: false
end
