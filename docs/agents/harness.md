# Harness and guardrails

Read this before editing `lib/`, `config/`, `test/`, `mix.exs` or `skills/`.

Specs: `specs/deployment.md`, `specs/hot-reload.md`, `specs/verification.md`, `specs/workspace-policy.md`, `specs/folder-skills.md`.

## What needs approval

- `skills/**` changes apply without asking, but a folder skill's tools always ask the user before running.
- Elixir changes (`lib/`, `config/`, `test/`) need the user's approval.

## The instructions the prompt carries

- The system prompt is the base prompt, then `AGENTS.md` (SKILL-10), then one section per skill (SKILL-5); `Elia.Skills.system_sections/2` builds it and `Elia.LLM.Context`'s breakdown sizes each piece. Measured in this tree: the base prompt ~150 tokens, `AGENTS.md` ~3.9k, the eleven skill sections ~4.4k, so `AGENTS.md` is the single biggest thing a chat reads every request.
- That text is **pinned by tests and specs**, so compressing it is not a free edit: `test/elia/self_modification_test.exs` (`the project's AGENTS.md carries the worktree recipe`) asserts ~13 exact phrases in `AGENTS.md`, `test/elia/skills_test.exs` the `bin/preview`/`ELIA_PREVIEW_THEME=dark`/`ELIA_PREVIEW_WIDTH=430` ones, and DEPLOY-28 to DEPLOY-30, VERIFY-11 (the timeout default and maximum), PREVIEW-9 and DONE-6 each pin a fact to `AGENTS.md`. The skill sections are pinned the same way by their own tests (`harness_test`, `shell_test`, `tasks_test`, `chats_test`, `working_directory_test`). Check both before cutting, and run the suite rather than judging the edit a docs one.
- The details behind a compressed bullet belong in this file: it is read on demand, where `AGENTS.md` is read every request.

## The live tree and a chat's own worktree

