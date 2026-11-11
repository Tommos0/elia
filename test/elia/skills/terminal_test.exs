defmodule Elia.Skills.TerminalTest do
  @moduledoc """
  The terminal skill (TERM-24 - TERM-28): the tools that start a terminal, read
  what it shows and stop it, from a turn.
  """
  use ExUnit.Case, async: false

  alias Elia.Skills.Terminal, as: TerminalSkill
  alias Elia.Terminal

  # A session runs a real tmux (TERM-29): where there is none these are skipped.
  @moduletag skip: if(Terminal.available?(), do: false, else: "tmux is not installed")

  setup do
    id = "terminal-skill-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
    dir = Path.join(System.tmp_dir!(), id)
    File.mkdir_p!(dir)

    on_exit(fn ->
      case Terminal.fetch(id) do
        {:ok, pid} ->
          Terminal.stop(id)
          DynamicSupervisor.terminate_child(Terminal.supervisor(), pid)

        :error ->
          :ok
      end

      File.rm_rf(dir)
    end)

    %{id: id, dir: dir, ctx: %{session_id: id, workspace: dir, jail: false}}
  end

  defp tool(name), do: Enum.find(TerminalSkill.tools(), &(&1.name == name))

  # TERM-24: the skill is a terminal, in the chat the turn belongs to.
  test "the skill offers starting, sending to, reading and stopping" do
    assert TerminalSkill.name() == "terminal"

    assert Enum.map(TerminalSkill.tools(), & &1.name) ==
             ["terminal_start", "terminal_send", "terminal_read", "terminal_stop"]

    # TERM-28: what the model is told is when a terminal — not the shell tool —
    # is the thing to reach for, and that it can type into one itself.
    assert TerminalSkill.instructions() =~ "keep running"
    assert TerminalSkill.instructions() =~ "terminal_send"
    assert tool("terminal_start").description =~ "watch"
    assert tool("terminal_send").description =~ "keyboard"
  end

  # TERM-10, TERM-25, TERM-32: starting and sending need the user's approval —
  # the command, and the keys — where reading and stopping are controls the user
  # has themselves (TERM-26, TERM-27).
  test "starting and sending need approval, reading and stopping do not" do
    assert Elia.Tool.approval(tool("terminal_start"), %{"command" => "htop"}, %{}) == :required
    assert Elia.Tool.approval(tool("terminal_send"), %{"keys" => "ls<Enter>"}, %{}) == :required
    assert Elia.Tool.approval(tool("terminal_read"), %{}, %{}) == :never
    assert Elia.Tool.approval(tool("terminal_stop"), %{}, %{}) == :never

    # TERM-25: the command is optional — with none the user's own shell runs.
    assert Elia.Tool.validate(tool("terminal_start"), %{}) == :ok

    # TERM-30: what to type is not.
    assert Elia.Tool.validate(tool("terminal_send"), %{"keys" => "x"}) == :ok
    assert {:error, message} = Elia.Tool.validate(tool("terminal_send"), %{})
    assert message =~ "keys is required"
  end

  # TERM-11, TERM-25: the tool starts the command in the chat's workspace, in
  # the jail the chat is in (TERM-7), and tells the model where the user can
  # watch it.
  test "starting runs the command in the chat's workspace and links to its page", %{
    id: id,
    dir: dir,
    ctx: ctx
  } do
    assert {:ok, output} =
             TerminalSkill.run_start(%{"command" => "printf 'in the terminal\\n'; sleep 60"}, ctx)

    assert output =~ "/c/#{id}/terminal"
    assert output =~ dir
    assert output =~ "unjailed"
    assert output =~ "terminal_read"

    assert {:ok, status} = Terminal.status(id)
    assert status.running
    assert status.workspace == dir

    # TERM-1: it is the chat's one terminal, and the model is told rather than
    # a second one started.
    assert {:error, message} = TerminalSkill.run_start(%{"command" => "htop"}, ctx)
    assert message =~ "already has a running terminal"
  end

  # TERM-26: what the terminal shows, as text and as what it is — a running
  # session, or one that has ended and how — and an error where a chat has no
  # terminal at all.
  test "reading returns the screen as text", %{id: id, ctx: ctx} do
    assert {:ok, _} =
             TerminalSkill.run_start(%{"command" => "printf 'the screen\\n'; sleep 60"}, ctx)

    :ok = Terminal.subscribe(id)
    assert_receive {:terminal_screen, screen}, 15_000
    collect_until("the screen", screen)

    assert {:ok, screen} = TerminalSkill.run_read(%{}, ctx)
    assert screen =~ "the screen"
    assert screen =~ "[terminal: running"
    refute screen =~ "\e["

    assert {:error, message} = TerminalSkill.run_read(%{}, %{session_id: "no-such-chat"})
    assert message =~ "no terminal"
  end

  # TERM-26, TERM-23, TERM-4: a session that has ended is read too — what an app
  # printed before it died is what a model usually wants — and the screen says
  # how it ended rather than looking like a quiet one.
  test "reading an ended session returns its last screen and how it ended", %{ctx: ctx} do
    assert {:ok, _} =
             TerminalSkill.run_start(%{"command" => "printf 'last words\\n'; exit 5"}, ctx)

    assert eventually(fn ->
             case TerminalSkill.run_read(%{}, ctx) do
               {:ok, screen} -> screen =~ "last words" and screen =~ "exited with status 5"
               _ -> false
             end
           end)
  end

  defp eventually(fun, tries \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, tries - 1)
    end
  end

  # TERM-30, TERM-32, TERM-33: the tool types into a running terminal and says
  # what it sent — and, when the call asks for it, hands the screen back in the
  # same result once the keys have had their wait.
  test "sending types into the terminal and can read the screen back", %{ctx: ctx} do
    assert {:ok, _} = TerminalSkill.run_start(%{"command" => "sleep 60"}, ctx)

    assert {:ok, output} = TerminalSkill.run_send(%{"keys" => "echo typed-42<Enter>"}, ctx)
    assert output =~ "Sent to the terminal"
    assert output =~ "echo typed-42"
    assert output =~ "<Enter>"

    # The output, not the echo: what was typed does not contain the answer.
    assert {:ok, output} =
             TerminalSkill.run_send(
               %{"keys" => "echo $((6*7))<Enter>", "read" => true, "wait_ms" => 800},
               ctx
             )

    assert output =~ "Then, 800 ms later"
    assert output =~ "[terminal: running"
    assert output =~ "42"
  end

  # TERM-31, TERM-34: a key name tmux does not know, and a chat with no
  # terminal, are refused with what to do about it rather than typed.
  test "sending refuses an unknown key name and a chat with no terminal", %{ctx: ctx} do
    assert {:ok, _} = TerminalSkill.run_start(%{"command" => "sleep 60"}, ctx)

    assert {:error, message} = TerminalSkill.run_send(%{"keys" => "<Entr><Enter>"}, ctx)
    assert message =~ "not a key name"

    assert {:error, message} =
             TerminalSkill.run_send(%{"keys" => "ls"}, %{
               session_id: "no-such-chat"
             })

    assert message =~ "no terminal"
  end

  # TERM-27: stopping ends the session, and a chat with none says so.
  test "stopping ends the session", %{id: id, ctx: ctx} do
    assert {:ok, _} = TerminalSkill.run_start(%{"command" => "sleep 60"}, ctx)

    assert {:ok, output} = TerminalSkill.run_stop(%{}, ctx)
    assert output =~ "stopped"
    assert {:ok, %{running: false}} = Terminal.status(id)

    assert {:error, message} = TerminalSkill.run_stop(%{}, %{session_id: "no-such-chat"})
    assert message =~ "no terminal"
  end

  # TERM-29: where tmux is missing the tool says what is missing instead of
  # starting something that cannot run.
  test "starting without tmux says what is missing", %{dir: dir} do
    previous = Application.get_env(:elia, Terminal)
    Application.put_env(:elia, Terminal, tmux: "/nonexistent/tmux")
    on_exit(fn -> Application.put_env(:elia, Terminal, previous) end)

    assert {:error, message} =
             TerminalSkill.run_start(%{"command" => "htop"}, %{
               session_id: "no-tmux",
               workspace: dir
             })

    assert message =~ "no tmux"
  end

  # What the app has written, from a client of its own: the screen it is sent on
  # joining may already hold it, so that counts too.
  defp collect_until(needle, collected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000

    cond do
      String.contains?(collected, needle) ->
        true

      true ->
        receive do
          {:terminal_output, output} -> collect_until(needle, collected <> output, deadline)
          {:terminal_screen, screen} -> collect_until(needle, collected <> screen, deadline)
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            flunk("no output containing #{inspect(needle)}, saw #{inspect(collected)}")
        end
    end
  end
end
