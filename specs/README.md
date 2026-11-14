# Specs

Elia is spec-driven: each feature has a Markdown spec here that describes the
behaviour it must have. The spec is the source of truth; code and tests follow
it.

## Workflow

1. **Change the spec first.** New feature: add a file. Changed behaviour: edit
   the requirements it affects. Keep the change reviewable on its own.
2. **Get the spec approved.** Stop and ask the user to approve the drafted spec
   before implementing it, unless the user explicitly asked to skip the spec
   approval for this change. Wait for that approval before touching code or
   tests.
3. **Implement** the change in code.
4. **Test** each new or changed requirement. Mention the requirement ID in the
   test name or a comment (e.g. `# SHELL-3`) so the two can be traced.
5. **Keep them in sync.** If code and spec disagree, one of them is a bug: fix
   the code, or update the spec deliberately.

## Format

Each spec follows the same shape:

```markdown
# <Feature name>

Status: Implemented | Draft | Planned | Retired

<One paragraph: what the feature is and why it exists.>

## Requirements

- **<PREFIX>-1** <One testable statement, in present tense.>
- **<PREFIX>-2** ...

## Configuration        (optional)
## Terms                (optional glossary)
## Out of scope         (optional)
## Stored data          (when a change alters a stored shape)
## Implementation       (modules that implement it)
## Tests                (test files that cover it)
```

Requirement IDs are stable: never renumber or reuse one. Retire a requirement
by striking it through (`~~**X-4** ...~~ Removed: <reason>`) rather than
deleting it.

## Rules

`specs/spec-hygiene.md` (SPEC) owns the rules below; they are what keeps the
corpus coherent, and `test/elia/spec_hygiene_test.exs` fails the suite on the
ones a machine can decide. A violation is fixed in the change that introduces
it.

- **Identity.** A requirement is `<PREFIX>-<n>`, the prefix this file's index
  row gives it (SPEC-1). Every ID names exactly one requirement (SPEC-2); an ID
  is never renumbered or reused, and a requirement added later takes the next
  unused number of its prefix (SPEC-3). Retiring keeps the number and spends it
  forever (SPEC-4).
- **Retirement.** A retired requirement stays where it is, struck through
  (`~~`), keeps its ID and says why in the same entry, after `Retired:`,
  `Removed:` or `Superseded by`; a spec whose requirements are all retired says
  `Status: Retired` (SPEC-5), and its index row says so (SPEC-7).
- **Status.** The `Status:` line is exactly one of `Implemented`, `Draft`,
  `Planned` or `Retired` — the one word and nothing else. What the status needs
  to explain goes on the lines below it (SPEC-6).
- **Index.** Every file in `specs/` other than this one, and every file in
  `specs/plans/`, is listed here: a spec as a row of the table with its prefix,
  a plan under `## Plans` (SPEC-8). Every row's link resolves, and its prefix is
  the one the file's IDs use (SPEC-9).
- **Shape.** A spec is a title, a `Status:` line, a paragraph saying what the
  feature is and why, and `## Requirements`. The only other sections are
  `Configuration`, `Terms` (a glossary), `Out of scope`, `Stored data`,
  `Implementation` and `Tests`;
  subheadings within them are free (SPEC-10). A change that alters a shape that
  outlives the process says which it is in `## Stored data` — backward
  compatible, or needing migration (SPEC-11).
- **A requirement** is one testable statement of behaviour, in the present
  tense (SPEC-12), and holds only that statement: rationale, history,
  incidents, line numbers, chat ids, worktree names and measured timings belong
  in the intro, the section's prose, a doc or the commit (SPEC-13).
  `Out of scope` lists what is deliberately not required, and no requirement is
  defined in it (SPEC-14).
- **Cross-references.** A `PREFIX-n` is one some spec defines — a retired
  requirement counts as defined — or a bare prefix, or a range within one
  prefix; never a number that names a different requirement than the one meant
  (SPEC-15).
- **Traceability.** Every requirement is accounted for by a test file that
  exists, named in a `## Tests` section, or by a `No test:` line in its own
  spec's section saying why; a retired requirement is exempt, and every path a
  section names under `test/` is there (TRACE,
  `specs/test-traceability.md`). `test/elia/spec_tests_test.exs` fails the
  suite on the rest.
