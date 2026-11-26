[Start](../README.md) · [Findings index](../FINDINGS.md) · [Routing index](../ai/ROUTING-INDEX.md)

# Commands, file policy, and skill boundaries

Review snapshot: `5be0bd873bd2716529de25541efb1825495cd12e` (2026-11-15). This is a source review, not an exploitation report or a claim that the application test suite passed. No repository files were changed. No live credentials, provider calls, or user data were accessed. The four findings below are high-confidence deductions from the implementation and its existing tests; Elixir execution and a real-jail end-to-end reproduction were not performed in this review track.

## Read this first

The jail is well centralized, but host-side file reads and writes do not inherit its protection. The most important finding is a host-side read of a symlinked `AGENTS.md`: the following model step can put a file that the jail cannot read into the provider request. A second finding allows a permitted-looking file-tool path to write protected/shared files through a symlink. Two correctness findings concern the lifecycle of the overlay mount lock and the difference between a script's working directory and its permitted workspace.

| Local ID | Priority | Finding | Confidence | Primary source |
| --- | --- | --- | --- | --- |
| SEC-01 | P1 | A symlinked `AGENTS.md` is read outside the jail and included in the model request | High, source-confirmed | `lib/elia/skills.ex:125–130`; `lib/elia/agent/loop.ex:229–234` |
| SEC-02 | P1 | File-tool aliases can write protected Git metadata and the shared dependency tree | High, source-confirmed | `lib/elia/workspace.ex:58–65`; `lib/elia/skills/files.ex:230–250, 287–355` |
| SEC-03 | P2 | The overlay mount lock is held for the entire command | High, source-confirmed | `lib/elia/shell.ex:294–350` |
| SEC-04 | P2 | A folder tool's jail binds the skill directory instead of its workspace | High, source-confirmed | `lib/elia/skills/folder.ex:151–177`; `lib/elia/shell.ex:544–564` |

