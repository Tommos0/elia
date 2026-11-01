defmodule EliaWeb.FilesLive do
  @moduledoc """
  Read-only workspace browser: a directory listing next to a plain-text file
  viewer. See `specs/file-explorer.md`.
  """
  use EliaWeb, :live_view

  alias Elia.{Explorer, SystemStats, Workspace}

  @highlight_max 128 * 1024

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Files")}
  end

  # EXPL-6, EXPL-9, EXPL-15
  @impl true
  def handle_params(params, _uri, socket) do
    project = project(params["project"])
    root = project.folder
    path = normalize(root, params["path"])

    {dir, file, error} =
      case Explorer.list(path, root) do
        {:ok, _} -> {path, nil, nil}
        {:error, :not_a_directory} -> {parent(path), path, nil}
        {:error, reason} -> {"", nil, reason}
      end

    {viewer, error} =
      case file && Explorer.read(file, root) do
        nil -> {nil, error}
        {:ok, data} -> {data, nil}
        {:error, :binary} -> {{:binary, file}, nil}
        {:error, reason} -> {nil, reason}
      end

    # The listing is read again after the viewer so that a vanished directory
    # falls back to the project root instead of crashing.
    {dir, entries} =
      case Explorer.list(dir, root) do
        {:ok, entries} -> {dir, entries}
        {:error, _} -> {"", elem(Explorer.list("", root), 1)}
      end

    {:noreply,
     assign(socket,
       project: project,
       projects: Elia.Projects.list(),
       dir: dir,
       entries: entries,
       selected: file,
       viewer: viewer,
       error: error,
       crumbs: crumbs(dir)
     )}
  end

  # EXPL-15: a missing or unknown project id browses Elia's own project.
  defp project(nil), do: Elia.Projects.harness()
  defp project(id), do: Elia.Projects.get(id) || Elia.Projects.harness()

  # EXPL-16: switch the browsed project, keeping the current path when it
  # exists in the new project (it falls back to that project's root otherwise).
  @impl true
  def handle_event("pick_project", %{"project" => id}, socket) do
    project = Elia.Projects.get(id) || Elia.Projects.harness()
    path = socket.assigns.selected || socket.assigns.dir
    path = if exists?(project, path), do: path, else: ""
    {:noreply, push_patch(socket, to: files_path(project, path))}
  end

  # EXPL-16: only keep the current path when the new project has it; otherwise
  # fall back to that project's root.
  defp exists?(project, path) do
    with true <- path != "",
         {:ok, abs} <- Explorer.safe_path(path, project.folder) do
      File.exists?(abs)
    else
      _ -> false
    end
  end

  defp normalize(_root, nil), do: ""

  defp normalize(root, path) when is_binary(path) do
    case Explorer.safe_path(path, root) do
      {:ok, abs} -> relative(abs, root)
      {:error, _} -> path
    end
  end

  defp normalize(_root, _path), do: ""

  defp relative(abs, root) do
    case Workspace.relative(abs, root) do
      "." -> ""
      rel -> rel
    end
  end

  defp parent(path) do
    case Path.dirname(path) do
      "." -> ""
      dir -> dir
    end
  end

  # EXPL-7
  defp crumbs(dir) do
    parts = if dir == "", do: [], else: Path.split(dir)

    parts
    |> Enum.scan("", fn part, acc -> Path.join(acc, part) end)
    |> Enum.zip(parts)
    |> Enum.map(fn {path, name} -> {name, path} end)
  end

  # EXPL-15: the default project's links stay param-free, so the URLs are stable.
  defp files_path(project, path) do
    params = if project.harness?, do: %{}, else: %{project: project.id}
    params = if path == "", do: params, else: Map.put(params, :path, path)

    if params == %{}, do: ~p"/files", else: ~p"/files?#{params}"
  end

  defp lines(content) do
    parts = String.split(content, "\n")
    if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
  end

  # EXPL-12: only small, complete files are highlighted.
  defp language(%{truncated?: false, size: size, path: path}) when size <= @highlight_max,
    do: Explorer.language(path)

  defp language(_viewer), do: nil

  defp gutter(0), do: ""
  defp gutter(count), do: Enum.map_join(1..count, "\n", &Integer.to_string/1)

  # EXPL-9
  defp error_message(:forbidden), do: "That path can't be browsed."
  defp error_message(:not_found), do: "That path doesn't exist."
  defp error_message(_), do: "That path couldn't be read."

  @impl true
  def render(assigns) do
    assigns =
      case assigns.viewer do
        %{content: content} ->
          count = content |> lines() |> length()

          assign(assigns,
            line_count: count,
            gutter: gutter(count),
            language: language(assigns.viewer)
          )

        _ ->
          assign(assigns, line_count: 0, gutter: "", language: nil)
      end

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex h-full flex-col lg:flex-row">
        <aside
          id="file-list"
          class="flex max-h-72 min-h-0 shrink-0 flex-col border-b border-base-300 lg:max-h-none lg:w-80 lg:border-r lg:border-b-0"
        >
          <div class="flex items-center gap-2 border-b border-base-300 px-4 py-2">
            <span
              id="project-name"
              class="min-w-0 flex-1 truncate text-sm font-medium"
              title={@project.folder}
            >
              {@project.name}
            </span>
            <form id="project-switch" phx-change="pick_project">
              <select
                id="project-picker"
                name="project"
                aria-label="Project"
                class="max-w-40 rounded-lg border border-base-300 bg-base-200/50 px-2 py-1 text-xs outline-none transition focus:border-primary focus:bg-base-100"
              >
                <option :for={p <- @projects} value={p.id} selected={p.id == @project.id}>
                  {p.name}
                </option>
              </select>
            </form>
          </div>
          <nav
            id="breadcrumbs"
            aria-label="Breadcrumb"
            class="flex flex-wrap items-center gap-x-1 border-b border-base-300 px-4 py-2.5 text-sm"
          >
            <.link patch={files_path(@project, "")} class="font-medium hover:underline">
              workspace
            </.link>
            <span :for={{name, path} <- @crumbs} class="flex items-center gap-1">
              <span class="text-base-content/40">/</span>
              <.link patch={files_path(@project, path)} class="hover:underline">{name}</.link>
            </span>
          </nav>

          <ul class="min-h-0 flex-1 overflow-y-auto p-2 text-sm">
            <li :if={@dir != ""}>
              <.link
                id="parent-dir"
                patch={files_path(@project, parent(@dir))}
                class="flex items-center gap-2 rounded-lg px-2 py-1.5 transition hover:bg-base-200"
              >
                <.icon name="hero-arrow-uturn-left" class="size-4 text-base-content/50" /> ..
              </.link>
            </li>
            <li :if={@entries == []} class="px-2 py-6 text-center text-base-content/50">
              Empty directory
            </li>
            <li :for={entry <- @entries}>
              <.link
                :if={entry.type in [:dir, :file]}
                data-entry={entry.path}
                patch={files_path(@project, entry.path)}
                aria-current={@selected == entry.path && "true"}
                class={[
                  "flex items-center gap-2 rounded-lg px-2 py-1.5 transition hover:bg-base-200",
                  @selected == entry.path && "bg-primary/10 font-medium text-primary"
                ]}
              >
                <.icon
                  name={if entry.type == :dir, do: "hero-folder", else: "hero-document-text"}
                  class="size-4 shrink-0 text-base-content/50"
                />
                <span class="min-w-0 flex-1 truncate">{entry.name}</span>
                <span
                  :if={entry.size}
                  class="shrink-0 font-mono text-xs tabular-nums text-base-content/40"
                >
                  {SystemStats.format_bytes(entry.size)}
                </span>
              </.link>
              <span
                :if={entry.type not in [:dir, :file]}
                data-entry={entry.path}
                class="flex items-center gap-2 px-2 py-1.5 text-base-content/40"
                title="Not opened"
              >
                <.icon name="hero-link" class="size-4 shrink-0" />
                <span class="min-w-0 flex-1 truncate">{entry.name}</span>
                <span class="text-xs">{if entry.type == :symlink, do: "symlink", else: "special"}</span>
              </span>
            </li>
          </ul>
        </aside>

        <section id="file-viewer" class="flex min-h-0 min-w-0 flex-1 flex-col">
          <%= cond do %>
            <% @error -> %>
              <div
                id="file-error"
                role="alert"
                class="m-6 flex items-center gap-2 rounded-xl border border-error/30 bg-error/10 px-4 py-3 text-sm text-error"
              >
                <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
                {error_message(@error)}
              </div>
            <% match?({:binary, _}, @viewer) -> %>
              <.file_header path={elem(@viewer, 1)} />
              <p id="file-binary" class="m-6 text-sm text-base-content/60">
                This looks like a binary file, so it isn't shown.
              </p>
            <% @viewer -> %>
              <.file_header path={@viewer.path} size={@viewer.size} lines={@line_count} />
              <p
                :if={@viewer.truncated?}
                id="file-truncated"
                class="border-b border-warning/30 bg-warning/10 px-4 py-1.5 text-xs text-warning"
              >
                Showing the first {SystemStats.format_bytes(Explorer.max_bytes())} of this file.
              </p>
              <div class="min-h-0 flex-1 overflow-auto font-mono text-[13px] leading-5">
                <div class="flex min-w-max py-3">
                  <%!-- Plain divs: whitespace must be kept exactly, and <pre> drops a leading newline. --%>
                  <div
                    id="file-gutter"
                    phx-no-format
                    aria-hidden="true"
                    class="sticky left-0 select-none whitespace-pre bg-base-100 px-3 text-right text-base-content/35"
                  >{@gutter}</div>
                  <div
                    id="file-content"
                    phx-no-format
                    phx-hook="Highlight"
                    data-language={@language}
                    class="whitespace-pre pr-6 pl-3"
                  >{@viewer.content}</div>
                </div>
              </div>
            <% true -> %>
              <div
                id="file-placeholder"
                class="grid flex-1 place-items-center text-sm text-base-content/50"
              >
                <div class="text-center">
                  <.icon name="hero-document-magnifying-glass" class="mb-2 size-8" />
                  <p>Select a file to view it</p>
                </div>
              </div>
          <% end %>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :path, :string, required: true
  attr :size, :integer, default: nil
  attr :lines, :integer, default: nil

  defp file_header(assigns) do
    ~H"""
    <header
      id="file-header"
      class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 border-b border-base-300 px-4 py-2.5"
    >
      <h1 id="file-path" class="min-w-0 truncate font-mono text-sm font-medium">{@path}</h1>
      <p :if={@size} class="text-xs text-base-content/50">
        {SystemStats.format_bytes(@size)} · {@lines} {if @lines == 1, do: "line", else: "lines"}
      </p>
    </header>
    """
  end
end
