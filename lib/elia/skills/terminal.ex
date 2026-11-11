defmodule Elia.Skills.Terminal do
  @moduledoc """
  Runs a terminal app in the chat's workspace and shows it to the user, on the
  chat's own terminal page. See `specs/terminal.md` (TERM-24 - TERM-34).
  """

  @behaviour Elia.Skill

  alias Elia.Terminal

  @impl true
  def name, do: "terminal"

  @impl true
  def description, do: "Run a terminal app in the chat's workspace and show it to the user."

  @impl true
  def instructions do
    """
    Use a terminal — not the `shell` tool — for a program that has to keep \
    running while the user watches it or types into it: a REPL, a watch-mode \
    test run, `htop`, an interactive installer. The `shell` tool is for a \
    command that finishes and hands back its output; a terminal is for one that \
    doesn't, and its output is not part of this transcript.

    `terminal_start` starts one, and it needs the user's approval — the command \
    is what they approve. After that the user can type into it, and so can you: \
    `terminal_send` types keys into a running terminal (`"htop<Enter>"`, \
    `"<C-x><C-s>"`, `"<Escape>:wq<Enter>"`), needs approval of its own — the \
    keys are what the user approves — and can hand you the screen back with \
    `read: true`, which is one call per step of driving an app. Reading the \
    screen is `terminal_read` (plain text, up to the configured scrollback) \
    where you only want to see it, and it needs no approval; `terminal_stop` \
    ends the session.

    A chat has one terminal at a time (TERM-1), and its session ends when its \
    command does or when the user stops it (TERM-3); a new one can then be \
    started. A terminal runs in the chat's workspace, in the same jail as a \
    command and at the same lower priority (TERM-7, TERM-8), so what it can \
    reach is what a command can reach, and it doesn't take the machine from the \
    UI. Where tmux is not installed the terminal is unavailable and says so \
    (TERM-29).
    """
  end

  @impl true
  def tools do
    [start_tool(), send_tool(), read_tool(), stop_tool()]
  end

  # TERM-25: starting needs approval — what the user approves is the command
  # (TERM-10), because after that the terminal is theirs to type into.
  defp start_tool do
    %Elia.Tool{
      name: "terminal_start",
      description:
        "Start a terminal in this chat's workspace and show it to the user on " <>
          "the chat's terminal page. Use it for a program that must keep running " <>
          "while the user watches or types into it (a REPL, a watch-mode test run, " <>
          "htop, an interactive installer); the shell tool is for a command that " <>
          "finishes. The user approves the command, and can then type into the " <>
          "terminal themselves — and so can you, with terminal_send, which asks " <>
          "them first. Read what it shows with terminal_read. It runs in the " <>
          "chat's workspace, in the same jail and at " <>
          "the same lower priority as a command, and its output is not part of this " <>
          "transcript. A chat has one terminal at a time.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" =>
              "The command line to run in the terminal, e.g. \"htop\" or " <>
                "\"mix test --watch\". Omit it for the user's own login shell."
          }
        }
      },
      approval: :required,
      run: &run_start/2
    }
  end

  # TERM-30, TERM-32: the agent typing into a terminal is an action of its own —
  # it would be typing into a shell the user approved to *watch* — so it needs
  # their approval, and what it types is what they approve.
  defp send_tool do
    %Elia.Tool{
      name: "terminal_send",
      description:
        "Type into this chat's terminal as if at its keyboard: use it to drive " <>
          "an app the user can watch you driving — a menu, a REPL, an editor. " <>
          "`keys` is text with keys named in angle brackets: \"htop<Enter>\" " <>
          "types htop and presses Enter, \"<C-x><C-s>\" presses C-x then C-s, " <>
          "\"<Escape>:wq<Enter>\" saves and leaves an editor. A name is a tmux " <>
          "key name (Enter, Escape, Tab, BSpace, Space, Up, Down, Left, Right, " <>
          "Home, End, Insert, Delete, PageUp, PageDown, F1-F12) with C-, M- or " <>
          "S- in front (<C-x>, <M-Up>, <S-F1>), and Esc, CR, RET, Backspace, " <>
          "PgUp, PgDn, Del and Ins mean those same keys. Text goes as it is: a " <>
          "newline in it is a line feed, where <Enter> is the carriage return an " <>
          "app expects from that key. A <...> that is not a key name is text " <>
          "(<b>, <foo bar>); one that names a key tmux does not know is an error " <>
          "rather than text, so a typo is never typed into the app. A send is " <>
          "refused when this chat has no terminal or its command has ended. It " <>
          "needs the user's approval, and the user sees the terminal. Set " <>
          "\"read\": true to get the screen back after the keys have had " <>
          "\"wait_ms\" (default 300) to take effect, which makes driving an app " <>
          "one call per step; leave it out when you don't need to see the result.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "keys" => %{
            "type" => "string",
            "description" =>
              "What to type: text as it is, with keys in angle brackets — " <>
                "\"htop<Enter>\", \"<C-x><C-s>\", \"<Escape>:wq<Enter>\"."
          },
          "read" => %{
            "type" => "boolean",
            "description" =>
              "Read the screen back after sending. Off by default: a send that " <>
                "doesn't need to see the result costs no screen text in the " <>
                "transcript."
          },
          "wait_ms" => %{
            "type" => "integer",
            "description" =>
              "With read: true, how long to let the keys take effect before " <>
                "reading. Default 300, at most 5000."
          }
        },
        "required" => ["keys"]
      },
      approval: :required,
      run: &run_send/2
    }
  end

  # TERM-26: reading a screen is reading, so it needs no approval of its own.
  defp read_tool do
    %Elia.Tool{
      name: "terminal_read",
      description:
        "What this chat's terminal is showing now, as plain text: its screen and " <>
          "up to the configured scrollback lines, truncated like a command's " <>
          "output. Use it to see what an app in the terminal is doing, since the " <>
          "terminal's output is not part of this transcript. It errors when the " <>
          "chat has no terminal.",
      input_schema: %{"type" => "object", "properties" => %{}},
      approval: :never,
      run: &run_read/2
    }
  end

  # TERM-27: stopping what the terminal was started with is a control the user
  # has on the page too, so the tool needs no approval of its own.
  defp stop_tool do
    %Elia.Tool{
      name: "terminal_stop",
      description:
        "Stop this chat's terminal: its whole process tree is killed and the " <>
          "terminal ends, keeping the screen it was showing so the user can still " <>
          "see it. A new terminal can be started afterwards.",
      input_schema: %{"type" => "object", "properties" => %{}},
      approval: :never,
      run: &run_stop/2
    }
  end

  @doc "Starts a session for the chat this turn runs in (TERM-25)."
  def run_start(input, ctx \\ %{}) do
    chat_id = chat_id(ctx)

    case Terminal.start(chat_id,
           command: command(input),
           workspace: workspace(ctx),
           jail: Map.get(ctx, :jail, true)
         ) do
      {:ok, _pid} ->
        {:ok, started_message(chat_id, input["command"], ctx)}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  Types keys into the chat's terminal (TERM-30), reading the screen back when
  the call asks for it (TERM-33).

  What is typed is what the user approves (TERM-32), so the result says what was
  sent, in the order it was sent.
  """
  def run_send(input, ctx \\ %{}) do
    chat_id = chat_id(ctx)

    with {:ok, segments} <- Terminal.keys(chat_id, input["keys"] || "") do
      if read?(input) do
        wait = wait_ms(input)
        Process.sleep(wait)

        case screen(chat_id) do
          {:ok, text} -> {:ok, "#{sent(segments)} Then, #{wait} ms later:\n#{text}"}
          {:error, message} -> {:error, message}
        end
      else
        {:ok, sent(segments)}
      end
    end
  end

  @doc """
  The terminal's screen as plain text (TERM-26).

  A session that has ended is read as well as one that is running — what an app
  printed before it died is usually the thing a model wants — and the screen says
  which of the two it is and how the session ended (TERM-4, TERM-23). Only a
  chat with no terminal at all is an error.
  """
  def run_read(_input, ctx \\ %{}), do: screen(chat_id(ctx))

  @doc "Stops the chat's terminal (TERM-27)."
  def run_stop(_input, ctx \\ %{}) do
    case Terminal.stop(chat_id(ctx)) do
      {:ok, status} -> {:ok, "Terminal stopped: #{ended(status)}."}
      {:error, message} -> {:error, message}
    end
  end

  # TERM-26, TERM-33: the screen as a reader gets it — what the terminal is
  # (running, or ended and how) above what is on it — in one place, so a read
  # and the read-back a send asks for are the same thing.
  defp screen(chat_id) do
    case Terminal.read(chat_id) do
      {:ok, text} ->
        {:ok, "#{heading(chat_id)}\n#{Elia.Shell.truncate(text, config(:max_output))}"}

      {:error, message} ->
        {:error, message}
    end
  end

  # TERM-30: what was sent, in the order it was sent, so both the transcript and
  # the user's approval show the keys rather than only that some were sent.
  defp sent(segments) do
    what =
      Enum.map_join(segments, " ", fn
        {:text, text} -> inspect(text)
        {:key, name} -> "<#{name}>"
      end)

    "Sent to the terminal: #{what}."
  end

  defp read?(input), do: input["read"] == true

  # TERM-33: the wait is what makes a read-back see the effect of the keys, and
  # a tool call is not the place for an unbounded one.
  defp wait_ms(input) do
    case input["wait_ms"] do
      ms when is_integer(ms) -> ms |> max(0) |> min(5_000)
      _ -> 300
    end
  end

  # What the screen is, before what is on it: the model reads a screen it can't
  # otherwise place, and a session that has ended says so rather than looking
  # like a quiet one (TERM-23, TERM-26).
  defp heading(chat_id) do
    case Terminal.status(chat_id) do
      {:ok, %{running: true} = status} -> "[terminal: running `#{status.command}`]"
      {:ok, status} -> "[terminal: ended — #{ended(status)}]"
      :error -> "[terminal: no session]"
    end
  end

  defp started_message(chat_id, command, ctx) do
    what =
      case command do
        nil -> "the user's login shell"
        command -> "`#{command}`"
      end

    jail = if Map.get(ctx, :jail, true), do: "jailed", else: "unjailed"

    "Terminal started in `#{workspace(ctx)}` (#{jail}), running #{what}. " <>
      "The user can watch it and type into it at [the terminal page](/c/#{chat_id}/terminal); " <>
      "its output is not part of this transcript, so read it with terminal_read, or " <>
      "type into it yourself with terminal_send, which needs the user's approval."
  end

  # How a session that is no longer running ended (TERM-4), as a phrase that
  # reads both after a Stop and on its own.
  defp ended(%{exit_status: status}) when is_integer(status),
    do: "its command had exited with status #{status}"

  defp ended(%{ended: :stopped}), do: "it was stopped"
  defp ended(%{ended: :crashed}), do: "it ended unexpectedly"
  defp ended(_status), do: "it was showing its last screen"

  defp command(input) do
    case String.trim(input["command"] || "") do
      "" -> nil
      command -> command
    end
  end

  # The chat this turn belongs to (TERM-2): a terminal is the chat's, so it is
  # the chat that names it (TERM-1) and the chat whose workspace it runs in.
  defp chat_id(ctx) do
    case ctx[:session_id] do
      nil -> "no-chat"
      id -> id
    end
  end

  defp workspace(ctx), do: ctx[:workspace] || Elia.Workspace.root()

  defp config(key) do
    Keyword.merge([max_output: 30_000], Application.get_env(:elia, __MODULE__, []))[key]
  end
end