- The live tree (`Elia.Workspace.runtime_root/0`, `config :elia, :runtime_root`, default: where the server was started) is where the server runs, where the code reloader reloads and where Elia's data (`.elia`) lives (DEPLOY-2). It is also the workspace of every chat in Elia's own project: the file and shell tools resolve against it and `ctx[:workspace]` is it (DEPLOY-1, PROJ-12), and a jailed command is confined to it (ISOL-13).
- A chat in Elia's own project makes **its own** worktree before it changes anything (DEPLOY-28) — a spec draft, an `AGENTS.md` edit and a doc included, not only code — because the live tree has to stay clean: what a chat leaves uncommitted there is neither deployed nor, since DEPLOY-37, refused — the next deploy puts it aside in a git stash and goes on — so a draft or a stray edit left there simply leaves the tree the user is looking at, and turns up in `git stash list`. The worktree is `<live tree>/tmp/worktrees/<chat id>` — gitignored — on branch `chat/<chat id>` forked from the trunk `master`, with `deps`, `_build` and `assets/node_modules` copied into it (DEPLOY-29). Nothing creates it for the chat: the harness makes no worktree and no branch (DEPLOY-1), `Elia.Deploy` no longer has a `workspace/2` for a chat, and a chat's workspace is the live tree whether the tree is set up for deployment or not, so a change made outside a worktree would land in the tree that runs. `spawn_task` returns as soon as the child has started and the parent goes on working; several children run at once (SUBTASK-2, SUBTASK-27, SUBTASK-33), and since they all work in the live tree they must keep their work in their own worktrees and branches — the `chat/<sub-task id>` branch is what a parent merges (SUBTASK-23).
- A draft written in the live tree before the worktree existed is moved into the worktree when the worktree is made, and the live tree is put back as it was — `git checkout -- <paths>` for the tracked files and the files the draft added deleted — so `git status --porcelain` printed in the live tree says nothing. Check that before the commit and again before the merge. This is the mess that blocked the user's deploy more than once, and leaving it there still loses the change rather than failing loudly: a deploy stashes it out of the way (DEPLOY-37) and the file is gone from the tree the chat was reading.
- A sub-task forks the branch its brief names (its parent's, `chat/<parent id>`), so it sees what its parent has committed; its work stops at its own branch, for the parent agent to merge itself (SUBTASK-23, SUBTASK-25).
- The instruction a chat carries is in `AGENTS.md`'s worktree bullet (DEPLOY-28 to DEPLOY-30); the `self-modification` skill that carried a second copy of it is retired (SKILL-9, PROJ-17). A tree whose trunk `master` is checked out can't be pushed to (`git push . HEAD:master` is refused for a checked-out branch), so the worktree route can't finish there and the chat says so and asks the user rather than editing the live tree (DEPLOY-30). A deploy needs the tree set up for deployment (checked out on `live`, `master` at or ahead of it, DEPLOY-14, `Elia.Deploy.deployable/1`), which is what makes the worktree route work. Set it up once with `git checkout -b live` and `git branch master`; a tree whose trunk is behind `live` needs `git branch -f master live` once. Removing the finished chat's branch afterwards takes `git branch -D`, not `-d`: the live tree's HEAD is `live`, not `master`, so `-d` refuses with "not fully merged" even after `git push . HEAD:master` has landed the work. Check the work is in the trunk first (`git merge-base --is-ancestor "chat/$ELIA_CHAT_ID" master`), then `-D`.
- A chat's `shell` calls run in its chat's working directory (`cd`, WD-1), so **removing a worktree removes the directory that chat is working in**: after `git worktree remove`, every later command of that chat fails before it starts — `git -C <live tree> …` included, since a shell cannot start in a directory that is gone. Move the chat back first, with the `cd` tool and the live tree's absolute path, and let the next step run the commands.
- The `cd` tool takes effect from the **next** step (WD-9), so a `cd` and a command that needs it must not share a message: the command runs in the old directory. When the old one is the live tree, that is a command run against the live tree — a `git checkout -- <paths>` meant for the worktree put the live tree's files back instead. Keep scratch under the worktree's own `tmp/` rather than `/tmp`, too: each `shell` call gets a fresh `/tmp` of its own (ISOL-2), so a file copied there in one call is gone in the next.
- **Never** edit `lib/elia/harness.ex` or `lib/elia/workspace.ex` to weaken the guardrails.

## Reserving a requirement ID

- Before drafting a spec change, run `bin/reserve <PREFIX> <count>` (SPEC-19 to SPEC-25): it prints the IDs to draft with and reserves each by making an empty directory under `elia-reservations/` in the repository's git directory (`git rev-parse --git-common-dir`). For a chat that is the live tree's `.git`, shared with every worktree of the project, which is what makes the reservation one every chat reads (SPEC-21) and what keeps it out of `git status --porcelain` (SPEC-22).
- A chat's jailed command reaches that store only because the jail binds the repository's git directory behind a worktree's `.git` pointer file (ISOL-4) — and it does that only when the workspace is inside the runtime root. A probe run with `runtime_root` at the worktree itself takes the "another project" branch of `Elia.Shell`'s bind list and binds no git directory, so a jailed `git` there fails with `fatal: not a git repository` and a reservation quietly falls back to the corpus (SPEC-25). Point `runtime_root` at the live tree when testing this, as `Elia.CommandIsolationTest`'s chat-worktree describe block does.

## Tests

- Debugging the harness itself: every `shell` tool call gets a fresh `/tmp` and pid namespace of its own (ISOL-2), so a script one call writes is gone by the next — write the script and run it in the same command, and have it print what you need.
- A turn is not verified: nothing runs `mix test` for you at the end of a turn, and nothing is rolled back. Run the tests — `mix test`, or plain `mix precommit` (a command never inherits the server's `MIX_ENV`, ISOL-24) — before finishing a change; a deploy runs the full suite in the live tree again (DEPLOY-5). A change you judge safe without a run — a docs, spec or comment edit — may skip it, with a line in your last message saying why the skip was safe (`AGENTS.md`).

## Waiting on a sub-task

- `await_task` can outlast the harness's own request: in one chat both `await_task` and `ask_user` came back as "the harness crashed while running this tool" at the boundary, while the sub-task itself carried on untouched (a turn's end, a stop or a crash doesn't end one — SUBTASK-16). Polling survives that: a `shell` call of `sleep 280`, then `list_chats` with `children: true` for its `status`, and its `report.md` beside `brief.md` when it reaches `done`. It costs a round trip per few minutes, and nothing is lost either way, since the child commits on its own branch.
- Merging a child rewrites its commits, so after `git merge --ff-only chat/<child id>` and a rebase, `git branch -d chat/<child id>` refuses with "not fully merged": the child's branch tip is no longer an ancestor of yours. Check the work is in `master` (it is — the merge was a fast-forward) and delete with `-D`. Same for your own branch once `git push . HEAD:master` has landed it.

## Sub-tasks: what not to reintroduce

Compressed out of `AGENTS.md`'s sub-task bullets, which now keep the rule and the pointer. A sub-task is an ordinary chat whose chat is marked done or not, and nothing else about it is special, so none of these may come back:

- A task status vocabulary (`running`, `blocked`, `failed`, `unfinished`, `cancelled`): a task ends when its chat is marked done (`specs/subtasks.md`, SUBTASK-33), and its own chat's status is the only status there is (`EliaWeb.ChatStatus`).
- A per-task watcher, a registry of running children or a per-task entry (retired SUBTASK-28, SUBTASK-31): a parent lists its children with `list_chats`'s `children` (HIST-2, `Elia.Store.children/1`).
- A child-only step or time limit: a child runs under the same turn limits as any chat (`specs/turn-limits.md`).
- A `finish_task` tool: `mark_done` ends it (DONE-6), and `list_tasks` as a listing: `list_chats` with `children` is the listing.
- A parent-side record of a child's commit and files: `await_task` gives `{"task_id", "summary"}` and nothing else (SUBTASK-9), and what the parent merges is the child's own branch (SUBTASK-23).
- A brief or report kept anywhere but `.tasks/<n>/brief.md` and the `report.md` beside it, which are scratch and never committed (`.gitignore` holds `/.tasks/`).

## Recovery

- There is no checkpoint to roll back to (`specs/checkpoints.md`, retired): a chat's work is on its own branch, and a deploy refuses to load a tree whose suite or compile fails (DEPLOY-5, HOT-4). `/recover` is back for the failure that gate does not catch — a deploy that passes its suite and still leaves the UI unusable: plain HTML, no bundle and no JavaScript, putting the app back on a revision it has already run (RECOVER-10..RECOVER-15, DEPLOY-25, DEPLOY-26, `specs/recovery.md`).

## Deploying

- A deploy is the only thing that loads code into the running app (DEPLOY-8): a request recompiles and loads nothing, so edits stay invisible to the running app until a deploy. Browser live reload doesn't watch `lib/` either. Reload the page after a deploy to see UI changes.
- A hot reload keeps running state (DEPLOY-6), so a change that adds a *key* to a map a long-lived process holds — a session's `settings` map (SESS-41), a compaction state, task metadata — breaks every chat whose process was started before the reload: the new code reads a key the old state's map does not have. A `KeyError` on a field read is what it looks like, and a page that reads one on mount 500s for every chat with a live session (this happened with the network setting, `030e615`: `ChatLive`'s `snapshot.settings.network` took down `GET /c/<id>`). Read such a map with its defaults filled in under what the state holds (`SESS-47`, `Elia.Agent.Session.settings/1`) so an old state reads the new key at its default; a restart is safe without it, since the new code builds the sessions.
- **Merging your work into the trunk is your step; deploying is the user's.** When a change is done: commit it, rebase on `master` if the trunk has moved, then `git push . HEAD:master` — fast-forward only, so the trunk must be an ancestor (DEPLOY-13). `AGENTS.md` says it, and there is no skill that says it a second time (SKILL-9, PROJ-17). The harness never merges your branch. A spec ID you drafted is not reserved while you work: a chat that merged in the meantime may have taken it — a `DEPLOY-37` of mine landed as another chat's stash work and my unlanded requirement became `DEPLOY-40` — so after the rebase, check the IDs your commit adds against `master` and renumber your own. An ID that never reached the trunk was never anyone's, and one the trunk already carries is not yours to reuse.
- The user then deploys from the Settings page (`Elia.Deploy.deploy/1`, DEPLOY-5..DEPLOY-7): Elia runs the full test suite in the live tree, fast-forwards `live` to `master` (rolling it back if the tests fail, HOT-4) and loads the result — by "Hot reload", which recompiles and loads the live tree keeping running state (DEPLOY-6), or by "Restart", which stops the runtime system with a non-zero status so `bin/serve` starts it again on the deployed code in a clean process (DEPLOY-7, RESTART-1).
- A git process that is killed — the harness kills a command that times out — leaves its lock behind (`.git/HEAD.lock`, `.git/index.lock`), and every git call in that tree fails until the file is removed. A merge that got as far as writing the index and the working files before the lock stopped it leaves the tree looking dirty, as if someone had left uncommitted changes there — which the next deploy would put in the stash with the user's own (DEPLOY-37), or, before that, be refused for. A deploy undoes such a half-merge itself and names the lock file (DEPLOY-38, DEPLOY-39), so removing the lock once no git is running is what lets the next deploy through. The undo is `git read-tree --reset -u <sha>`: `git reset --hard` needs the very lock that stopped the merge.
- What a deploy actually did is in the live tree's record, `.elia/deploy.json` (DEPLOY-23, DEPLOY-2): `last` is the operation that ended — its `result.error` is the message the user saw — and `running` is the one in flight, `null` when no deploy is running, so a failed `last` under `running: null` is a deploy that finished badly and must be fixed, not one still to be waited out. The jail masks `.elia` (ISOL-6), so from inside a command the data dir lists as empty and reading the record takes a `jail: false` call; the Settings section reads it through `Elia.Deploy.last_deploy/1`.
- The Settings Deployment section also has a **Push** control, which sends
  `master` to `origin` (`Elia.Deploy.push/1`, DEPLOY-41 to DEPLOY-43): it is not
  a deploy — no step, no record entry, no rollback — and it is the one command
  Elia runs **unjailed** (`jail: false`, DEPLOY-42), because what it needs is
  outside a command's jail on purpose (a credential helper, an SSH key,
  `~/.gitconfig`, ISOL-5). A jailed push could never authenticate; the command
  is fixed and runs with `GIT_TERMINAL_PROMPT=0`, so a missing credential comes
  back as git's message instead of hanging.
- Make all the edits for a change first, run the tests, then commit and merge — a multi-file edit is on the chat's branch, so the running app can't be broken halfway. Don't expect the change to be live until the user has deployed it.
- Not needed for `skills/**` (use `reload_skills`) or for tests and docs.
- A UI change — a template, `assets/css/`, a hook — can be seen *before* it is deployed: `bin/preview` in the chat's workspace screenshots its own code in a real headless browser, in the test env, and prints a Markdown image link per page (PREVIEW, `specs/ui-preview.md`). Nothing is deployed, no API key is involved and no live data is read; the pictures land in the gitignored `tmp/preview/`, and the running app serves a chat's own ones at `/preview/<chat id>/<file>` (PREVIEW-7). Paste the links into a reply to show the user. Preview in dark mode at a mobile width by default: `ELIA_PREVIEW_THEME=dark ELIA_PREVIEW_WIDTH=430 bin/preview …` (PREVIEW-3, PREVIEW-13). `/settings`'s Deployment section renders only on a tree set up for deployment (CONF-19, DEPLOY-14), and a chat's own worktree is on `chat/<id>` rather than `live` — so a preview of `/settings` shows that section's warning and no deploy control at all. A picture of that section needs a live tree of its own: a throwaway preview test that points `:runtime_root` at `LiveTree.create/0`, clicks `#deployment summary` and screenshots it, deleted before the commit (a picture the chat wants to keep goes in the live tree's own `tmp/preview/`, which is served after a worktree is removed, PREVIEW-7). A chat's worktree has no `origin` remote of its own, so a picture of the Push control needs `LiveTree.origin/2` to give the throwaway tree a bare remote outside it (DEPLOY-43), and the `#deploy-origin` line only counts commits once something has been pushed from the tree — one `Deploy.push/1` in the test's setup. `PhoenixTest.Playwright.evaluate/3` returns the *connection* and hands the value to a function, so read a value out of the page with `evaluate(conn, js, fn value -> send(self(), {:value, value}) end)` and `assert_receive`.

## Editing a file

- `git commit -m` takes **one** argument: give a multi-line message through a heredoc, `git commit -F - <<'EOF' … EOF`. A bare newline inside the command ends it there and the rest of the message runs as its own command — the commit lands with a truncated message and the shell reports `No such file or directory` for the line after it. `git commit --amend -F - <<'EOF'` fixes the message without a second commit.


There are no file tools, so a change is a `shell` command (SHELL-15). Two
things that cost a round trip each:

- `/tmp` belongs to the call, not to the chat: a scratch file written in one
  `shell` call is gone by the next (`ISOL-2`, `specs/command-isolation.md`), so
  write a patch and apply it in the *same* command — never in two.
- A hand-written unified diff is easy to get wrong, and `patch` reports it
  badly: `malformed patch` is your line counts, `Hunk #N FAILED` is your
  context, and a multi-hunk patch stops at the first hunk it cannot place,
  leaving the rest silently out. A hunk that reports success *with fuzz*
  (`Hunk #1 succeeded at 27 with fuzz 2`) has matched the wrong lines: it
  applied somewhere near them and dropped or duplicated one, so treat fuzz as a
  failure, re-read the block, and delete the `<file>.orig` it leaves behind. For a multi-line block, prefer an
  exact-string replacement that fails when the text matches zero times or
  twice — `python3 - <<'PY'` with `assert s.count(old) == 1`, which is in the
  jail — and check the result with `git diff`.
- A replacement written from `python3` fails to match when the old text differs by
  a byte, and one written from `perl` fails when the old text holds an `@`: a perl
  string in double quotes interpolates, so a source line holding the module
  attributes `@scan` or `@list_max` has to be written as `\@scan` to match it. The
  file's own text is not a template.
- Quoting a block to replace it in a later call means quoting the file as
  `mix format` last left it: a formatter run reflows exactly the long line you
  are aiming at, so re-read the block after formatting rather than trusting the
  text from before it.

## Adding a skill

Prefer a folder skill over changing Elixir code.

1. Create `skills/<name>/SKILL.md` with frontmatter (`name`, `description`) followed by instructions.
2. Optionally add `skills/<name>/tools.json` with script-backed tools and the scripts they run. The format is documented in `lib/elia/skills/folder.ex`.
3. Call `reload_skills` and fix any reported errors. New tools are available from the next step.
4. Tool input arrives in `$ELIA_INPUT` (JSON) and `$ELIA_ARG_<FIELD>`. Never splice it into the command.

Folder skills don't need a spec. Built-in skills live in `lib/elia/skills/` and do.

Adding or removing a tool of a built-in skill ripples past the skill: the APPR-7
table in `specs/tool-approval.md` must name every built-in tool with the
approval it declares, or `test/elia/tool_approval_test.exs` fails, and the tool
names a session is offered are pinned in `test/elia/agent_test.exs` and in the
skill's own test (`test/elia/skills/chats_test.exs` for `chats`).

## Showing a project's HTML

A file opened in the Files page can never run its own script: an HTML document's
raw view is served under `sandbox` with scripting off (EXPL-24, EXPL-30), which
deliberately keeps workspace script out of this app's origin. That is why a
project's built page — anything from Vite, and any single-file build with a
`<noscript>` note in it — shows "needs JavaScript" there, in every browser: it
is the response's policy, not the browser, and `<noscript>` renders whenever a
context has scripting disabled.

To look at a project's build, use the preview host (`specs/preview-host.md`,
`SERVE`): `ELIA_PREVIEW_HOST=<host>` serves one project's files at a hostname of
their own — `/` is the open project (`Elia.Projects.default/0`), `/<slug>/…` is
any project — over the app's own port and with no policy of its own. Behind the
Cloudflare tunnel one public hostname pointing at `http://localhost:7000` covers
every project, present and future. Unset, the feature is off and nothing
changes. The route reads no session and never serves the app, so it is exactly
as reachable as the app is.

