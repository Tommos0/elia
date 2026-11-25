defmodule EliaWeb.ProjectsLive do
  @moduledoc """
  The projects page: every project with its folder and number of chats and a
  link to its own page (PROJ-51), a form to create one from a name — which makes
  the project's folder under the projects root, a git repository with one commit
  (PROJ-34 - PROJ-38) — and a control showing and setting that root. What acts
  on one project is on that project's page (PROJ-51, PROJ-54). See
  `specs/projects.md` (PROJ-23, PROJ-32 - PROJ-41, PROJ-53).
  """
  use EliaWeb, :live_view

  alias Elia.Projects

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Projects",
       error: nil,
       root_error: nil
     )
     |> assign(form: empty_form(), root_form: root_form())
     |> refresh()}
  end

  # PROJ-39: the form takes a name and nothing else; the folder is made under
  # the projects root.
  @impl true
  def handle_event("create", %{"project" => %{"name" => name}}, socket) do
    socket =
      case Projects.create(name) do
        {:ok, project} ->
          socket
          |> assign(form: empty_form(), error: nil)
          |> put_flash(:info, "Created #{project.name}.")
          |> refresh()

        # PROJ-41: the project is made; its repository is not.
        {:ok, project, :no_repository} ->
          socket
          |> assign(form: empty_form(), error: nil)
          |> put_flash(
            :error,
            "Created #{project.name}, but its git repository couldn't be set up."
          )
          |> refresh()

        {:error, :blank_name} ->
          assign(socket, error: "Give the project a name.", form: name_form(name))

        {:error, :folder_exists} ->
          assign(socket,
            error:
              "There's already a folder #{Projects.folder_for(name)}. Give the project " <>
                "another name, or set another projects root.",
            form: name_form(name)
          )

        {:error, :folder_failed} ->
          assign(socket,
            error: "Couldn't make #{Projects.folder_for(name)}. Is the projects root writable?",
            form: name_form(name)
          )
      end

    {:noreply, socket}
  end

  # PROJ-40: the root a project's own folder is made under.
  @impl true
  def handle_event("save_root", %{"root" => %{"folder" => folder}}, socket) do
    socket =
      case Projects.set_root(folder) do
        :ok ->
          socket
          |> assign(root_error: nil, root_form: root_form())
          |> put_flash(:info, "Projects root saved.")
          |> refresh()

        {:error, :blank_root} ->
          assign(socket,
            root_error: "Give a folder for new projects.",
            root_form: root_form(folder)
          )
      end

    {:noreply, socket}
  end

  defp empty_form, do: name_form("")

  defp name_form(name), do: to_form(%{"name" => name}, as: :project)

  defp root_form(folder \\ ""), do: to_form(%{"folder" => folder}, as: :root)

  # PROJ-23: every project with its chat count.
  defp refresh(socket) do
    chats = Elia.Store.list(1000)

    projects =
      Enum.map(Projects.list(), &Map.put(&1, :chats, count_chats(chats, &1)))

    assign(socket, projects: projects, root: Projects.root())
  end

  # A chat without a project id belongs to Elia's own project (PROJ-9).
  defp count_chats(chats, %{harness?: true}),
    do: Enum.count(chats, &(&1.project_id in [nil, "harness"]))

  defp count_chats(chats, project), do: Enum.count(chats, &(&1.project_id == project.id))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} chats={@chat_list} active_chats={@active_chats}>
      <div class="h-full overflow-y-auto">
        <div class="mx-auto max-w-3xl px-4 py-10 sm:px-6">
          <h1 class="text-2xl font-semibold tracking-tight">Projects</h1>
          <p class="mt-1 text-sm text-base-content/60">
            A project is a folder on disk. Every chat belongs to one, and its tools work in that
            folder.
          </p>

          <div class="mt-8 rounded-2xl border border-base-300 p-5">
            <.form for={@form} id="new-project" phx-submit="create">
              <h2 class="font-medium">New project</h2>
              <p class="mt-1 text-xs text-base-content/60">
                Its folder is made under the projects root, below, as a git repository with
                an initial commit.
              </p>
              <div class="mt-4 flex flex-col gap-2 sm:flex-row sm:items-start">
                <div class="flex-1">
                  <.input
                    field={@form[:name]}
                    type="text"
                    placeholder="Name"
                    autocomplete="off"
                    class="w-full rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 text-sm outline-none transition focus:border-primary focus:bg-base-100"
                  />
                </div>
                <button
                  type="submit"
                  id="create-project"
                  class="flex h-11 shrink-0 items-center gap-1.5 rounded-xl bg-primary px-4 text-sm font-medium text-primary-content transition hover:brightness-110"
                >
                  <.icon name="hero-plus" class="size-4" /> Create
                </button>
              </div>

              <p
                :if={@error}
                id="project-error"
                role="alert"
                class="mt-3 flex items-center gap-2 rounded-lg bg-error/10 px-3 py-2 text-xs text-error"
              >
                <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" /> {@error}
              </p>
            </.form>

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
              <div class="mt-4 flex flex-col gap-2 sm:flex-row sm:items-start">
                <div class="flex-1">
                  <.input
                    field={@root_form[:folder]}
                    id="projects-root-input"
                    type="text"
                    placeholder="~/elia-projects"
                    autocomplete="off"
                    class="w-full rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 font-mono text-sm outline-none transition focus:border-primary focus:bg-base-100"
                  />
                </div>
                <button
                  type="submit"
                  id="save-project-root"
                  class="flex h-11 shrink-0 items-center gap-1.5 rounded-xl border border-base-300 px-4 text-sm font-medium transition hover:bg-base-200"
                >
                  <.icon name="hero-check" class="size-4" /> Save
                </button>
              </div>

              <p class="mt-3 flex items-center gap-2 text-xs text-base-content/50">
                <.icon name="hero-folder" class="size-4 shrink-0" />
                <span id="projects-root-path" class="truncate font-mono" title={@root}>
                  {@root}
                </span>
              </p>

              <p
                :if={@root_error}
                id="projects-root-error"
                role="alert"
                class="mt-3 flex items-center gap-2 rounded-lg bg-error/10 px-3 py-2 text-xs text-error"
              >
                <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" /> {@root_error}
              </p>
            </.form>
          </div>

          <div class="mt-4 space-y-4">
            <section
              :for={project <- @projects}
              id={"project-#{project.id}"}
              class="rounded-2xl border border-base-300 p-5 transition duration-200 hover:border-base-content/20 hover:shadow-sm"
            >
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="flex items-center gap-3">
                  <div
                    id={"project-icon-#{project.id}"}
                    class="grid size-10 place-items-center rounded-xl text-white"
                    style={"background-color: #{Projects.color(project).hex}"}
                  >
                    <.icon name="hero-rectangle-stack" class="size-5" />
                  </div>
                  <div class="min-w-0">
                    <h2 id={"project-name-#{project.id}"} class="font-medium">
                      <.link
                        navigate={~p"/p/#{project.id}"}
                        id={"project-open-#{project.id}"}
                        class="transition hover:underline"
                      >
                        {project.name}
                      </.link>
                    </h2>
                    <p
                      id={"project-folder-#{project.id}"}
                      class="truncate font-mono text-xs text-base-content/50"
                      title={project.folder}
                    >
                      {project.folder}
                    </p>
                  </div>
                </div>
                <span
                  id={"project-chats-#{project.id}"}
                  class="rounded-full bg-base-200 px-2.5 py-1 text-xs font-medium text-base-content/70"
                >
                  {project.chats} {if project.chats == 1, do: "chat", else: "chats"}
                </span>
              </div>
            </section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