P1/P2 follow the [package priority definitions](../FINDINGS.md) and describe repair order for this local, single-user developer harness. These are not CVSS scores. SEC-02 still requires a file-tool action that the policy calls `:required`; a symlink under `skills/` is explicitly downgraded to `:core`, so this review does not claim that merely naming an extension path bypasses the approval policy. That policy includes per-chat auto-approval: new empty chats initialize all approvable tools in their set, and children copy their parent’s policy. A fresh human prompt is therefore not guaranteed. [Initial auto-approval](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/agent/session.ex#L710-L725), [child inheritance](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/tasks.ex#L332-L340).

## Boundary map

| Layer | What it currently controls | What must not be assumed |
| --- | --- | --- |
| Tool approval | Whether a tool call is denied, runs, or waits for a human | An approved build command cannot be assumed to contain only benign code. The isolation spec explicitly anticipates model-written tests. |
| `Elia.Workspace` | Lexical classes, `..` expansion, bounded symlink resolution | A lexical `:core` name does not mean its referent is writable. |
| `Elia.Shell` | Bubblewrap argv, workspace mounts, environment, deadline, process-tree cleanup, priority | It does not confine `File.read` or `File.write` performed in the BEAM process. |
| `Elia.Skills.Files` | File-tool policy and host-side operations | The current `reachable?` is a read-reachability check, not a writable-target policy. |
| `Elia.Skills` | Host-side reading of project instructions and skill metadata | Prompt construction is a file ingress boundary too; it is not covered by the file tools. |
| `Elia.Shell.Lock` | Queueing/ownership for one overlay mount | Correct lock ownership does not by itself establish the correct release point. |
| `Elia.Terminal.Session` | tmux protocol, stream fan-out, command lifecycle | The terminal's explicit early lock release does not fix the separate shell-command path. |

Sources: [workspace policy](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/workspace-policy.md), [command isolation](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/command-isolation.md), [shell implementation](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/shell.ex), [terminal session](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/terminal/session.ex).

## SEC-01 — Confine project-instruction reads before building the model request

### Evidence and consequence

`Elia.Skills.project_instructions/1` opens `<root>/AGENTS.md` with ordinary host `File.read`, trims it, and caps the returned text at 32,000 bytes. It does not check the real target or whether the path traverses a symlink. The agent loop calls this function with `ctx.workspace` on every step and passes the result to `Skills.system_prompt/2`, which becomes the provider request's `system` field. This is a different path from `Elia.Skills.Files.read_file/2`; none of its confinement checks or read approvals is consulted.

Sources: [instruction read and cap, `skills.ex:119–160`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/skills.ex#L119-L160), [request construction, `loop.ex:218–237`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/agent/loop.ex#L218-L237), [system prompt composition, `skills.ex:104–117`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/skills.ex#L104-L117).

A repository or a model-written program running inside the jail can create a symbolic link whose target does not exist inside that jail. On the next step, the unjailed host opens the target. If it is a readable text file under the host user's permissions, its contents enter the model request. No ability to read the target from the jailed process is needed. A file of more than 32,000 bytes is only partially disclosed, but the cap is not an authorization boundary. With a remote provider the text is sent off machine; with a local provider it is still made available to the model in violation of the intended workspace boundary.

**Preconditions:** control of the workspace's `AGENTS.md` symlink (for example a checked-out project containing it, or a permitted/auto-approved command that creates it), a known or guessed readable host text-file path, and a following model step. This does not require network access from the command. It does not require the user to approve a `read_file` request for that host path.

### Existing coverage and specification fit

`skills_test.exs` tests regular instruction files, missing/blank/unreadable files, refresh-on-read, and the UTF-8 cap, but has no symlink-confinement case in that group. File-tool tests do cover outward symlinks, demonstrating that this boundary is recognized elsewhere. The isolation introduction explicitly promises that even model-written tests cannot read credentials; ISOL-5 and FILE-12/FILE-13 express the nearby boundary, while SKILL-10/SKILL-11 and PROJ-15 govern loading instructions. The missing rule belongs in the instruction-loading specification as well as the implementation; it should not be left as an implication of the file-tool spec.

Sources: [instruction tests, `skills_test.exs:46–98`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/skills_test.exs#L46-L98), [outward-link tests, `self_modification_test.exs:197–230`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/self_modification_test.exs#L197-L230), [isolation threat model, `command-isolation.md:5–20`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/command-isolation.md#L5-L20).

### Safe reproduction plan

In a disposable test fixture, create sibling directories `project/` and `outside/`. Write `outside/review-sentinel.txt` with the harmless text `ELIA_REVIEW_SENTINEL`. Create `project/AGENTS.md` as a symbolic link to that sentinel. Call `Skills.project_instructions(project)` directly: the current source returns the sentinel. Then use the existing fake provider to capture one loop request and assert that its `system` contains the sentinel. Do not use a real key, private user file, or real provider. The unit-level demonstration requires no bubblewrap; a separate integration test can confirm that the sentinel path is absent from the command jail while the host instruction reader previously followed it.

### Repair and acceptance

Define a confinement-aware metadata reader for project instructions and use it at every host-side prompt-construction call site, including context previews. Explicitly decide whether an in-workspace symlink is supported. Refuse an outward or unresolvable target before returning content; avoid a check-then-follow sequence that a concurrent command can redirect. Treat the folder-skill metadata readers as adjacent inputs to audit, because they also use host `File.read`.

Acceptance: a normal regular `AGENTS.md` still updates on the next step; permitted internal links behave as specified; outward, broken-outward, looped, and replaced-during-read links contribute no external bytes to the prompt; a fake-provider test verifies the entire request, not just an error return. Error messages may identify the refused path but must not quote its contents. Review any persisted representation only if the chosen implementation changes one; the direct read-policy fix itself need not change saved-chat shapes.

## SEC-02 — Apply write policy to the real referent and its mount permissions

### Evidence and consequence

`Workspace.classify/2` protects `.git`, `_build`, `deps`, and `.elia` only when they are the first lexical component. It deliberately labels a path under `skills/` that traverses a symlink as `:core`. `Files.write_policy/2` then denies unreachable targets, but accepts a reachable `:core` path after approval. A chat-worktree's `Shell.reachable?/3` deliberately considers the live repository's `.git` and shared `deps` readable. Finally `write_file/2` and `edit_file/2` execute `File.write` in the host process, following the alias and bypassing the jail's read-only Git mounts and dependency overlay.

Sources: [lexical classes, `workspace.ex:50–65`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/workspace.ex#L50-L65), [write policy and host write, `files.ex:230–355`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/skills/files.ex#L230-L355), [shared-tree reachability, `shell.ex:162–192`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/shell.ex#L162-L192), [read-only Git submounts and dependency overlay, `shell.ex:578–614`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/shell.ex#L578-L614).

Concrete paths, using a disposable live tree `/fixture/live` and chat worktree `/fixture/live/.elia/worktrees/review`:

| Tool path | Actual target | Current policy result |
| --- | --- | --- |
| `deps/shared/sentinel.txt` | shared live dependency | Protected lexical path; denied |
| `alias-deps/shared/sentinel.txt`, where `alias-deps -> /fixture/live/deps` | the same shared live dependency | Reachable `:core`; approval required, then host write follows the link |
| `.gitdir/config`, where `.gitdir -> /fixture/live/.git` | live Git config | Reachable `:core`; approval required, then host write follows the link |
| `skills/alias/config`, where `skills/alias -> /fixture/live/.git` | live Git config | `:core`, **not** `:extension`; approval is still required |

The existing test itself creates `.gitdir -> live/.git` and establishes that it is readable; it never asserts that a write through this alias is denied. This is therefore a realistic policy interaction, not a hypothetical path outside all the allowed mounts.

Source: [the existing shared-tree fixture, `self_modification_test.exs:265–294`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/self_modification_test.exs#L265-L294).

**Impact:** approved file-tool actions can change data that the advertised protected-path policy says these tools may never change. A shared dependency write lands in the live lower tree, affecting other worktrees; it does not enter the command jail's private overlay. A Git metadata write defeats the separate read-only protections intended to prevent command planting. This finding does not claim that every metadata write immediately executes code, or that normal approval is bypassed. It identifies a stronger refusal boundary being converted into ordinary approval.

`delete_file` needs a precise distinction: deleting a final symlink removes the link itself and does not delete its target. Deleting `directory-alias/child`, however, follows the directory alias when locating `child` and is subject to the same protected-target gap. File locks are also keyed by the lexical absolute path, so two aliases to one file do not share a lock; that is an adjacent integrity risk to handle while designing the fix, not a separately scored finding here.

Sources: [delete and lock implementation, `files.ex:591–680`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/skills/files.ex#L591-L680), [file-tool write contract, FILE-5/FILE-11/FILE-21/FILE-22](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/file-tools.md), [WS-1/WS-5](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/workspace-policy.md).

### Repair and acceptance

Preserve readable reachability, but introduce a separate writable-target decision. Apply both lexical policy and real-target protection; a path being visible must not imply that the host may write it. Refuse aliases into protected workspace paths, shared dependencies, and protected Git metadata. Perform the decisive check within the mutation's synchronization/secure-open boundary, including ancestor symlinks and missing descendants. Do not weaken the jail to make the two implementations agree. If internal symlink writes remain supported, lock by canonical target or inode identity as appropriate and define link-replacement behavior.

Acceptance: use sentinel files in a throwaway live/worktree fixture, never a real checkout's config. Deny write/edit and directory-alias child deletion into the protected targets, verify bytes unchanged, and preserve deletion of an ordinary permitted final symlink. Cover live-tree and chat-worktree modes, jail on/off as specified, long/looped links, and a symlink target swapped during an attempted mutation. Add a test proving a file-tool operation cannot modify the shared lower dependency tree even though it is readable. Update the specification deliberately because WS-5 currently documents lexical classification; the stronger invariant needs an explicit requirement, with the project's normal spec-approval workflow before implementation.

## SEC-03 — Release the mount lock when readiness arrives

### Evidence and consequence

The comment in `Shell.execute/3` says the lock is held until the jail is ready. The actual `try … after` wraps `run_jail/4`, and the release at line 310 runs only when that function returns. `attempt/4` handles `{:ready, rest}` by immediately entering `collect/3`; it never releases the lock there. `collect/3` returns when the command exits or its deadline expires. The lock therefore covers the entire command, not only mount creation.

Sources: [`shell.ex:294–350`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/shell.ex#L294-L350), [readiness handling, `shell.ex:420–448`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/shell.ex#L420-L448), [lock acquire timeout, `shell/lock.ex:22–43`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/shell/lock.ex#L22-L43).

**Preconditions:** two shell commands in the same chat worktree while the dependency overlay is enabled, or a terminal starting while such a command holds the mount lock. A short second command waits behind the first command until the first finishes or the second reaches the lock's 30-second acquisition timeout. After that timeout it runs without the lock. The command deadline is set before acquisition, so waiting also consumes the command's execution budget; the fixed acquisition wait can itself exceed a shorter requested command timeout.

This directly affects a parent or child agent batching a quick diagnostic alongside a build. It reduces the concurrency promised by LOOP-10 and violates ISOL-28's explicit release-on-readiness requirement. The terminal implementation does release on the first output (`release_lock` at lines 317–323); this does not change the separate shell path's behavior.

Sources: [ISOL-28](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/command-isolation.md#L176-L207), [terminal release, `terminal/session.ex:316–359`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/terminal/session.ex#L316-L359).

The tests verify that a command waits for a manually held lock, that several short commands all eventually succeed, and that the argv requests a readiness report. None of those assertions proves that a still-running ready command has released the lock.

Sources: [`command_isolation_test.exs:292–323`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/command_isolation_test.exs#L292-L323), [`shell_test.exs:537–552`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/shell_test.exs#L537-L552).

### Repair and acceptance

Separate acquiring/mounting from collecting command output. Release the lock exactly once after a valid readiness signal, while retaining cleanup for setup failure, process death, retries, and cancellation. Pass the remaining command budget to lock acquisition. A retry that mounts again must reacquire appropriately; a read-only fallback has no overlay mount to serialize.

Acceptance should use an explicit barrier rather than a long sleep: command A emits/establishes readiness and waits for a fixture signal; command B must finish a harmless operation in the same worktree before A is released. Assert mount starts are still serialized. Cover a terminal start behind a ready command, deadline expiry while queued, setup failure and retry, and death of the lock holder. Run this through the real jail in a qualified CI environment, with a deterministic fake-bwrap harness for fast lifecycle checks.

## SEC-04 — Distinguish a folder tool's working directory from its workspace

### Evidence and consequence

`Folder.run_script/5` exports `ELIA_WORKSPACE=workspace(ctx)` but passes `cd: dir` to `Shell.run/2`, where `dir` is the skill directory. `Shell.jail_args/3` uses that same `cd` for both `bind_args` and `--chdir`. For a normal external project `/project`, a tool in `/project/skills/probe` receives only that skill directory as the writable project bind; `/project/README.md`, `/project/lib`, and the project's `.git` are absent. For a tool nested under Elia's live tree, the helper adds live Git/dependency mounts but still omits the rest of the promised chat workspace.

Sources: [`folder.ex:151–177`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/skills/folder.ex#L151-L177), [conflated root/cwd, `shell.ex:454–471`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/shell.ex#L454-L471), [bind selection, `shell.ex:539–564`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/shell.ex#L539-L564).

**Preconditions:** a working bubblewrap jail and a folder skill that needs project files outside its own folder. The example-style Git summary tool, a test runner, or a project inspection script can fail even though it has the correct `ELIA_WORKSPACE`. This is a functional regression, not a reason to turn off isolation. In unjailed mode the working directory and environment value behave as expected, which can hide it during tests.

FOLDER-6 requires running from the skill directory; FOLDER-7 and PROJ-12 give the tool its project workspace. Both requirements should be true simultaneously. The existing FOLDER-6 isolation test forces the missing-bwrap path and uses only `echo hi`, so its assertion checks setting propagation without exercising a real workspace bind.

Sources: [FOLDER-6/FOLDER-7](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/folder-skills.md#L27-L36), [PROJ-12](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/projects.md#L52-L63), [`command_isolation_test.exs:196–253`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/command_isolation_test.exs#L196-L253).

### Repair and acceptance

Give the shell launcher an explicit confinement workspace separate from cwd. Choose mounts and dependency-layer ownership from the workspace; set cwd to the tool's folder. A shared/global skill may live outside the chat worktree, so decide explicitly how its script directory is supplied—typically a narrow read-only extra bind—without binding the whole live tree or another project's data. Keep input in environment variables rather than interpolating it into the command.

Acceptance: a real jailed folder tool reads a sentinel at `ELIA_WORKSPACE`, has the skill folder as cwd, uses project-local Git as intended, and cannot read a sibling sentinel outside the workspace. Cover an external project, an Elia chat worktree, and a global skill used by that worktree. Verify the overlay/lock belongs to the workspace, not a nested `skills/...` path. The missing-bwrap and explicitly unjailed behaviors still need their own tests.

## Strengths to preserve

The shell and terminal share the jail/priority implementation, avoiding a second security policy that could drift. Jailed environments are rebuilt from a short allowlist; the live-tree data directory is masked; shared dependency writes use an overlay; and Git configuration, hooks, and info are deliberately overmounted read-only. File tools already refuse outward and unresolved symlinks under the jail decision, including when bubblewrap is absent, so the right policy building blocks exist. The child-process watcher and absolute command deadline address stopped turns and noisy commands, while bounded output collection limits ordinary shell-result memory. Terminal text is hex-encoded for tmux `send-keys`, and key names are separately validated. These are substantive protections worth retaining while closing host-side gaps.

Sources: [`shell.ex`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/shell.ex), [`files.ex`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/skills/files.ex), [`terminal/session.ex:525–571`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/terminal/session.ex#L525-L571), [`terminal/keys.ex`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/terminal/keys.ex).

## Scope boundaries and follow-up

The reviewed system is a single-user local harness, not a tenant-isolation service. An explicitly disabled jail, network access retained by design, writable trunk refs needed by the existing merge workflow, and deployment of code the user approves are not scored as vulnerabilities here. No claim is made that all isolation paths were audited or that external dependency versions are vulnerability-free. Browser/socket authentication is assigned to the web review; deploy trust and rollback to the deployment review.

The source ledger accompanying this note distinguishes full reads from targeted reads. Security integration checks should run on a host that can actually create the expected user/pid/mount namespaces and overlay; a test suite that skips the real-jail tests cannot establish these findings are fixed. Before implementing, follow the repository's spec-first workflow and obtain the required spec approval. Review output itself changes no project behavior and requires no such implementation approval.
