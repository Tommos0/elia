# Human summary

[Start and reading routes](README.md) · [All findings](FINDINGS.md) · [Recommended roadmap](review/ROADMAP.md)

**Elia has a coherent architecture and a substantial regression-test foundation. The most valuable next work is to make its boundaries agree: which directory a child owns, which files host-side code may open, which process owns an active turn, and which asset bytes a rejected deploy leaves running.** The review recommends retaining the current architecture while repairing those concrete gaps.

This review covers the cloned repository at commit [`5be0bd873bd2716529de25541efb1825495cd12e`](https://github.com/Tommos0/elia/commit/5be0bd873bd2716529de25541efb1825495cd12e), dated **15 November 2026**. It is a whole-project snapshot review. The source checkout was left unchanged; there is no patch or deployment hidden in this package.

There are **17 source-confirmed findings**, grouped into **6 P1** and **11 P2** priorities. These are development priorities, not vulnerability scores. The application could not be compiled or tested in this environment because Elixir/Erlang/Mix were absent. Source-confirmed means the code path supports the stated trigger; it does not mean an exploit or ExUnit failure was reproduced. The archive makes this distinction on each route. [Full index](FINDINGS.md), [actual validation](meta/VALIDATION.md).

## What Elia does well

The project is built around explicit behavior specifications. Stable requirement IDs connect feature descriptions to implementation and tests, and the test suite includes spec hygiene, traceability and persisted-shape checks. This gives both people and agents a useful way to ask “which behavior am I changing?” before editing a large module. The review inventory contains **339 tracked files, 93 application `.ex` files, 103 test files and 59 Markdown files under `specs/`**; the last count includes the index and draft plan. These are repository counts, not coverage or test-pass statistics. [Spec workflow](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/README.md), [inventory and counting method](evidence/static-checks.json).

The main runtime responsibilities are also understandable. A session owns conversational state, a separate loop performs model/tool work, and subtask watchers collect structured child results. Compaction derives a smaller provider request while preserving the full transcript. Fake providers, temporary live-tree fixtures and real-browser tests create seams for focused verification. [Architecture](review/ARCHITECTURE.md), [core assessment](review/CORE.md), [provider assessment](review/LLM-AND-COMPACTION.md).

The isolation and deployment work contains substantive protections: centralized command launch, restricted command environments, dependency overlays, explicit approvals, per-chat worktrees, a deploy runner independent of a browser page, and a recovery page independent of the main bundle. Markdown sanitization, byte-safe terminal transport and known-answer push-crypto tests are further strengths. The findings arise mainly where one of these mechanisms meets a different mechanism, rather than from a missing overall design. [Security strengths](review/SECURITY.md), [deployment design](review/DEPLOYMENT-AND-SETUP.md), [web strengths](review/WEB.md).

## The six issues to address first

| Priority finding | Why it matters | Qualification and repair direction |
| --- | --- | --- |
| **SEC-01: instruction-file reads can escape the jail boundary** | A symlinked workspace `AGENTS.md` is opened by the host, and its text enters the next provider request. A file unreadable inside the command jail can still be read by this separate path. | Requires control of that workspace path and a readable host target. Confine prompt metadata reads as carefully as file tools. |
| **SEC-02: protected files can be written through aliases** | File policy classifies a path by its spelling, while a host write follows its target. An alias can turn a protected Git/dependency target into an ordinary approval-required write. | The action follows ordinary approval or per-chat auto-approval; the missing boundary is protected-target refusal. Apply policy to the actual referent. |
| **CORE-01: external-project children can work in the wrong repository** | The child carries the right project label but receives Elia's global root as its tool workspace and Git baseline. This risks changes and reports in the wrong tree. | Check actual cwd, file effects and Git identity in a two-repository fixture. Fix the root used throughout the task flow. |
| **CORE-02: session death can leave work running** | An unlinked loop outlives its owning session, and its workers can continue. Reopening the chat can create overlapping old and resumed work. | Applies while the application remains alive, not after the entire VM exits. Tie worker lifetime to explicit session ownership. |
| **DEP-01: Git rollback does not restore the served bundle** | A failed build can leave new, partial or missing ignored assets beside the previous running code. Returning HEAD to the old commit does not restore those bytes. | Dev watchers may recover later but offer no transaction guarantee. Stage/preserve bundles and verify HTTP-served output after rejection. |
| **W01: terminal browser connections lack origin/session enforcement** | The default operating config disables origin checks and the terminal socket accepts connections without validating its session information. | An unrelated origin needs a known existing terminal chat ID and browser/proxy reachability. Test the actual handshake and add explicit origin/session proof. |

Each row is backed by pinned source links and test analysis in [Security](review/SECURITY.md), [Core](review/CORE.md), [Deployment](review/DEPLOYMENT-AND-SETUP.md) or [Web](review/WEB.md). The review does not treat the project's intentional single-user/no-login model as an automatic defect; W01 is a separate browser-origin boundary.

## The next reliability work

Several narrower defects are worth fixing with small, outcome-based regressions. The shell's overlay lock is held through the whole command rather than just setup, delaying commands that should run concurrently. A folder tool uses its skill directory as the jail's confinement root, which can hide the surrounding project. An old terminal page can start using a stale jail preference. Push state updates can overwrite each other, and the Files page's missing-root fallback can turn an error into a rendering crash. [SEC-03/04](review/SECURITY.md), [W02–W04](review/WEB.md).

Persistence needs tests at two boundaries: valid encoded terms with invalid chat shapes, and transient I/O failure after a turn has already completed. The latter can leave an old active-turn marker on disk because the session clears its dirty timer before a save succeeds. These are specific failure sequences; the review does not object to the existing policy of keeping the live chat running after a save error. [CORE-03/04](review/CORE.md).

Long-chat responsiveness also needs attention. Manual and turn-start compaction can make a summarizing provider call inside the session callback. A slow summary can outlast the five-second caller timeout while blocking Stop/snapshot requests. Move that work into a monitored operation with explicit cancellation and late-result handling. The shared stream parser also needs to handle nonnumeric error codes without raising; the review does not claim a current provider necessarily emits the example malformed code. [LLM-01/02](review/LLM-AND-COMPACTION.md).

For contributors, the documented clean setup omits the npm installation required by the xterm imports, including a direct relative stylesheet import. Restart readiness has a different prerequisite gap: Mix/reloader availability is treated as proof that an external supervisor will start a replacement process. Both deserve executable setup/service checks. [DEV-01 and DEP-02](review/DEPLOYMENT-AND-SETUP.md).

## What was actually verified

The repository was cloned and its SHA was matched to GitHub's default branch at review time. The local checkout remained clean. Four shell scripts passed syntax checking; all four first-party JS modules plus the service worker passed JavaScript syntax checking; the three strict JSON package/manifest files parsed; and the test runner's plan assigned all **103** test files exactly once, with no omissions or duplicates. Syntax checking does not establish successful bundling or browser behavior. [Recorded results V01–V10](evidence/static-checks.json).

Two disposable demonstrations established the filesystem premises behind selected findings: host file operations follow symbolic links, and a Git hard reset leaves ignored candidate assets untouched while the tracked tree can appear clean. They used generated dummy files and a new repository. They did not run Elia, access real secrets, send provider traffic or establish a real-jail exploit. The asset-package resolver also confirmed the clean clone has no installed xterm packages. [Validation scope](meta/VALIDATION.md).

The full ExUnit suite, `mix precommit`, asset build, real browser tests, real-jail tests and live provider integration remain **not run**. GitHub returned no Actions runs and the checked-in tree has no workflow definition; that is an observation about this snapshot, not proof that the maintainer has no local or external CI. [Metadata](evidence/review-metadata.json), [testing assessment](review/TESTING-AND-QUALITY.md).

## A practical sequence for the next development cycle

First establish a clean runtime verification lane and reproduce the high-priority findings with harmless fixtures. In parallel, decide the missing behavioral contracts for host metadata reads, browser origins and session death. The existing `AGENTS.md` requires spec approval before implementing behavior changes; the review's recommendations are not that approval. [Repository workflow](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/AGENTS.md).

Then repair confinement and workspace identity, make session ownership explicit, and make rejected deployments restore the actual served assets. Keep one integration owner for shared session/shell modules. Follow with persistence and push atomicity, responsive compaction, terminal settings and explorer error handling. The roadmap defines outcomes rather than speculative day estimates. [Roadmap](review/ROADMAP.md), [delegable work packages](ai/WORK-PACKAGES.md).

Finally reconcile the documentation that agents are likely to read first. The draft subagent plan contradicts current auto-approval inheritance, the spec index describes implemented concurrency as future work, and the README still says there is no recovery page even though one exists. A future agent should read the current `AGENTS.md` and owning implemented spec before historical plans. [Documentation drift table](review/TESTING-AND-QUALITY.md).

## Where to go next

Humans can stop after this summary and the [findings index](FINDINGS.md), then open only the report relevant to a decision. A parent AI should read the compact [orchestrator brief](ai/ORCHESTRATOR.md), select a row from the [routing index](ai/ROUTING-INDEX.md), and give a child the relevant finding, spec, code and acceptance criteria. [Method](meta/METHOD.md) and [Sources](meta/SOURCES.md) explain the evidence trail and the boundaries of this review.