## Listing chats

`Elia.Store.list/2` reads every saved chat (`all_entries/0`), keeps the ones a
`where:` function keeps, and only then takes the limit — so a limit caps what is
returned, not what is read, and a `where:` over a store of any size costs a read
per saved chat. It is a listing, not a query: `Elia.Store.entry/1` is the one that
reads a single chat (`listed/1` on its meta file, so the full text is not decoded
unless it is asked for). Whoever derives something over every chat — the
dashboard's cards (DASH-3), the header's active chats control (ACTIVE-2, ACTIVE-3)
— reads with a bound of its own (1000) and does it again on each activity event
it follows.

One project's chats are the ones `Elia.Projects.chats_of/1` keeps — the predicate
`Store.list/2`'s `where:` takes (PROJ-31, STORE-52) — and it is the predicate to use
rather than comparing a chat's `project_id` yourself: a chat with no `project_id` and
one whose project has been deleted both belong to Elia's own project (PROJ-9), which
`Elia.Projects.chat_project_id/2` also resolves a listed chat through. The three
`chats` tools list, read and search only the chat's own project's chats (HIST-11),
which is where a scoped search gets its candidates.

## Measuring search cost

A search's cost is decided by the shape of an index entry, so measure it rather
than reason about it. `search_chats` cost the whole corpus per query term while
`Elia.Store.Index` kept a table of every chat's tokens: an absent term cost what a
present one did, which is what a scan looks like, and at 300 chats / 19 MB of text
a term was ~0.5 s, three terms ~1.8 s, the cold build ~3 s, and the index 189 MB of
ETS (600 chats / 37 MB: ~1.1 s a term, ~4.4 s, ~10 s). Now that an entry holds each
message's folded text and `Index.term/1` searches it with one compiled pattern,
the same corpus measures ~11-17 ms a term, ~90 ms for three, ~0.8 s cold, 1.1 MB of
table plus 20 MB of off-heap text.

