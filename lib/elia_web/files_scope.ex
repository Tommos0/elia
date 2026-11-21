defmodule EliaWeb.FilesScope do
  @moduledoc """
  Which workspace a Files URL browses, for the page and for the route that
  serves a preview's bytes (`specs/file-explorer.md`, EXPL-24): the open project
  (EXPL-15, PROJ-28) or the project of the chat a `chat` parameter names, which
  wins (EXPL-17) — so both answer the same question the same way, and what the
  page previews is what the route serves (EXPL-25).
  """

  alias Elia.{Projects, Store}

  @doc """
  The project and the chat in view for `params`, `{project, chat}`, where `chat`
  is a saved chat's id or `nil` (EXPL-15, EXPL-17).
  """
  @spec viewed(map()) :: {Projects.t(), String.t() | nil}
  def viewed(params) do
    chat = chat(params["chat"])
    {(chat && project_of(chat)) || project(), chat}
  end

  @doc "The workspace the page browses for `params` (EXPL-15, EXPL-17)."
  @spec root(map()) :: String.t()
  def root(params) do
    {project, _chat} = viewed(params)
    project.folder
  end

  # EXPL-17: a chat in view is a saved chat, or nothing.
  defp chat(id) do
    if is_binary(id) and Store.exists?(id), do: id
  end

  # PROJ-9: a chat without a project belongs to Elia's own.
  defp project_of(chat) do
    case Store.load_project(chat) do
      nil -> Projects.harness()
      id -> Projects.get(id) || Projects.harness()
    end
  end

  # EXPL-15: with no chat in view the page browses the open project (PROJ-8).
  defp project, do: Projects.default()
end
