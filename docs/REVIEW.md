# Elia code review

First pass at `df856e1`: `lib/` (~28.7k lines), `config/`, `test/` (102 files), `specs/` (59).
Updated at `b886e29` (16 commits later): the findings that were fixed are gone from this
document — the list of what was fixed and where is below, so the reader can tell a fixed
finding from one the review never made.

Findings marked **verified** were reproduced; the rest come from reading the code. Line
numbers are from `df856e1`, except where a fix moved them — those were updated. Everything
else in the tree has grown since, so treat the numbers as approximate.

## Fixed since the first pass

| Finding | Fix | Requirement |
| --- | --- | --- |
| S3 symlink-chain escape | `2b2f119` | WS-6 (`specs/workspace-policy.md`) |
| S4 writable live `.git` in a worktree jail | `c360649` | ISOL-29, ISOL-30 |
| C1 the fallback save drops fields; C2 shared temp file, no fsync | `25c79c6` | STORE-43, SUBTASK-31/32 |
| C3 a stopped turn leaves OS processes running | `9faf37e` | SHELL-12, SESS-43 |
| C4 unbounded output buffering | `a753136` | SHELL-13 |
| C5 a crashing tool takes down the whole step | `3864bd3` | LOOP-26 |
| C6 O(n²) history handling in a session | `2802788` | SESS-44 |
| C7 listing decodes every chat in full | `f5a5ba0` | STORE-44, STORE-45 |

Two further bugs, found while fixing the above and not in the first pass, are also fixed:
a stop racing a terminal's own exit crashed the session (`5be0bd8`, TERM-35), and a terminal
whose command ended on its own leaked its tmux server and socket (`b886e29`, TERM-36).

## Summary

Elia is a carefully built, unusually well-documented codebase. Each behaviour is tied to a spec
ID, and hygiene tests keep specs and tests in sync. The jail design (bubblewrap, rebuilt env,
masked `.elia`, a deps overlay) is thoughtful. The main risks left are:

1. **Several 1.3k–2.8k-line modules** that mix UI, orchestration and I/O (maintainability).
2. **The web layer reaches into storage directly**, alongside the session that owns the same
   file — the coupling that produced C2 is still there even though C2 itself is fixed.
3. **Test runs in different worktrees share one scratch namespace**, so two chats cannot run
   the suite at the same time (C8).

## 1. Security

**S1 — Cross-site WebSocket access to terminals, and S2 — unauthenticated app.** Accepted, not
to be fixed: Elia is a single-user application, and the corpus already says so — the
`## Out of scope` section of `specs/terminal.md` (and five other specs) states that access
control is out of scope and that anyone who can reach the app can open a terminal in any chat's
workspace. Recorded here only so a future review doesn't re-raise it. If Elia is ever exposed
beyond the machine it runs on, revisit: the terminal socket
(`lib/elia_web/terminal_socket.ex:17`, `lib/elia_web/terminal_channel.ex:22`) needs no token and
the endpoint sets `check_origin: false` (`config/dev.exs:13`), and `config/runtime.exs:73`
binds `::` in prod.

