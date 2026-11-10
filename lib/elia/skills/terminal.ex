defmodule Elia.Skills.Terminal do
  @moduledoc """
  Runs a terminal app in the chat's workspace and shows it to the user, on the
  chat's own terminal page. See `specs/terminal.md` (TERM-24 - TERM-28).
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
    is what they approve. After that the user can type into it and you cannot: \
    nothing types for you, so read the screen with `terminal_read` (plain text, \
    up to the configured scrollback) rather than expecting output in a tool \
    result. `terminal_stop` ends it.

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
    [start_tool(), read_tool(), stop_tool()]
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
          "terminal themselves — nothing types for you, so read what it shows with " <>
          "terminal_read. It runs in the chat's workspace, in the same jail and at " <>
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
  The terminal's screen as plain text (TERM-26).

  A session that has ended is read as well as one that is running — what an app
  printed before it died is usually the thing a model wants — and the screen says
  which of the two it is and how the session ended (TERM-4, TERM-23). Only a
  chat with no terminal at all is an error.
  """
  def run_read(_input, ctx \\ %{}) do
    chat_id = chat_id(ctx)

    case Terminal.read(chat_id) do
      {:ok, text} ->
        {:ok, "#{heading(chat_id)}\n#{Elia.Shell.truncate(text, config(:max_output))}"}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc "Stops the chat's terminal (TERM-27)."
  def run_stop(_input, ctx \\ %{}) do
    case Terminal.stop(chat_id(ctx)) do
      {:ok, status} -> {:ok, "Terminal stopped: #{ended(status)}."}
      {:error, message} -> {:error, message}
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
      "its output is not part of this transcript, so use terminal_read to see what it shows."
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
