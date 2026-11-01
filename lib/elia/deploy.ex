defmodule Elia.Deploy do
  @moduledoc """
  Bringing a chat's code into the running app (spec: `specs/deployment.md`).

  A deploy is the only thing that loads code into the running app; a request
  never does (DEPLOY-8). The hard deploy mode is a restart (`bin/serve`); the
  soft one is `Elia.Harness.hot_reload/1`.
  """

  @doc """
  The endpoint's code reloader. It never reloads on a request (DEPLOY-8): a
  merge into the live tree stays inert until a deploy loads it.

  Kept as a no-op rather than dropping the plug, because `hot_reload` still
  calls `Phoenix.CodeReloader.reload/1` directly (HOT-5).
  """
  def reload(_endpoint, _opts \\ []), do: :ok
end
