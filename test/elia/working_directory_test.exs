defmodule Elia.WorkingDirectoryTest do
  @moduledoc """
  A chat's working directory (`specs/working-directory.md`): what a relative path
  in a command run by the `shell` call resolves against, the `cd` tool that
  changes it, and the entry it saves with the chat (WD-1 to WD-12, STORE-46).
  """
  # Not async: a chat's session is a process of the app's supervision tree and
  # the store writes the app's own data directory.
  use ExUnit.Case, async: false

  alias Elia.{Agent, FakeLLM}
  alias Elia.LLM.Message
  alias Elia.Skills.Shell

  # WD-3, WD-5: the resolution itself, and where a directory may be.
  alias Elia.Workdir, as: Wd

  setup do
    start_supervised!(FakeLLM)

    tag = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    dir = Path.join(System.tmp_dir!(), "elia-wd-#{tag}")
    lib = Path.join(dir, "lib")
    outside = Path.join(System.tmp_dir!(), "elia-out-#{tag}")

    File.mkdir_p!(lib)
    File.mkdir_p!(outside)
    File.write!(Path.join(dir, "top.txt"), "at the top\n")
    File.write!(Path.join(lib, "lib.txt"), "in lib\n")
    # A link from inside the workspace to a directory outside it: `cd` follows
    # the path to where it lands (WS-5, WD-5).
    File.ln_s!(outside, Path.join(dir, "out-link"))

    on_exit(fn ->
      File.rm_rf!(dir)
      File.rm_rf!(outside)
    end)

    %{dir: dir, lib: lib, outside: outside}
  end

  defp await_status(id, status) do
    assert_receive {:agent, ^id, {:status, ^status}}, 5000
  end

  # A chat of this test's own, working in `dir` (PROJ-12, DEPLOY-1).
  defp start_chat(dir, opts \\ []) do
    id = Agent.new_id()
    {:ok, pid} = Agent.ensure_started(id, Keyword.put(opts, :workspace, dir))
    Agent.subscribe(id)
    on_exit(fn -> stop_chat(id, pid) end)
    {id, pid}
  end

  defp stop_chat(id, pid) do
    DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
    Elia.Store.delete(id)
  end

  ## What a relative path names (WD-1, WD-9)

  # WD-1: a call's working directory is its workspace root until the chat has
  # one of its own, and the context it carries is what decides (WD-10).
  test "the working directory of a call is its workspace root until it has one",
       %{dir: dir, lib: lib} do
    assert Wd.of(%{workspace: dir}) == dir
    assert Wd.of(%{workspace: dir, cwd: lib}) == lib
    assert Wd.of(%{cwd: lib}) == lib

    # WD-1: with neither, Elia's own root.
    assert Wd.of(%{}) == Elia.Workspace.root()
  end

  # WD-9, SHELL-2: the same relative path names a different file once the chat
  # has moved.
  test "a relative path resolves against the working directory", %{dir: dir, lib: lib} do
    root_ctx = %{workspace: dir, jail: false}
    lib_ctx = %{workspace: dir, cwd: lib, jail: false}

    # In the workspace root: `top.txt` is here and `lib.txt` is not.
    assert {:ok, "at the top\n\n[exit: 0]"} = Shell.run(%{"command" => "cat top.txt"}, root_ctx)
    assert {:error, message} = Shell.run(%{"command" => "cat lib.txt"}, root_ctx)
    assert message =~ "lib.txt"

    # After `cd lib`: the same relative paths name other files.
    assert {:ok, "in lib\n\n[exit: 0]"} = Shell.run(%{"command" => "cat lib.txt"}, lib_ctx)
    assert {:ok, "at the top\n\n[exit: 0]"} = Shell.run(%{"command" => "cat ../top.txt"}, lib_ctx)

    # SHELL-2, WD-9: a command runs in the working directory.
    assert {:ok, out} = Shell.run(%{"command" => "ls"}, lib_ctx)
    assert out =~ "lib.txt"
    refute out =~ "top.txt"

    assert {:ok, top} = Shell.run(%{"command" => "ls"}, root_ctx)
    assert top =~ "top.txt"
  end

  ## Where a chat may stand (WD-5)

  # WD-5: a directory outside the workspace, one that is missing and one that
  # isn't a directory are each refused with the path and the reason.
  test "a directory outside the workspace, or not a directory at all, is refused",
       %{dir: dir, lib: lib, outside: outside} do
    assert {:ok, ^lib} = Wd.resolve("lib", dir, dir)
    assert {:ok, ^dir} = Wd.resolve("..", lib, dir)
    assert {:ok, ^lib} = Wd.resolve(lib, dir, dir)

    assert {:error, missing} = Wd.resolve("lib/nope", dir, dir)
    assert missing =~ "lib/nope"
    assert missing =~ "no such file"

    assert {:error, not_dir} = Wd.resolve("top.txt", dir, dir)
    assert not_dir =~ "top.txt"
    assert not_dir =~ "not a directory"

    # WS-5: the path is judged by where it lands, so a link out of the workspace
    # is the outside directory it points at.
    assert {:error, link} = Wd.resolve("out-link", dir, dir)
    assert link =~ outside
    assert link =~ "outside the workspace"

    assert {:error, up} = Wd.resolve("..", dir, dir)
    assert up =~ "outside the workspace"
  end

  # WD-5, WS-7: while the chat is jailed a protected directory — `.git` here,
  # directly, below it, or through a link inside the workspace — is refused with
  # the path and why; while it isn't, nothing is protected.
  test "cd into .git is refused only while the chat is jailed", %{dir: dir} do
    git = Path.join(dir, ".git")
    refs = Path.join(git, "refs")
    File.mkdir_p!(refs)
    File.ln_s!(git, Path.join(dir, "git-link"))

    assert {:error, direct} = Wd.resolve(".git", dir, dir, protected: true)
    assert direct =~ git
    assert direct =~ "protected"

    assert {:error, below} = Wd.resolve(".git/refs", dir, dir, protected: true)
    assert below =~ "protected"

    assert {:error, link} = Wd.resolve("git-link", dir, dir, protected: true)
    assert link =~ "resolves to #{git}"
    assert link =~ "protected"

    # A name that only starts like a protected one is an ordinary directory.
    File.mkdir_p!(Path.join(dir, ".github"))
    assert {:ok, _} = Wd.resolve(".github", dir, dir, protected: true)

    # Unjailed, the same paths are ordinary directories.
    assert {:ok, ^git} = Wd.resolve(".git", dir, dir)
    assert {:ok, ^refs} = Wd.resolve(".git/refs", dir, dir, protected: false)
    assert {:ok, ^git} = Wd.resolve("git-link", dir, dir, protected: false)
  end

  # WD-5, ISOL-16, ISOL-20: the `cd` a chat's session runs judges a protected
  # directory by that chat's own jail setting, with the host's jail on.
  test "a jailed chat's cd refuses .git and an unjailed chat's allows it", %{dir: dir} do
    git = Path.join(dir, ".git")
    File.mkdir_p!(git)

    shell = Application.get_env(:elia, Elia.Shell, [])
    Application.put_env(:elia, Elia.Shell, Keyword.put(shell, :jail, true))
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, shell) end)

    {jailed, _pid} = start_chat(dir, jail: true)
    assert {:error, message} = Agent.set_cwd(jailed, ".git")
    assert message =~ "protected"
    assert Agent.cwd(jailed) == Wd.real_root(dir)

    {unjailed, _pid} = start_chat(dir, jail: false)
    assert {:ok, ".git"} = Agent.set_cwd(unjailed, ".git")
    assert Agent.cwd(unjailed) == Path.join(Wd.real_root(dir), ".git")

    # The host's jail off is the jail off, whatever the chat's own setting says.
    Application.put_env(:elia, Elia.Shell, Keyword.put(shell, :jail, false))
    {host_off, _pid} = start_chat(dir, jail: true)
    assert {:ok, ".git"} = Agent.set_cwd(host_off, ".git")
  end

  # WD-3, WD-4, WD-5: `cd` through a chat's session — it sets the chat's working
  # directory, reports where it is, and changes nothing when it refuses.
  test "cd sets the chat's working directory and reports it", %{dir: dir} do
    {id, _pid} = start_chat(dir)
    root = Wd.real_root(dir)

    # WD-1: a fresh chat works in its workspace root.
    assert Agent.cwd(id) == root

    # WD-4: with no path it reports where the chat is and changes nothing.
    assert {:ok, "."} = Agent.set_cwd(id, nil)
    assert Agent.cwd(id) == root

    # WD-3: the new directory comes back relative to the workspace root, and a
    # path relative to the current one works as an absolute one does.
    assert {:ok, "lib"} = Agent.set_cwd(id, "lib")
    assert Agent.cwd(id) == Path.join(root, "lib")
    assert {:ok, "lib"} = Agent.set_cwd(id, ".")
    assert {:ok, "."} = Agent.set_cwd(id, Path.join(dir, "lib/.."))
    assert Agent.cwd(id) == root

    # WD-5: a refusal says why, and leaves the chat where it was.
    assert {:ok, "lib"} = Agent.set_cwd(id, "lib")
    assert {:error, message} = Agent.set_cwd(id, "nope")
    assert message =~ "nope"
    assert Agent.cwd(id) == Path.join(root, "lib")

    assert {:error, message} = Agent.set_cwd(id, "../..")
    assert message =~ "outside the workspace"
    assert Agent.cwd(id) == Path.join(root, "lib")
  end

  # WD-12: a skill run outside a chat — no session to change the directory of —
  # refuses instead of crashing.
  test "cd with no chat to change the directory of is an error result", %{dir: dir} do
    tool = Enum.find(Elia.Skills.Workdir.tools(), &(&1.name == "cd"))

    assert tool.approval == :never

    assert {:error, message} = Elia.Tool.call(tool, %{"path" => dir}, %{})
    assert message =~ "no chat"
  end

  ## Saved with the chat (WD-2, WD-7, STORE-46)

  # STORE-46: the option writes the key, its loader reads it, and a save that
  # gives none carries no entry — which is what a chat saved before this key
  # existed gives (WD-7).
  test "the working directory is saved with the chat", %{dir: dir} do
    id = Agent.new_id()
    lib = Path.join(Wd.real_root(dir), "lib")
    on_exit(fn -> Elia.Store.delete(id) end)

    :ok = Elia.Store.save(id, [Message.user("hi")])
    assert Elia.Store.load_cwd(id) == nil

    :ok = Elia.Store.save(id, [Message.user("hi")], cwd: lib)
    assert Elia.Store.load_cwd(id) == lib

    # Moving back to the root drops the entry again, so a chat that never
    # changed directory and one that moved back read the same.
    :ok = Elia.Store.save(id, [Message.user("hi")])
    assert Elia.Store.load_cwd(id) == nil

    assert Elia.Store.load_cwd("no-such-chat") == nil
  end

  # WD-2: the working directory is the chat's, not a turn's, so it outlives the
  # process that set it. WD-7: a value that is no longer a directory inside the
  # workspace reads as the workspace root.
  test "the working directory survives a restart", %{dir: dir} do
    id = Agent.new_id()
    root = Wd.real_root(dir)
    lib = Path.join(root, "lib")

    {:ok, pid} = Agent.ensure_started(id, workspace: dir)
    Agent.subscribe(id)
    on_exit(fn -> stop_chat(id, pid) end)

    assert {:ok, "lib"} = Agent.set_cwd(id, "lib")

    # An empty chat is saved with its first message (SESS-14), and the working
    # directory goes with it.
    assert Elia.Store.load_cwd(id) == nil

    FakeLLM.push(FakeLLM.assistant([Message.text("Hello!")]))
    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)
    assert Elia.Store.load_cwd(id) == lib

    # WD-2: a session that starts again for the chat reads it back.
    DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
    {:ok, restarted} = Agent.ensure_started(id, workspace: dir)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, restarted) end)
    Agent.subscribe(id)
    assert Agent.cwd(id) == lib

    # WD-7: moving back to the workspace root takes the entry off the file.
    assert {:ok, "."} = Agent.set_cwd(id, "..")
    assert Agent.cwd(id) == root
    assert Elia.Store.load_cwd(id) == nil
  end

  # WD-7: a saved directory that is gone, or is outside the workspace, reads as
  # the workspace root — what a workspace that has moved leaves behind.
  test "a saved working directory that is no longer there reads as the root", %{dir: dir} do
    root = Wd.real_root(dir)

    for saved <- [Path.join(dir, "gone"), System.tmp_dir!()] do
      id = Agent.new_id()
      :ok = Elia.Store.save(id, [Message.user("hi")], cwd: saved)
      {:ok, pid} = Agent.ensure_started(id, workspace: dir)
      on_exit(fn -> stop_chat(id, pid) end)

      assert Agent.cwd(id) == root
      # WD-4: and the chat is told it is at the root.
      assert {:ok, "."} = Agent.set_cwd(id, nil)
    end
  end

  ## A step at a time (WD-10)

  # WD-10: a `cd` takes effect from the next step — the calls of one step run at
  # the same time (LOOP-10) — so a command beside it still resolves against the
  # directory the step began in, and the command after it resolves against `lib`.
  test "a cd moves the next step, not a call running beside it", %{dir: dir} do
    {id, _pid} = start_chat(dir)

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("c1", "cd", %{"path" => "lib"}),
        FakeLLM.tool_call("c2", "shell", %{"command" => "cat top.txt"})
      ])
    )

    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("c3", "shell", %{"command" => "cat lib.txt"})])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Both read.")]))

    :ok = Agent.send_message(id, "read both")
    await_status(id, :idle)

    [_first, second, third] = FakeLLM.requests()

    # The `cd` ran and said where the chat now is (WD-3)…
    assert %{content: "Working directory: lib", is_error: false} = result(second, "c1")

    # …and the command of its own step still resolved against the workspace root.
    assert %{content: "at the top\n\n[exit: 0]", is_error: false} = result(second, "c2")

    # The next step's command resolved against `lib`.
    assert %{content: "in lib\n\n[exit: 0]", is_error: false} = result(third, "c3")

    assert Agent.cwd(id) == Path.join(Wd.real_root(dir), "lib")
  end

  # The tool result of `call_id` in what the model was sent for that step.
  defp result(request, call_id) do
    request.messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.flat_map(& &1.content)
    |> Enum.find(&(&1.tool_call_id == call_id))
  end

  ## What the model is told (WD-6, WD-11)

  # WD-11: the skill's instructions and the tool's description say what the
  # working directory is, that a relative path resolves against it and that `cd`
  # changes it — and the `shell` skill says that a command runs in it, since `cd`
  # is not one of its tools.
  test "the instructions say what the working directory is and what cd does" do
    assert Elia.Skills.Workdir.name() == "workdir"
    [cd] = Elia.Skills.Workdir.tools()

    # WD-11: the skill's instructions say what the working directory is and that
    # `cd` moves it…
    assert Elia.Skills.Workdir.instructions() =~ "cd"
    assert Elia.Skills.Workdir.instructions() =~ "relative"
    assert Elia.Skills.Workdir.instructions() =~ "workspace root"

    # …and the tool's description says what it sets, relative to what, and that
    # it needs no approval (WD-6).
    assert cd.description =~ "working directory"
    assert cd.description =~ "relative"
    assert cd.description =~ "workspace root"
    assert cd.description =~ "approval"

    assert Elia.Skills.Workdir.description() =~ "working directory"

    # WD-11, SHELL-2: `cd` is not a tool of the shell's, so the shell skill says
    # where a command's relative paths resolve and where to change it.
    assert Shell.instructions() =~ "cd"
    assert Shell.instructions() =~ "working directory"

    [shell] = Shell.tools()
    assert shell.description =~ "working directory"
    assert shell.description =~ "cd"

    # WD-6: `cd` changes no file and grants no reach, so no call of it is put to
    # the user (APPR-13).
    assert cd.approval == :never
    assert Elia.Tool.approval(cd, %{"path" => "."}, %{}) == :never
  end
end
