defmodule EliaWeb.ProjectLive do
  @moduledoc """
  A project's own page, `/p/<project id>` (PROJ-51): what the project is — its
  name, its folder and its icon in its colour — the chats that belong to it
  (PROJ-52), a control that starts a chat in it (PROJ-26) and the controls that
  act on it: its colour (PROJ-45), its allowlist (PROJ-50), its Files (PROJ-48)
  and its deletion (PROJ-54). Opening the page opens the project (PROJ-8,
  PROJ-28), so the header names it and the chat list holds its chats.
  """
  use EliaWeb, :live_view

  alias Elia.{Agent, Projects, Store}
  alias EliaWeb.{ChatList, ChatStatus, TimeAgo}

  # PROJ-52: the chats the page lists to begin with, and how many "Load more
  # chats" adds — the chat list's own first page (UI-4).
  @chat_page 30
  # PROJ-52, UI-34: the relative times keep up with the clock.
  @time_tick :timer.minutes(1)

  @impl true
  def mount(%{"project_id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(project: nil, page_title: "Project", limit: @chat_page, allowlist_error: nil)
     |> load(id)}
  end

  # PROJ-51: the page shows the project its id names, whether it arrived fresh
  # or the same LiveView was navigated to another project.
  @impl true
  def handle_params(%{"project_id" => id}, _uri, socket) do
    case socket.assigns.project do
      %{id: ^id} -> {:noreply, socket}
      _other -> {:noreply, load(socket, id)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # PROJ-52: "Load more chats" lists the next page of the project's chats. The
  # event is named for this page: the chat list attaches a hook on every page of
  # the live session that claims `more_chats` itself and halts, so a handler of
  # that name here would never be reached.
  @impl true
  def handle_event("project_more_chats", _params, socket) do
    {:noreply, socket |> assign(limit: socket.assigns.limit + @chat_page) |> refresh()}
  end

  # PROJ-45: a swatch stores the colour it names (PROJ-44); the automatic one
  # clears the stored colour, so the project goes back to the colour its name
  # derives (PROJ-43).
  def handle_event("set_color", %{"color" => color}, socket) do
    case Projects.set_color(socket.assigns.project, if(color == "auto", do: nil, else: color)) do
      {:ok, project} -> {:noreply, assign(socket, project: project)}
      {:error, :unknown_color} -> {:noreply, socket}
    end
  end

  # PROJ-50, NET-11: the project's allowlist, saved when Save is pressed. A list
  # holding an entry that is not one of NET-7's forms changes nothing and the
  # page names the entry.
  def handle_event("save_allowlist", %{"allowlist" => text}, socket) do
    case Projects.set_allowlist(socket.assigns.project, text) do
      {:ok, project} ->
        # The project the save returns carries the entries it stored (PROJ-49),
        # so the field shows them cleaned and the page is drawn again.
        {:noreply, assign(socket, project: project, allowlist_error: nil)}

      {:error, entry} ->
        {:noreply, assign(socket, allowlist_error: allowlist_error(entry))}
    end
  end

  # PROJ-48: the Files button opens the project's files, so it makes the project
  # the open one first (PROJ-8, PROJ-28) — the Files page browses the open
  # project and nothing else (EXPL-15).
  def handle_event("open_files", _params, socket) do
    :ok = Projects.set_default(socket.assigns.project.id)
    {:noreply, push_navigate(socket, to: ~p"/files")}
  end

  # PROJ-54, PROJ-7: deleting the project the page is about leaves the page with
  # nothing to show, so it goes home, to the dashboard (DASH-1). The project's
  # chats are kept (PROJ-7).
  def handle_event("delete", _params, socket) do
    project = socket.assigns.project

    case Projects.delete(project.id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Project deleted.") |> push_navigate(to: ~p"/")}

      {:error, :harness_project} ->
        {:noreply, put_flash(socket, :error, "Elia's own project can't be deleted.")}
    end
  end

  # PROJ-52, UI-59: a chat's status changes as a turn starts, ends or waits for
  # the user, and the page shows it without a reload.
  @impl true
  def handle_info({:chat_status, _id, _status}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:chat_deleted, _id}, socket), do: {:noreply, refresh(socket)}

  # PROJ-52, UI-34: the relative times keep up with the clock.
  def handle_info(:tick, socket), do: {:noreply, assign(socket, now: DateTime.utc_now())}

  defp allowlist_error(entry) do
    "#{inspect(entry)} is not a host, a *.suffix or one of those with a port."
  end

  # PROJ-51: the project the id names, or the dashboard when it names none
  # (PROJ-23). Opening it opens the project (PROJ-8, PROJ-28), which is why the
  # chat list's state — what the header names (PROJ-29) — is read again here.
  defp load(socket, id) do
    case Projects.get(id) do
      nil ->
        push_navigate(socket, to: ~p"/")

      project ->
        :ok = Projects.set_default(project.id)

        socket
        |> watch()
        |> assign(project: project, page_title: project.name)
        |> ChatList.refresh()
        |> refresh()
    end
  end

  # PROJ-52: the statuses follow the registry while the page is open (UI-59) and
  # the relative times follow the clock (UI-34). Subscribed once, however many
  # times the page is navigated to another project.
  defp watch(socket) do
    if connected?(socket) and !socket.assigns[:watching] do
      Agent.subscribe_activity()
      :timer.send_interval(@time_tick, :tick)
      assign(socket, watching: true)
    else
      socket
    end
  end

  # PROJ-52: the project's chats, newest first (PROJ-31, UI-4, STORE-12), and
  # the statuses they are shown with (UI-59, DONE-2). The page holds its own
  # bound on what it reads, as the dashboard's cards do (DASH-3).
  defp refresh(socket) do
    chats = project_chats(socket.assigns.project)
    {page, more} = Enum.split(chats, socket.assigns.limit)

    assign(socket,
      chats: page,
      more_chats: more != [],
      now: DateTime.utc_now(),
      marks: %{
        awaiting: Agent.awaiting_approval(),
        input: Agent.awaiting_input(),
        paused: Agent.paused(),
        running: Agent.running(),
        interrupted: for(%{interrupted: true} = chat <- chats, do: chat.id)
      }
    )
  end

  # PROJ-52: a sub-task chat (STORE-17) is not listed on its own — it is reached
  # from the chat that spawned it (UI-45) — and the listed entry names that chat
  # under `:parent_id` (STORE-17).
  defp project_chats(project) do
    Store.list(1000, where: Projects.chats_of(project))
    |> Enum.reject(&Map.get(&1, :parent_id))
  end

  # PROJ-45: the chosen swatch is ringed; the others are not.
  defp swatch_ring(true), do: "ring-2 ring-base-content/60 ring-offset-2 ring-offset-base-100"
  defp swatch_ring(false), do: "ring-1 ring-base-content/15"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      chats={@chat_list}
      active_chats={@active_chats}
      new_project={@new_project}
    >
      <div class="h-full overflow-y-auto">
        <div class="mx-auto max-w-3xl px-4 py-10 sm:px-6">
          <.link
            navigate={~p"/"}
            class="inline-flex items-center gap-1.5 text-xs font-medium text-base-content/60 transition hover:text-base-content"
          >
            <.icon name="hero-arrow-left" class="size-3.5" /> Home
          </.link>

          <%!-- PROJ-51, PROJ-47: what the project is — its name, its folder and
          its icon in its colour. --%>
          <header class="mt-4 flex flex-wrap items-start justify-between gap-3">
            <div class="flex min-w-0 items-center gap-3">
              <div
                id={"project-icon-#{@project.id}"}
                class="grid size-10 shrink-0 place-items-center rounded-xl text-white"
                style={"background-color: #{Projects.color(@project).hex}"}
              >
                <.icon name="hero-rectangle-stack" class="size-5" />
              </div>
              <div class="min-w-0">
                <h1
                  id={"project-name-#{@project.id}"}
                  class="truncate text-xl font-semibold tracking-tight"
                >
                  {@project.name}
                </h1>
                <p
                  id={"project-folder-#{@project.id}"}
                  class="truncate font-mono text-xs text-base-content/50"
                  title={@project.folder}
                >
                  {@project.folder}
                </p>
              </div>
            </div>

            <%!-- PROJ-51: starting a chat here; PROJ-54, PROJ-48, PROJ-7: the
            Files button and the delete button, on every project but Elia's
            own. --%>
            <div class="flex items-center gap-2">
              <.link
                navigate={~p"/p/#{@project.id}/new"}
                id="project-new-chat"
                class="flex items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-xs font-medium text-primary-content transition hover:brightness-110"
              >
                <.icon name="hero-plus" class="size-4" /> New chat
              </.link>
              <button
                :if={!@project.harness?}
                type="button"
                id={"project-files-#{@project.id}"}
                phx-click="open_files"
                class="flex items-center gap-1.5 rounded-lg border border-base-300 px-3 py-1.5 text-xs font-medium transition hover:bg-base-200"
              >
                <.icon name="hero-folder" class="size-4" /> Files
              </button>
              <button
                :if={!@project.harness?}
                type="button"
                id={"delete-project-#{@project.id}"}
                phx-click="delete"
                data-confirm={"Delete the project #{@project.name}? Its chats are kept."}
                class="flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium text-error transition hover:bg-error/10"
              >
                <.icon name="hero-trash" class="size-3.5" /> Delete
              </button>
            </div>
          </header>

          <%!-- PROJ-52: the chats that belong to the project, newest first, each
          a row linking to the chat. --%>
          <section class="mt-8">
            <h2 class="font-medium">Chats</h2>
            <ul class="mt-3 space-y-1">
              <li :for={chat <- @chats} id={"project-chat-#{chat.id}"}>
                <.link
                  navigate={~p"/c/#{chat.id}"}
                  title={chat.description}
                  class="flex items-center gap-2 rounded-xl px-3 py-2 text-sm text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
                >
                  <ChatStatus.status_icon
                    id={"project-chat-status-#{chat.id}"}
                    status={ChatStatus.for_chat(chat, @marks)}
                  />
                  <span class="min-w-0 flex-1 truncate">{chat.title}</span>
                  <time
                    datetime={DateTime.to_iso8601(chat.created_at)}
                    title={Calendar.strftime(chat.created_at, "%Y-%m-%d %H:%M:%S UTC")}
                    class="shrink-0 text-xs text-base-content/50"
                  >
                    {TimeAgo.format(chat.created_at, @now)}
                  </time>
                </.link>
              </li>
            </ul>
            <p :if={@chats == []} id="project-no-chats" class="mt-3 text-sm text-base-content/50">
              No chats yet.
            </p>
            <button
              :if={@more_chats}
              type="button"
              id="project-load-more"
              phx-click="project_more_chats"
              class="mt-3 w-full rounded-xl border border-base-300 px-3 py-2 text-xs font-medium transition hover:bg-base-200"
            >
              Load more chats
            </button>
          </section>

          <%!-- PROJ-54, PROJ-45: the picker for the project's colour — one
          swatch per palette entry (PROJ-42) and the automatic one, painted in
          the colour the name derives (PROJ-43). --%>
          <section class="mt-8 rounded-2xl border border-base-300 p-5">
            <h2 class="font-medium">Colour</h2>
            <div class="mt-3 flex flex-wrap items-center gap-2">
              <button
                type="button"
                id={"project-color-#{@project.id}-auto"}
                phx-click="set_color"
                phx-value-color="auto"
                title="Automatic"
                data-selected={to_string(@project.color == nil)}
                class={[
                  "grid size-6 place-items-center rounded-full text-[10px] font-semibold text-white transition hover:scale-110",
                  swatch_ring(@project.color == nil)
                ]}
                style={"background-color: #{Projects.auto_color(@project).hex}"}
              >
                A<span class="sr-only">Automatic</span>
              </button>
              <button
                :for={color <- Projects.palette()}
                type="button"
                id={"project-color-#{@project.id}-#{color.name}"}
                phx-click="set_color"
                phx-value-color={color.name}
                title={color.name}
                data-selected={to_string(@project.color == color.name)}
                class={[
                  "size-6 rounded-full transition hover:scale-110",
                  swatch_ring(@project.color == color.name)
                ]}
                style={"background-color: #{color.hex}"}
              >
                <span class="sr-only">{color.name}</span>
              </button>
            </div>
          </section>

          <%!-- PROJ-54, PROJ-50, NET-28: the hosts the project's chats in
          allowlist mode may reach, one per line, saved when Save is pressed. --%>
          <section class="mt-4 rounded-2xl border border-base-300 p-5">
            <h2 class="font-medium">Network allowlist</h2>
            <p class="mt-1 text-xs text-base-content/60">
              Hosts this project's chats may reach, one per line: a host
              (api.example.com), a <code>*.suffix</code> (*.example.com) or either with a port
              (api.example.com:443). Empty means they reach nothing.
            </p>
            <.form
              for={%{}}
              id={"project-allowlist-form-#{@project.id}"}
              phx-submit="save_allowlist"
              class="mt-3"
            >
              <textarea
                id={"project-allowlist-#{@project.id}"}
                name="allowlist"
                rows="3"
                class="w-full rounded-lg border border-base-300 bg-base-100 p-2 font-mono text-xs"
                placeholder="api.example.com"
              >{Enum.join(Projects.allowlist(@project), "\n")}</textarea>
              <p
                :if={@allowlist_error}
                id={"project-allowlist-error-#{@project.id}"}
                role="alert"
                class="mt-2 flex items-center gap-2 rounded-lg bg-error/10 px-3 py-2 text-xs text-error"
              >
                <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
                {@allowlist_error}
              </p>
              <button
                type="submit"
                id={"save-project-allowlist-#{@project.id}"}
                class="mt-3 rounded-lg bg-primary px-3 py-1.5 text-xs font-medium text-primary-content transition hover:brightness-110 active:scale-95"
              >
                Save allowlist
              </button>
            </.form>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
