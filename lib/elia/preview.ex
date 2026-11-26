defmodule Elia.Preview do
  @moduledoc """
  What a UI preview names, seeds and serves (`specs/ui-preview.md`).

  A preview boots the chat's own code as the test env app and screenshots pages
  with the browser layer's Playwright (PREVIEW-1 - PREVIEW-6); that half lives
  in the test layer, where the Playwright dependency is (BROWSER-1). What is
  here is what the running app shares with it: the file names a preview writes
  (PREVIEW-4), the sample chats it seeds so the pages have something to render
  (PREVIEW-10 - PREVIEW-12, PREVIEW-15), and the lookup the route serving those
  images does (PREVIEW-7) — no browser involved.
  """

  alias Elia.LLM.Message
  alias Elia.{Agent, Explorer, Store, Terminal, Workspace}

  # PREVIEW-4: a preview's own dir, gitignored so it never reaches a commit or
  # a deploy.
  @dir "tmp/preview"

  # PREVIEW-11: a fixed id keeps the sample chat's page and file name stable
  # from one run to the next.
  @sample_id "preview"

  # PREVIEW-10: the sample chat is a named chat (TITLE-1), so its row and page
  # title show a title of its own, and its transcript shows the `set_title` call
  # that named it (TITLE-5).
  @sample_title "Sample chat"

  # PREVIEW-15: the second sample chat, whose turn is paused on a question. Its
  # id is fixed for the same reason as the first one's, and the question and its
  # options are the fixed sample input, so the picture of the card is the same
  # from one run to the next.
  @question_id "preview-question"
  @question_prompt "Set up this project for me."
  @question %{
    "question" => "How should the shell tool run commands in this project?",
    "options" => ["In the jail", "Unjailed", "Ask me each time"]
  }

  @extensions ~w(.png .jpg .jpeg .webp)

  # UPLOAD-6, UPLOAD-12: where a chat's uploaded files land — its own
  # workspace's `uploads/`, which is what the chips name. The sample chat seeds
  # no such file, so its picture shows the paths a message with attachments
  # carries rather than working links to them.
  @sample_uploads ["uploads/transcript.png", "uploads/report.pdf"]

  # VISION-16: the picture the sample chat's look read, and a file of the tree
  # the preview runs in (PREVIEW-2), so the card shows the picture itself rather
  # than a path that leads nowhere.
  @sample_picture "priv/static/images/icon-512.png"
  @sample_picture_bytes 3571

  # PREVIEW-16: the chats seeded beyond the chat list's first page (UI-4), with
  # a fixed id each for the same reason as the sample chat's.
  @page_count 30
  @page_id "preview-chat"

  # PREVIEW-18: the sample chat whose sub-tasks a picture shows behind the
  # dropdown the list draws (UI-112, UI-113), and the two chats that name it as
  # their parent (STORE-16, STORE-17). Fixed ids, as the sample chat's is
  # (PREVIEW-11).
  @subtasks_id "preview-parent"
  @subtasks_title "Plan the release"
  @subtasks [{"preview-task-1", "Write the notes"}, {"preview-task-2", "Check the links"}]

  # PREVIEW-17: the sample chat whose terminal is running, so a picture shows
  # the mark a chat with one carries (UI-111, TERM-41). A fixed id for the same
  # reason as the sample chat's, and a command that outlives the preview.
  @terminal_id "preview-terminal"
  @terminal_title "Terminal chat"
  @terminal_command "sleep 900"

  @doc "The dir a workspace's previews are written to, under `root` (PREVIEW-4)."
  @spec dir(binary()) :: binary()
  def dir(root \\ Workspace.root()), do: Path.join(root, @dir)

  @doc "The file a path's screenshot gets: `<n>-<slug>.<ext>` (PREVIEW-4)."
  @spec file_name(non_neg_integer(), binary()) :: binary()
  def file_name(index, path), do: "#{index}-#{slug(path)}.png"

  # PREVIEW-4: the slug is the path with anything that isn't a letter or digit
  # turned into `-`, so `/` is `root` and the name is stable across runs.
  defp slug(path) do
    case path |> String.replace(~r/[^A-Za-z0-9]+/, "-") |> String.trim("-") do
      "" -> "root"
      slug -> slug |> String.downcase() |> String.slice(0, 40)
    end
  end

  @doc "The sample chat's id (PREVIEW-11)."
  @spec sample_id() :: binary()
  def sample_id, do: @sample_id

  @doc "The sample chat's path in the app (PREVIEW-11)."
  @spec sample_path() :: binary()
  def sample_path, do: "/c/" <> @sample_id

  @doc "The paused-question chat's id (PREVIEW-15)."
  @spec question_id() :: binary()
  def question_id, do: @question_id

  @doc "The paused-question chat's path in the app (PREVIEW-15)."
  @spec question_path() :: binary()
  def question_path, do: "/c/" <> @question_id

  @doc """
  The question the paused turn is waiting on (PREVIEW-15): the `ask_user` input
  — a question and a few short options — the picture of the card shows.
  """
  @spec question_input() :: map()
  def question_input, do: @question

  @doc "The message the paused-question chat's turn is started with (PREVIEW-15)."
  @spec question_prompt() :: binary()
  def question_prompt, do: @question_prompt

  @doc """
  Starts the paused-question chat's turn (PREVIEW-15): the chat is started
  through the app's own agent (`Elia.Agent`) and sent `question_prompt/0`, so
  the page renders the wait itself rather than a stubbed template. The model's
  answer is the scripted provider the browser layer runs (BROWSER-3), which must
  already hold an `ask_user` call carrying `question_input/0`; the caller then
  waits for the chat to be awaiting an answer (`Elia.Agent.awaiting_input/0`)
  before it visits the page.
  """
  @spec start_question() :: :ok
  def start_question do
    {:ok, _pid} = Agent.ensure_started(@question_id)
    :ok = Agent.send_message(@question_id, @question_prompt)
  end

  @doc "The chat with sub-tasks' id (PREVIEW-18)."
  @spec subtasks_id() :: binary()
  def subtasks_id, do: @subtasks_id

  @doc "The chat with sub-tasks' path in the app (PREVIEW-18)."
  @spec subtasks_path() :: binary()
  def subtasks_path, do: "/c/" <> @subtasks_id

  @doc "The chat with a terminal running's id (PREVIEW-17)."
  @spec terminal_id() :: binary()
  def terminal_id, do: @terminal_id

  @doc "The chat with a terminal running's path in the app (PREVIEW-17)."
  @spec terminal_path() :: binary()
  def terminal_path, do: "/c/" <> @terminal_id

  @doc """
  Saves the sample chat whose terminal is running and starts that terminal
  (PREVIEW-17): a real session through the app's own terminal (TERM-1) in the
  workspace the preview runs in, so what a picture shows on its row is what the
  app shows (UI-111, TERM-41) rather than something stubbed. It is saved after
  the sample chat (PREVIEW-10), so it is the newest chat and the dashboard's
  "Continue" card holds it (DASH-3) as well as "Recent chats" (DASH-7). Where no
  terminal can run — a machine without tmux (TERM-29) — the chat is saved
  without one, and the mark is simply absent from the picture.
  """
  @spec start_terminal() :: :ok
  def start_terminal do
    :ok =
      Store.save(@terminal_id, [Message.user("Run the suite in a terminal.")],
        title: @terminal_title
      )

    # Unjailed: a picture needs a command that runs, and a machine without the
    # jail's own tools (ISOL-1) would otherwise show no mark at all.
    case Terminal.start(@terminal_id, command: @terminal_command, jail: false) do
      {:ok, _pid} -> :ok
      {:error, _message} -> :ok
    end
  end

  @doc """
  What a preview's argument means as a path: `@chat` is the sample chat, `@ask`
  the paused-question chat, `@terminal` the chat with a terminal running and
  `@subtasks` the chat with sub-tasks (PREVIEW-11, PREVIEW-15, PREVIEW-17,
  PREVIEW-18).
  """
  @spec resolve_path(binary()) :: binary()
  def resolve_path("@chat"), do: sample_path()
  def resolve_path("@ask"), do: question_path()
  def resolve_path("@terminal"), do: terminal_path()
  def resolve_path("@subtasks"), do: subtasks_path()
  def resolve_path(path), do: path

  @doc """
  The colour scheme a preview emulates (PREVIEW-13): `:dark` or `:light` when
  `ELIA_PREVIEW_THEME` names one, else `nil` for the browser's own default. The
  scheme reaches the app as `prefers-color-scheme`, which its theme script
  follows when no theme is stored, so `:dark` renders the dark theme (CONF-17).
  """
  @spec theme(binary() | nil) :: :dark | :light | nil
  def theme("dark"), do: :dark
  def theme("light"), do: :light
  def theme(_), do: nil

  @doc """
  The URL the chat shows `file` at (PREVIEW-5, PREVIEW-7). The running app
  serves it from the `tmp/preview/` the preview wrote it to.
  """
  @spec url(binary(), binary()) :: binary()
  def url(chat_id, file), do: "/preview/#{chat_id}/#{file}"

  @doc """
  The file `file` names in the `tmp/preview/` a preview ran in, if it is there
  and may be served (PREVIEW-7): `{:ok, absolute path}`, or `:not_found` for
  anything else — an unknown chat, a file name that isn't a single segment with
  an image extension, a path that leads out of `tmp/preview/` or through a
  symlink (EXPL-1, EXPL-2), or a file that isn't a regular file. There is
  nothing here to enumerate and nothing else to reach.

  `root` is the chat's project's folder, which for a chat in Elia's own project
  is the live tree. A chat that made itself a worktree inside that folder
  (DEPLOY-28) wrote its pictures in the worktree's own `tmp/preview/`, so that
  one is served first; the folder's own is served when the chat made none or
  the file isn't there.
  """
  @spec path(binary(), binary(), binary()) :: {:ok, binary()} | {:error, :not_found}
  def path(chat_id, file, root \\ Workspace.runtime_root()) do
    with :ok <- check_id(chat_id),
         :ok <- check_file(file),
         {:ok, abs} <- served(served_roots(chat_id, root), file) do
      {:ok, abs}
    else
      _ -> {:error, :not_found}
    end
  end

  # PREVIEW-7: the first of `trees` that serves `file` — a regular file at the
  # path that tree's `tmp/preview/` gives it, which EXPL-1 and EXPL-2 allow —
  # or `{:error, :not_found}` when none of them does.
  defp served(trees, file) do
    Enum.find_value(trees, {:error, :not_found}, &served_file(&1, file))
  end

  defp served_file(tree, file) do
    with {:ok, path} <- Explorer.safe_path(Path.join(@dir, file), tree),
         {:ok, %File.Stat{type: :regular}} <- File.stat(path) do
      {:ok, path}
    else
      _ -> nil
    end
  end

  # PREVIEW-7: the trees whose `tmp/preview/` a chat's pictures go in, in the
  # order they are looked for — the worktree the chat made for itself under its
  # project's folder first, then the folder's own.
  defp served_roots(chat_id, root), do: [Path.join([root, "tmp", "worktrees", chat_id]), root]

  defp check_id(chat_id) do
    if Store.valid_id?(chat_id), do: :ok, else: {:error, :not_found}
  end

  defp check_file(file) do
    cond do
      not is_binary(file) -> {:error, :not_found}
      Path.basename(file) != file -> {:error, :not_found}
      String.downcase(Path.extname(file)) not in @extensions -> {:error, :not_found}
      true -> :ok
    end
  end

  @doc """
  Saves the sample chats into the app's own data, so the pages a preview takes a
  picture of have something to render (PREVIEW-10, PREVIEW-16). Their workspace
  is the one the preview runs in (PREVIEW-2), so no other data is touched.
  """
  @spec seed() :: :ok | {:error, term()}
  def seed do
    with :ok <- seed_page(),
         :ok <- seed_subtasks() do
      Store.save(@sample_id, sample_messages(), title: @sample_title)
    end
  end

  # PREVIEW-18: a chat with two sub-tasks of its own (STORE-16, STORE-17), saved
  # after the chats of PREVIEW-16 and before the sample chat, so a picture of its
  # page has the dropdown they sit behind (UI-112) and its count (UI-113) near the
  # top of the list while the sample chat stays its newest (PREVIEW-16).
  defp seed_subtasks do
    with :ok <- seed_tasks(@subtasks) do
      Store.save(@subtasks_id, [Message.user("Plan the release.")], title: @subtasks_title)
    end
  end

  defp seed_tasks(tasks) do
    Enum.reduce_while(tasks, :ok, fn {id, title}, :ok ->
      case seed_subtask(id, title) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp seed_subtask(id, title) do
    Store.save(id, [Message.user("A sub-task of the sample chat.")],
      title: title,
      task: %{parent_id: @subtasks_id, started_at: DateTime.utc_now()}
    )
  end

  # PREVIEW-16: more chats than the chat list's first page holds (UI-4), so what
  # the list does with them — the "Load more chats" button (UI-84) and the page
  # it loads — is in a picture. They are saved before the sample chat, so the
  # chat a picture is of is still the newest one, at the top of the list its
  # page opens (STORE-12).
  defp seed_page do
    Enum.reduce_while(1..@page_count, :ok, fn n, :ok ->
      case Store.save("#{@page_id}-#{n}", [Message.user("Sample chat #{n}")]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # SNAP-6, SNAP-10: the pair a sample `shell` call's result carries — the two
  # snapshot refs, the files that differ between them and their diff, as a real
  # call's pair holds them. A preview takes no snapshot of the workspace it runs
  # in, so the sample writes the shapes a card renders.
  defp sample_snapshot do
    %{
      root: ".",
      from: "refs/elia/snapshots/1731000000000-1a2b3c4d5e6f",
      to: "refs/elia/snapshots/1731000003600-9f8e7d6c5b4a",
      files: [
        %{status: "modified", path: "lib/elia/skills/shell.ex"},
        %{status: "added", path: "test/elia/snapshot_test.exs"}
      ],
      diff: """
      diff --git a/lib/elia/skills/shell.ex b/lib/elia/skills/shell.ex
      index 1a2b3c4..9f8e7d6 100644
      --- a/lib/elia/skills/shell.ex
      +++ b/lib/elia/skills/shell.ex
      @@ -208,7 +208,7 @@
         config :elia, Elia.Skills.Shell,
           default_timeout: 300,
      -  max_timeout: 1_800,
      +  max_timeout: 3_600,
           max_output: 30_000

      diff --git a/test/elia/snapshot_test.exs b/test/elia/snapshot_test.exs
      new file mode 100644
      index 0000000..3c4d5e6
      --- /dev/null
      +++ b/test/elia/snapshot_test.exs
      @@ -0,0 +1,2 @@
      +defmodule Elia.SnapshotTest do
      +end
      """
    }
  end

  @doc """
  The sample chat's messages (PREVIEW-10): a user message, an assistant reply
  with the Markdown a transcript renders (UI-25) and a requirement it cites
  (CITE-1), a reasoning block (UI-29), the
  `set_title` call that named the chat (TITLE-5, UI-74), a `cd` call whose path
  its card links (FLINK-4), a `shell` call with its output and the files its
  snapshots say it changed (SNAP-10) and a failed one (UI-15, UI-16, UI-20), and
  a last user message carrying uploaded files (UPLOAD-12).
  """
  @spec sample_messages() :: [Message.t()]
  def sample_messages do
    [
      %{
        Message.user("What does a chat look like once it has done some work?")
        | meta: %{at: minutes_ago(12)}
      },
      %Message{
        role: :assistant,
        meta: %{at: minutes_ago(11)},
        content: [
          %{
            type: :reasoning,
            text:
              "A sample transcript, seeded by `bin/preview`. It should show the " <>
                "pieces a chat renders: a reply with Markdown, a tool call with " <>
                "its output, and one that failed."
          },
          Message.text(markdown()),
          %{
            type: :tool_call,
            id: "call-preview-3",
            name: "set_title",
            input: %{"title" => @sample_title}
          },
          # FLINK-4: a `cd` call is one whose input has a `path`, so its card
          # links the directory the chat moved into.
          %{
            type: :tool_call,
            id: "call-preview-4",
            name: "cd",
            input: %{"path" => "lib"}
          },
          # VISION-12, VISION-16: a look at a picture is an ordinary tool call
          # whose card shows the picture it read.
          %{
            type: :tool_call,
            id: "call-preview-6",
            name: "view_image",
            input: %{"path" => @sample_picture}
          },
          %{
            type: :tool_call,
            id: "call-preview-1",
            name: "shell",
            input: %{"command" => "mix test"}
          },
          %{
            type: :tool_call,
            id: "call-preview-2",
            name: "shell",
            # UI-98: a command over more than one line, so a picture shows the
            # card a multi-line command gets — its first line and the whole
            # command one press away.
            input: %{"command" => "git add -A\ngit commit -m \"wip\"\ngit push"}
          },
          # UI-43: a `spawn_task` call is an ordinary tool call whose input is
          # mostly a brief, so its picture shows the brief under it and no
          # status of its own (the retired UI-44).
          %{
            type: :tool_call,
            id: "call-preview-5",
            name: "spawn_task",
            input: %{
              "title" => "Docs: the store's shapes",
              "brief" =>
                "Read `specs/persistence.md`, then write `docs/store-shapes.md`: " <>
                  "one section per saved key, with what reads it. Commit on your own " <>
                  "branch and say in your last message what you changed."
            }
          }
        ]
      },
      %Message{
        role: :tool,
        meta: %{at: minutes_ago(10)},
        content: [
          Message.tool_result("call-preview-3", "This chat is now titled \"#{@sample_title}\"."),
          Message.tool_result("call-preview-4", "Working directory: lib"),
          # VISION-12, VISION-16: the look records the path it read, which is
          # what its card renders the picture from; the sample writes that shape
          # rather than reading the file (PREVIEW-10).
          Message.tool_result(
            "call-preview-6",
            "Looked at #{@sample_picture} (image/png, " <>
              "#{Elia.SystemStats.format_bytes(@sample_picture_bytes)}); its picture is sent " <>
              "with this result.",
            false,
            %{
              image: %{
                path: @sample_picture,
                media_type: "image/png",
                size: @sample_picture_bytes
              }
            }
          ),
          # SNAP-6, SNAP-10: a `shell` call's result carries the pair of
          # snapshots bracketing it, so its card lists the files the call
          # changed and their diff. The pair is the sample's own: a preview
          # seeds the shapes a card renders, and takes no snapshot (PREVIEW-10).
          Message.tool_result("call-preview-1", "12 tests, 0 failures\n[exit: 0]", false, %{
            snapshot: sample_snapshot()
          }),
          Message.tool_result(
            "call-preview-2",
            "fatal: no upstream branch to push to\n[exit: 128]",
            true
          ),
          # SUBTASK-2: what a spawn returns at once — the child's id, its title
          # and the status its chat has, `working` (UI-59).
          Message.tool_result(
            "call-preview-5",
            ~s({"task_id":"preview-child","title":"Docs: the store's shapes","status":"working"})
          )
        ]
      },
      %Message{
        role: :assistant,
        meta: %{at: minutes_ago(9)},
        content: [
          Message.text("The suite passes. Nothing is pushed: there is no upstream branch yet.")
        ]
      },
      # UPLOAD-12: a message carrying uploaded files, so a picture shows the
      # chips under it — the name of each file it carries, and its timestamp
      # (MSGAT-9) like every other item's.
      Message.user("Have a look at what I mean — both files are attached.", @sample_uploads)
      |> Map.put(:meta, %{attachments: @sample_uploads, at: minutes_ago(8)})
    ]
  end

  # MSGAT-9: the sample chat carries stamps, so a picture of a chat shows the
  # times the transcript puts under each item.
  defp minutes_ago(minutes),
    do: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

  defp markdown do
    """
    Here is what the harness did, in the order it did it.

    ## What changed

    - a new `Elia.Preview` module, whose `Elia.Preview.file_name/2` names a
      picture's file, with the preview's path safety
    - a route that serves a preview's images, and only those

    | Piece | Where |
    | --- | --- |
    | naming | `Elia.Preview` |
    | serving | `EliaWeb.PreviewController` |

    ```elixir
    def file_name(index, path), do: "\#{index}-\#{slug(path)}.png"
    ```

    The workflow is written up in `AGENTS.md`, and the spec is
    [ui-preview.md](/files?path=specs%2Fui-preview.md). A preview is taken
    before a deploy (`PREVIEW-1`), and what it shows is the workspace's own
    code (PREVIEW-2).
    """
  end
end
