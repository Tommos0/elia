defmodule EliaWeb.ChatLive do
  use EliaWeb, :live_view

  alias Elia.Agent
  alias Elia.LLM
  alias Elia.LLM.{Compaction, Context, Message}

  @impl true
  # PROJ-26: `/p/<id>/new` starts a chat in that project; an unknown id goes home.
  def mount(%{"project_id" => project_id}, _session, %{assigns: %{live_action: :new}} = socket) do
    case Elia.Projects.get(project_id) do
      nil -> {:ok, push_navigate(socket, to: ~p"/")}
      project -> start_new_chat(socket, project)
    end
  end

  # PROJ-26: `/` (the logo and "Chats" header button) starts a chat in the
  # default project (PROJ-8). The sidebar's "New chat" (UI-31) instead goes to
  # the open chat's project, `/p/<id>/new` above.
  def mount(_params, _session, %{assigns: %{live_action: :new}} = socket) do
    start_new_chat(socket, Elia.Projects.default())
  end

  def mount(%{"id" => id}, _session, socket) do
    if Elia.Store.valid_id?(id),
      do: mount_chat(id, socket),
      else: {:ok, push_navigate(socket, to: ~p"/")}
  end

  # PROJ-11: starting a chat in a project makes it the default, and the session
  # carries the project so the chat belongs to it from its first message.
  defp start_new_chat(socket, project) do
    :ok = Elia.Projects.set_default(project.id)
    id = Agent.new_id()
    # STORE-22, UI-63: the chat is saved as it is started, so the sidebar lists
    # it (as "New chat") before its first message. A save that fails is not
    # fatal (SESS-13): the chat opens either way.
    _ = Elia.Store.save(id, [], project: project.id)
    {:ok, _pid} = Agent.ensure_started(id, project: project)
    {:ok, push_navigate(socket, to: ~p"/c/#{id}")}
  end

  defp mount_chat(id, socket) do
    {:ok, _pid} = Agent.ensure_started(id)

    if connected?(socket) do
      Agent.subscribe(id)
      Agent.subscribe_activity()
      Elia.Skills.subscribe()
      Process.send_after(self(), :tick_now, 60_000)
    end

    snapshot = Agent.snapshot(id)
    project = snapshot.project
    {skills, _errors} = Elia.Skills.for_project(project)

    socket =
      socket
      |> assign(
        session_id: id,
        project: project,
        status: snapshot.status,
        tool_status: snapshot.tool_status,
        last_usage: snapshot.last_usage,
        show_context: false,
        context_window: LLM.context_window(snapshot.selection),
        # COMPACT-2: the full history, which the transcript always shows, and the
        # chat's compaction state, from which the request view is derived.
        messages: [],
        compaction: %Compaction{},
        context_elided: 0,
        draft: "",
        draft_reasoning: "",
        form: to_form(%{"text" => ""}, as: :chat),
        page_title: Elia.Store.title(snapshot.messages),
        chats: Elia.Store.list(30),
        projects: Elia.Projects.list(),
        # UI-47: chats with a tool call awaiting approval, kept live.
        awaiting: Agent.awaiting_approval(),
        # UI-58: chats whose turn is paused at a limit, kept live.
        paused: Agent.paused(),
        # UI-59: chats whose turn is running (working), kept live.
        running: Agent.running(),
        # UI-57: the message of this chat's pause, when its turn is paused.
        pause: snapshot.pause,
        # UI-44: spawn_task call id => %{child_id, status}.
        tasks: task_children(id),
        # UI-48: this chat's own task metadata, when it is a task chat.
        task: snapshot.task,
        task_status: task_status(id, snapshot.task),
        parent_title: parent_title(snapshot.task),
        chats_open: false,
        now: DateTime.utc_now(),
        selection: LLM.selection(snapshot.selection),
        picker_open: false,
        model_query: "",
        search_form: to_form(%{"q" => ""}, as: :model_search),
        # provider key => :loading | {:ok, models} | {:error, message}
        catalogs: %{},
        auto_approve: snapshot.auto_approve,
        auto_approve_open: false,
        # UI-67, UI-68: this chat's jail setting (ISOL-16) and whether the host
        # has a jail at all (ISOL-12, ISOL-20), which decides if it can be off.
        jail: snapshot.jail,
        jail_available: Elia.Shell.jailed?(),
        # UI-70, ISOL-23: whether this chat's worktree is being synced right now
        # (a page that connects mid-sync shows it), then `{:deps_sync, on?}`.
        deps_sync: Elia.DepsSync.syncing?(Elia.Deploy.worktree_path(id)),
        approvable_tools: approvable_tools(skills),
        skills: skills,
        # UI-60: the compact transcript, chosen in the browser (localStorage).
        compact_view: false,
        # UI-62: the current step of the turn, the one-line summary of it that
        # the compact view shows, and whether the one-second refresh runs.
        activity: nil,
        work_summary: nil,
        work_ticking: false
      )
      |> stream(:models, [])
      |> derive_view(snapshot.messages, snapshot.compaction, snapshot.last_usage)
      |> load_messages(snapshot.messages)
      |> refresh_work_summary()
      |> start_work_ticker()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="relative flex h-full">
        <%!-- UI-36: backdrop for the small-screen chat drawer --%>
        <button
          :if={@chats_open}
          type="button"
          id="chats-backdrop"
          phx-click="toggle_chats"
          aria-label="Close chats"
          class="absolute inset-0 z-20 bg-black/40 lg:hidden"
        ></button>
        <aside
          id="sidebar"
          phx-window-keydown={@chats_open && "close_chats"}
          phx-key="Escape"
          class={[
            "flex-col border-r border-base-300 lg:relative lg:z-auto lg:flex lg:w-[var(--sidebar-width,16rem)] lg:max-w-none lg:shrink-0 lg:bg-base-200/30 lg:shadow-none",
            @chats_open &&
              "absolute inset-y-0 left-0 z-30 flex w-72 max-w-[85vw] bg-base-100 shadow-xl",
            !@chats_open && "hidden"
          ]}
        >
          <div
            id="sidebar-resize"
            phx-hook=".SidebarResize"
            role="separator"
            aria-orientation="vertical"
            aria-label="Resize sidebar"
            tabindex="0"
            title="Drag to resize, double-click to reset"
            class="absolute inset-y-0 -right-1 z-10 hidden w-2 cursor-col-resize touch-none transition-colors hover:bg-primary/30 focus-visible:bg-primary/30 focus-visible:outline-none active:bg-primary/40 lg:block"
          >
          </div>
          <p class="px-4 pt-4 pb-2 text-xs font-medium uppercase tracking-wider text-base-content/50">
            Chats
          </p>
          <%!-- UI-31, PROJ-26: start a chat in the open chat's project --%>
          <.link
            navigate={~p"/p/#{@project.id}/new"}
            id="new-chat"
            class="mx-2 mb-1 flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium transition hover:bg-base-200"
          >
            <.icon name="hero-plus" class="size-4" /> New chat
          </.link>
          <nav id="chat-list" class="flex-1 space-y-0.5 overflow-y-auto px-2 pb-4">
            <%!-- UI-4, PROJ-24: chats grouped by project, newest first --%>
            <%= for group <- project_groups(@projects, @chats) do %>
              <div
                id={"project-header-#{group.project.id}"}
                class="flex items-center gap-1 px-3 pt-3 pb-1"
              >
                <.icon name="hero-rectangle-stack" class="size-3.5 shrink-0 text-base-content/40" />
                <span class="min-w-0 flex-1 truncate text-xs font-medium uppercase tracking-wider text-base-content/50">
                  {group.project.name}
                </span>
                <.link
                  navigate={~p"/p/#{group.project.id}/new"}
                  id={"new-chat-#{group.project.id}"}
                  title={"New chat in #{group.project.name}"}
                  class="rounded-md p-1 text-base-content/50 transition hover:bg-base-200 hover:text-base-content"
                >
                  <.icon name="hero-plus" class="size-3.5" />
                </.link>
              </div>
              <%= for {chat, children} <- group.tree do %>
                <.chat_row
                  chat={chat}
                  active={chat.id == @session_id}
                  now={@now}
                  awaiting={chat.id in @awaiting}
                  paused={chat.id in @paused}
                  running={chat.id in @running}
                />
                <div
                  :if={children != []}
                  id={"chat-children-#{chat.id}"}
                  class="ml-3 space-y-0.5 border-l border-base-300 pl-1.5"
                >
                  <.chat_row
                    :for={child <- children}
                    chat={child}
                    active={child.id == @session_id}
                    now={@now}
                    awaiting={child.id in @awaiting}
                    paused={child.id in @paused}
                    running={child.id in @running}
                  />
                </div>
              <% end %>
            <% end %>
            <p :if={@chats == []} class="px-3 py-2 text-sm text-base-content/50">No chats yet</p>
          </nav>
        </aside>
        <div class="flex min-w-0 flex-1 flex-col">
          <div class="border-b border-base-300 px-4 py-1.5 sm:px-6 lg:hidden">
            <button
              type="button"
              id="chats-toggle"
              phx-click="toggle_chats"
              aria-expanded={to_string(@chats_open)}
              aria-controls="sidebar"
              class="flex items-center gap-1.5 rounded-lg px-2 py-1 text-sm transition hover:bg-base-200 active:scale-95"
            >
              <.icon name="hero-bars-3" class="size-4" /> Chats
            </button>
          </div>
          <.task_header
            :if={@task}
            task={@task}
            status={@task_status}
            parent_title={@parent_title}
          />
          <.context_header
            total={@context_breakdown.total}
            context_length={@context_window.context_length}
            show={@show_context}
            buckets={@context_breakdown.buckets}
            provider_tokens={Context.provider_input_tokens(@last_usage)}
            elided={@context_elided}
          />
          <%!-- UI-57: the turn paused at a limit; the user decides. --%>
          <div
            :if={@pause}
            id="pause-banner"
            class="border-b border-warning/40 bg-warning/10"
          >
            <div class="mx-auto flex max-w-3xl flex-wrap items-center gap-2 px-4 py-2 text-sm sm:px-6">
              <.icon name="hero-pause-circle" class="size-4 shrink-0 text-warning" />
              <span id="pause-message" class="min-w-0 flex-1">{@pause}</span>
              <button
                type="button"
                id="fail-button"
                phx-click="fail_task"
                title="End the sub-task now"
                class="rounded-lg px-3 py-1 text-xs font-medium text-base-content/70 transition hover:bg-base-300"
              >
                Fail
              </button>
              <button
                type="button"
                id="resume-button"
                phx-click="resume"
                title="Continue with a fresh budget"
                class="rounded-lg bg-primary px-3 py-1 text-xs font-medium text-primary-content transition hover:brightness-110 active:scale-95"
              >
                Continue
              </button>
            </div>
          </div>
          <div id="transcript-scroll" class="flex-1 overflow-y-auto" phx-hook=".ScrollBottom">
            <div class="mx-auto max-w-3xl space-y-5 px-4 py-8 sm:px-6">
              <div id="transcript" phx-update="stream" class="space-y-5">
                <div id="transcript-empty" class="hidden only:block py-24 text-center">
                  <p class="text-2xl font-semibold tracking-tight">What should we work on?</p>
                  <p class="mt-2 text-sm text-base-content/60">
                    Elia can run shell commands on this machine. You approve every command.
                  </p>
                </div>
                <div
                  :for={{dom_id, item} <- @streams.items}
                  id={dom_id}
                  class="group/item"
                  data-request-status={request_status(item)}
                >
                  <%!-- UI-56: an item the model was not sent is dimmed, so a pruned region reads at a glance. --%>
                  <div
                    class={["transition-opacity", pruned?(item) && "opacity-40 hover:opacity-100"]}
                    data-pruned={to_string(pruned?(item))}
                  >
                    <.item item={item} jail={@jail} />
                  </div>
                  <.item_meta :if={!@compact_view and Map.get(item, :request_status)} item={item} />
                </div>
              </div>

              <div :if={@draft_reasoning != "" and !@compact_view} id="draft-reasoning">
                <.item item={%{kind: :reasoning, text: @draft_reasoning, streaming: true}} />
              </div>
              <div :if={@draft != ""} id="draft">
                <.item item={%{kind: :assistant, text: @draft}} />
              </div>
              <%!-- UI-62: the compact view's one-line summary of the current step. --%>
              <div
                :if={@compact_view and @work_summary}
                id="work-summary"
                class="flex flex-wrap items-center gap-2 text-sm text-base-content/60"
              >
                <.icon name="hero-arrow-path" class="size-3.5 shrink-0 motion-safe:animate-spin" />
                <span>{@work_summary}</span>
                <button
                  :if={@status == :awaiting_approval}
                  type="button"
                  id="work-summary-review"
                  phx-click="set_compact_view"
                  phx-value-on="false"
                  title="Show the tool call so you can approve it"
                  class="rounded-lg border border-warning/50 px-2 py-0.5 text-xs font-medium text-warning transition hover:bg-warning/10 active:scale-95"
                >
                  Review
                </button>
              </div>
              <div
                :if={!@compact_view and @status == :running and @draft == ""}
                id="thinking-indicator"
                class="flex items-center gap-2 text-sm text-base-content/50"
              >
                <span class="flex gap-1">
                  <span class="size-1.5 animate-bounce rounded-full bg-current [animation-delay:-0.3s]" />
                  <span class="size-1.5 animate-bounce rounded-full bg-current [animation-delay:-0.15s]" />
                  <span class="size-1.5 animate-bounce rounded-full bg-current" />
                </span>
                Working
              </div>
            </div>
          </div>

          <div class="border-t border-base-300 bg-base-100">
            <div class="mx-auto flex max-w-3xl flex-wrap items-center gap-2 px-4 pt-3 sm:px-6">
              <.model_picker
                selection={@selection}
                open={@picker_open}
                search_form={@search_form}
                streams={@streams}
              />
              <.auto_approve_picker
                open={@auto_approve_open}
                tools={@approvable_tools}
                enabled={@auto_approve}
              />
              <.jail_toggle on={@jail} available={@jail_available} />
              <%!-- UI-60: switch the transcript between full and compact. --%>
              <button
                type="button"
                id="view-toggle"
                phx-click="toggle_view"
                phx-hook=".ViewToggle"
                aria-pressed={to_string(@compact_view)}
                title={
                  if @compact_view,
                    do: "Show tool calls and reasoning",
                    else: "Hide tool calls and reasoning, keeping only the messages"
                }
                class={[
                  "group flex items-center gap-1.5 rounded-lg border px-2.5 py-1 text-xs transition active:scale-[0.98]",
                  @compact_view && "border-primary/50 bg-primary/5 text-primary",
                  !@compact_view &&
                    "border-base-300 text-base-content/70 hover:border-base-content/20 hover:text-base-content"
                ]}
              >
                <.icon name="hero-bars-3-bottom-left" class="size-3.5 shrink-0 opacity-70" />
                <span class="font-medium">Focus</span>
              </button>
              <%!-- COMPACT-10: compact this chat now, on demand --%>
              <button
                type="button"
                id="compact-button"
                phx-click="compact"
                title="Elide the older turns of this chat's context now"
                class="group flex items-center gap-1.5 rounded-lg border border-base-300 px-2.5 py-1 text-xs text-base-content/70 transition hover:border-base-content/20 hover:text-base-content active:scale-[0.98]"
              >
                <.icon name="hero-archive-box-arrow-down" class="size-3.5 shrink-0 opacity-70" />
                <span class="font-medium">Compact</span>
              </button>
              <%!-- UI-70, ISOL-23: the worktree's dependency sync, while it runs.
              Text beside the controls, so it never blocks the composer or the
              transcript. --%>
              <span
                :if={@deps_sync}
                id="deps-sync"
                class="flex items-center gap-1.5 text-xs text-base-content/60"
              >
                <.icon name="hero-arrow-path" class="size-3.5 shrink-0 motion-safe:animate-spin" />
                Preparing shared dependencies…
              </span>
            </div>
            <.form
              for={@form}
              id="chat-form"
              phx-submit="send"
              class="mx-auto flex max-w-3xl items-end gap-2 px-4 pt-2 pb-4 sm:px-6"
            >
              <textarea
                id="chat-input"
                name={@form[:text].name}
                rows="1"
                phx-hook=".SubmitOnEnter"
                placeholder={if @status == :idle, do: "Message Elia…", else: "Elia is working…"}
                disabled={@status != :idle}
                class="max-h-48 min-h-11 flex-1 resize-none rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 text-sm outline-none transition focus:border-primary focus:bg-base-100 disabled:opacity-60"
              >{@form[:text].value}</textarea>
              <button
                :if={@status == :idle}
                type="submit"
                id="send-button"
                class="grid size-11 place-items-center rounded-xl bg-primary text-primary-content transition hover:brightness-110 active:scale-95"
              >
                <.icon name="hero-arrow-up" class="size-5" />
              </button>
              <button
                :if={@status != :idle}
                type="button"
                id="stop-button"
                phx-click="stop"
                class="grid size-11 place-items-center rounded-xl bg-base-300 transition hover:bg-error hover:text-error-content active:scale-95"
                title="Stop"
              >
                <.icon name="hero-stop-solid" class="size-5" />
              </button>
            </.form>
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitOnEnter">
        export default {
          mounted() {
            const resize = () => {
              this.el.style.height = "auto"
              this.el.style.height = this.el.scrollHeight + "px"
            }
            this.el.addEventListener("input", resize)
            this.el.addEventListener("keydown", e => {
              if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                e.preventDefault()
                this.el.form.requestSubmit()
              }
            })
            this.handleEvent("chat:clear", () => { this.el.value = ""; resize() })
          },
          updated() { if (!this.el.disabled) this.el.focus() }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SidebarResize">
        // The width lives in a CSS variable on <html>, so LiveView patches
        // (which rewrite element attributes) never reset it.
        const KEY = "elia:sidebar-width"
        const DEFAULT = 256
        const MIN = 192
        const MAX = 640

        export default {
          mounted() {
            const root = document.documentElement
            const aside = this.el.parentElement
            const clamp = w => Math.round(Math.min(Math.max(w, MIN), MAX, window.innerWidth / 2))
            const current = () => aside.getBoundingClientRect().width
            const apply = w => {
              root.style.setProperty("--sidebar-width", clamp(w) + "px")
              this.el.setAttribute("aria-valuenow", clamp(w))
            }
            const save = () => {
              try { localStorage.setItem(KEY, String(Math.round(current()))) } catch (_e) {}
            }

            this.el.setAttribute("aria-valuemin", MIN)
            this.el.setAttribute("aria-valuemax", MAX)

            let stored = null
            try { stored = parseInt(localStorage.getItem(KEY), 10) } catch (_e) {}
            if (stored) apply(stored)
            else this.el.setAttribute("aria-valuenow", DEFAULT)

            this.el.addEventListener("pointerdown", e => {
              e.preventDefault()
              this.el.setPointerCapture(e.pointerId)
              this.dragging = {x: e.clientX, width: current()}
              document.body.style.userSelect = "none"
            })
            this.el.addEventListener("pointermove", e => {
              if (this.dragging) apply(this.dragging.width + e.clientX - this.dragging.x)
            })
            const stop = () => {
              if (!this.dragging) return
              this.dragging = null
              document.body.style.userSelect = ""
              save()
            }
            this.el.addEventListener("pointerup", stop)
            this.el.addEventListener("pointercancel", stop)

            this.el.addEventListener("dblclick", () => {
              apply(DEFAULT)
              try { localStorage.removeItem(KEY) } catch (_e) {}
            })

            this.el.addEventListener("keydown", e => {
              const step = e.shiftKey ? 48 : 16
              if (e.key === "ArrowLeft") apply(current() - step)
              else if (e.key === "ArrowRight") apply(current() + step)
              else return
              e.preventDefault()
              save()
            })
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollBottom">
        export default {
          mounted() {
            this.stick = true
            this.el.addEventListener("scroll", () => {
              this.stick = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 80
            })
            new MutationObserver(() => {
              if (this.stick) this.el.scrollTop = this.el.scrollHeight
            }).observe(this.el, {childList: true, subtree: true, characterData: true})
            this.el.scrollTop = this.el.scrollHeight
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ViewToggle">
        // UI-60: the compact view is remembered per browser, so every chat
        // opens the way the reader last left it.
        const KEY = "elia:compact-view"

        export default {
          mounted() {
            let stored = null
            try { stored = localStorage.getItem(KEY) } catch (_e) {}
            if (stored === "1") this.pushEvent("set_compact_view", {on: true})
            this.handleEvent("view:remember", ({on}) => {
              try { localStorage.setItem(KEY, on ? "1" : "0") } catch (_e) {}
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :chat, :map, required: true
  attr :active, :boolean, required: true
  attr :now, :any, required: true
  attr :awaiting, :boolean, default: false
  attr :paused, :boolean, default: false
  attr :running, :boolean, default: false

  # UI-4, UI-34, UI-46, UI-47, UI-58, UI-59, UI-64
  defp chat_row(assigns) do
    {status_id, status} = chat_status(assigns.chat, assigns)
    assigns = assign(assigns, status_id: status_id, status: status)

    ~H"""
    <%!-- UI-64: the delete button sits beside the link, as its sibling, so no
    interactive element is nested inside another. --%>
    <div id={"chat-row-#{@chat.id}"} class="flex gap-0.5">
      <.link
        navigate={~p"/c/#{@chat.id}"}
        id={"chat-link-#{@chat.id}"}
        title={@chat.description}
        class={[
          "block min-w-0 flex-1 rounded-lg px-3 py-2 text-sm transition",
          @active && "bg-base-300 font-medium",
          !@active && "text-base-content/70 hover:bg-base-200 hover:text-base-content"
        ]}
      >
        <span class="flex items-center gap-1.5">
          <.status_icon id={@status_id} status={@status} />
          <span class="block min-w-0 flex-1 truncate">{@chat.title}</span>
        </span>
        <time
          id={"chat-time-#{@chat.id}"}
          datetime={DateTime.to_iso8601(@chat.created_at)}
          title={Calendar.strftime(@chat.created_at, "%Y-%m-%d %H:%M:%S UTC")}
          class="block text-xs font-normal text-base-content/50"
        >
          {EliaWeb.TimeAgo.format(@chat.created_at, @now)}
        </time>
      </.link>
      <button
        type="button"
        id={"delete-chat-#{@chat.id}"}
        phx-click="delete_chat"
        phx-value-id={@chat.id}
        data-confirm={"Delete the chat #{@chat.title}? This can't be undone."}
        aria-label="Delete chat"
        title="Delete chat"
        class="shrink-0 rounded-lg px-1.5 text-base-content/40 transition hover:bg-error/10 hover:text-error focus-visible:bg-error/10 focus-visible:text-error focus-visible:outline-none active:scale-95"
      >
        <.icon name="hero-trash" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :status, :string, required: true

  # UI-44, UI-46, UI-47, UI-58, UI-59: a chat's status as an icon — waiting for
  # approval or paused first (UI-47, UI-58), then a task's own status (UI-46),
  # then an ordinary chat's loop activity (`working`/`idle`, UI-59).
  defp status_icon(assigns) do
    {icon, class} = status_icon_spec(assigns.status)
    assigns = assign(assigns, icon: icon, class: class)

    ~H"""
    <span
      id={@id}
      data-status={@status}
      title={status_title(@status)}
      class="inline-flex shrink-0 items-center"
    >
      <.icon :if={@icon} name={@icon} class={["size-3.5", @class]} />
      <span :if={!@icon} class={["block size-1.5 rounded-full bg-current", @class]}></span>
    </span>
    """
  end

  defp status_icon_spec("working"), do: {"hero-arrow-path", "text-info motion-safe:animate-spin"}
  defp status_icon_spec("running"), do: {"hero-arrow-path", "text-info motion-safe:animate-spin"}
  defp status_icon_spec("awaiting_approval"), do: {"hero-hand-raised", "text-warning"}
  defp status_icon_spec("paused"), do: {"hero-pause-circle", "text-warning"}
  defp status_icon_spec("done"), do: {"hero-check-circle", "text-success"}
  defp status_icon_spec("blocked"), do: {"hero-pause-circle", "text-warning"}
  defp status_icon_spec("failed"), do: {"hero-x-circle", "text-error"}
  defp status_icon_spec("unfinished"), do: {"hero-question-mark-circle", "text-warning"}
  defp status_icon_spec("cancelled"), do: {"hero-stop-circle", "text-base-content/60"}
  defp status_icon_spec("idle"), do: {nil, "text-base-content/30"}
  defp status_icon_spec(_other), do: {"hero-exclamation-triangle", "text-base-content/50"}

  defp status_title("working"), do: "Working"
  defp status_title("idle"), do: "Idle"
  defp status_title("awaiting_approval"), do: "Needs approval"
  defp status_title("paused"), do: "Paused"
  defp status_title(status), do: "Task #{status}"

  # UI-46, UI-47, UI-58, UI-59: the one status indicator a sidebar chat shows.
  defp chat_status(chat, %{awaiting: true}), do: {"chat-status-#{chat.id}", "awaiting_approval"}
  defp chat_status(chat, %{paused: true}), do: {"chat-status-#{chat.id}", "paused"}
  defp chat_status(%{task_status: status} = chat, _state), do: {"chat-status-#{chat.id}", status}
  defp chat_status(chat, %{running: true}), do: {"chat-status-#{chat.id}", "working"}
  defp chat_status(chat, _state), do: {"chat-status-#{chat.id}", "idle"}

  attr :task, :map, required: true
  attr :status, :string, required: true
  attr :parent_title, :string, required: true

  # UI-48
  defp task_header(assigns) do
    assigns = assign(assigns, result: Map.get(assigns.task, :result))

    ~H"""
    <div id="task-header" class="border-b border-base-300 bg-base-200/40">
      <div class="mx-auto max-w-3xl space-y-1.5 px-4 py-2 text-xs sm:px-6">
        <div class="flex items-center gap-2">
          <.status_icon id="task-header-status" status={@status} />
          <span class="text-base-content/60">Task of</span>
          <.link
            navigate={~p"/c/#{@task.parent_id}"}
            id="task-parent-link"
            class="min-w-0 truncate font-medium text-primary transition hover:underline"
          >
            {@parent_title}
          </.link>
          <span class="ml-auto shrink-0 capitalize text-base-content/60">{@status}</span>
        </div>
        <details :if={@task[:brief]} id="task-header-brief" class="group/brief">
          <summary class="flex cursor-pointer list-none items-center gap-1 text-base-content/60 hover:text-base-content">
            <.icon name="hero-chevron-right" class="size-3 transition group-open/brief:rotate-90" />
            Brief
          </summary>
          <div class="mt-1 max-h-60 overflow-auto whitespace-pre-wrap rounded-lg bg-base-100/70 px-3 py-2">
            {@task.brief}
          </div>
        </details>
        <div :if={@result} id="task-result" class="space-y-1 rounded-lg bg-base-100/70 px-3 py-2">
          <p class="font-medium">Result</p>
          <p class="whitespace-pre-wrap">{@result["summary"]}</p>
          <p :if={@result["commit"]}>
            Commit <code class="font-mono">{String.slice(@result["commit"], 0, 8)}</code>
          </p>
          <div :if={@result["files"] not in [nil, []]}>
            <p class="text-base-content/60">Changed files</p>
            <ul class="font-mono">
              <li :for={file <- @result["files"]} class="truncate">{file}</li>
            </ul>
          </div>
          <div :if={@result["questions"] not in [nil, []]}>
            <p class="text-base-content/60">Open questions</p>
            <ul class="list-disc pl-4">
              <li :for={question <- @result["questions"]}>{question}</li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :total, :integer, required: true
  attr :context_length, :integer, default: nil
  attr :show, :boolean, required: true
  attr :buckets, :list, required: true
  attr :provider_tokens, :integer, default: nil
  attr :elided, :integer, default: 0

  defp context_header(assigns) do
    assigns = assign(assigns, :percent, percent_of(assigns.total, assigns.context_length))

    ~H"""
    <div class="border-b border-base-300 bg-base-200/40">
      <div class="mx-auto max-w-3xl px-4 pt-2 sm:px-6">
        <button
          type="button"
          id="context-indicator"
          phx-click="toggle_context"
          aria-expanded={to_string(@show)}
          title="What makes up the context?"
          class="group flex items-center gap-1.5 rounded-lg px-2 py-1 text-xs transition hover:bg-base-300/60"
        >
          <.icon name="hero-cube" class="size-3.5 text-base-content/50" />
          <span class="font-medium text-base-content/70">Context</span>
          <span id="context-size" class="tabular-nums font-semibold">{format_tokens(@total)}</span>
          <span
            :if={@elided > 0}
            id="context-elided-badge"
            title={"#{@elided} tokens of this chat were elided by compaction and are not sent"}
            class="tabular-nums text-base-content/40"
          >
            (−{format_tokens(@elided)})
          </span>
          <span :if={@context_length} id="context-window" class="tabular-nums text-base-content/50">
            / {format_tokens(@context_length)}
          </span>
          <span :if={@percent} id="context-percent" class="tabular-nums text-base-content/50">
            {@percent}%
          </span>
          <span
            :if={@context_length}
            class="block h-1.5 w-16 overflow-hidden rounded-full bg-base-300/80"
          >
            <span
              id="context-bar"
              class={["block h-full rounded-full transition-all", context_bar_class(@percent)]}
              style={"width: #{@percent}%"}
            />
          </span>
          <.icon
            name={if @show, do: "hero-chevron-up", else: "hero-chevron-down"}
            class="size-3.5 text-base-content/40 transition group-hover:text-base-content"
          />
        </button>

        <div :if={@show} id="context-breakdown" class="space-y-2 pb-3 pt-2 text-xs">
          <p class="text-[11px] font-medium uppercase tracking-wider text-base-content/40">
            What makes up the context
          </p>
          <.context_bucket_list buckets={@buckets} />
          <%!-- COMPACT-26: the estimate is over the request view; the elided
                amount is shown but is not part of it. --%>
          <div
            :if={@elided > 0}
            id="context-elided"
            class="flex items-center justify-between gap-3 rounded-lg bg-base-200/60 px-3 py-1.5"
          >
            <span class="flex items-center gap-1.5 text-base-content/60">
              <.icon name="hero-eye-slash" class="size-3.5 shrink-0" />
              <span>Elided by compaction (not sent)</span>
            </span>
            <span class="tabular-nums text-base-content/60">−{format_tokens(@elided)}</span>
          </div>
          <div class="flex items-center justify-between border-t border-base-300/70 pt-2 text-base-content/70">
            <span>Estimated total</span>
            <span id="context-total" class="tabular-nums font-semibold">
              {format_tokens(@total)}
            </span>
          </div>
          <p
            :if={@provider_tokens}
            id="context-provider-usage"
            class="text-[11px] text-base-content/40"
          >
            The model API reported {format_tokens(@provider_tokens)} input tokens on the last
            reply.
          </p>
        </div>
      </div>
    </div>
    """
  end

  attr :buckets, :list, required: true

  defp context_bucket_list(assigns) do
    ~H"""
    <ul class="space-y-1">
      <.context_bucket :for={bucket <- @buckets} bucket={bucket} />
    </ul>
    """
  end

  attr :bucket, :map, required: true

  defp context_bucket(%{bucket: %{children: children}} = assigns) when is_list(children) do
    ~H"""
    <li class="rounded-lg bg-base-100/70 px-3 py-1.5">
      <div class="flex items-center justify-between gap-3">
        <span class="font-medium">{@bucket.label}</span>
        <span class="tabular-nums text-base-content/60">{format_tokens(Context.bucket_tokens(@bucket))}</span>
      </div>
      <ul class="ml-3 space-y-0.5 border-l border-base-300 pl-3 pt-1">
        <.context_bucket :for={child <- @bucket.children} bucket={child} />
      </ul>
    </li>
    """
  end

  defp context_bucket(assigns) do
    ~H"""
    <li class="flex items-center justify-between gap-3 py-0.5 pl-3 text-base-content/80">
      <span class="flex min-w-0 items-center gap-1.5">
        <span class="truncate">{@bucket.label}</span>
        <span
          :if={@bucket.count && @bucket.count > 0}
          class="shrink-0 text-[10px] text-base-content/40"
        >
          {@bucket.count}
        </span>
      </span>
      <span class="tabular-nums text-base-content/60">{format_tokens(@bucket.tokens)}</span>
    </li>
    """
  end

  attr :open, :boolean, required: true
  attr :tools, :list, required: true
  attr :enabled, :list, required: true

  # UI-38, UI-39
  defp auto_approve_picker(assigns) do
    ~H"""
    <div class="relative inline-block max-w-full">
      <button
        type="button"
        id="auto-approve-button"
        phx-click="toggle_auto_approve_picker"
        aria-haspopup="true"
        aria-expanded={to_string(@open)}
        class={[
          "group flex items-center gap-1.5 rounded-lg border px-2.5 py-1 text-xs transition active:scale-[0.98]",
          @open && "border-primary/50 bg-primary/5",
          !@open &&
            "border-base-300 text-base-content/70 hover:border-base-content/20 hover:text-base-content"
        ]}
      >
        <.icon name="hero-shield-check" class="size-3.5 shrink-0 opacity-70" />
        <span class="font-medium">Auto-approve</span>
        <span
          :if={@enabled != []}
          id="auto-approve-count"
          class="rounded-full bg-warning/20 px-1.5 text-[11px] font-medium tabular-nums text-warning"
        >
          {length(@enabled)}
        </span>
      </button>

      <div
        :if={@open}
        id="auto-approve"
        phx-click-away="close_auto_approve_picker"
        phx-window-keydown="close_auto_approve_picker"
        phx-key="Escape"
        class="absolute bottom-full left-0 z-30 mb-2 w-[min(22rem,calc(100vw-2rem))] overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-xl shadow-base-content/5 motion-safe:animate-[picker-in_120ms_ease-out]"
      >
        <p class="border-b border-base-300 px-3 py-2 text-xs text-base-content/60">
          Auto-approved tools run in this chat without asking.
        </p>
        <ul class="max-h-72 overflow-y-auto py-1">
          <li :for={tool <- @tools} class="px-1">
            <button
              type="button"
              id={"auto-approve-#{tool.name}"}
              phx-click="toggle_auto_approve"
              phx-value-tool={tool.name}
              role="switch"
              aria-checked={to_string(tool.name in @enabled)}
              class="flex w-full items-center gap-3 rounded-lg px-2 py-1.5 text-left text-sm transition hover:bg-base-200"
            >
              <.icon name={tool_icon(tool.name)} class="size-4 shrink-0 text-base-content/60" />
              <span class="min-w-0 flex-1 truncate font-medium">{tool.name}</span>
              <span
                id={"auto-approve-state-#{tool.name}"}
                class={[
                  "text-xs font-medium",
                  tool.name in @enabled && "text-warning",
                  tool.name not in @enabled && "text-base-content/50"
                ]}
              >
                {if tool.name in @enabled, do: "On", else: "Off"}
              </span>
              <span class={[
                "relative h-5 w-9 shrink-0 rounded-full transition",
                tool.name in @enabled && "bg-warning",
                tool.name not in @enabled && "bg-base-300"
              ]}>
                <span class={[
                  "absolute top-0.5 size-4 rounded-full bg-base-100 shadow transition-all",
                  tool.name in @enabled && "left-[1.125rem]",
                  tool.name not in @enabled && "left-0.5"
                ]} />
              </span>
            </button>
          </li>
          <li :if={@tools == []} class="px-3 py-2 text-xs text-base-content/40">
            No tools need approval
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :on, :boolean, required: true
  attr :available, :boolean, required: true

  # UI-67, UI-68: the chat's jail switch, next to the model picker and the
  # auto-approve button. A host with no jail (ISOL-12, ISOL-20) can't protect a
  # chat, so the switch is disabled and says so rather than claiming it does.
  defp jail_toggle(assigns) do
    assigns = assign(assigns, :jailed, assigns.on and assigns.available)

    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <button
        type="button"
        id="jail-toggle"
        phx-click="toggle_jail"
        role="switch"
        aria-checked={to_string(@jailed)}
        disabled={!@available}
        title={jail_title(@jailed, @available)}
        class={[
          "group flex items-center gap-1.5 rounded-lg border px-2.5 py-1 text-xs transition active:scale-[0.98] disabled:cursor-not-allowed disabled:active:scale-100",
          @jailed && "border-primary/50 bg-primary/5 text-primary",
          !@jailed && @available &&
            "border-warning/50 bg-warning/5 text-warning hover:border-warning/70",
          !@available && "border-base-300 text-base-content/40"
        ]}
      >
        <.icon
          name={if @jailed, do: "hero-lock-closed", else: "hero-lock-open"}
          class="size-3.5 shrink-0 opacity-70"
        />
        <span class="font-medium">Jail</span>
        <span id="jail-state" class="font-medium">{jail_state(@jailed)}</span>
      </button>
      <span :if={!@available} id="jail-unavailable" class="text-xs text-base-content/50">
        This host has no jail (bubblewrap is unavailable), so commands run unjailed.
      </span>
      <span :if={@available and !@on} id="jail-warning" class="text-xs text-warning">
        Commands run unjailed: they can read the settings database and your credentials.
      </span>
    </div>
    """
  end

  defp jail_state(true), do: "Jailed"
  defp jail_state(false), do: "Not jailed"

  defp jail_title(true, _available),
    do: "Commands run in a jail holding the workspace and the toolchain, and nothing else"

  defp jail_title(false, true), do: "Commands run unjailed, on the whole machine"
  defp jail_title(false, false), do: "This host has no jail, so commands run unjailed"

  attr :selection, :map, required: true
  attr :open, :boolean, required: true
  attr :search_form, :any, required: true
  attr :streams, :any, required: true

  defp model_picker(assigns) do
    ~H"""
    <div class="relative inline-block max-w-full">
      <button
        type="button"
        id="model-picker-button"
        phx-click={if @open, do: "close_picker", else: "open_picker"}
        aria-haspopup="listbox"
        aria-expanded={to_string(@open)}
        class={[
          "group flex max-w-full items-center gap-1.5 rounded-lg border px-2.5 py-1 text-xs transition active:scale-[0.98]",
          @open && "border-primary/50 bg-primary/5",
          !@open &&
            "border-base-300 text-base-content/70 hover:border-base-content/20 hover:text-base-content"
        ]}
      >
        <.provider_badge provider={@selection.provider} id="selected-provider" />
        <span id="selected-model" class="truncate font-medium">{@selection.name}</span>
        <.icon
          name="hero-chevron-up-down"
          class="size-3.5 shrink-0 opacity-60 transition group-hover:opacity-100"
        />
      </button>

      <div
        :if={@open}
        id="model-picker"
        phx-click-away="close_picker"
        phx-window-keydown="close_picker"
        phx-key="Escape"
        class="absolute bottom-full left-0 z-30 mb-2 flex max-h-[28rem] w-[min(28rem,calc(100vw-2rem))] flex-col overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-xl shadow-base-content/5 motion-safe:animate-[picker-in_120ms_ease-out]"
      >
        <.form
          for={@search_form}
          id="model-search-form"
          phx-change="search_models"
          phx-submit="search_models"
          class="border-b border-base-300 p-2"
        >
          <label class="flex items-center gap-2 rounded-lg bg-base-200/60 px-2.5 focus-within:ring-1 focus-within:ring-primary/50">
            <.icon name="hero-magnifying-glass" class="size-4 shrink-0 text-base-content/40" />
            <input
              type="text"
              id="model-search"
              name={@search_form[:q].name}
              value={@search_form[:q].value}
              placeholder="Search models…"
              autocomplete="off"
              phx-debounce="120"
              phx-mounted={JS.focus()}
              class="h-9 w-full bg-transparent text-sm outline-none"
            />
          </label>
        </.form>
        <ul id="model-list" phx-update="stream" role="listbox" class="flex-1 overflow-y-auto py-1">
          <li :for={{dom_id, entry} <- @streams.models} id={dom_id}>
            <.model_entry entry={entry} selection={@selection} />
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :selection, :map, required: true

  defp model_entry(%{entry: %{kind: :header}} = assigns) do
    ~H"""
    <div
      id={"group-#{@entry.provider}"}
      class="sticky top-0 z-10 flex items-center gap-2 border-b border-base-300/60 bg-base-100/95 px-3 py-2 backdrop-blur [li:not(:first-child)>&]:mt-1 [li:not(:first-child)>&]:border-t"
    >
      <.provider_badge provider={@entry.provider} />
      <span class="truncate text-[11px] text-base-content/50">{provider_route(@entry.provider)}</span>
      <span :if={@entry.count} class="ml-auto text-[11px] tabular-nums text-base-content/40">
        {@entry.count}
      </span>
    </div>
    <%= case @entry.status do %>
      <% :loading -> %>
        <div class="flex items-center gap-2 px-3 py-2 text-xs text-base-content/50">
          <.icon name="hero-arrow-path" class="size-3.5 motion-safe:animate-spin" /> Loading models…
        </div>
      <% :no_key -> %>
        <.link
          navigate={~p"/settings"}
          id={"add-key-#{@entry.provider}"}
          class="mx-2 mb-1 flex items-center gap-2 rounded-lg px-2 py-2 text-xs text-primary transition hover:bg-primary/10"
        >
          <.icon name="hero-key" class="size-3.5" /> Add an API key in Settings
          <.icon name="hero-arrow-right" class="ml-auto size-3.5" />
        </.link>
      <% {:error, message} -> %>
        <div
          id={"catalog-error-#{@entry.provider}"}
          class="mx-2 mb-1 flex items-start gap-2 rounded-lg bg-error/10 px-2 py-2 text-xs text-error"
        >
          <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
          <span class="break-words">{message}</span>
        </div>
      <% :empty -> %>
        <p class="px-3 py-2 text-xs text-base-content/40">No matching models</p>
      <% _ -> %>
    <% end %>
    """
  end

  defp model_entry(assigns) do
    assigns =
      assign(assigns,
        selected?:
          assigns.selection.provider == assigns.entry.provider and
            assigns.selection.model == assigns.entry.model
      )

    ~H"""
    <button
      type="button"
      role="option"
      aria-selected={to_string(@selected?)}
      phx-click="select_model"
      phx-value-provider={@entry.provider}
      phx-value-model={@entry.model}
      phx-value-name={@entry.name}
      class={[
        "group mx-1 flex w-[calc(100%-0.5rem)] items-center gap-3 rounded-lg px-2 py-1.5 text-left transition",
        @selected? && "bg-primary/10",
        !@selected? && "hover:bg-base-200"
      ]}
    >
      <div class="min-w-0 flex-1">
        <p class={["truncate text-sm", @selected? && "font-medium text-primary"]}>{@entry.name}</p>
        <p class="flex min-w-0 items-center gap-1.5">
          <.provider_badge provider={@entry.provider} size="xs" />
          <span class="truncate font-mono text-[11px] text-base-content/40">{@entry.model}</span>
        </p>
      </div>
      <div class="shrink-0 text-right text-[11px] leading-tight text-base-content/50">
        <p :if={@entry.context_length}>{format_context(@entry.context_length)}</p>
        <p :if={@entry.prompt_price}>
          {format_price(@entry.prompt_price)} / {format_price(@entry.completion_price)}
        </p>
      </div>
      <.icon
        name="hero-check"
        class={["size-4 shrink-0 text-primary", !@selected? && "invisible"]}
      />
    </button>
    """
  end

  defp provider_route("anthropic"), do: "Direct from the Anthropic API"
  defp provider_route("openrouter"), do: "Many vendors, routed via OpenRouter"
  defp provider_route(_key), do: ""

  defp format_context(tokens) when tokens >= 1_000_000,
    do: "#{Float.round(tokens / 1_000_000, 1) |> trim_float()}M ctx"

  defp format_context(tokens) when tokens >= 1000, do: "#{div(tokens, 1000)}K ctx"
  defp format_context(tokens), do: "#{tokens} ctx"

  # CTX-10: the provider adjustment can be negative.
  defp format_tokens(tokens) when tokens < 0, do: "-#{format_tokens(-tokens)}"

  defp format_tokens(tokens) when tokens >= 1_000_000,
    do: "#{Float.round(tokens / 1_000_000, 1) |> trim_float()}M"

  defp format_tokens(tokens) when tokens >= 1000, do: "#{div(tokens, 1000)}K"
  defp format_tokens(tokens), do: "#{tokens}"

  defp percent_of(_tokens, nil), do: nil

  defp percent_of(tokens, window) when is_integer(window) and window > 0,
    do: min(100, div(tokens * 100 + window - 1, window))

  defp context_bar_class(nil), do: ""
  defp context_bar_class(percent) when percent <= 60, do: "bg-success"
  defp context_bar_class(percent) when percent <= 85, do: "bg-warning"
  defp context_bar_class(_percent), do: "bg-error"

  defp format_price(nil), do: "?"
  defp format_price(price) when price == 0, do: "free"
  defp format_price(price) when price < 0.1, do: "$#{Float.round(price, 3) |> trim_float()}"
  defp format_price(price), do: "$#{Float.round(price, 2) |> trim_float()}"

  defp trim_float(float) do
    if float == Float.round(float), do: trunc(float), else: float
  end

  @doc "DOM id of a model in the picker (ids contain `/`, `:` and `.`)."
  def model_dom_id(provider, model),
    do: "models-m-#{provider}-#{Base.url_encode64(model, padding: false)}"

  attr :item, :map, required: true
  attr :jail, :boolean, default: true

  defp item(%{item: %{kind: :user}} = assigns) do
    ~H"""
    <div class="flex justify-end">
      <div class="max-w-[85%] whitespace-pre-wrap rounded-2xl rounded-br-md bg-primary px-4 py-2.5 text-sm text-primary-content">
        {@item.text}
      </div>
    </div>
    """
  end

  defp item(%{item: %{kind: :assistant}} = assigns) do
    ~H"""
    <div class="markdown text-sm leading-relaxed">{EliaWeb.Markdown.to_html(@item.text)}</div>
    """
  end

  # COMPACT-19, COMPACT-25: the folded summary stands in for the turns the model
  # was not sent, rendered where they end so the compression is visible in place.
  defp item(%{item: %{kind: :summary}} = assigns) do
    ~H"""
    <details
      id="compaction-summary"
      open
      class="group/summary rounded-xl border border-dashed border-base-300 bg-base-200/40 px-3 py-2 text-xs"
    >
      <summary class="flex cursor-pointer list-none items-center gap-1.5 font-medium text-base-content/70">
        <.icon name="hero-archive-box" class="size-3.5 shrink-0 text-base-content/50" />
        <span>Earlier turns summarized</span>
        <span id="compaction-summary-length" class="font-normal text-base-content/40">
          {length(String.split(@item.text))} words
        </span>
        <.icon name="hero-chevron-right" class="size-3 transition group-open/summary:rotate-90" />
      </summary>
      <div
        id="compaction-summary-text"
        class="mt-1.5 ml-1.5 whitespace-pre-wrap border-l-2 border-base-300 pl-3 text-base-content/70"
      >
        {@item.text}
      </div>
    </details>
    """
  end

  # UI-29, UI-30: collapsed by default; the client keeps `open` across patches
  # so an expanded streaming block stays expanded.
  defp item(%{item: %{kind: :reasoning}} = assigns) do
    assigns =
      assign(assigns,
        streaming: Map.get(assigns.item, :streaming, false),
        words: length(String.split(assigns.item.text))
      )

    ~H"""
    <details
      class="group/reasoning text-xs text-base-content/50"
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary class="reasoning-summary inline-flex cursor-pointer list-none items-center gap-1.5 rounded-md py-0.5 pr-1.5 transition hover:text-base-content/80">
        <.icon name="hero-light-bulb" class={["size-3.5 shrink-0", @streaming && "animate-pulse"]} />
        <span class="font-medium">{if @streaming, do: "Reasoning…", else: "Reasoning"}</span>
        <span class="text-base-content/40">· {@words} {if @words == 1, do: "word", else: "words"}</span>
        <.icon name="hero-chevron-right" class="size-3 transition group-open/reasoning:rotate-90" />
      </summary>
      <div class="reasoning-text mt-1 ml-1.5 whitespace-pre-wrap border-l-2 border-base-300 pl-3 italic">
        {@item.text}
      </div>
    </details>
    """
  end

  defp item(%{item: %{kind: :tool}} = assigns) do
    ~H"""
    <div class={[
      "overflow-hidden rounded-xl border text-sm transition",
      @item.status == :awaiting_approval && "border-warning/60 shadow-sm shadow-warning/10",
      @item.status != :awaiting_approval && "border-base-300"
    ]}>
      <div class="flex items-center justify-between gap-3 bg-base-200/60 px-3 py-2">
        <div class="flex min-w-0 items-center gap-2">
          <.icon name={tool_icon(@item.name)} class="size-4 shrink-0 text-base-content/60" />
          <span class="font-medium">{@item.name}</span>
        </div>
        <.tool_badge status={@item.status} is_error={@item.is_error} />
      </div>
      <pre class="overflow-x-auto px-3 py-2 font-mono text-xs leading-relaxed"><span :if={@item.name == "shell"} class="select-none text-base-content/40">$ </span>{tool_summary(@item)}</pre>
      <%!-- UI-43: task card --%>
      <details
        :if={@item.name == "spawn_task" && is_binary(@item.input["brief"])}
        id={"task-brief-#{@item.call_id}"}
        open={@item.status == :awaiting_approval}
        class="group/brief border-t border-base-300"
      >
        <summary class="flex cursor-pointer list-none items-center gap-1 px-3 py-1.5 text-xs text-base-content/60 hover:text-base-content">
          <.icon name="hero-chevron-right" class="size-3 transition group-open/brief:rotate-90" />
          Brief
        </summary>
        <div class="max-h-96 overflow-auto whitespace-pre-wrap bg-base-200/40 px-3 py-2 text-xs leading-relaxed">
          {@item.input["brief"]}
        </div>
      </details>
      <div
        :if={Map.get(@item, :task)}
        id={"task-card-#{@item.call_id}"}
        class="flex flex-wrap items-center gap-2 border-t border-base-300 px-3 py-2 text-xs"
      >
        <.status_icon id={"task-status-#{@item.call_id}"} status={@item.task.status} />
        <span class="capitalize text-base-content/70">{@item.task.status}</span>
        <span
          :if={@item.task.awaiting}
          id={"task-awaiting-#{@item.call_id}"}
          class="flex items-center gap-1 rounded-full bg-warning/20 px-2 py-0.5 font-medium text-warning"
        >
          <.icon name="hero-hand-raised" class="size-3" /> Waiting for approval in the task chat
        </span>
        <span
          :if={@item.task.paused}
          id={"task-paused-#{@item.call_id}"}
          class="flex items-center gap-1 rounded-full bg-warning/20 px-2 py-0.5 font-medium text-warning"
        >
          <.icon name="hero-pause-circle" class="size-3" /> Paused at a limit in the task chat
        </span>
        <.link
          navigate={~p"/c/#{@item.task.child_id}"}
          id={"task-link-#{@item.call_id}"}
          class="ml-auto flex items-center gap-1 font-medium text-primary transition hover:underline"
        >
          Open task chat <.icon name="hero-arrow-right" class="size-3" />
        </.link>
      </div>
      <details
        :if={detail = tool_detail(@item)}
        open={@item.status == :awaiting_approval}
        class="group/detail border-t border-base-300"
      >
        <summary class="flex cursor-pointer list-none items-center gap-1 px-3 py-1.5 text-xs text-base-content/60 hover:text-base-content">
          <.icon name="hero-chevron-right" class="size-3 transition group-open/detail:rotate-90" />
          Changes
        </summary>
        <div class="max-h-96 overflow-auto font-mono text-xs leading-relaxed">
          <pre
            :for={{kind, text} <- detail}
            class={[
              "whitespace-pre-wrap px-3 py-1.5",
              kind == :removed && "bg-error/10 text-error",
              kind == :added && "bg-success/10",
              kind == :content && "bg-base-200/40"
            ]}
          >{text}</pre>
        </div>
      </details>
      <div
        :if={@item.status == :awaiting_approval}
        class="flex items-center justify-end gap-2 border-t border-base-300 px-3 py-2"
      >
        <span class="mr-auto text-xs text-base-content/60">
          Allow this? <%!-- ISOL-17, UI-69: the state is visible at the moment it matters. --%>
          <span :if={!@jail} id={"unjailed-#{@item.call_id}"} class="font-medium text-warning">
            It runs unjailed.
          </span>
        </span>
        <button
          id={"always-allow-#{@item.call_id}"}
          phx-click="always_allow"
          phx-value-tool={@item.name}
          title={"Approve this and every later #{@item.name} call in this chat"}
          class="rounded-lg px-3 py-1 text-xs font-medium text-base-content/70 transition hover:bg-base-300"
        >
          Always allow
        </button>
        <button
          id={"deny-#{@item.call_id}"}
          phx-click="deny"
          phx-value-id={@item.call_id}
          class="rounded-lg px-3 py-1 text-xs font-medium transition hover:bg-base-300"
        >
          Deny
        </button>
        <button
          id={"approve-#{@item.call_id}"}
          phx-click="approve"
          phx-value-id={@item.call_id}
          class="rounded-lg bg-primary px-3 py-1 text-xs font-medium text-primary-content transition hover:brightness-110 active:scale-95"
        >
          Approve
        </button>
      </div>
      <details :if={@item.output} class="group border-t border-base-300">
        <summary class="flex cursor-pointer list-none items-center gap-1 px-3 py-1.5 text-xs text-base-content/60 hover:text-base-content">
          <.icon name="hero-chevron-right" class="size-3 transition group-open:rotate-90" /> Output
        </summary>
        <pre class={[
          "max-h-96 overflow-auto bg-base-200/40 px-3 py-2 font-mono text-xs leading-relaxed",
          @item.is_error && "text-error"
        ]}>{@item.output}</pre>
      </details>
    </div>
    """
  end

  defp item(%{item: %{kind: kind}} = assigns) when kind in [:notice, :error] do
    ~H"""
    <div class={[
      "flex items-center gap-2 rounded-lg px-3 py-2 text-xs",
      @item.kind == :error && "bg-error/10 text-error",
      @item.kind == :notice && "bg-base-200 text-base-content/70"
    ]}>
      <.icon
        name={
          if @item.kind == :error, do: "hero-exclamation-triangle", else: "hero-information-circle"
        }
        class="size-4 shrink-0"
      />
      {@item.text}
    </div>
    """
  end

  attr :item, :map, required: true

  # COMPACT-25: what the model was sent of this item. The
  # UI never implies the model saw something it did not.
  defp item_meta(assigns) do
    assigns =
      assigns
      |> assign(:id, request_id(assigns.item))
      |> assign(:label, request_label(assigns.item))
      |> assign(:pruned, pruned?(assigns.item))

    ~H"""
    <div class="mt-1 flex items-center gap-2 text-[11px]">
      <span
        :if={@label}
        id={"status-#{@id}"}
        class={
          [
            "flex items-center gap-1 text-base-content/45",
            # UI-56: an item the model was not sent is dimmed, so its note reads as
            # a chip rather than fading with it.
            @pruned && "rounded-md bg-base-200 px-1.5 py-0.5 font-medium text-base-content/70"
          ]
        }
      >
        <.icon name={request_icon(request_status(@item))} class="size-3 shrink-0" />
        <span>{@label}</span>
        <span :if={Map.get(@item, :elided) > 0} class="tabular-nums">
          −{format_tokens(@item.elided)} tokens
        </span>
      </span>
    </div>
    """
  end

  defp request_id(%{kind: :tool, call_id: id}), do: "call-#{id}"
  defp request_id(%{index: index, block: block}) when is_integer(block), do: "m#{index}-#{block}"
  defp request_id(%{index: index}), do: "m#{index}"
  defp request_id(_item), do: "item"

  # UI-56: an item the model was not sent at all is dimmed in the transcript; one
  # it was sent, or got only part of (truncated), is not. The wrapper's
  # `data-request-status` and the note (UI-51) come from this one rule.
  defp pruned?(item), do: request_status(item) in [:elided, :summarized]

  defp request_status(%{request_status: :summarized}), do: :summarized
  defp request_status(%{block_status: :elided}), do: :elided
  defp request_status(%{request_status: :truncated}), do: :truncated
  defp request_status(%{request_status: :elided}), do: :elided
  defp request_status(_item), do: :sent

  # A block-level rule (dropped reasoning, an elided tool result) decides for the
  # block, unless a summary stands in for the whole message (COMPACT-25).
  defp request_label(item) do
    case request_status(item) do
      :summarized -> "Summarized for the model"
      :truncated -> "Truncated for the model"
      :elided -> "Not sent to the model"
      :sent -> nil
    end
  end

  defp request_icon(:truncated), do: "hero-scissors"
  defp request_icon(_status), do: "hero-eye-slash"

  attr :status, :atom, required: true
  attr :is_error, :boolean, default: false

  defp tool_badge(assigns) do
    {label, class} =
      case {assigns.status, assigns.is_error} do
        {:awaiting_approval, _} -> {"Needs approval", "bg-warning/15 text-warning"}
        {:approved, _} -> {"Approved", "bg-info/15 text-info"}
        {:running, _} -> {"Running", "bg-info/15 text-info animate-pulse"}
        {:done, true} -> {"Failed", "bg-error/15 text-error"}
        {:done, false} -> {"Done", "bg-success/15 text-success"}
        _ -> {"Pending", "bg-base-300 text-base-content/60"}
      end

    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span class={["rounded-full px-2 py-0.5 text-[11px] font-medium", @class]}>{@label}</span>
    """
  end

  defp tool_icon("shell"), do: "hero-command-line"
  defp tool_icon(name) when name in ~w(read_file write_file edit_file), do: "hero-document-text"
  defp tool_icon("spawn_task"), do: "hero-rectangle-stack"
  defp tool_icon(_name), do: "hero-wrench-screwdriver"

  defp tool_summary(%{name: "shell", input: %{"command" => command}}), do: command

  defp tool_summary(%{name: "spawn_task", input: %{"title" => title}}) when is_binary(title),
    do: title

  defp tool_summary(%{input: %{"path" => path}}), do: path
  defp tool_summary(%{input: input}) when input == %{}, do: "(no input)"
  defp tool_summary(%{input: input}), do: Jason.encode!(input, pretty: true)

  defp tool_detail(%{name: "write_file", input: %{"content" => content}}), do: [content: content]

  defp tool_detail(%{name: "edit_file", input: %{"old_string" => old, "new_string" => new}}) do
    [removed: old, added: new]
  end

  defp tool_detail(_item), do: nil

  ## Events

  @impl true
  def handle_event("send", %{"chat" => %{"text" => text}}, socket) do
    text = String.trim(text)

    if text != "" and Agent.send_message(socket.assigns.session_id, text) == :ok do
      {:noreply, push_event(socket, "chat:clear", %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_chats", _params, socket) do
    {:noreply, assign(socket, chats_open: !socket.assigns.chats_open)}
  end

  def handle_event("close_chats", _params, socket) do
    {:noreply, assign(socket, chats_open: false)}
  end

  def handle_event("toggle_context", _params, socket) do
    {:noreply, assign(socket, show_context: !socket.assigns.show_context)}
  end

  # UI-60: switch the transcript between the full and the compact view, and ask
  # the browser to remember the choice.
  def handle_event("toggle_view", _params, socket) do
    on = not socket.assigns.compact_view

    {:noreply,
     socket
     |> set_compact_view(on)
     |> push_event("view:remember", %{on: on})}
  end

  # UI-60: the stored choice, and the "Review" button (UI-62), arrive as values.
  def handle_event("set_compact_view", params, socket) do
    {:noreply, set_compact_view(socket, params["on"] in [true, "true"])}
  end

  # COMPACT-10
  def handle_event("compact", _params, socket) do
    case Agent.compact(socket.assigns.session_id) do
      :ok ->
        {:noreply, socket}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Elia is working; try again in a moment.")}
    end
  end

  def handle_event("approve", %{"id" => call_id}, socket) do
    Agent.approve(socket.assigns.session_id, call_id)
    {:noreply, socket}
  end

  def handle_event("deny", %{"id" => call_id}, socket) do
    Agent.deny(socket.assigns.session_id, call_id)
    {:noreply, socket}
  end

  def handle_event("always_allow", %{"tool" => tool}, socket) do
    set_auto_approve(socket, tool, true)
  end

  def handle_event("toggle_auto_approve", %{"tool" => tool}, socket) do
    set_auto_approve(socket, tool, tool not in socket.assigns.auto_approve)
  end

  def handle_event("toggle_auto_approve_picker", _params, socket) do
    {:noreply, assign(socket, auto_approve_open: !socket.assigns.auto_approve_open)}
  end

  def handle_event("close_auto_approve_picker", _params, socket) do
    {:noreply, assign(socket, auto_approve_open: false)}
  end

  # UI-67, SESS-30: turn this chat's jail on or off. The switch follows the
  # session's broadcast, so every tab stays in sync.
  def handle_event("toggle_jail", _params, socket) do
    Agent.set_jail(socket.assigns.session_id, not socket.assigns.jail)
    {:noreply, socket}
  end

  def handle_event("stop", _params, socket) do
    Agent.stop(socket.assigns.session_id)
    {:noreply, socket}
  end

  # UI-64, UI-65, SESS-29: delete a chat from the sidebar — the open one or any
  # other, running or not. Deleting the open chat opens a fresh one (UI-1).
  def handle_event("delete_chat", %{"id" => id}, socket) do
    case Agent.delete(id) do
      :ok ->
        socket =
          socket
          |> assign(chats: Elia.Store.list(30))
          |> put_flash(:info, "Chat deleted.")

        if id == socket.assigns.session_id do
          {:noreply, push_navigate(socket, to: ~p"/")}
        else
          {:noreply, socket}
        end

      _error ->
        {:noreply, put_flash(socket, :error, "That chat can't be deleted.")}
    end
  end

  # UI-57, SESS-27: the user's decision on a turn paused at a limit.
  def handle_event("resume", _params, socket) do
    Agent.resume(socket.assigns.session_id)
    {:noreply, socket}
  end

  def handle_event("fail_task", _params, socket) do
    Agent.fail_task(socket.assigns.session_id)
    {:noreply, socket}
  end

  def handle_event("open_picker", _params, socket) do
    catalogs =
      for info <- LLM.providers(), LLM.api_key(info.key) != nil, into: %{} do
        case socket.assigns.catalogs[info.key] do
          {:ok, _} = loaded -> {info.key, loaded}
          _ -> {info.key, :loading}
        end
      end

    socket =
      Enum.reduce(catalogs, socket, fn
        {key, :loading}, socket -> start_async(socket, {:catalog, key}, fn -> LLM.models(key) end)
        _loaded, socket -> socket
      end)

    socket
    |> assign(
      picker_open: true,
      catalogs: catalogs,
      model_query: "",
      search_form: to_form(%{"q" => ""}, as: :model_search)
    )
    |> stream_models()
    |> noreply()
  end

  def handle_event("close_picker", _params, socket) do
    {:noreply, assign(socket, picker_open: false)}
  end

  def handle_event("search_models", %{"model_search" => %{"q" => query}}, socket) do
    socket
    |> assign(model_query: query, search_form: to_form(%{"q" => query}, as: :model_search))
    |> stream_models()
    |> noreply()
  end

  def handle_event("select_model", %{"provider" => key, "model" => model} = params, socket) do
    case Agent.select_model(socket.assigns.session_id, key, model, params["name"]) do
      {:ok, selection} ->
        socket
        |> assign(selection: selection, context_window: LLM.context_window(selection))
        |> assign(picker_open: false)
        |> noreply()

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_async({:catalog, key}, result, socket) do
    catalog =
      case result do
        {:ok, {:ok, models}} -> {:ok, models}
        {:ok, {:error, message}} -> {:error, message}
        {:exit, reason} -> {:error, "Could not load models: #{Exception.format_exit(reason)}"}
      end

    socket
    |> assign(
      catalogs: Map.put(socket.assigns.catalogs, key, catalog),
      context_window: LLM.context_window(socket.assigns.selection)
    )
    |> stream_models()
    |> noreply()
  end

  defp noreply(socket), do: {:noreply, socket}

  defp set_auto_approve(socket, tool, on?) do
    case Agent.set_auto_approve(socket.assigns.session_id, tool, on?) do
      :ok ->
        {:noreply, socket}

      {:error, :not_approvable} ->
        {:noreply, put_flash(socket, :error, "#{tool} never asks for approval.")}
    end
  end

  # Tools the user can auto-approve: those that can need approval (APPR-13).
  defp approvable_tools(skills) do
    skills
    |> Elia.Skills.tools()
    |> Enum.filter(&(&1.approval != :never))
    |> Enum.sort_by(& &1.name)
  end

  # Rebuilds the picker list: a header per provider, then its matching models.
  defp stream_models(%{assigns: %{picker_open: false}} = socket), do: socket

  defp stream_models(socket) do
    query = socket.assigns.model_query |> String.trim() |> String.downcase()

    entries =
      Enum.flat_map(LLM.providers(), fn info ->
        header = %{id: "g-#{info.key}", kind: :header, provider: info.key, name: info.name}

        case socket.assigns.catalogs[info.key] do
          nil ->
            [Map.merge(header, %{status: :no_key, count: nil})]

          {:ok, models} ->
            matches = Enum.filter(models, &model_matches?(&1, query))
            status = if matches == [], do: :empty, else: :ok

            count =
              if query == "", do: length(models), else: "#{length(matches)}/#{length(models)}"

            [Map.merge(header, %{status: status, count: count})] ++
              Enum.map(matches, &model_entry_data(info.key, &1))

          other ->
            [Map.merge(header, %{status: other, count: nil})]
        end
      end)

    stream(socket, :models, entries, reset: true)
  end

  defp model_matches?(_model, ""), do: true

  defp model_matches?(model, query) do
    String.contains?(String.downcase(model.name), query) or
      String.contains?(String.downcase(model.id), query)
  end

  defp model_entry_data(key, model) do
    "models-" <> id = model_dom_id(key, model.id)

    %{
      id: id,
      kind: :model,
      provider: key,
      model: model.id,
      name: model.name,
      context_length: model[:context_length],
      prompt_price: model[:prompt_price],
      completion_price: model[:completion_price]
    }
  end

  @impl true
  # PROJ-24: the popover and context follow the chat's project, so a reload
  # re-resolves that project's skills (the broadcast carries Elia's own).
  def handle_info({:skills_reloaded, skills}, socket) do
    {skills, instructions} = project_skills(socket.assigns.project, skills)

    socket
    |> assign(skills: skills, approvable_tools: approvable_tools(skills))
    |> put_context(Context.put_skills(socket.assigns.context, skills, instructions))
    |> noreply()
  end

  def handle_info({:agent, _id, event}, socket), do: {:noreply, apply_event(event, socket)}

  # UI-47, UI-58, UI-59: follows every chat's status, to flag those awaiting
  # approval, those paused at a limit, and those working.
  def handle_info({:chat_status, id, status}, socket) do
    awaiting = put_member(socket.assigns.awaiting, id, status == :awaiting_approval)
    paused = put_member(socket.assigns.paused, id, status == :paused)
    running = put_member(socket.assigns.running, id, status == :running)

    if awaiting == socket.assigns.awaiting and paused == socket.assigns.paused and
         running == socket.assigns.running do
      {:noreply, socket}
    else
      socket = assign(socket, awaiting: awaiting, paused: paused, running: running)

      # UI-44, UI-58: the card of the task chat that is waiting.
      call_ids = for {call_id, %{child_id: ^id}} <- socket.assigns.tasks, do: call_id
      {:noreply, Enum.reduce(call_ids, socket, &refresh_task_card(&2, &1))}
    end
  end

  # Keeps the sidebar's relative times current (UI-34).
  def handle_info(:tick_now, socket) do
    Process.send_after(self(), :tick_now, 60_000)
    {:noreply, assign(socket, now: DateTime.utc_now())}
  end

  # UI-62: while a turn runs, refresh the compact view's "working on" summary
  # about once a second, so it lags the step by no more than a second. The timer
  # reschedules itself only while the turn runs, so an idle chat is left alone.
  def handle_info(:tick_work_summary, socket) do
    if socket.assigns.status == :running do
      Process.send_after(self(), :tick_work_summary, 1_000)
      {:noreply, refresh_work_summary(socket)}
    else
      {:noreply, assign(socket, work_ticking: false)}
    end
  end

  # PROJ-24: a skills reload carries Elia's own skills; a chat in another project
  # re-resolves that project's skills instead.
  defp project_skills(%{harness?: true} = project, broadcast_skills),
    do: {broadcast_skills, Elia.Skills.project_instructions(project.folder)}

  defp project_skills(project, _broadcast_skills) do
    {skills, _errors} = Elia.Skills.for_project(project)
    {skills, Elia.Skills.project_instructions(project.folder)}
  end

  # The estimate is folded in per change, never rebuilt on render (CTX-8).
  defp put_context(socket, context) do
    assign(socket, context: context, context_breakdown: Context.breakdown(context))
  end

  # COMPACT-2, COMPACT-26: the request view and the estimate over it. The loop
  # and this page derive the view with the same function, so the transcript's
  # annotations and the estimate can never disagree with what the model was sent.
  # `usage` calibrates the total (CTX-10); nil clears the adjustment.
  defp derive_view(socket, messages, compaction, usage \\ nil) do
    %{project: project, skills: skills} = socket.assigns
    view = Compaction.view(messages, compaction)

    context =
      Context.new(view.messages, skills, Elia.Skills.project_instructions(project.folder))
      |> Context.calibrate(usage)

    socket
    |> assign(
      messages: messages,
      compaction: compaction,
      view: view,
      context_elided: view.elided
    )
    |> put_context(context)
  end

  # UI-60, UI-61: rebuilding the stream is what changes which items render, since
  # a stream only diffs inserts (docs/agents/phoenix-liveview.md). So switching
  # views reloads the transcript, which then omits (or restores) the tool calls
  # and reasoning.
  defp set_compact_view(socket, on) do
    if on == socket.assigns.compact_view do
      socket
    else
      socket
      |> assign(compact_view: on)
      |> load_messages(socket.assigns.messages)
    end
  end

  # UI-6, UI-63: the sidebar's list and this chat's page title, re-read from the
  # store.
  defp refresh_listed(socket) do
    assign(socket,
      chats: Elia.Store.list(30),
      page_title: Elia.Store.title(Elia.Store.load(socket.assigns.session_id))
    )
  end

  defp apply_event({:message, %Message{} = message}, socket) do
    socket =
      if message.role == :assistant,
        do: assign(socket, draft: "", draft_reasoning: ""),
        else: socket

    messages = socket.assigns.messages ++ [message]
    index = length(messages) - 1
    status = Compaction.status(message, index, socket.assigns.compaction)

    socket
    |> assign(messages: messages)
    |> fold_message(message, status)
    |> insert_message(message, index, status)
  end

  defp apply_event({:model, selection}, socket) do
    socket
    |> assign(selection: selection, context_window: LLM.context_window(selection))
    |> stream_models()
  end

  defp apply_event({:auto_approve, names}, socket), do: assign(socket, auto_approve: names)

  # UI-67, SESS-30: every tab on the chat follows the jail setting.
  defp apply_event({:jail, on?}, socket), do: assign(socket, jail: on?)

  # UI-70, ISOL-23: the worktree's dependency sync, on while it is in flight and
  # gone when it ends, whether that was a success or a failure.
  defp apply_event({:deps_sync, on?}, socket), do: assign(socket, deps_sync: on?)

  # UI-44, UI-49: the card's status and link follow the child.
  defp apply_event({:subtask, call_id, child_id, status}, socket) do
    tasks = Map.put(socket.assigns.tasks, call_id, %{child_id: child_id, status: status})

    socket
    |> assign(tasks: tasks, chats: Elia.Store.list(30))
    |> refresh_task_card(call_id)
  end

  # UI-48, UI-49: this chat's own task metadata changed.
  defp apply_event({:task, task}, socket) do
    assign(socket,
      task: task,
      task_status: task_status(socket.assigns.session_id, task),
      chats: Elia.Store.list(30)
    )
  end

  defp apply_event({:usage, usage}, socket) do
    socket
    |> assign(last_usage: usage)
    |> put_context(Context.calibrate(socket.assigns.context, usage))
  end

  # COMPACT-25: the request view changed, so the transcript's annotations, the
  # summary notice and the estimate over the view are derived again. COMPACT-27:
  # the CTX-10 adjustment (which calibrated the old view) is dropped with it.
  defp apply_event({:compaction, compaction}, socket) do
    socket
    |> derive_view(socket.assigns.messages, Compaction.from_map(compaction))
    |> load_messages(socket.assigns.messages)
  end

  defp apply_event({:delta, :text, text}, socket) do
    # Progress notes before a text block are superseded by the answer.
    assign(socket, draft: socket.assigns.draft <> text, activity: :writing)
  end

  defp apply_event({:delta, :reasoning, text}, socket) do
    assign(socket, draft_reasoning: socket.assigns.draft_reasoning <> text, activity: :thinking)
  end

  defp apply_event({:status, status}, socket) do
    previous = socket.assigns.status
    socket = assign(socket, status: status)
    # UI-57: the banner follows the status; the message arrives with {:paused, …}.
    socket = if status == :paused, do: socket, else: assign(socket, pause: nil)

    # UI-6, UI-63: a turn's start and end both refresh the sidebar and the page
    # title, so a chat that was just started shows its first message as its
    # title without waiting for the turn to end.
    socket = if status in [:running, :idle], do: refresh_listed(socket), else: socket

    socket = if status == :idle, do: assign(socket, draft: "", draft_reasoning: ""), else: socket

    # UI-62: a fresh turn starts from no step; every other status change keeps
    # the step and recomputes the compact view's summary from it.
    socket =
      if status == :running and previous in [:idle, :paused],
        do: assign(socket, activity: nil),
        else: socket

    socket
    |> assign(work_summary: work_summary_for(status, socket))
    |> start_work_ticker()
  end

  # UI-57, SESS-27: the turn paused at a limit.
  defp apply_event({:paused, message}, socket), do: assign(socket, pause: message)

  defp apply_event({:tool_status, call_id, status}, socket) do
    socket =
      socket
      |> assign(tool_status: Map.put(socket.assigns.tool_status, call_id, status))
      |> track_activity(call_id, status)

    case socket.assigns.calls do
      %{^call_id => call} -> put_call(socket, %{call | status: status})
      _ -> socket
    end
  end

  defp apply_event({kind, text}, socket) when kind in [:notice, :error] do
    item = %{id: "#{kind}-#{System.unique_integer([:positive])}", kind: kind, text: text}
    stream_insert(socket, :items, item)
  end

  defp apply_event({:reset, messages}, socket) do
    socket
    |> assign(last_usage: nil)
    |> derive_view(messages, socket.assigns.compaction)
    |> load_messages(messages)
  end

  # A message that arrives while the chat is compacted may itself be cut (a huge
  # user message, COMPACT-11), in which case the estimate is rebuilt from the
  # view; otherwise it is folded in, as before (CTX-8).
  defp fold_message(socket, message, %{status: :sent}) do
    put_context(socket, Context.add(socket.assigns.context, message))
  end

  defp fold_message(socket, _message, _status) do
    derive_view(socket, socket.assigns.messages, socket.assigns.compaction)
  end

  ## Task cards (UI-43 to UI-48)

  # The task chats this chat started, by the `spawn_task` call that started each.
  defp task_children(id) do
    for %{parent_call_id: call_id} = child <- Elia.Store.children(id),
        is_binary(call_id),
        into: %{},
        do: {call_id, %{child_id: child.id, status: child.task_status}}
  end

  defp task_card(socket, call_id) do
    case socket.assigns.tasks do
      %{^call_id => %{child_id: child_id, status: status}} ->
        %{
          child_id: child_id,
          status: status,
          awaiting: child_id in socket.assigns.awaiting,
          # UI-58: the child is paused at a limit (SESS-27).
          paused: child_id in socket.assigns.paused
        }

      _ ->
        nil
    end
  end

  defp put_member(list, id, true), do: if(id in list, do: list, else: [id | list])
  defp put_member(list, id, false), do: List.delete(list, id)

  defp refresh_task_card(socket, call_id) do
    case socket.assigns.calls do
      %{^call_id => call} -> put_call(socket, %{call | task: task_card(socket, call_id)})
      _ -> socket
    end
  end

  # A task saved as running without a live turn lost its session (STORE-17).
  defp task_status(_id, nil), do: nil

  defp task_status(id, %{status: "running"}),
    do: if(Elia.Tasks.running?(id), do: "running", else: "interrupted")

  defp task_status(_id, %{status: status}), do: status

  defp parent_title(%{parent_id: parent_id}),
    do: parent_id |> Elia.Store.load() |> Elia.Store.title()

  defp parent_title(_task), do: nil

  # UI-45: task chats nested under their parent; orphans stay at the top level.
  defp chat_tree(chats) do
    ids = MapSet.new(chats, & &1.id)
    {nested, top} = Enum.split_with(chats, &(Map.get(&1, :parent_id) in ids))
    by_parent = nested |> Enum.reverse() |> Enum.group_by(& &1.parent_id)
    Enum.map(top, &{&1, Map.get(by_parent, &1.id, [])})
  end

  # PROJ-24: the listed chats grouped by project, each project with its nested
  # tree of chats. A chat without a project id belongs to Elia's own project
  # (PROJ-9); projects without chats still get an entry (an empty tree).
  defp project_groups(projects, chats) do
    by_project = Enum.group_by(chats, &(&1.project_id || "harness"))

    Enum.map(projects, fn project ->
      %{project: project, tree: chat_tree(Map.get(by_project, project.id, []))}
    end)
  end

  ## Transcript items

  # UI-62: the current step of the turn — the tool that is running, a reply being
  # written, or the model thinking — kept as the turn's events arrive, so the
  # compact view's summary can name it.
  defp track_activity(socket, call_id, status) when status in [:running, :awaiting_approval] do
    case socket.assigns.calls do
      %{^call_id => call} ->
        kind = if status == :awaiting_approval, do: :awaiting, else: :tool
        assign(socket, activity: {kind, call})

      _ ->
        socket
    end
  end

  defp track_activity(socket, _call_id, _status), do: socket

  defp current_activity(socket), do: socket.assigns.activity || running_call(socket)

  # A fallback for a page that connects mid-turn (SESS-7): the call that is
  # running or already waiting for approval names the step.
  defp running_call(socket) do
    Enum.find_value(socket.assigns.calls, fn
      {_id, %{status: :awaiting_approval} = call} -> {:awaiting, call}
      {_id, %{status: :running} = call} -> {:tool, call}
      _ -> nil
    end)
  end

  defp refresh_work_summary(socket),
    do: assign(socket, work_summary: work_summary_for(socket.assigns.status, socket))

  # UI-62: starts the one-second summary timer, once, whenever a turn is running.
  # It stops itself (and clears the flag) as soon as the turn is no longer
  # running, so nothing ticks for an idle chat.
  defp start_work_ticker(socket) do
    cond do
      socket.assigns.status != :running ->
        socket

      socket.assigns.work_ticking ->
        socket

      true ->
        Process.send_after(self(), :tick_work_summary, 1_000)
        assign(socket, work_ticking: true)
    end
  end

  defp work_summary_for(status, socket) when status in [:running, :awaiting_approval],
    do: work_summary(current_activity(socket))

  defp work_summary_for(_status, _socket), do: nil

  # UI-62: one sentence naming the current step.
  defp work_summary(nil), do: "Working."
  defp work_summary(:thinking), do: "Thinking."
  defp work_summary(:writing), do: "Writing a reply."

  defp work_summary({:tool, call}) do
    {ing, _verb, object} = step(call)
    "#{ing} #{object}."
  end

  defp work_summary({:awaiting, call}) do
    {_ing, verb, object} = step(call)
    "Waiting for your approval to #{verb} #{object}."
  end

  defp step(%{name: "shell", input: %{"command" => command}}),
    do: {"Running", "run", "`#{short(command)}`"}

  defp step(%{name: "read_file", input: %{"path" => path}}),
    do: {"Reading", "read", short(path)}

  defp step(%{name: "write_file", input: %{"path" => path}}),
    do: {"Writing", "write", short(path)}

  defp step(%{name: "edit_file", input: %{"path" => path}}),
    do: {"Editing", "edit", short(path)}

  defp step(%{name: "spawn_task", input: %{"title" => title}}) when is_binary(title),
    do: {"Starting", "start", "the sub-task “#{short(title)}”"}

  defp step(%{name: name}), do: {"Using", "use", name}

  defp short(text, max \\ 60) do
    text = text |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  @sent %{status: :sent, blocks: %{}, elided: 0, pinned: false}

  defp load_messages(socket, messages) do
    view = Compaction.view(messages, socket.assigns.compaction)
    count = length(messages)

    socket =
      socket
      |> assign(calls: %{}, view: view, context_elided: view.elided)
      |> stream(:items, [], reset: true)

    socket =
      messages
      |> Enum.with_index()
      |> Enum.reduce(socket, fn {message, index}, socket ->
        socket
        |> maybe_summary_notice(index, count)
        |> insert_message(message, index, Map.get(view.statuses, index, @sent))
      end)

    # A summary covering every message of the chat has no message to sit before.
    maybe_summary_notice(socket, count, count)
  end

  # COMPACT-19, COMPACT-25: the summary renders as a notice at the boundary of
  # the region it covers, so the user sees the compression in place.
  defp maybe_summary_notice(socket, index, count) do
    with %Compaction{summary: summary, folded: folded} <- socket.assigns.compaction,
         true <- is_binary(summary) and String.trim(summary) != "",
         true <- index == folded or (index == count and folded >= count) do
      stream_insert(socket, :items, %{
        id: "compaction-summary",
        kind: :summary,
        text: summary
      })
    else
      _ -> socket
    end
  end

  defp insert_message(
         socket,
         %Message{role: :user, meta: %{harness: true}} = message,
         index,
         status
       ) do
    stream_item(
      socket,
      %{id: "m#{index}", kind: :notice, text: Message.text_content(message), index: index},
      status
    )
  end

  defp insert_message(socket, %Message{role: :user} = message, index, status) do
    stream_item(
      socket,
      %{id: "m#{index}", kind: :user, text: Message.text_content(message), index: index},
      status
    )
  end

  defp insert_message(socket, %Message{role: :tool, content: results}, _index, status) do
    Enum.reduce(results, socket, fn result, socket ->
      case socket.assigns.calls do
        %{} = calls when is_map_key(calls, result.tool_call_id) ->
          call = calls[result.tool_call_id]

          # COMPACT-25: an elided result is the card's own "not sent" note.
          call =
            if status.status == :sent do
              call
            else
              %{
                call
                | request_status: status.status,
                  block_status: Map.get(status.blocks, 0),
                  elided: status.elided
              }
            end

          put_call(socket, %{
            call
            | output: result.content,
              is_error: result.is_error,
              status: :done
          })

        _ ->
          socket
      end
    end)
  end

  defp insert_message(socket, %Message{role: :assistant, content: content}, index, status) do
    content
    |> Enum.with_index()
    |> Enum.reduce(socket, fn
      {%{type: :text, text: text}, i}, socket when text != "" ->
        stream_item(
          socket,
          %{id: "m#{index}-#{i}", kind: :assistant, text: text, index: index, block: i},
          status,
          i
        )

      {%{type: :reasoning, text: text}, i}, socket when text != "" ->
        stream_item(
          socket,
          %{id: "m#{index}-#{i}", kind: :reasoning, text: text, index: index, block: i},
          status,
          i
        )

      {%{type: :tool_call} = call, i}, socket ->
        item =
          annotate(
            %{
              id: "call-#{call.id}",
              kind: :tool,
              call_id: call.id,
              name: call.name,
              input: call.input,
              index: index,
              task: task_card(socket, call.id),
              status: Map.get(socket.assigns.tool_status, call.id, :pending),
              output: nil,
              is_error: false
            },
            status,
            i
          )

        put_call(socket, item)

      _other, socket ->
        socket
    end)
  end

  defp stream_item(socket, item, status, block \\ nil) do
    if visible?(socket.assigns.compact_view, item.kind) do
      stream_insert(socket, :items, annotate(item, status, block))
    else
      socket
    end
  end

  # UI-61: the compact view keeps the direct messages and hides tool calls and
  # reasoning, both when the transcript loads and as items arrive.
  defp visible?(_compact, kind) when kind not in [:tool, :reasoning], do: true
  defp visible?(compact, _kind), do: not compact

  # COMPACT-25: every item carries its request-view status, so the UI never
  # implies the model saw something it did not.
  defp annotate(item, status, block) do
    block = block || Map.get(item, :block)

    Map.merge(item, %{
      request_status: status[:status] || :sent,
      block_status: Map.get(status[:blocks] || %{}, block),
      elided: status[:elided] || 0,
      pinned: Map.get(status, :pinned, false)
    })
  end

  defp put_call(socket, call) do
    socket = assign(socket, calls: Map.put(socket.assigns.calls, call.call_id, call))
    # UI-61: the card is still tracked in `calls`, but a compact view doesn't
    # render it.
    if visible?(socket.assigns.compact_view, call.kind),
      do: stream_insert(socket, :items, call),
      else: socket
  end
end
