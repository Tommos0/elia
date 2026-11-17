defmodule Elia.Skills.SelfModification do
  @moduledoc """
  Changing Elia's own code, behind the guardrails (PROJ-17, SKILL-9): the
  approval rules, merging the chat's branch into the trunk and the spec-driven
  workflow. A chat has this skill only when its project is Elia's own; other
  projects get `Elia.Skills.Harness` alone (PROJ-16).

  It carries no tools of its own: what it needs done is done with the shell.
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
    Nothing verifies a turn and nothing is rolled back, so run the tests \
    yourself — `mix test`, or plain `mix precommit` (no command inherits the \
    server's `MIX_ENV`, so the alias's `preferred_envs` picks `test`, ISOL-24) — \
    before finishing a change, and give a suite run a longer `timeout_seconds` \
    than the shell's default: a first run in a fresh worktree compiles deps and \
    app before its first test.

    A chat in this project works in the project's folder — the live tree the \
    server runs from (DEPLOY-1) — so don't change code in it. Make yourself a \
    worktree first and work there, on your own branch:

    ```sh
    mkdir -p tmp/worktrees
    git worktree add -b "chat/$ELIA_CHAT_ID" "tmp/worktrees/$ELIA_CHAT_ID" master
    cp -a deps _build "tmp/worktrees/$ELIA_CHAT_ID/"
    [ -d assets/node_modules ] && cp -a assets/node_modules "tmp/worktrees/$ELIA_CHAT_ID/assets/"
    cd "tmp/worktrees/$ELIA_CHAT_ID"
    ```

    `$ELIA_CHAT_ID` is your chat's id, which every `shell` call is given \
    (SHELL-14). The two copies are what makes the first command in that worktree \
    quick: without them every dependency is fetched and compiled from source and \
    the browser bundle is built from nothing — minutes, every time; with them \
    the first compile is warm. A sub-task forks the branch its brief names (its \
    parent's), and stops at its own branch for its parent to merge.

    Running code never changes while you edit in there: an Elixir change reaches \
    the running app only through a deploy, which \
    the user runs from Settings — it brings the trunk `master` to `live` and \
    then hot reloads or restarts the server (DEPLOY-5–DEPLOY-7). So make all the \
    edits for a change first, run the tests in the worktree, then commit your \
    work and merge your branch into the trunk yourself: rebase on `master` if it \
    has moved, then `git push . HEAD:master`, which is fast-forward only \
    (DEPLOY-13). Then remove the worktree (`git worktree remove \
    tmp/worktrees/$ELIA_CHAT_ID`, from the live tree, then `git branch -d \
    chat/$ELIA_CHAT_ID`) and tell the user the change is ready and let them \
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
    it reports, too. Preview in dark mode at a mobile width by default \
    (`ELIA_PREVIEW_THEME=dark` with `ELIA_PREVIEW_WIDTH=390`), and take a light \
    or desktop picture as well only when the change is about that.
    """
  end

  @impl true
  def tools, do: []
end
