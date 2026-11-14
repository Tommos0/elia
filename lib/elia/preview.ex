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
  alias Elia.{Agent, Deploy, Explorer, Store, Workspace}

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

  # PREVIEW-16: the chats seeded beyond the chat list's first page (UI-4), with
  # a fixed id each for the same reason as the sample chat's.
  @page_count 30
  @page_id "preview-chat"

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

  @doc """
  What a preview's argument means as a path: `@chat` is the sample chat and
  `@ask` the paused-question chat (PREVIEW-11, PREVIEW-15).
  """
  @spec resolve_path(binary()) :: binary()
  def resolve_path("@chat"), do: sample_path()
  def resolve_path("@ask"), do: question_path()
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
  serves it from the chat's own worktree, whoever is looking.
  """
  @spec url(binary(), binary()) :: binary()
  def url(chat_id, file), do: "/preview/#{chat_id}/#{file}"

  @doc """
  The file `file` names in `chat_id`'s worktree, if it is there and may be
  served (PREVIEW-7): `{:ok, absolute path}`, or `:not_found` for anything else
  — an unknown chat, a file name that isn't a single segment with an image
  extension, a path that leads out of `tmp/preview/` or through a symlink
  (EXPL-1, EXPL-2), or a file that isn't a regular file. There is nothing here
  to enumerate and nothing else to reach.
  """
  @spec path(binary(), binary(), binary()) :: {:ok, binary()} | {:error, :not_found}
  def path(chat_id, file, root \\ Workspace.runtime_root()) do
    with :ok <- check_id(chat_id),
         :ok <- check_file(file),
         {:ok, abs} <-
           Explorer.safe_path(Path.join(@dir, file), Deploy.worktree_path(chat_id, root)),
         {:ok, %File.Stat{type: :regular}} <- File.stat(abs) do
      {:ok, abs}
    else
      _ -> {:error, :not_found}
    end
  end

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
  The chat whose worktree `root` is, or `nil` when it isn't one (PREVIEW-5).

  A preview runs *inside* the worktree, where the live tree isn't the configured
  root (a test run's config points at its own scratch workspace), so the chat
  comes from the path itself: the one `Elia.Deploy.worktrees_dir/1` puts a
  chat's worktree at, `<data dir>/worktrees/<chat id>` (DEPLOY-1).
  """
  @spec worktree_chat(binary()) :: binary() | nil
  def worktree_chat(root) do
    root = Path.expand(root)
    dir = Path.dirname(root)
    id = Path.basename(root)

    if Path.basename(dir) == Path.basename(Deploy.worktrees_dir()) and
         Path.basename(Path.dirname(dir)) == Path.basename(Workspace.data_dir()) and
         Store.valid_id?(id) do
      id
    end
  end

  @doc """
  Saves the sample chats into the app's own data, so the pages a preview takes a
  picture of have something to render (PREVIEW-10, PREVIEW-16). Their workspace
  is the one the preview runs in (PREVIEW-2), so no other data is touched.
  """
  @spec seed() :: :ok | {:error, term()}
  def seed do
    with :ok <- seed_page(), do: Store.save(@sample_id, sample_messages(), title: @sample_title)
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

  @doc """
  The sample chat's messages (PREVIEW-10): a user message, an assistant reply
  with the Markdown a transcript renders (UI-25), a reasoning block (UI-29), the
  `set_title` call that named the chat (TITLE-5, UI-74), a `read_file` call for a
  file of the workspace (FLINK-4), a `shell` call with its
  output and a failed one (UI-15, UI-16, UI-20).
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
          %{
            type: :tool_call,
            id: "call-preview-4",
            name: "read_file",
            input: %{"path" => "lib/elia/preview.ex"}
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
            input: %{"command" => "git push"}
          }
        ]
      },
      %Message{
        role: :tool,
        meta: %{at: minutes_ago(10)},
        content: [
          Message.tool_result("call-preview-3", "This chat is now titled \"#{@sample_title}\"."),
          Message.tool_result(
            "call-preview-4",
            "defmodule Elia.Preview do\n  # … and the file the card links (FLINK-4)\n"
          ),
          Message.tool_result("call-preview-1", "12 tests, 0 failures\n[exit: 0]"),
          Message.tool_result(
            "call-preview-2",
            "fatal: no upstream branch to push to\n[exit: 128]",
            true
          )
        ]
      },
      %Message{
        role: :assistant,
        meta: %{at: minutes_ago(9)},
        content: [
          Message.text("The suite passes. Nothing is pushed: there is no upstream branch yet.")
        ]
      }
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

    - a new `Elia.Preview` module with the preview's file names and path safety
    - a route that serves a preview's images, and only those

    | Piece | Where |
    | --- | --- |
    | naming | `Elia.Preview` |
    | serving | `EliaWeb.PreviewController` |

    ```elixir
    def file_name(index, path), do: "\#{index}-\#{slug(path)}.png"
    ```

    The workflow is written up in `AGENTS.md`, and the spec is
    [ui-preview.md](/files?path=specs%2Fui-preview.md).
    """
  end
end
