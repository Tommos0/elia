defmodule Elia.Skills.SelfModification do
  @moduledoc """
  Changing Elia's own code, behind the guardrails (PROJ-17, SKILL-9): the
  approval rules, merging the chat's branch into the trunk and the spec-driven
  workflow. A chat has this skill only when its project is Elia's own; other
  projects get `Elia.Skills.Harness` alone (PROJ-16).

  It carries no tools of its own: what it needs done is done with `run_tests`
  (`Elia.Skills.Harness`) and the shell.
  """

  @behaviour Elia.Skill

  @impl true
  def name, do: "self-modification"

  @impl true
  def description, do: "Change Elia's own code safely, behind the guardrails."

  @impl true
  def instructions do
    """
    Changing Elixir code (`lib/`, `config/`, `test/`) needs the user's approval. \
    Nothing verifies a turn and nothing is rolled back, so run `run_tests` (or \
    `MIX_ENV=test mix precommit`) yourself before finishing a change.

    A chat in this project works in its own git worktree, not in the tree the \
    server runs from (DEPLOY-1). Running code therefore never changes while you \
    edit: an Elixir change reaches the running app only through a deploy, which \
    the user runs from Settings — it brings the trunk `master` to `live` and \
    then hot reloads or restarts the server (DEPLOY-5–DEPLOY-7). So make all the \
    edits for a change first, run `run_tests`, then commit your work and merge \
    your branch into the trunk yourself: rebase on `master` if it has moved, \
    then `git push . HEAD:master`, which is fast-forward only (DEPLOY-13). That \
    is where your part ends — tell the user the change is ready and let them \
    deploy it. Never edit \
    `lib/elia/harness.ex` or `lib/elia/workspace.ex` \
    to weaken the guardrails.

    This project is spec-driven: each feature has a spec in `specs/` with \
    numbered requirements (workflow and index in `specs/README.md`). Before \
    changing Elixir code, update the affected spec or add one for a new feature, \
    then implement it and cite the requirement IDs you touched in your tests \
    (e.g. `# SHELL-3`). Never renumber or reuse requirement IDs.

    A UI change — a template, `assets/css/`, a hook or another client-side file \
    — is invisible to the user until they deploy it, so show them what it looks \
    like: run `bin/preview` in the workspace (it can take seconds to a minute the \
    first time, because it builds assets and starts a browser, so give the \
    `shell` call a longer `timeout_seconds`), and put the Markdown image links \
    it prints into your reply. That is a preview: the workspace's own code in a \
    real headless browser, in the test env, with no deploy and no API key \
    (`specs/ui-preview.md`). Pictures of the pages you changed are the useful \
    ones — `bin/preview /files` or `bin/preview @chat`; check the "page errors" \
    it reports, too.
    """
  end

  @impl true
  def tools, do: []
end