**S5 — The dev `secret_key_base` is committed** (`config/dev.exs:15`), and it signs the cookies
of the server people really run when the app runs in the `dev` Mix env. Generate it per install
(README's setup step, or a check that refuses to boot on the committed value).

## 2. Correctness and concurrency

**C8 — Test runs from different worktrees share one scratch namespace.** `bin/test:30` derives a
partition's directory as `${TMPDIR:-/tmp}/elia-test-p$1`, and `config/test.exs:57,63` derive the
settings database and the scratch workspace from `System.tmp_dir!()` — so every worktree, every
partition and every concurrent chat use the same paths. Two runs at once corrupt each other's
`settings.dets` and fail with phantom `{:bad_object, :eval_work_list}` errors in whichever
partitions collide (`docs/agents/testing.md:116-120` states the rule that no two runs may
overlap, which is a workaround for this, not a fix). *Fix:* put a run-unique component in the
default — the worktree path, or the pid, or a run id — under `<tmp>/elia-test-<run>-p<n>/`, and
keep `TMPDIR`/`ELIA_TEST_*` as the explicit override it already is. That is a change to
`bin/test` and `config/test.exs` only; the specs that name the variables are
`specs/test-suite.md:75-85`.

**C9 — The output cap bounds the collected buffer, not the port's mailbox.** SHELL-13 keeps a
bounded head and tail while collecting, but unread port messages still accumulate in the
runner's mailbox, so on a loaded node a chatty command can hold more than the cap before the
collector drains it. The cap is what the model sees and what the truncation notice counts;
bounding the mailbox too means reading the port on a timer rather than on demand, or closing
the port once the cap is passed and the command's output no longer matters.

## 3. Architecture and module boundaries

- **Layering is mostly sound.** Provider-neutral `Elia.LLM` sits behind `Provider`, skills are
  data (`Elia.Skill`/`Elia.Tool`), there is one GenServer per chat, and all OS access goes
  through `Elia.Shell`. Keep that discipline.
- **Oversized modules:** `chat_live.ex` (2711 lines), `settings_live.ex` (1954),
  `compaction.ex` (1443), `deploy.ex` (1396), `agent/session.ex` (1384) and `chat_settings_live.ex`
  (1261). `ChatLive` mixes transcript rendering, the composer, the chat list, sub-task trees and
  file links. Extract function components (`TranscriptComponents`, `ChatListComponent`) and move
  data shaping into plain modules. `Deploy` mixes worktree lifecycle, git plumbing, the deploy
  record and front-end builds: split out `Deploy.Git` (the `git/3` wrapper at `:1374` and the
  predicates at `:1357-1365`), `Deploy.Worktrees` and `Deploy.Record`.
- **The web layer reaches into storage directly.** `ChatLive` calls `Elia.Store`
  (`chat_live.ex:31,46,997,2070,2261,2303` — `:46` is the `Store.save(id, [], project: …)` that
  used to race the session) while the session also owns the same file. C2 came from this and is
  fixed at the write, but the ownership is still shared. Route chat creation and metadata through
  `Elia.Agent`, and keep `Store` private to the session plus a read-only listing API.
- **Duplicated path logic.** `symlink_on_path?/2` exists twice, in `lib/elia/workspace.ex:135`
  and `lib/elia/explorer.ex:154`, and the two differ: Explorer rejects `"."`. `inside?/2` is
  duplicated in `workspace.ex:133` and `shell.ex:618`. Make `Workspace` the single owner of path
  policy — the depth-exhaustion bug (S3) was one of the costs of this split, and a fix applied
  in one copy is easy to lose in the other.
- **`Elia.Workspace.root/0` falls back to `File.cwd!()`** (`workspace.ex:29`). That is implicit
  global state: a `File.cd` anywhere in the VM changes policy roots. Resolve it once at boot and
  store it in application env.

## 4. Code quality and readability

- Comments are dense and spec-linked. That helps traceability, but some functions are more than
  half comment (e.g. `Shell.open/4`, `Store.save/3`), so the code itself is hard to follow. Move
  the rationale to the spec and keep one-line `# ID: why` pointers.
- `Store.save/3` still builds the map with a chain of rebinds (`store.ex:42-91`) — seven
  `chat = if …` lines plus the limits block. A declarative `@optional_fields` list of
  `{key, keep?/1}` pairs would shorten it and make C1-type omissions easier to spot.
- `true = valid_id?(id)` (`store.ex:39`) crashes the caller with a `MatchError`. Return
  `{:error, :invalid_id}` to match the declared spec.
- `decode/1` runs `Code.ensure_all_loaded` for the whole app on first use (`store.ex:578-582`),
  to make `:safe` work. That is a hidden boot cost on the first request and couples storage to
  module loading. Storing atoms as strings, or a versioned map with known keys, would remove the
  need for it.

## 5. Tests

- **Strengths:** broad coverage (agent, deploy, isolation, tasks concurrency, recovery, the
  terminal channel), real-browser tests behind a flag, and spec-traceability tests that fail the
  suite. The fixes above each arrived with the test the finding asked for: the S3 chain, the S4
  hook and fsmonitor plantings, the C1/C2 concurrent save and fallback, the C3 process-tree kill,
  the C4 bound, the C5 exiting tool, and the terminal stop/exit races.
- **Still missing:**
  - No unit test for `Elia.Workspace` itself. `real_location/1` is exercised only through
    `test/elia/self_modification_test.exs` and the isolation tests. Add chain-length, loop and
    relative-target cases as a focused module, so the next change to `resolve/3` has somewhere
    to be pinned down.
  - No test that the terminal socket rejects a foreign `Origin` — accepted with S1, so a test
    would be documenting an accepted hole; skip it unless S1 is revisited.
- **Speed and flakiness:** 70 modules in 68 files are `async: false` against 28 `async: true`,
  and there are 34 `Process.sleep` calls in `test/` (no `:timer.sleep`). Many of the non-async
  modules share global `Application` env (`:workspace`, `:runtime_root`). Passing roots
  explicitly (most functions already accept a `root` argument) would let more files run async.
  Replace sleeps with `assert_receive` on PubSub or telemetry events. Counts taken at `b886e29`;
  the suite has grown by ~40 tests since the first pass.

## 6. Suggested improvements, in priority order

1. Give each test run its own scratch namespace (C8), so two worktrees can run the suite at once
   and the "never run two at once" rule can go.
2. Decide where chat state lives: move creation and metadata behind `Elia.Agent` and make
   `Store` the session's, with a read-only listing API for the UI.
3. Make `Workspace` the single owner of path policy, and add its unit tests.
4. Bound the shell runner's mailbox, not just the collected buffer (C9).
5. Generate the dev `secret_key_base` per install (S5).
6. Split `ChatLive`, `SettingsLive`, `Deploy` and `Agent.Session` along the seams above, and
   trim the comment-to-code ratio in `Shell.open/4` and `Store.save/3`.
