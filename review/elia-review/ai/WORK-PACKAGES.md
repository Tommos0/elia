# Ready-to-assign work packages

[Routes](ROUTING-INDEX.md) · [Parent brief](ORCHESTRATOR.md) · [Return contract](RETURN-CONTRACT.md) · [Roadmap](../review/ROADMAP.md)

These are implementation briefs for a future authorized development task. They are not patches, approved specifications or instructions to deploy. Each starts with source confirmation at the developer's actual HEAD. The parent drafts any behavior specification, obtains the approval required by `AGENTS.md`, and then assigns a bounded implementation step. Read the current repository instructions before using these briefs.

## Common brief fields

Send the child: exact base commit; one package/finding; owning spec and approved requirement IDs; allowed source/test files; observable acceptance checks; integration dependencies; the return contract. Require a note on every persisted shape touched. An unchanged format still deserves an explicit statement that old data remains readable.

Run tests through a single parent-controlled queue. Multiple children may inspect code and prepare patches concurrently; they must not independently launch overlapping `mix test`, `bin/test` or `mix precommit` processes. Internal partitions from one `bin/test` invocation are expected.

## A — Confinement for host reads and writes

**Findings:** SEC-01, SEC-02. **Owner:** file/workspace policy. **Read:** route A and the two security sections.

First enumerate every host read that can become prompt context, beginning with project instructions, and every file mutation that resolves aliases. State permitted final and intermediate symlink behavior separately for reads, writes and deletion. A readable shared dependency mount must not become a writable target just because its bytes are reachable.

Deliver a small policy boundary used by the affected call sites, with an explicit answer for replacement races and canonical lock identity. Avoid a purely lexical prefix patch. Run a fake-provider sentinel test for instruction ingress; protected sentinel tests for write/edit and directory-alias deletion; ordinary file and allowed-symlink regression tests. Deleting a final symlink is different from deleting a child through a directory alias.

**Handoff:** agree the root/referent API with B before both edit shell/workspace code. No live keys or user files are needed. No persisted chat migration is expected unless a new stored policy field is introduced; declare the decision rather than assuming it.

## B — Command setup and folder-tool reach

**Findings:** SEC-03, SEC-04. **Owner:** shell/mount lifecycle. **Read:** route B; preserve separate process, PID and temporary namespaces.

B1 should release overlay setup ownership when the command's readiness signal proves mounting is complete, with cleanup on failure/retry/holder death. Use a deterministic barrier: command A announces readiness and remains blocked; B must finish before A is released. Do not substitute a timing benchmark for this ordering assertion. Define whether lock wait consumes the command's timeout and eliminate an accidental unlocked timeout path.

B2 should pass both the project confinement root and skill cwd. A real jailed folder script must read a project sentinel through `ELIA_WORKSPACE`, execute in its skill directory and fail to read an outside sibling. Cover a global skill requiring a narrow extra mount, an external project and an Elia worktree. A fallback run without bubblewrap cannot establish this acceptance result.

**Handoff:** coordinate with A's path policy and G's browser/tool dependency paths. B1 and B2 both touch `shell.ex`; integrate sequentially under one owner.

## C — External-project child identity

**Finding:** CORE-01. **Owner:** task/workspace resolution. **Read:** route C.

Use two disposable Git trees whose content and branches differ. Spawn a child for the external tree and assert actual `pwd`, read/write effects, Git baseline/result and lock key. A correct `project_id` is insufficient. Verify that Elia's tree is unchanged, two distinct external roots do not falsely serialize, and a resumed child uses the intended baseline.

Resolve one authoritative parent workspace, then thread it through the existing Elia-only worktree special case and shared external-workspace path. Do not broaden this fix into external-project worktree support. Decide how an older saved task with a wrong baseline should be handled; coordinate that answer with D.

## D — Session ownership, persistence and preparation

**Findings:** CORE-02/03/04, LLM-01. **Owner:** one session integration owner with narrow subordinate tasks. **Read:** route D. This is the most important shared-file boundary in the plan.