To re-measure: in a chat's own worktree, save chats with `Elia.Store.save/3` against
a `:runtime_root` of your own under `System.tmp_dir!()`, then time
`Elia.Store.Index.refresh/1`, `Index.term/1` and the `search_chats` run of
`Elia.Skills.Chats.tools()`. Run it with `mix run --no-start`: plain `mix run` starts
the app and binds the endpoint port the live server already holds, and the script
must then start what it needs itself — `:telemetry`, `Elia.Store.Cache` and
`Elia.Store.Index` by hand, since without the last two the cache never hits and a
warm search decodes every chat again. Count the index's memory as
`:ets.info(table, :memory)` *plus* `:erlang.memory(:binary)`: a binary over 64 bytes
lives off-heap and is only referenced by the table, so the table's own figure can
look tiny while the text it holds is the much larger number beside it.

## Reaching the running server

`bin/serve` starts the dev server as a named node (`elixir --sname elia -S mix
phx.server`), so an *unjailed* chat can call the app's own API in the running
server instead of writing its files behind its back. The node is
`elia@<short hostname>` (`:net_adm.names/0` names it, `hostname -s` gives the
host), and a throwaway node reaches it with no cookie of its own:

    elixir --sname "eliactl$RANDOM" -e ':rpc.call(:"elia@bee", Code, :eval_string, [code], 120_000)'

