# Routing index for focused readers

[Start](../README.md) · [Parent brief](ORCHESTRATOR.md) · [Work packages](WORK-PACKAGES.md) · [Machine routes](routes.json)

Use one route per question. Read the named finding first, then the owning requirement, then the implementation and nearest test. Repository paths below are relative to the cloned Elia checkout; review links are relative to this archive. Every machine route includes pinned source URLs. **The parent does not need to read every file in this table.**

## Shared entry rule

Before implementing, read the checkout's current `AGENTS.md`, `specs/README.md`, and only the topic documents that its task table selects. This review is not a specification approval. Read-only confirmation can proceed; behavior changes follow the repository's spec-first approval workflow. Every child returns [this contract](RETURN-CONTRACT.md). Test invocations must be serialized across worktrees.

## Select a workstream

| Route | Question and findings | First review reading | Repository entry points | Nearest tests |
| --- | --- | --- | --- | --- |
| **A — Host paths** | Can prompt reads or approved writes cross intended file boundaries? SEC-01, SEC-02 | [Security](../review/SECURITY.md), SEC-01/02 | `skills.ex:project_instructions/1`; `skills/files.ex`; `workspace.ex`; `shell.ex` reachability | `skills_test.exs`, `skills/files_test.exs`, `self_modification_test.exs` |
| **B — Command mounts** | Is mount ownership bounded by setup, and is cwd distinct from workspace? SEC-03, SEC-04 | [Security](../review/SECURITY.md), SEC-03/04 | `shell.ex`; `shell/lock.ex`; `skills/folder.ex`; terminal startup as a counterexample | `command_isolation_test.exs`, `shell_test.exs`, `shell_lock_test.exs`, `skills_test.exs` |
| **C — Child identity** | Does a child really use its parent's external project? CORE-01 | [Core](../review/CORE.md), CORE-01 | `tasks.ex:repo_root/1` and child options; `agent/session.ex` initialization; `projects.ex`; `deploy.ex` workspace path | `tasks_test.exs`, `tasks_git_test.exs`, `tasks_concurrency_test.exs` |
| **D — Session lifetime** | Who owns active work, durable state and slow preparation? CORE-02/03/04, LLM-01 | [Core](../review/CORE.md), selected finding; [Compaction](../review/LLM-AND-COMPACTION.md), LLM-01 | `agent/session.ex`; `agent/loop.ex`; `agent/resumer.ex`; `store.ex`; `llm/compaction.ex`; public `agent.ex` | `agent_test.exs`, `auto_resume_test.exs`, `store_test.exs`, `store_shape_test.exs`, `llm/compaction_test.exs`; web `live/compaction_test.exs` |
| **E — Terminal browser boundary** | Who can connect, and which jail state is actually in force? W01, W02 | [Web](../review/WEB.md), W01/02 | `terminal_socket.ex`; `terminal_channel.ex`; `endpoint.ex`; `live/terminal_live.ex`; `config/dev.exs`; core `terminal.ex` | web `terminal_channel_test.exs`, `live/terminal_live_test.exs`, `browser/terminal_test.exs` |
| **F — Small state/error fixes** | Are push updates atomic, and does a missing root render safely? W03, W04 | [Web](../review/WEB.md), W03 or W04 | Push: `push.ex`, `push/subscriptions.ex`, `settings.ex`. Explorer: `explorer.ex`, web `live/files_live.ex` | `push_test.exs`, `push_subscriptions_test.exs`, `settings_test.exs`, `explorer_test.exs`; web `live/files_live_test.exs` |
| **G — Build and deploy** | Does a clean setup build, and do rejection/restart states match reality? DEV-01, DEP-01, DEP-02 | [Deployment](../review/DEPLOYMENT-AND-SETUP.md) | `mix.exs`; `assets/package*.json`; `deploy.ex`; `deploy/runner.ex`; `bin/serve`; endpoint/static layout | `deployment_test.exs`, `serve_script_test.exs`, `install_service_test.exs`; web `browser_assets_test.exs`, `recovery_test.exs`, `live/settings_live_test.exs` |
| **H — Provider errors** | Do unknown streamed codes preserve a useful error? LLM-02 | [Providers](../review/LLM-AND-COMPACTION.md), LLM-02 | `llm/openai.ex`; `llm/sse.ex`; `llm/retry.ex`; OpenRouter and llama.cpp adapters | `llm/open_ai_test.exs`, `llm/open_router_test.exs`, `llm/llama_cpp_test.exs` |