| Step | Observable result | Key constraint |
| --- | --- | --- |
| D1: CORE-02 | Killing the session while a fake model/tool is blocked ends its loop and workers; reopening cannot overlap with orphaned work | Cleanup must survive abnormal death; `terminate/2` alone does not cover `:kill` |
| D2: CORE-03 | One validly encoded but malformed saved record cannot crash a listing or boot recovery of valid peers | Preserve supported old shapes and provider raw blocks; define visible quarantine/diagnostic behavior |
| D3: CORE-04 | A final failed write remains dirty; after recovery, the latest snapshot is persisted or a defined failure is reported | Do not equate a cleared timer with successful durability; bound retries |
| D4: LLM-01 | A held summarizer leaves control calls responsive; Stop prevents a late result from starting work | Build on D1 ownership; track operation/generation identity and preserve summary-failure fallback |

D2 can be researched independently in `store.ex`. D1, D3 and D4 share `session.ex`; do not merge them concurrently. For D3, include a no-further-mutation shutdown case. For D4, exercise both manual and turn-start summarization with eligible nonempty aged-out history, not only mid-turn pruning. Keep stopped-child-turn semantics unchanged.

## E — Terminal origin and confinement state

**Findings:** W01, W02. **Owner:** terminal web boundary. **Read:** route E and the pinned Phoenix transport evidence in the web report.

Choose an explicit origin/session-proof contract that works through the supported proxy deployment. Test the actual HTTP/WebSocket handshake with missing and invalid proof and a foreign origin; channel test helpers alone bypass the relevant transport path. Use an existing dummy terminal ID and a harmless echo target. Preserve same-origin success, byte encoding, output replay and terminal jail behavior.

Independently, Start must consult the current authoritative jail preference. The running-terminal warning must use the process's actual confinement state. Test two views with a preference change between mount and Start, and a running unjailed terminal after the preference is re-enabled. Do not promise retroactive confinement of an already running process.

## F — Push transactions and explorer errors

**Findings:** W03, W04. **Owners:** F-push and F-explorer may be separate.

For push, serialize the whole get-or-create key operation and every subscription read/modify/write transaction. Concurrent initial callers must receive the same persisted key pair; parallel device additions must both survive; removal/clear must not be reversed by a stale writer. Use controlled barriers, generated test keys and injected sends. Retain the persisted format if possible and assess all callers of any new Settings API.

For explorer, pattern-match the root fallback as well as the requested-directory result. Delete/move a temporary registered root and assert a stable page, an error, a usable project picker and list-valued entries. Do not silently browse another project. This is a small, separable patch with no expected stored-format change.

## G — Setup, generated bundles and restart readiness

**Findings:** DEV-01, DEP-01, DEP-02. **Owner:** one deployment integration owner.

G1 makes the literal README setup reproducible from a clean checkout, including locked Node dependencies needed by the asset imports. Verify actual JS/CSS output and the terminal hook; an Elixir compile alone is insufficient. Keep normal non-browser tests independent from browser installation.

G2 treats generated assets as part of deployment promotion/restoration. A fixture must ignore generated outputs as the real project does. After a deliberately partial failed build, compare served revision-A asset bytes, loaded revision, Git state and recorded failure. Cover deletion/truncation, no-merge deployment and rollback failure; coordinate watcher behavior. Avoid relying on `git reset` or a committed bundle fixture to prove asset recovery.

G3 separates hot-reload capability from restart-supervisor readiness. A bare `mix phx.server` launch must not accept a restart that only stops it. A supervised fixture must prove that a replacement process actually comes up. Decide how the supervisor advertises its capability; do not infer it merely from Mix availability.

**Handoff:** retain bundle-independent `/recover`. Assess ignored dependency state during rollback separately; it is an open follow-up, not a fourth confirmed finding in this package.

## H — Provider error parser

**Finding:** LLM-02. **Owner:** provider adapters. **Read:** route H.

Drive the shared OpenAI-format stream parser with HTTP-200 SSE error fixtures containing integer, numeric string, symbolic string, partial numeric string, absent, null and unexpected code types. Preserve useful provider text without raising. Match complete `Integer.parse/1` results and leave unknown errors non-transient unless the contract explicitly says otherwise. Exercise both OpenRouter and llama.cpp integration paths. No paid API call or claim about current live provider payload frequency is needed.

## Final integration gate

Confirm each child's evidence and actual test log; rebase shared-file work in the stated order; review the combined tree for persisted-data compatibility and boundary changes. Then run the required serialized `mix precommit`, selected browser/real-jail checks and UI previews when relevant. A commit, trunk integration and user deployment remain separate steps under the current repository rules. Report blocked gates plainly.
