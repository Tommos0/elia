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
## Out of scope         (optional)
## Implementation       (modules that implement it)
## Tests                (test files that cover it)
```

Requirement IDs are stable: never renumber or reuse one. Retire a requirement
by striking it through (`~~**X-4** ...~~ Removed: <reason>`) rather than
deleting it.

## Index

| Spec | Prefix | Summary |
| --- | --- | --- |
| [Projects](projects.md) | `PROJ` | Project folders; chats belong to a project, which supplies its own `AGENTS.md` and skills |
| [Chat UI](chat-ui.md) | `UI` | LiveView chat: transcript, Markdown, streaming, approvals, chat list |
| [Context indicator](context-indicator.md) | `CTX` | Context size and window shown per chat, with a clickable breakdown |
| [Compaction](compaction.md) | `COMPACT` | Keeps the full transcript but sends the model a smaller request view; pruning, a ledger and incremental summaries |
| [Client sessions](client-sessions.md) | `CLIENT` | Sessions page listing open tabs with IP, browser and page |
| [System dashboard](system-dashboard.md) | `SYS` | CPU, memory, disks, network, load and VM stats |
| [Log viewer](log-viewer.md) | `LOG` | In-memory capture of the server's logs, on a `/logs` page |
| [File explorer](file-explorer.md) | `EXPL` | Read-only workspace browser with a plain-text file viewer |
| [Agent sessions](agent-sessions.md) | `SESS` | One process per conversation; turns, status, stop, events |
| [Agent loop](agent-loop.md) | `LOOP` | Model ↔ tool loop, limits, error handling |
| [Tool approval](tool-approval.md) | `APPR` | Which tool calls pause for the user, how decisions apply, per-chat auto-approval |
| [Conversation persistence](persistence.md) | `STORE` | Saving, loading and listing chats |
| [LLM providers](llm-providers.md) | `LLM` | Provider-neutral messages; Anthropic and OpenRouter backends |
| [Model selection](model-selection.md) | `MODEL` | Model picker, provider catalogs, per-turn selection |
| [Settings and API keys](settings.md) | `CONF` | On-disk settings database, API key entry and checks |
| [Skills registry](skills.md) | `SKILL` | Built-in and folder skills, system prompt, reload |
| [Folder skills](folder-skills.md) | `FOLDER` | `skills/<name>/` with `SKILL.md` and script tools |
| [Shell tool](shell-tool.md) | `SHELL` | Running OS commands |
| [Command isolation](command-isolation.md) | `ISOL` | Commands run in a bubblewrap jail by default: the settings database, saved chats and credentials aren't reachable; per-chat switch |
| [File tools](file-tools.md) | `FILE` | `read_file`, `write_file`, `edit_file` |
| [Workspace policy](workspace-policy.md) | `WS` | Path classes: extension, core, protected, outside |
| [Checkpoints](checkpoints.md) | `CKPT` | Retired: per-chat worktrees replaced snapshots and rollback |
| [Test runs](verification.md) | `VERIFY` | `run_tests`: running `mix test` in a chat's workspace |
| [Hot reload](hot-reload.md) | `HOT` | Hot reload: the soft deploy mode, loading tested code into the running server |
| [Guarded files](guarded-files.md) | `GUARD` | Retired: per-chat worktrees replaced it; the "never reload on request" rule moved to Deployment |
| [Auto reconnect](auto-reconnect.md) | `CONN` | Page reconnects or reloads itself when the LiveView socket dies |
| [Installable web app](pwa.md) | `PWA` | Manifest, icons and service worker so the app installs on a phone |
| [Recovery](recovery.md) | `RECOVER` | Retired: per-chat worktrees and the deploy gate replaced `/recover` |
| [Sub-tasks](subtasks.md) | `SUBTASK` | `spawn_task` hands work to a child chat; `list_tasks`/`await_task` report its status and result; `finish_task` returns a structured result |
| [Auto restart](auto-restart.md) | `RESTART` | `bin/serve` restarts the server after a crash, with backoff; the app is permanent; systemd user service |
| [Deployment](deployment.md) | `DEPLOY` | Per-chat worktrees forked from the trunk `master`; a deploy from Settings brings `master` to `live` by hot reload or restart |
| [Real-browser tests](browser-tests.md) | `BROWSER` | PhoenixTest + Playwright headless Chromium tests for JavaScript, websocket and layout; excluded from the default run |
