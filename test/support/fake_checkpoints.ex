defmodule EliaWeb.FakeCheckpoints do
  @moduledoc """
  Stand-in for `Elia.Checkpoint` in recovery tests (`EliaWeb.Recovery`'s
  `:checkpoints` option). `list/1` returns what the test put under
  `:fake_checkpoints_list` in the process dictionary, or raises if unset;
  `rollback/1` always fails.
  """

  def list(_limit) do
    Process.get(:fake_checkpoints_list) || raise "list failed"
  end

  def rollback(_sha), do: {:error, "boom <b>"}
end
