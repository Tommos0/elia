defmodule Elia.InstallServiceTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)

  # A fake systemctl that logs its arguments, one call per line.
  defp fake_systemctl!(dir) do
    path = Path.join(dir, "fake-systemctl")
    File.write!(path, "#!/bin/sh\necho \"$*\" >> '#{dir}/calls'\n")
    File.chmod!(path, 0o755)
    path
  end

  defp install(dir, args \\ [], opts \\ []) do
    root = Keyword.get(opts, :root, @root)

    System.cmd("sh", [Path.join(root, "bin/install-service") | args],
      env: [
        {"XDG_CONFIG_HOME", Path.join(dir, "config")},
        {"SYSTEMCTL", fake_systemctl!(dir)},
        {"PATH", "/opt/elixir/bin:/usr/bin:/odd%path"}
      ],
      stderr_to_stdout: true
    )
  end

  defp unit(dir), do: File.read!(Path.join(dir, "config/systemd/user/elia.service"))
  defp calls(dir), do: dir |> Path.join("calls") |> File.read!() |> String.split("\n", trim: true)

  test "the template is a user unit that runs bin/serve (RESTART-8)" do
    template = File.read!(Path.join(@root, "deploy/elia.service"))

    assert template =~ "WorkingDirectory=@ROOT@"
    assert template =~ "ExecStart=@ROOT@/bin/serve"
    assert template =~ "Environment=PATH=@PATH@"
    assert template =~ "Environment=MIX_ENV=dev"
    assert template =~ "EnvironmentFile=-%h/.config/elia/env"
    assert template =~ "Restart=on-failure"
    assert template =~ "KillMode=mixed"
    assert template =~ "WantedBy=default.target"
  end

  test "renders the unit and enables it (RESTART-9)", %{tmp_dir: dir} do
    {out, 0} = install(dir)

    unit = unit(dir)
    assert unit =~ "ExecStart=#{@root}/bin/serve"
    assert unit =~ "WorkingDirectory=#{@root}\n"
    assert unit =~ "Environment=PATH=/opt/elixir/bin:/usr/bin:/odd%%path\n"
    refute unit =~ "@ROOT@"
    refute unit =~ "@PATH@"
    assert out =~ "systemctl --user start"

    assert calls(dir) == ["--user daemon-reload", "--user enable elia.service"]
  end

  test "--now enables and starts in one step (RESTART-9)", %{tmp_dir: dir} do
    {_, 0} = install(dir, ["--now"])

    assert calls(dir) == ["--user daemon-reload", "--user enable --now elia.service"]
  end

  test "refuses a project path that needs escaping (RESTART-10)", %{tmp_dir: dir} do
    root = Path.join(dir, "my root")
    File.mkdir_p!(Path.join(root, "bin"))
    File.mkdir_p!(Path.join(root, "deploy"))
    File.cp!(Path.join(@root, "bin/install-service"), Path.join(root, "bin/install-service"))
    File.cp!(Path.join(@root, "deploy/elia.service"), Path.join(root, "deploy/elia.service"))

    {out, status} = install(dir, [], root: root)

    assert status != 0
    assert out =~ "contains whitespace"
    refute File.exists?(Path.join(dir, "config/systemd/user/elia.service"))
    refute File.exists?(Path.join(dir, "calls"))
  end
end
