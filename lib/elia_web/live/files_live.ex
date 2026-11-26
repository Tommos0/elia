defmodule EliaWeb.FilesLive do
  @moduledoc """
  Read-only workspace browser: a directory listing next to a viewer that shows a
  file's source as text or the file itself as the browser renders it — a
  picture, a PDF, a media file, a page (EXPL-22 - EXPL-33).
  See `specs/file-explorer.md`.
  """
  use EliaWeb, :live_view

  alias Elia.{Explorer, Projects, Store, SystemStats, Workspace}
  alias EliaWeb.FilesScope

  @highlight_max 128 * 1024

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Files")}
  end

  # The activity the live session announces to every page — a chat's status, a
  # deletion, a terminal starting (SESS-19, TERM-41) — is drawn by the chat list
  # and the header's control (`EliaWeb.ChatList`, `EliaWeb.ActiveChats`), and
  # this page shows neither, so there is nothing here to do with it.
  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  # EXPL-6, EXPL-9, EXPL-15, EXPL-17, EXPL-19
  @impl true
  def handle_params(params, _uri, socket) do
    {project, chat} = FilesScope.viewed(params)
    root = project.folder
    path = normalize(root, params["path"])

    {dir, file, error} = listing(path, root)
    raw_view = raw_view_for(file, root)
    mode = mode(params["mode"], default_mode(raw_view), raw_view)

    # EXPL-8, EXPL-23: only the source mode reads the file as text, so a file the
    # browser renders is never read for bytes it doesn't show.
    {viewer, error} = text_view(file, mode, root, error)

    # EXPL-24, EXPL-26: the URL the browser fetches the raw view from, which the
    # page's own parameters carry so the route serves the file it browsed.
    raw = raw_view && raw_path(raw_view.path, chat)

    {dir, entries, root_error} = listing_or_root(dir, root)

    # EXPL-19: an unavailable root is what the page reports, not the path that
    # couldn't be reached inside it.
    error = if root_error, do: nil, else: error

    {:noreply,
     assign(socket,
       project: project,
       chat: chat,
       chat_title: chat && Store.chat_title(chat),
       root: root,
       dir: dir,
       entries: entries,
       selected: file,
       viewer: viewer,
       raw_view: raw_view,
       mode: mode,
       raw: raw,
       open_url: open_url(raw_view, chat, project, raw),
       line: line(params, viewer),
       error: error,
       root_error: root_error,
       crumbs: crumbs(dir)
     )}
  end

  # The listing of the path in view: the directory to show, the file selected
  # when the path is one, or the reason the path could not be listed at all.
  defp listing(path, root) do
    case Explorer.list(path, root) do
      {:ok, _} -> {path, nil, nil}
      {:error, :not_a_directory} -> {parent(path), path, nil}
      {:error, reason} -> {"", nil, reason}
    end
  end

  # EXPL-24, EXPL-25, EXPL-31: what the browser may be given of this file, by
  # the same check the route serves by.
  defp raw_view_for(file, root) do
    case file && Explorer.raw_file(file, root) do
      {:ok, raw} -> raw
      _ -> nil
    end
  end

  # EXPL-22, EXPL-30: a file the browser renders of itself opens in the raw
  # mode, which is the mode a missing one falls back to. It takes no reading to
  # know, and a file with no raw view of that kind (EXPL-31) opens as source.
  defp default_mode(raw_view) do
    if raw_view && preview_kind?(raw_view.kind), do: :raw, else: :source
  end

  # The listing is read again after the viewer so that a vanished directory
  # falls back to the project root instead of crashing (EXPL-9) — and so that
  # a root which is itself unavailable reports that, rather than putting an
  # error atom where the listing belongs (EXPL-19).
  defp listing_or_root(dir, root) do
    case Explorer.list(dir, root) do
      {:ok, entries} -> {dir, entries, nil}
      {:error, _} -> root_listing(root)
    end
  end

  # EXPL-30: which of the two modes the URL asks for. A `mode` that is missing,
  # that names neither, or that asks for `raw` for a file the browser renders
  # nothing of (EXPL-31) is the file's default mode.
  defp mode("source", _default, _raw_view), do: :source
  defp mode("raw", _default, raw_view) when is_map(raw_view), do: :raw
  defp mode(_other, default, _raw_view), do: default

  # EXPL-8, EXPL-22, EXPL-23, EXPL-25: the source mode reads the file as text,
  # which is where EXPL-4's cap and its binary refusal apply. The raw mode shows
  # the file's own bytes and has no text to read, and neither has a path the
  # listing already refused (EXPL-9, EXPL-25).
  defp text_view(_file, :raw, _root, error), do: {nil, error}
  defp text_view(nil, _mode, _root, error), do: {nil, error}

  defp text_view(file, :source, root, _error) do
    case Explorer.read(file, root) do
      {:ok, viewer} -> {viewer, nil}
      {:error, :binary} -> {{:binary, file}, nil}
      {:error, reason} -> {nil, reason}
    end
  end

  # EXPL-23, EXPL-32: a kind the browser renders of itself gets its own element
  # in the pane, and every other kind the frame.
  defp preview_kind?(kind), do: kind in [:image, :pdf, :video, :audio]

  # SERVE-15: an HTML document in a project's `dist` folder opens at its URL on
  # the preview host when the install has one — the only URL a browser runs it
  # at, since a raw view has its scripts off (EXPL-24). A document elsewhere in
  # the project's folder, and one in a chat's own workspace, have none: the
  # preview serves a project's build output, not its sources.
  defp open_url(%{kind: :html} = raw_view, nil, project, raw) do
    with "dist/" <> path <- raw_view.path,
         segments when is_list(segments) <- preview_segments(project, path),
         url when is_binary(url) <- EliaWeb.PreviewHost.url(segments) do
      url
    else
      _other -> raw
    end
  end

  defp open_url(_raw_view, _chat, _project, raw), do: raw

  # SERVE-16: the preview's path is the project's slug and then the document's
  # path under `dist`. A project whose name gives no slug has no URL there.
  defp preview_segments(project, path) do
    case Projects.slug(project.name) do
      slug when is_binary(slug) -> [slug | String.split(path, "/")]
      nil -> nil
    end
  end

  # EXPL-27: the line a link named, when the text in view has it. It is
  # ignored otherwise — a `line` that isn't a positive whole number, one past
  # the text shown (a truncated file's text is only what is shown), and one
  # that comes with no text at all (a preview, a binary file, a directory) —
  # so the file opens as it otherwise would. EXPL-28: it is never carried
  # along, since `files_path/2` builds every other URL without it.
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

  # EXPL-29: the header's switcher (PROJ-29) makes the project chosen the open
  # one and this page browses it, without leaving the page: the path in view is
  # kept when that project has it and it falls back to the root when it doesn't
  # (EXPL-9). It leaves a chat in view behind, so the page browses the project's
  # own folder (EXPL-18).
  @impl true
  def handle_event("switch_project", %{"project" => id}, socket) do
    case Elia.Projects.get(id) do
      nil ->
        {:noreply, socket}

      project ->
        :ok = Elia.Projects.set_default(project.id)
        path = socket.assigns.selected || socket.assigns.dir
        path = if exists?(project, path), do: path, else: ""

        # PROJ-29, PROJ-46: the header names the open project and wears its
        # colour, so the chat list's state is read again with it — and the menu
        # a project was chosen from closes.
        socket = EliaWeb.ChatList.refresh(socket)
        chat_list = %{socket.assigns.chat_list | projects_open: false}
        {:noreply, push_patch(assign(socket, :chat_list, chat_list), to: files_path(path, nil))}
    end
  end

  # EXPL-29: only keep the current path when the new project has it; otherwise
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

  # EXPL-15, EXPL-17: the open project's links stay param-free — it is what the
  # page browses, so naming it would say nothing — and a chat in view is named
  # instead, which the page takes from the chat (EXPL-18).
  defp scope_params(chat) do
    if chat, do: %{chat: chat}, else: %{}
  end

  defp files_path(path, chat) do
    params = scope_params(chat)
    params = if path == "", do: params, else: Map.put(params, :path, path)

    if params == %{}, do: ~p"/files", else: ~p"/files?#{params}"
  end

  # EXPL-24, EXPL-26: the route that serves a raw view's bytes takes the same
  # parameters as the page, so it serves the file the page is showing.
  defp raw_path(path, chat) do
    ~p"/files/raw?#{Map.put(scope_params(chat), :path, path)}"
  end

  # EXPL-33: the mode control's URL — the workspace, the file in view and the
  # mode asked for, so it shows the same file the other way.
  defp mode_path(path, chat, mode) do
    params = Map.merge(scope_params(chat), %{path: path, mode: Atom.to_string(mode)})
    ~p"/files?#{params}"
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

  # EXPL-8, EXPL-12, EXPL-32: only the text view has a line count, a gutter or a
  # language to highlight; a raw view has none of them.
  defp text_assigns(assigns) do
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
  end

  @impl true
  def render(assigns) do
    assigns = text_assigns(assigns)

    ~H"""
    <Layouts.app
      flash={@flash}
      chats={@chat_list}
      active_chats={@active_chats}
      new_project={@new_project}
      project_switch={:switch}
    >
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
          </div>
          <nav
            id="breadcrumbs"
            aria-label="Breadcrumb"
            class="flex flex-wrap items-center gap-x-1 border-b border-base-300 px-4 py-2.5 text-sm"
          >
            <.link patch={files_path("", @chat)} class="font-medium hover:underline">
              workspace
            </.link>
            <span :for={{name, path} <- @crumbs} class="flex items-center gap-1">
              <span class="text-base-content/40">/</span>
              <.link patch={files_path(path, @chat)} class="hover:underline">{name}</.link>
            </span>
          </nav>

          <ul class="min-h-0 flex-1 overflow-y-auto p-2 text-sm">
            <li :if={@dir != ""}>
              <.link
                id="parent-dir"
                patch={files_path(parent(@dir), @chat)}
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
                patch={files_path(entry.path, @chat)}
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
            <% @mode == :raw -> %>
              <%!-- EXPL-32: the file itself, in place of the source. --%>
              <.file_header
                path={@raw_view.path}
                size={@raw_view.size}
                url={@open_url}
                mode={@mode}
                chat={@chat}
              />
              <.preview_pane
                :if={preview_kind?(@raw_view.kind)}
                preview={@raw_view}
                url={@raw}
              />
              <.raw_frame :if={not preview_kind?(@raw_view.kind)} path={@raw_view.path} url={@raw} />
            <% match?({:binary, _}, @viewer) -> %>
              <.file_header
                path={elem(@viewer, 1)}
                url={@open_url}
                mode={@raw_view && @mode}
                chat={@chat}
              />
              <p id="file-binary" class="m-6 text-sm text-base-content/60">
                This looks like a binary file, so it isn't shown.
              </p>
            <% @viewer -> %>
              <%!-- EXPL-30: the source mode, with the name of the other mode
              beside it when the file has a raw view to switch to. --%>
              <.file_header
                path={@viewer.path}
                size={@viewer.size}
                lines={@line_count}
                url={@open_url}
                mode={@raw_view && @mode}
                chat={@chat}
              />
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
  attr :mode, :atom, default: nil
  attr :chat, :string, default: nil

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
        <%!-- EXPL-33: the mode in view, and the other one of a file that has a
        raw view. --%>
        <nav :if={@mode} id="file-modes" class="flex items-center gap-1" aria-label="View mode">
          <.link
            id="mode-source"
            patch={mode_path(@path, @chat, :source)}
            aria-current={@mode == :source && "true"}
            class={[
              "rounded px-1.5 py-0.5",
              @mode == :source && "bg-base-200 font-medium text-base-content",
              @mode != :source && "hover:text-base-content"
            ]}
          >
            Source
          </.link>
          <.link
            id="mode-raw"
            patch={mode_path(@path, @chat, :raw)}
            aria-current={@mode == :raw && "true"}
            class={[
              "rounded px-1.5 py-0.5",
              @mode == :raw && "bg-base-200 font-medium text-base-content",
              @mode != :raw && "hover:text-base-content"
            ]}
          >
            Raw
          </.link>
        </nav>
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

  # EXPL-23, EXPL-32: what the browser renders itself, in place of the text
  # view. An image fits the pane without being enlarged past its own size; the
  # others fill it with the browser's own controls.
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

  attr :path, :string, required: true
  attr :url, :string, required: true

  # EXPL-24, EXPL-32: the file's own bytes in a frame, sandboxed with nothing
  # allowed, so a page a script-carrying file names can neither run nor reach
  # this app's origin — and served with the policy EXPL-24 names, which is the
  # same restriction for the file's URL opened on a page of its own (EXPL-26).
  defp raw_frame(assigns) do
    ~H"""
    <iframe
      id="file-raw"
      src={@url}
      sandbox=""
      title={@path}
      class="min-h-0 w-full flex-1 border-0 bg-white"
    ></iframe>
    """
  end
end
