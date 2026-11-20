defmodule Elia.Skills.Image do
  @moduledoc """
  Looking at a picture of the chat's workspace (`specs/image-input.md`).

  A model that can see pictures reads one because the agent asked for it
  (VISION-12, VISION-15): the `view_image` call names a path, this reads that
  file, and the picture rides on the call's own result (VISION-14) — a screenshot
  the user uploaded (UPLOAD-10), or one the agent made itself with a preview
  (PREVIEW). The saved chat keeps the path the look recorded and no picture
  (VISION-15).

  A look that cannot be answered fails with the reason rather than an empty
  picture (VISION-13): a path outside the chat's workspace, a file that isn't
  there or isn't an image, one over the bound for a single picture, and a model
  that accepts no pictures.
  """

  @behaviour Elia.Skill

  alias Elia.LLM.Images

  @impl true
  def name, do: "image"

  @impl true
  def description, do: "Look at a picture in the chat's workspace."

  @impl true
  def instructions do
    """
    A picture is looked at with the `view_image` tool, never guessed from its \
    path: an image the user attached, or one you made yourself with a preview, \
    is something you can see only once you have looked at it — the file's path \
    is all a message carries. Look when what the picture shows may change your \
    answer, and look again after it changes.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "view_image",
        description:
          "Look at one picture of the chat's workspace: reads the file at `path` and " <>
            "sends its picture to the model with this call's own result, so you can " <>
            "answer about what it shows. A path outside the chat's workspace, a file " <>
            "that isn't there, one that isn't a PNG, JPEG, WebP or GIF, one over 5 MB, " <>
            "and a model that accepts no pictures all fail with the reason.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "The picture's path in the chat's workspace"
            }
          },
          "required" => ["path"]
        },
        approval: :never,
        run: &run/2
      }
    ]
  end

  @doc """
  Reads one picture of the chat's workspace (VISION-12): `{:ok, text, facts}`,
  where the text says which picture was looked at and `facts` records the path,
  the media type and the size it read (VISION-14) — or `{:error, text}` saying
  why it could not be looked at (VISION-13).
  """
  @spec run(map(), map()) :: {:ok, binary(), Elia.Tool.facts()} | {:error, binary()}
  def run(input, ctx \\ %{}) do
    path = input["path"]

    with :ok <- vision(ctx),
         {:ok, block} <- Images.read(workspace(ctx), path) do
      {:ok,
       "Looked at #{path} (#{block.media_type}, #{Elia.SystemStats.format_bytes(block.size)}); " <>
         "its picture is sent with this result.",
       %{image: %{path: block.path, media_type: block.media_type, size: block.size}}}
    else
      {:error, reason} -> {:error, refusal(reason, path)}
    end
  end

  # VISION-4, VISION-7, VISION-13: a model that accepts no pictures is refused
  # before anything is read, so no path is recorded either.
  defp vision(%{vision: true}), do: :ok
  defp vision(_ctx), do: {:error, :no_vision}

  defp refusal(:no_vision, _path),
    do: "This chat's model accepts no pictures, so looking at one would send nothing (VISION-7)."

  defp refusal(:forbidden, path),
    do: "#{path} is not a path in the chat's workspace, so it can't be looked at."

  defp refusal(:not_found, path), do: "There is no file at #{path}."
  defp refusal(:not_a_file, path), do: "#{path} is not a regular file."
  defp refusal(:unreadable, path), do: "#{path} couldn't be read."

  defp refusal(:not_an_image, path),
    do:
      "#{path} is not an image: a picture needs a .png, .jpg, .jpeg, .webp or .gif " <>
        "extension and bytes of that format."

  defp refusal(:too_large, path),
    do: "#{path} is larger than the 5 MB a single picture may be."

  defp workspace(ctx), do: ctx[:workspace] || Elia.Workspace.root()
end
