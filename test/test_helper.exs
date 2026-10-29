# Scratch workspace for file, checkpoint and session tests (see config/test.exs).
root = Application.fetch_env!(:elia, :workspace)
File.rm_rf!(root)
File.mkdir_p!(root)
{_, 0} = System.cmd("git", ["init", "--quiet"], cd: root)

ExUnit.start()
