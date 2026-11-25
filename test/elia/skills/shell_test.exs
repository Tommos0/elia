defmodule Elia.Skills.ShellTest do
  # The timeout settings are application-wide, and a test that exercises the
  # ceiling sets them (SHELL-10), so this module doesn't run async.
  use ExUnit.Case, async: false

  alias Elia.Skills.Shell

  @moduletag :tmp_dir

  test "returns output and exit code" do
    assert {:ok, "hi\n\n[exit: 0]"} = Shell.run(%{"command" => "echo hi"})
    assert {:error, output} = Shell.run(%{"command" => "echo oops >&2; exit 3"})
    assert output =~ "oops"
    assert output =~ "[exit: 3]"
  end

  # SECRET-5, SECRET-3: a command of a chat in a project has that project's
  # secrets in its environment, read from the project's own `.env` (SECRET-1) —
  # and the directory the chat works in does not decide which file that is. A
  # command that belongs to no chat is given none of them.
  test "a project's secrets reach the command's environment", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "sub"))
    File.write!(Path.join(dir, ".env"), "STRIPE_KEY=sk_live_env_value\n")

    ctx = %{
      session_id: "chatX",
      project: %{folder: dir},
      workspace: dir,
      cwd: Path.join(dir, "sub")
    }

    assert {:ok, output} = Shell.run(%{"command" => "printenv STRIPE_KEY"}, ctx)
    assert output =~ "sk_live_env_value"

    # A jailed command gets them in the jail's own `--setenv` arguments (ISOL-8).
    assert {:ok, output} =
             Shell.run(%{"command" => "printenv STRIPE_KEY"}, Map.put(ctx, :jail, true))

    assert output =~ "sk_live_env_value"

    assert {:error, output} = Shell.run(%{"command" => "printenv STRIPE_KEY"}, %{})
    assert output =~ "[exit: 1]"
  end

  # SHELL-15: the shell is how the model works with files. The instructions and
  # the description send file work to no other tool, and say how a file is read,
  # how text is found and how a file is changed.
  test "instructions and tool description send file work to the shell" do
    assert [%{description: description}] = Shell.tools()

    for text <- [Shell.instructions(), description] do
      # No tool left to send file work to.
      refute text =~ "read_file"
      refute text =~ "search_files"

      # Reading a file is a command, and its output is truncated like any
      # other command's when it is long (SHELL-5).
      assert text =~ "cat"
      assert text =~ "truncated"

      # Finding text in the tree is the shell's own search.
      assert text =~ "grep"
      assert text =~ "rg"

      # Creating, editing and deleting a file is a command the user approves as
      # it stands (SHELL-1).
      assert text =~ "approve"
    end
  end

  # SHELL-9
  test "instructions and tool description say which shell runs and warn off bash-only syntax" do
    assert [%{description: description}] = Shell.tools()

    for text <- [Shell.instructions(), description] do
      assert text =~ "bash -c"
      assert text =~ "POSIX"
      assert text =~ "PIPESTATUS"
      assert text =~ "set -o pipefail"
    end
  end

  # PRIO-8: the model is told a command runs below the server's priority, so a
  # command that seems slow while a compile runs reads as expected rather than
  # broken.
  test "instructions and tool description say a command runs below the server" do
    assert [%{description: description}] = Shell.tools()

    for text <- [Shell.instructions(), description] do
      assert text =~ "lower"
      assert text =~ "priority"
    end
  end

  # ISOL-21
  test "instructions and tool description explain the jail and when it is off" do
    assert [%{description: description}] = Shell.tools()

    for text <- [Shell.instructions(), description] do
      assert text =~ "jail by default"
      assert text =~ "workspace"
      assert text =~ "toolchain"
      assert text =~ "settings database"
      assert text =~ "saved conversations"
      assert text =~ "credentials"
      assert text =~ "expected, not broken"
      assert text =~ "unjailed"

      # ISOL-21, ISOL-31, ISOL-32: and that a call may ask for no jail of its
      # own, which the user is asked about every time.
      assert text =~ "ask for no jail"
      assert text =~ "asked about it every time"
    end
  end

  # NET-27
  test "instructions and tool description say what the chat's network setting is" do
    assert [%{description: description}] = Shell.tools()

    for text <- [Shell.instructions(), description] do
      assert text =~ "network"
      assert text =~ "allowlisted"
      assert text =~ "http_proxy"
      assert text =~ "no name resolution"
      assert text =~ "reaches nothing"
      assert text =~ "no ssh"
    end

    # NET-35: a host a command cannot reach is a reason to ask for it, and the
    # tool that asks is named.
    for text <- [Shell.instructions(), description] do
      assert text =~ "request_network_host"
    end
  end

  # SHELL-14: a command is told which chat it belongs to, as `ELIA_CHAT_ID`, so a
  # chat can name the worktree and the branch it makes for itself (DEPLOY-28)
  # without being told its own id — and a step the harness runs for no chat gets
  # no such variable (DEPLOY-18).
  test "a chat's command is told its chat id, and the harness's own is not" do
    assert {:ok, output} =
             Shell.run(%{"command" => "printenv ELIA_CHAT_ID"}, %{session_id: "aBc123"})

    assert output =~ "aBc123"
    refute output =~ "[exit: 1]"

    # No chat: nothing to name, so the variable is not set at all.
    assert {:ok, output} = Shell.run(%{"command" => "printenv ELIA_CHAT_ID; echo status=$?"}, %{})
    assert output =~ "status=1"
    refute output =~ "aBc123"

    # The same, when the process running the command has one of its own: a suite
    # a chat started inherits that chat's id, and a command for no chat must not
    # be told it (SHELL-14, DEPLOY-18).
    previous = System.get_env("ELIA_CHAT_ID")
    System.put_env("ELIA_CHAT_ID", "leaked1")
    on_exit(fn -> restore("ELIA_CHAT_ID", previous) end)

    assert {:ok, output} = Shell.run(%{"command" => "printenv ELIA_CHAT_ID; echo status=$?"}, %{})
    assert output =~ "status=1"
    refute output =~ "leaked1"

    # And a command for a chat is given that chat's id, not the inherited one.
    assert {:ok, output} =
             Shell.run(%{"command" => "printenv ELIA_CHAT_ID"}, %{session_id: "aBc123"})

    assert output =~ "aBc123"
    refute output =~ "leaked1"
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)

  test "does not wait on stdin" do
    assert {:ok, "\n[exit: 0]"} = Shell.run(%{"command" => "cat", "timeout_seconds" => 5})
  end

  test "kills commands that time out" do
    assert {:error, output} =
             Shell.run(%{"command" => "echo start; sleep 30", "timeout_seconds" => 1})

    assert output =~ "start"
    assert output =~ "timeout after 1s"
  end

  # SHELL-10
  test "a timeout above the configured maximum runs with the maximum and says so" do
    # The settings are global, which is why this module doesn't run async.
    previous = Application.get_env(:elia, Shell, [])

    Application.put_env(:elia, Shell,
      default_timeout: 5,
      max_timeout: 1,
      max_output: 30_000
    )

    on_exit(fn -> Application.put_env(:elia, Shell, previous) end)

    assert {:error, output} =
             Shell.run(%{"command" => "echo start; sleep 30", "timeout_seconds" => 600})

    assert output =~ "start"
    assert output =~ "timeout after 1s (asked for 600s, the most is 1s)"

    # The tool's description names the default and the ceiling, so a long run is
    # asked for rather than run into (SHELL-8, SHELL-9).
    [tool] = Shell.tools()
    text = get_in(tool.input_schema, ["properties", "timeout_seconds", "description"])

    assert text =~ "The default is 5"
    assert text =~ "the most is 1"
  end

  # SHELL-5, SHELL-13: the tool runs its command with the cap, so a result that
  # was cut carries the one marker the run made, not a second cut through it.
  test "a long result is cut once, with one marker that counts what was removed" do
    assert {:ok, output} =
             Shell.run(%{"command" => "head -c 1000000 /dev/zero | tr '\\0' a"})

    assert [_one, _other] = String.split(output, "characters truncated")
    assert output =~ "... [970000 characters truncated] ..."
    assert String.ends_with?(output, String.duplicate("a", 15_000) <> "\n[exit: 0]")
  end

  # SHELL-10
  test "a timeout that isn't a whole number of seconds of at least 1 is refused" do
    assert {:error, output} = Shell.run(%{"command" => "echo hi", "timeout_seconds" => 0})
    assert output =~ "timeout_seconds must be a whole number of seconds of at least 1"
    assert output =~ "the default is 300s and the most is 1800s"
    refute output =~ "hi"

    assert {:error, _} = Shell.run(%{"command" => "echo hi", "timeout_seconds" => -5})
  end

  # ISOL-32, SHELL-16, APPR-19: a call may ask for no jail, and that call is the
  # user's to allow every time — never one the chat's auto-approval waves
  # through (APPR-8).
  test "a call that asks for no jail is the user's to allow, and says so" do
    [tool] = Shell.tools()

    assert Elia.Tool.approval(tool, %{"command" => "echo hi"}, %{}) == :required

    assert Elia.Tool.approval(tool, %{"command" => "echo hi", "jail" => false}, %{}) ==
             {:required, :always}

    # SHELL-16: the input is a boolean, and leaving it out leaves the chat's
    # setting to decide (ISOL-16).
    assert Elia.Tool.validate(tool, %{"command" => "echo hi", "jail" => false}) == :ok

    assert {:error, message} =
             Elia.Tool.validate(tool, %{"command" => "echo hi", "jail" => "no"})

    assert message =~ "jail must be a boolean"

    # ISOL-33: the result says which jail it ran under, before the output.
    assert {:ok, output} = Shell.run(%{"command" => "echo hi", "jail" => false}, %{jail: true})
    assert output =~ "[jail: off at this call's request]\nhi"

    # A call that asked for nothing says nothing.
    assert {:ok, output} = Shell.run(%{"command" => "echo hi"}, %{jail: false})
    refute output =~ "jail: off"
  end
end