Abbreviated Elia module paths are under `lib/elia/`; web-marked module paths are under `lib/elia_web/`. Root-relative paths beginning with `assets/`, `bin/` or `config/`, and `mix.exs`, remain as written. Unprefixed test paths are under `test/elia/`; web-marked tests are under `test/elia_web/`. The machine index removes this shorthand.

## Owning specifications and integration boundaries

| Route | Owning specification entry points | Requirement examples | Coordination required |
| --- | --- | --- | --- |
| A | `skills.md`, `workspace-policy.md`, `file-tools.md`, `command-isolation.md`, `projects.md` | SKILL-10/11; WS-1/5; FILE-5/11/21/22; ISOL-5 | Agree read/write/canonical-target policy with B; avoid two incompatible `shell.ex` or workspace APIs |
| B | `command-isolation.md`, `folder-skills.md`, `shell-tool.md`, `agent-loop.md`, `projects.md` | ISOL-28; FOLDER-6/7; LOOP-10 | A owns shared path policy; B owns lock/readiness and mount construction |
| C | `projects.md`, `subtasks.md`, `agent-sessions.md` | PROJ-12; SUBTASK-23; SESS-23 | Tell D which workspace/baseline is persisted and how old task metadata behaves |
| D | `agent-sessions.md`, `persistence.md`, `auto-resume.md`, `interrupted-turns.md`, `compaction.md`, `stopped-turns.md` | SESS-11/13; STORE shape rules; COMPACT-5/6/10/17/20 | One `session.ex` integration owner; implement ownership before adding new asynchronous compaction work |
| E | `terminal.md`, `chat-settings.md`, `command-isolation.md` | TERM-7/9/12/13/20; CSET-4; ISOL-16 | Handshake tests need real transport; preserve configured reverse proxies and byte semantics |
| F | `push-notifications.md`, `settings.md`, `file-explorer.md` | PUSH-1/3/4/7/16; EXPL-9/15 | Split F-push and F-explorer freely; settings transaction API has callers beyond push |
| G | `deployment.md`, `auto-restart.md`, `recovery.md`, `hot-reload.md`, `ui-preview.md`, `terminal.md` | DEPLOY-5/7/19/24/26; RESTART-11; PREVIEW-14 | One `deploy.ex` owner; preserve bundle-independent recovery and coordinate watchers |
| H | `llm-providers.md`, `llamacpp-provider.md`, `turn-retries.md` | LLM-22/23/36; LOCAL-10 | Keep unknown errors distinct from transient errors; no live-provider credential needed |

The examples are entry points, not an instruction to change every cited requirement. All spec filenames in this table are under `specs/`. Read the current text before deciding whether the change restores an existing requirement or needs a newly approved one.

## Example dispatch

> Confirm CORE-01 at the pinned SHA. Read only route C and its CORE-01 section, then PROJ-12/SESS-23/SUBTASK-23 and the listed source/tests. Return a failing-test design that verifies actual cwd, file effects and Git identity in two temporary repositories. Do not edit code until the parent has handled any required spec approval. Report compatibility for old task baselines and any collision with route D. Use RETURN-CONTRACT.md.

Once approved, replace the investigative objective with the specific approved requirement and allowed files. Do not send a child the whole report as an unbounded “fix all of this” assignment.
