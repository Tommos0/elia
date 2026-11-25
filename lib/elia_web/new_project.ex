defmodule EliaWeb.NewProject do
  @moduledoc """
  The header's new-project modal (PROJ-30, PROJ-39 to PROJ-41, PROJ-55): the
  state it is drawn from, the events that drive it and the markup it is drawn
  with.

  It stands where the projects page did (PROJ-23): a name makes a project's
  folder under the projects root, as a git repository with one commit
  (PROJ-34 - PROJ-38), and that root is shown and set here.

  Like `EliaWeb.ChatList` and `EliaWeb.ActiveChats` it hangs off every page of
  the live session (`EliaWeb.Router`), which is what lets the switcher's entry
  open it (PROJ-30) wherever the user is, and what the layout draws it from. Its
  events are the chat list's too: opening it closes the switcher's menu.
  """

  use EliaWeb, :html

  alias Elia.Projects
  alias EliaWeb.ChatList

  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  @doc """
  PROJ-55: the modal's state and events, on every page of the live session.
  """
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:new_project, closed())
      |> attach_hook(:new_project_events, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  # PROJ-55: the modal starts closed, with nothing typed in it. The projects
  # root is read as it opens rather than here, so a page that never opens it
  # costs nothing.
  defp closed,
    do: %{open: false, name: "", error: nil, root: "", root_input: "", root_error: nil}

  ## Events

  # PROJ-30, PROJ-55: the switcher's menu's entry opens the modal, and the menu
  # closes with it — the modal is a dialog over the page, and the menu it was
  # opened from would otherwise stand behind it.
  defp handle_event("open_new_project", _params, socket) do
    state = %{closed() | open: true, root: Projects.root()}

    {:halt, socket |> ChatList.close_menu() |> assign(:new_project, state)}
  end

  # PROJ-55: its own control, Escape and a press outside it (the backdrop) all
  # close it, leaving the page it was opened on as it was.
  defp handle_event("close_new_project", _params, socket), do: {:halt, close(socket)}

  # PROJ-39: the form takes a name and nothing else; the folder is made under
  # the projects root. A creation closes the modal and names the project in the
  # flash (PROJ-41); an error leaves it open, with what was typed, in
  # `#project-error`.
  defp handle_event("create_project", %{"project" => %{"name" => name}}, socket) do
    socket = assign(socket, :new_project, %{socket.assigns.new_project | name: name})

    case Projects.create(name) do
      {:ok, project} ->
        {:halt, created(socket, "Created #{project.name}.")}

      # PROJ-41: the project is made; its repository is not.
      {:ok, project, :no_repository} ->
        {:halt,
         created(
           socket,
           "Created #{project.name}, but its git repository couldn't be set up.",
           :error
         )}

      {:error, :blank_name} ->
        {:halt, fail(socket, "Give the project a name.")}

      {:error, :folder_exists} ->
        {:halt,
         fail(
           socket,
           "There's already a folder #{Projects.folder_for(name)}. Give the project " <>
             "another name, or set another projects root."
         )}

      {:error, :folder_failed} ->
        {:halt,
         fail(
           socket,
           "Couldn't make #{Projects.folder_for(name)}. Is the projects root writable?"
         )}
    end
  end

  # PROJ-40: the root a project's own folder is made under, shown in the modal
  # (`#projects-root-path`) and set from the field beside it.
  defp handle_event("save_root", %{"root" => %{"folder" => folder}}, socket) do
    case Projects.set_root(folder) do
      :ok ->
        state = %{
          socket.assigns.new_project
          | root: Projects.root(),
            root_input: "",
            root_error: nil
        }

        {:halt, socket |> assign(:new_project, state) |> put_flash(:info, "Projects root saved.")}

      {:error, :blank_root} ->
        state = %{
          socket.assigns.new_project
          | root_input: folder,
            root_error: "Give a folder for new projects."
        }

        {:halt, assign(socket, :new_project, state)}
    end
  end

  # Anything else is another module's event (UI-91, ACTIVE-1): this hook lets it
  # through.
  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # PROJ-39, PROJ-55: the project is made, so the modal has nothing left to ask
  # for: it closes, and the switcher's menu holds the project it made when it is
  # opened again (PROJ-29).
  defp created(socket, message, level \\ :info) do
    socket
    |> close()
    |> ChatList.refresh_projects()
    |> put_flash(level, message)
  end

  defp fail(socket, message),
    do: assign(socket, :new_project, %{socket.assigns.new_project | error: message})

  defp close(socket), do: assign(socket, :new_project, closed())

  @doc """
  PROJ-55: the modal itself. Drawn by `EliaWeb.Layouts` on every page whose
  header carries the switcher (PROJ-29), and nothing at all while it is closed.
  """
  attr :state, :map, required: true

  def modal(assigns) do
    assigns =
      assigns
      |> assign(:name_form, to_form(%{"name" => assigns.state.name}, as: :project))
      |> assign(:root_form, to_form(%{"folder" => assigns.state.root_input}, as: :root))

    ~H"""
    <div
      :if={@state.open}
      id="new-project-modal"
      phx-window-keydown="close_new_project"
      phx-key="Escape"
      role="dialog"
      aria-modal="true"
      aria-label="New project"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
    >
      <%!-- PROJ-55, FEED-1: a press on the backdrop closes the modal, and a
      backdrop is not a control, so it does not press. --%>
      <button
        type="button"
        id="new-project-backdrop"
        phx-click="close_new_project"
        aria-label="Close"
        data-press="none"
        class="absolute inset-0 bg-black/40"
      ></button>

      <div class="relative z-10 max-h-full w-full max-w-md overflow-y-auto rounded-2xl border border-base-300 bg-base-100 p-5 shadow-xl">
        <div class="flex items-start justify-between gap-3">
          <h2 class="text-base font-semibold tracking-tight">New project</h2>
          <button
            type="button"
            id="new-project-close"
            phx-click="close_new_project"
            title="Close"
            aria-label="Close"
            class="-mt-1 -mr-1 grid size-8 shrink-0 place-items-center rounded-lg text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <%!-- PROJ-39: a name and nothing else. --%>
        <.form for={@name_form} id="new-project" phx-submit="create_project" class="mt-4">
          <p class="text-xs text-base-content/60">
            Its folder is made under the projects root, below, as a git repository with an
            initial commit.
          </p>
          <div class="mt-3 flex flex-col gap-2 sm:flex-row sm:items-start">
            <.input
              field={@name_form[:name]}
              type="text"
              placeholder="Name"
              autocomplete="off"
              class="w-full rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 text-sm outline-none transition focus:border-primary focus:bg-base-100"
            />
            <button
              type="submit"
              id="create-project"
              class="flex h-11 shrink-0 items-center justify-center gap-1.5 rounded-xl bg-primary px-4 text-sm font-medium text-primary-content transition hover:brightness-110"
            >
              <.icon name="hero-plus" class="size-4" /> Create
            </button>
          </div>

          <p
            :if={@state.error}
            id="project-error"
            role="alert"
            class="mt-3 flex items-center gap-2 rounded-lg bg-error/10 px-3 py-2 text-xs text-error"
          >
            <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" /> {@state.error}
          </p>
        </.form>

        <%!-- PROJ-40: the root a project's own folder is made under. --%>
        <.form
          for={@root_form}
          id="projects-root-form"
          phx-submit="save_root"
          class="mt-5 border-t border-base-300 pt-5"
        >
          <h2 class="font-medium">Projects root</h2>
          <p class="mt-1 text-xs text-base-content/60">
            A project created from a name gets a folder of its own under this one.
          </p>
          <div class="mt-3 flex flex-col gap-2 sm:flex-row sm:items-start">
            <.input
              field={@root_form[:folder]}
              id="projects-root-input"
              type="text"
              placeholder="~/elia-projects"
              autocomplete="off"
              class="w-full rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 font-mono text-sm outline-none transition focus:border-primary focus:bg-base-100"
            />
            <button
              type="submit"
              id="save-project-root"
              class="flex h-11 shrink-0 items-center justify-center gap-1.5 rounded-xl border border-base-300 px-4 text-sm font-medium transition hover:bg-base-200"
            >
              <.icon name="hero-check" class="size-4" /> Save
            </button>
          </div>

          <p class="mt-3 flex items-center gap-2 text-xs text-base-content/50">
            <.icon name="hero-folder" class="size-4 shrink-0" />
            <span id="projects-root-path" class="truncate font-mono" title={@state.root}>
              {@state.root}
            </span>
          </p>

          <p
            :if={@state.root_error}
            id="projects-root-error"
            role="alert"
            class="mt-3 flex items-center gap-2 rounded-lg bg-error/10 px-3 py-2 text-xs text-error"
          >
            <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" /> {@state.root_error}
          </p>
        </.form>
      </div>
    </div>
    """
  end
end