- **The lint** is `test/elia/spec_hygiene_test.exs` (SPEC-16, SPEC-17): it reads
  `specs/**/*.md` and nothing else, so it runs in `mix test`, `bin/test` and
  `mix precommit`. One statement per requirement, rationale inside one, required
  behaviour under `Out of scope` and whether a stored shape needs migration are
  review rules, not lint failures (SPEC-18).

## Index

| Spec | Prefix | Summary |
| --- | --- | --- |
| [Projects](projects.md) | `PROJ` | Project folders; chats belong to a project, which supplies its own `AGENTS.md` and skills |
| [Dashboard](dashboard.md) | `DASH` | `/` is a home screen: what needs you, where you left off, recent chats, projects, the machine and the deploy state |
| [Chat UI](chat-ui.md) | `UI` | LiveView chat: transcript, Markdown, streaming, approvals, chat list |
| [Chat titles](chat-titles.md) | `TITLE` | A chat's own title, set by the agent's `set_title` tool; the first-message derivation stays as the fallback |
| [Chat done](chat-done.md) | `DONE` | A chat can be marked done (with it in the saved chat), shown as its status and skipped by the chat list's resume; a message reopens it |
| [Image viewer](image-viewer.md) | `IMG` | An image in the transcript opens over the chat, closable by its own button or the back button, never in a new tab |
| [Chat settings](chat-settings.md) | `CSET` | The per-chat settings page: model, auto-approval, jail, limits and compaction options |
| [Turn limits](turn-limits.md) | `LIMIT` | Per-chat step limit, time budget and whether a limit pauses the turn; reaching one pauses by default, and the transcript says so |
| [Context indicator](context-indicator.md) | `CTX` | Context size and window shown per chat, with a clickable breakdown |
| [Compaction](compaction.md) | `COMPACT` | Keeps the full transcript but sends the model a smaller request view; pruning, a ledger and incremental summaries |
| [Client sessions](client-sessions.md) | `CLIENT` | Sessions page listing open tabs with IP, browser and page |
| [System dashboard](system-dashboard.md) | `SYS` | CPU, memory, disks, network, load and VM stats |
| [Log viewer](log-viewer.md) | `LOG` | In-memory capture of the server's logs, on a `/logs` page |
| [File explorer](file-explorer.md) | `EXPL` | Read-only workspace browser with a plain-text file viewer |
| [File links](file-links.md) | `FLINK` | A file the agent mentions in a reply or on a tool card links to the Files page |
| [Agent sessions](agent-sessions.md) | `SESS` | One process per conversation; turns, status, stop, events |
| [Interrupted turns](interrupted-turns.md) | `INTR` | A turn the app restarted during is recorded, reported in the transcript and flagged in the chat list |
| [Stopped turns](stopped-turns.md) | `STOP` | A turn that ends without the model finishing — a limit, a provider error, a refusal, a crash, the user's stop — writes why into the transcript |
| [Agent loop](agent-loop.md) | `LOOP` | Model ↔ tool loop, limits, error handling |
| [Turn retries](turn-retries.md) | `RETRY` | A model call that failed transiently — a timeout, a dropped connection, an overloaded provider — is asked again after a wait, so the turn carries on by itself |
| [Step timing](step-timing.md) | `TIME` | Every loop step recorded beside the chat with its stamps, durations and usage, so a review of where time goes measures a turn instead of inferring it |
| [Tool approval](tool-approval.md) | `APPR` | Which tool calls pause for the user, how decisions apply, per-chat auto-approval |
| [Structured user input](user-input.md) | `ASK` | `ask_user` puts a question with options to the user as a card of buttons; the turn waits and the answer comes back as the call's result |
| [Conversation persistence](persistence.md) | `STORE` | Saving, loading and listing chats |
| [Reading earlier chats](chat-history.md) | `HIST` | `list_chats`, `read_chat` and `search_chats`: the agent can consult chats other than the one it runs in, jailed or not |
| [LLM providers](llm-providers.md) | `LLM` | Provider-neutral messages; Anthropic, OpenRouter and a local llama.cpp server backends |
| [llama.cpp local provider](llamacpp-provider.md) | `LOCAL` | A local `llama-server` as a third provider: no API key, and Elia starts and stops it from a `.gguf` |
| [Model selection](model-selection.md) | `MODEL` | Model picker, provider catalogs, per-turn selection |
| [Settings and API keys](settings.md) | `CONF` | On-disk settings database, API key entry and checks, and the Deployment section: what a deploy is doing, what it did, and going back |
| [Skills registry](skills.md) | `SKILL` | Built-in and folder skills, system prompt, reload |
| [Folder skills](folder-skills.md) | `FOLDER` | `skills/<name>/` with `SKILL.md` and script tools |
| [Shell tool](shell-tool.md) | `SHELL` | Running OS commands |
| [Process priority](process-priority.md) | `PRIO` | Every process Elia spawns runs below the server's own CPU and I/O priority, so the UI and the agent loops stay responsive while a compile or a test suite runs |
| [Command isolation](command-isolation.md) | `ISOL` | Commands run in a bubblewrap jail by default: the settings database, saved chats and credentials aren't reachable; per-chat switch |
| [Terminal](terminal.md) | `TERM` | A chat's own terminal: a pty (tmux in control mode) with xterm.js in the browser, jailed and niced like a command, on `/c/:id/terminal` |
| [File tools](file-tools.md) | `FILE` | `read_file`, `write_file`, `edit_file`, `list_files`, `search_files`, `delete_file` |
| [Workspace policy](workspace-policy.md) | `WS` | Path classes: extension, core, protected, outside |
| [Checkpoints](checkpoints.md) | `CKPT` | Retired: per-chat worktrees replaced snapshots and rollback |
| [Test runs](verification.md) | `VERIFY` | Running `mix test` in the workspace: the deploy's gate calls `Elia.Harness.run_tests/3`, a chat runs the suite through the shell |
| [Parallel test suite](test-suite.md) | `SUITE` | `bin/test` runs the suite as concurrent partitions with their own scratch state; `mix precommit` uses it |
| [Hot reload](hot-reload.md) | `HOT` | Hot reload: the soft deploy mode, loading tested code into the running server |
| [Guarded files](guarded-files.md) | `GUARD` | Retired: per-chat worktrees replaced it; the "never reload on request" rule moved to Deployment |
| [Auto reconnect](auto-reconnect.md) | `CONN` | Page reconnects or reloads itself when the LiveView socket dies |
| [Installable web app](pwa.md) | `PWA` | Manifest, icons and service worker so the app installs on a phone |
| [Push notifications](push-notifications.md) | `PUSH` | Web Push: a chat that needs you notifies your device through the browser's push service |
| [Recovery](recovery.md) | `RECOVER` | `/recover`: plain HTML that needs none of the tree's front end, sending the app back to a revision it has run when a deploy has broken the UI |
| [Sub-tasks](subtasks.md) | `SUBTASK` | `spawn_task` hands work to a child chat; `list_tasks`/`await_task` report its status and result; `finish_task` returns a structured result |
| [Auto restart](auto-restart.md) | `RESTART` | `bin/serve` restarts the server after a crash, with backoff; the app is permanent; systemd user service |
| [Deployment](deployment.md) | `DEPLOY` | Per-chat worktrees forked from the trunk `master`; a deploy from Settings brings `master` to `live` by hot reload or restart, reports its steps, checks the bundle it built, and can be undone |
| [Worktree build cache](worktree-build-cache.md) | `BUILD` | A chat's worktree is seeded with a private copy of the live tree's build output, so its first compile reuses the dependencies' artifacts instead of building them from source |
| [Real-browser tests](browser-tests.md) | `BROWSER` | PhoenixTest + Playwright headless Chromium tests for JavaScript, websocket and layout; excluded from the default run |
| [UI preview](ui-preview.md) | `PREVIEW` | `bin/preview` screenshots the chat's own code with the browser layer, before a deploy; the chat shows the pictures |
| [Interaction feedback](interaction-feedback.md) | `FEED` | Every control shows a pressed state at once and reads as working while the server has not replied |
| [Spec hygiene](spec-hygiene.md) | `SPEC` | The rules that keep `specs/` coherent, and the lint that fails the suite on the ones a machine can decide |
| [Test traceability](test-traceability.md) | `TRACE` | Every requirement is accounted for by a test file that exists or by a `No test:` line saying why, and a lint keeps it true |

## Plans

A plan is not a spec: it is a working document with no requirement IDs, for work
whose requirements are written later.

- [Sub-agents](plans/subagents.md) — the multi-phase plan `specs/subtasks.md` implements: phases 1 to 3 done, phase 4 (concurrent sub-tasks) and phase 5 (read-only children) still to come
