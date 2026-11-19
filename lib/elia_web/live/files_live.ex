defmodule EliaWeb.FilesLive do
  @moduledoc """
  Read-only workspace browser: a directory listing next to a viewer that shows a
  text file as text and previews what the browser renders itself (EXPL-22 - EXPL-26).
  See `specs/file-explorer.md`.
  """
  use EliaWeb, :live_view

  alias Elia.{Explorer, Store, SystemStats, Workspace}
  alias EliaWeb.FilesScope

  @highlight_max 128 * 1024

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Files")}
  end

  # EXPL-6, EXPL-9, EXPL-15, EXPL-17, EXPL-19
  @impl true
  def handle_params(params, _uri, socket) do
    {project, chat} = FilesScope.viewed(params)
    root = project.folder
    path = normalize(root, params["path"])

    {dir, file, error} =
      case Explorer.list(path, root) do
        {:ok, _} -> {path, nil, nil}
        {:error, :not_a_directory} -> {parent(path), path, nil}
        {:error, reason} -> {"", nil, reason}
      end

    # EXPL-8, EXPL-23: a file the browser renders itself is previewed rather
    # than read as text, and EXPL-25 refuses that when the file can't be shown.
    {viewer, error} =
      case file && view(file, root) do
        nil -> {nil, error}
        {:ok, viewer} -> {viewer, nil}
        {:error, :binary} -> {{:binary, file}, nil}
        {:error, reason} -> {nil, reason}
      end

    # EXPL-24, EXPL-26: the URL the browser fetches a preview from, which the
    # page's own parameters carry so the route serves the file it browsed.
    raw =
      case viewer do
        {:preview, preview} -> raw_path(project, preview.path, chat)
        _ -> nil
      end

    # The listing is read again after the viewer so that a vanished directory
    # falls back to the project root instead of crashing (EXPL-9) — and so that
    # a root which is itself unavailable reports that, rather than putting an
    # error atom where the listing belongs (EXPL-19).
    {dir, entries, root_error} =
      case Explorer.list(dir, root) do
        {:ok, entries} -> {dir, entries, nil}
        {:error, _} -> root_listing(root)
      end

    # EXPL-19: an unavailable root is what the page reports, not the path that
    # couldn't be reached inside it.
    error = if root_error, do: nil, else: error

    {:noreply,
     assign(socket,
       project: project,
       chat: chat,
       chat_title: chat && Store.chat_title(chat),
       root: root,
       projects: Elia.Projects.list(),
       dir: dir,
       entries: entries,
       selected: file,
       viewer: viewer,
       raw: raw,
       line: line(params, viewer),
       error: error,
       root_error: root_error,
       crumbs: crumbs(dir)
     )}
  end

  # EXPL-8, EXPL-22, EXPL-25: a file the browser renders itself is a preview,
  # which the page shows once the same check the route serves by has confirmed
  # it is a file of this workspace; every other file is read as text.
  defp view(file, root) do
    case Explorer.preview_file(file, root) do
      {:ok, preview} -> {:ok, {:preview, preview}}
      {:error, :no_preview} -> Explorer.read(file, root)
      {:error, reason} -> {:error, reason}
    end
  end

  # EXPL-27: the line a link named, when the text in view has it. It is
  # ignored otherwise — a `line` that isn't a positive whole number, one past
  # the text shown (a truncated file's text is only what is shown), and one
  # that comes with no text at all (a preview, a binary file, a directory) —
  # so the file opens as it otherwise would. EXPL-28: it is never carried
  # along, since `files_path/3` builds every other URL without it.
  defp line(%{"line" => value}, %{content: content}) when is_binary(value) do
    count = content |> lines() |> length()

    with {number, ""} <- Integer.parse(value),
         true <- number > 0,
         true <- number <= count do
      number
    else
      _ -> nil
    end
  end

  defp line(_params, _viewer), do: nil

  # EXPL-9, EXPL-19: the fallback is the browsed root's own listing; a root that
  # can't be listed leaves an empty listing and the error to report.
  defp root_listing(root) do
    case Explorer.list("", root) do
      {:ok, entries} -> {"", entries, nil}
      {:error, reason} -> {"", [], reason}
    end
  end

  # EXPL-16, EXPL-18: switch the browsed project, keeping the current path when
  # it exists in the new project (it falls back to that project's root
  # otherwise). It leaves a chat in view behind, so the page browses the
  # project's own folder.
  @impl true
  def handle_event("pick_project", %{"project" => id}, socket) do
    project = Elia.Projects.get(id) || Elia.Projects.harness()
    path = socket.assigns.selected || socket.assigns.dir
    path = if exists?(project, path), do: path, else: ""
    {:noreply, push_patch(socket, to: files_path(project, path, nil))}
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

  # EXPL-15, EXPL-17: the default project's links stay param-free, so the URLs
  # are stable; a chat in view is named instead of its project, which the page
  # takes from the chat (EXPL-18).
  defp scope_params(project, chat) do
    params = if project.harness? or chat, do: %{}, else: %{project: project.id}
    if chat, do: Map.put(params, :chat, chat), else: params
  end

  defp files_path(project, path, chat) do
    params = scope_params(project, chat)
    params = if path == "", do: params, else: Map.put(params, :path, path)

    if params == %{}, do: ~p"/files", else: ~p"/files?#{params}"
  end

  # EXPL-24, EXPL-26: the route that serves a preview's bytes takes the same
  # parameters as the page, so it serves the file the page is showing.
  defp raw_path(project, path, chat) do
    ~p"/files/raw?#{Map.put(scope_params(project, chat), :path, path)}"
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

  # EXPL-19
  defp root_error_message(:not_found, root),
    do: "This project's folder is no longer there: #{root}"

  defp root_error_message(:not_a_directory, root),
    do: "This project's folder isn't a directory: #{root}"

  defp root_error_message(_reason, root), do: "This project's folder can't be read: #{root}"

  # PROJ-27: a project whose folder is gone is marked rather than dropped from
  # the picker, since the folder may only be temporarily away.
  defp project_label(project) do
    if File.dir?(project.folder), do: project.name, else: project.name <> " (unavailable)"
  end

  # EXPL-8, EXPL-23: a preview has no text, so it has no line count, gutter or
  # language to prepare either.
  defp text_assigns(assigns) do
    case assigns.viewer do
      %{content: content} ->
        count = content |> lines() |> length()

        assign(assigns,
          line_count: count,
          gutter: gutter(count),
          language: language(assigns.viewer)
        )

      {:preview, preview} ->
        assign(assigns, preview: preview, line_count: 0, gutter: "", language: nil)

      _ ->
        assign(assigns, line_count: 0, gutter: "", language: nil)
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(preview: nil)
      |> text_assigns()

    ~H"""
    <Layouts.app flash={@flash} chats={@chat_list} notifications={@notifications}>
      <div class="flex h-full flex-col lg:flex-row">
        <aside
          id="file-list"
          class="flex max-h-72 min-h-0 shrink-0 flex-col border-b border-base-300 lg:max-h-none lg:w-80 lg:border-r lg:border-b-0"
        >
          <div class="flex items-center gap-2 border-b border-base-300 px-4 py-2">
            <div class="min-w-0 flex-1">
              <span
                id="project-name"
                class="block truncate text-sm font-medium"
                title={@project.folder}
              >
                {@project.name}
              </span>
              <%!-- EXPL-18: a chat in view browses its own workspace, not the
              project's folder, so the page names it. --%>
              <span
                :if={@chat}
                id="workspace-note"
                class="flex items-center gap-1 text-xs text-base-content/50"
                title={@root}
              >
                <.icon name="hero-chat-bubble-left-right" class="size-3.5 shrink-0" />
                <span class="truncate">{@chat_title}</span>
              </span>
            </div>
            <form id="project-switch" phx-change="pick_project">
              <select
                id="project-picker"
                name="project"
                aria-label="Project"
                class="max-w-40 rounded-lg border border-base-300 bg-base-200/50 px-2 py-1 text-xs outline-none transition focus:border-primary focus:bg-base-100"
              >
                <option :for={p <- @projects} value={p.id} selected={p.id == @project.id}>
                  {project_label(p)}
                </option>
              </select>
            </form>
          </div>
          <nav
            id="breadcrumbs"
            aria-label="Breadcrumb"
            class="flex flex-wrap items-center gap-x-1 border-b border-base-300 px-4 py-2.5 text-sm"
          >
            <.link patch={files_path(@project, "", @chat)} class="font-medium hover:underline">
              workspace
            </.link>
            <span :for={{name, path} <- @crumbs} class="flex items-center gap-1">
              <span class="text-base-content/40">/</span>
              <.link patch={files_path(@project, path, @chat)} class="hover:underline">{name}</.link>
            </span>
          </nav>

          <ul class="min-h-0 flex-1 overflow-y-auto p-2 text-sm">
            <li :if={@dir != ""}>
              <.link
                id="parent-dir"
                patch={files_path(@project, parent(@dir), @chat)}
                class="flex items-center gap-2 rounded-lg px-2 py-1.5 transition hover:bg-base-200"
              >
                <.icon name="hero-arrow-uturn-left" class="size-4 text-base-content/50" /> ..
              </.link>
            </li>
            <li
              :if={@entries == [] and is_nil(@root_error)}
              class="px-2 py-6 text-center text-base-content/50"
            >
              Empty directory
            </li>
            <li :for={entry <- @entries}>
              <.link
                :if={entry.type in [:dir, :file]}
                data-entry={entry.path}
                patch={files_path(@project, entry.path, @chat)}
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
            <% @root_error -> %>
              <div
                id="root-error"
                role="alert"
                class="m-6 flex items-center gap-2 rounded-xl border border-error/30 bg-error/10 px-4 py-3 text-sm text-error"
              >
                <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
                {root_error_message(@root_error, @root)}
              </div>
            <% @error -> %>
              <div
                id="file-error"
                role="alert"
                class="m-6 flex items-center gap-2 rounded-xl border border-error/30 bg-error/10 px-4 py-3 text-sm text-error"
              >
                <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
                {error_message(@error)}
              </div>
            <% @preview -> %>
              <.file_header path={@preview.path} size={@preview.size} url={@raw} />
              <.preview_pane preview={@preview} url={@raw} />
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
                    data-line={@line}
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
  attr :url, :string, default: nil

  defp file_header(assigns) do
    ~H"""
    <header
      id="file-header"
      class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 border-b border-base-300 px-4 py-2.5"
    >
      <h1 id="file-path" class="min-w-0 truncate font-mono text-sm font-medium">{@path}</h1>
      <p class="flex items-center gap-3 text-xs text-base-content/50">
        <span :if={@size}>
          {SystemStats.format_bytes(@size)}
          <span :if={@lines}>
            · {@lines} {if @lines == 1, do: "line", else: "lines"}
          </span>
        </span>
        <%!-- EXPL-26: the file's own URL, for a page of its own or a save. --%>
        <.link
          :if={@url}
          id="file-preview-open"
          href={@url}
          target="_blank"
          rel="noreferrer"
          class="flex items-center gap-1 hover:text-base-content"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-3.5" /> Open
        </.link>
      </p>
    </header>
    """
  end

  attr :preview, :map, required: true
  attr :url, :string, required: true

  # EXPL-23: what the browser renders itself, in place of the text view. An
  # image fits the pane without being enlarged past its own size; the others
  # fill it with the browser's own controls.
  defp preview_pane(assigns) do
    ~H"""
    <div id="file-preview-pane" class={pane_class(@preview.kind)}>
      <img
        :if={@preview.kind == :image}
        id="file-preview"
        src={@url}
        alt={Path.basename(@preview.path)}
        class="max-h-full max-w-full"
      />
      <iframe
        :if={@preview.kind == :pdf}
        id="file-preview"
        src={@url}
        title={@preview.path}
        class="h-full w-full border-0"
      ></iframe>
      <video
        :if={@preview.kind == :video}
        id="file-preview"
        src={@url}
        controls
        class="max-h-full max-w-full"
      ></video>
      <audio
        :if={@preview.kind == :audio}
        id="file-preview"
        src={@url}
        controls
        class="w-full"
      ></audio>
    </div>
    """
  end

  defp pane_class(:pdf), do: "min-h-0 flex-1"
  defp pane_class(_kind), do: "grid min-h-0 flex-1 place-items-center overflow-auto p-4"
end