What this is for is the bookkeeping the harness's own tools don't reach: marking
a chat done from another chat. `mark_done` touches only the chat it runs in, and
a bulk action is out of scope (`specs/chat-done.md`) — but `Elia.Agent.set_done/2`
does any chat, and it is exactly what that chat's own done control calls. Three
things to know:

- `set_done/2` needs a live session, so `Elia.Agent.ensure_started/1` first.
  Starting one *resumes* a turn the chat's file records (RESUME-2), so read
  `Elia.Store.load_turn/1` before starting anything, and terminate the session
  again afterwards (`DynamicSupervisor.terminate_child/2`) so the tree is left
  as it was.
- A chat with no messages saves no flag (SESS-14, SESS-35), so an empty "New
  chat" can't be marked done. Neither can a file the store reads as a chat with
  no history (STORE-48) — one holding `Elia.LLM.Message` structs from before
  that module was renamed, say: those are listed as open "New chat" rows.
- Never edit `.elia/sessions/*.term` by hand: a chat's file is written from its
  session's state, so that chat's next save takes the edit off again.

Two things that job got wrong once: `list_chats` shows only a page (the newest
100) where the store held 338 chats, so the number to trust is the header's active
chats count (`EliaWeb.ActiveChats`, ACTIVE-3) or `Elia.Store.list/2` itself, never
a listing's page; and an id transcribed from a dump by hand can be a typo, which
marks nothing and says nothing — `ensure_started/1` starts a session for a chat
with no file and `set_done/2` then has nothing to save. Mark the ids read out of
`Elia.Store.list/2` inside the server rather than ids typed into a command.

### Marking a chat done re-dates it, so the list jumps

`Elia.Store.save/3` writes `created_at: created_at(id) || now`, and `created_at/1`
is nil when the store can't read a chat's file — so a chat whose file it reads as
"a chat with no history" (STORE-48) gets *today* as its creation date the moment
anything saves it. The chat list sorts by `created_at` and shows its relative time
(`lib/elia_web/chat_list.ex`, `Elia.Store.all_entries/0`), so marking 50 such chats
done put all 50 at the top as "just now". `updated_at` is bumped too and no screen
reads it. Repair the dates, don't edit the files: assemble each one from the
sources that survived — a message's `meta.at`, the chat's `.timing` file, a
checkpoint commit (`git log --all`, "before agent turn <chat id>-<n>", which is
how the old sub-task chats are dated) and the mtime of `.elia/worktrees/<id>` —
then write it with `Elia.Store.update/2`, which keeps the rest of the file
(STORE-43). A chat whose file was never written has no `created_at` to lose.
`Enum.min/max` on `DateTime` structs is not chronological (struct term order), so
compare with `DateTime.to_unix/2`.
