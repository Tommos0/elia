# Spec corpus review

Scope: the 74 specs in `specs/` and the plan, read against the rules in `specs/README.md` (SPEC)
and `specs/test-traceability.md` (TRACE), and checked against `lib/` where a finding depends on it.
Findings run from most to least severe. "→" is the suggested change.

## 1. Contradictions

**C1. `cd` into a protected path: two specs say it's refused, but the spec that owns `cd` and the code allow it.**
`specs/workspace-policy.md:62` (WS-7) says a path that resolves into `.git`/`_build`/`deps`/`.elia`
"is refused where a protected path is (WD-5, SKILL-17)". `specs/working-directory.md:94` (Out of scope)
says "`cd` into them is refused". But WD-5 (`specs/working-directory.md:33`) only refuses missing,
non-directory, unresolvable or *outside* paths, and `lib/elia/workdir.ex:47` checks only `:outside`.
So `cd .git` succeeds today. The Out-of-scope bullet also breaks SPEC-14 (it states required behaviour).
→ Decide which is right. If `cd` should refuse protected paths, add "or whose real location is
`:protected` (WS-7)" to WD-5 and fix `Workdir.resolve/3`. If not, drop WD-5 from WS-7's list and delete
the Out-of-scope bullet. Either way, add a test that cites WD-5 or WS-7 for `.git`.

**C2. DEPLOY-5 puts the suite before the merge; HOT-4 and the code put it after.**
`specs/deployment.md:139` says a deploy "runs the full test suite in the live tree … then fast-forwards
`live` to `master` when the tests pass; when they fail it rolls `live` back". You can't roll back a
branch that hasn't moved yet. HOT-4/HOT-5 (`specs/hot-reload.md:23-26`) and `@steps [:merge, :deps, :tests, …]`
(`lib/elia/deploy.ex:80`) merge first and test the merged tree.
→ Reword DEPLOY-5: "fast-forwards `live` to `master`, fetches deps (DEPLOY-18), runs the full suite in
the live tree; if it fails, `live` is reset to where it was and nothing is loaded".

**C3. Two origin rules that disagree behind a proxy.**
RECOVER-13 (`specs/recovery.md:57`) and SERVE-5 (`specs/preview-host.md:36`) trust `X-Forwarded-Proto`
and `X-Forwarded-Host` when deciding same-origin. `specs/socket-origin.md:66` (Out of scope) refuses to
trust exactly those headers for the socket's origin check, and `specs/client-sessions.md:66` notes they
can be spoofed when clients connect directly. Behind a TLS proxy, `/recover`'s POST is accepted while
the socket is refused unless SOCK-4 origins are configured. Without a proxy, `/recover`'s check can be
fooled by forged headers.
→ Write one origin rule, owned by SOCK, and have RECOVER-13 and SERVE-5 cite it. Either everything
trusts forwarded headers only from configured proxies, or everything uses SOCK-4's configured origins.

**C4. DEPLOY-10's retirement note contradicts chat-worktrees.**
`specs/deployment.md:474-483` still says "the worktree a chat made itself is one it removes once its work
is merged", that the user clears leftovers "with ordinary git", and that "nothing prunes by time".
WTREE-5, WTREE-6 and WTREE-7 (`specs/chat-worktrees.md:43-55`) say the chat removes nothing and a timed
sweep prunes. WTREE-7 cites this retired text as its authority. The `Elia.Deploy` moduledoc
(`lib/elia/deploy.ex:19`) has the same stale sentence.
→ Edit the retirement reason to "Retired: the harness creates no worktree; a chat's own worktree is
swept by WTREE-6/WTREE-7". In WTREE-7, cite STORE-23 (delete removes only the chat), not DEPLOY-10.

**C5. The RESUME index row describes a registry that was retired.**
`specs/README.md:136` says sub-task chats resume "with their entry in the running-children registry
taken again". RESUME-7 (`specs/auto-resume.md:93-105`) says there is no entry to take (SUBTASK-11 is
retired).
→ Row: "…sub-task chats included, which need nothing put back first — once per turn…".

**C6. SPEC-22 says an unused reservation stays unused; SPEC's Out of scope lets a chat release it.**
SPEC-22 (`specs/spec-hygiene.md`, Reserving a number) and `specs/README.md:13` say "a reserved number
that is never used stays unused". `specs/spec-hygiene.md:230` lets a chat `rmdir` its reservation, and
then `bin/reserve` hands the number out again.
→ Pick one. Recommended: keep SPEC-22 strict and delete the `rmdir` clause. Otherwise amend SPEC-22:
"…stays unused unless its reserving chat releases it before any commit names it".

**C7. "Always needs approval" vs "auto-approved by default".**
SHELL-1 (`specs/shell-tool.md:18`, "Every `shell` call needs approval"), the APPR-7 `always` rows and
APPR-16's definition ("needs it for every call") all read as if the user is asked each time. APPR-14
(`specs/tool-approval.md:76`) puts every such tool in a new chat's auto-approved set, so by default
nothing asks. ISOL-19's "no tool is auto-approved" (`specs/command-isolation.md:292`) then reads as false.
→ Rename the APPR-16 value to something like `asks` ("pauses unless auto-approved, APPR-8/APPR-14"),
and reword SHELL-1 and ISOL-19 to match.

## 2. Gaps

**G1. Code spawns processes outside the single spawn point that ISOL-1 and PRIO-2 promise.**
ISOL-1 (`specs/command-isolation.md:26`) says every git call the harness makes goes through
`Elia.Shell`. PRIO-2 (`specs/process-priority.md:27`) calls `Elia.Shell.execute/3` "the single spawn
point". But `lib/elia/worktrees.ex:260` (the WTREE sweep) and `lib/elia/projects.ex:508,521` (project
creation, PROJ-38) call `System.cmd("git", …)` directly: unjailed, not niced, no timeout.
→ Either route them through `Elia.Shell`, or add requirements that name these host-side git calls as
exceptions (and say why), then fix ISOL-1 and PRIO-2's lists.

**G2. ISOL-1 describes a migration, not behaviour, and names a module that no longer exists.**
"the `System.cmd("git", …)` calls in `Elia.Tasks` and `Elia.Deploy` move behind it, since they bypass
it today" (`specs/command-isolation.md:30`). `Elia.Tasks` is gone, and `Elia.Deploy` no longer calls git
directly.
→ Delete the sentence. With G1 fixed, ISOL-1 is a plain list.

**G3. Requirements claimed by a Tests section that no test cites.**
These pass TRACE only because a range or a prose claim in a `## Tests` section covers them; no file
under `test/` mentions the ID: APPR-5, APPR-6, LIMIT-4 (the Continue/Fail decision), STORE-8, NET-2,
PUSH-6, PUSH-10, TERM-6, LLM-8, LOCAL-12, FEED-8, CONN-3, PREVIEW-14, FOLDER-9. For example,
`specs/turn-limits.md:170` covers "LIMIT-1 to LIMIT-4". This is TRACE-9's review gap.
→ Add `# ID` citations to the tests that really cover each one, or move them to `No test:` lines.
Consider a TRACE rule that a range in a Tests section only counts for IDs some test file cites.

**G4. Stored state with no `## Stored data` section (SPEC-11).**
These specs define per-chat or per-install state that outlives the process, with no `## Stored data`:
`turn-limits.md` (limits, `pause_on_limit`), `tool-approval.md` (auto-approved set), `command-isolation.md`
(jail setting), `chat-settings.md`, `chat-titles.md`, `model-selection.md`, `push-notifications.md`
(subscriptions), `llamacpp-provider.md` (LOCAL-28 settings), `project-secrets.md`.
→ Give each a short `## Stored data`: the key, where it lives, and that a missing key reads as the default.

**G5. DASH-9's chat count has no live definition.**
DASH-9 (`specs/dashboard.md:108`) says "how many chats it has". The code counts project-less chats under
Elia's own project, the rule of the retired PROJ-23 (`lib/elia_web/live/dashboard_live.ex:184`).
→ State that rule in DASH-9.

**G6. Uploads in another project.** UPLOAD-6 writes `<project>/uploads/`. Elia's `.gitignore:56`
ignores it, but nothing ignores it in other projects. → Say whether that's intended.

## 3. Status honesty

No spec is `Draft` or `Planned`, and all five `Retired` specs have no live requirement. Within
`Implemented` specs, though, some text no longer matches the code:
- `specs/spec-hygiene.md:178` lists "deployment.md's `## Terms` moved into its intro" as a repair.
  `specs/deployment.md:33` has `## Terms` again. → Drop the claim (Terms is an allowed section).
- Module names that don't exist: `EliaWeb.Live.ChatLive` (`specs/chat-worktrees.md:105`, the module is
  `EliaWeb.ChatLive`); `Elia.Net.Relay` (`specs/network-access.md:267`, the relay is the script
  `priv/net/relay.exs`); `Elia.Agent.Registry` (`specs/agent-sessions.md:149,308`) is a `Registry`
  name, not a module. Fix the names.
- DEPLOY-1 (`specs/deployment.md:56`) says "its file and shell tools resolve against". The file tools
  are retired (FILE). → "its shell commands and `cd`".
- `lib/elia/llm/openai.ex:21` cites `LOCAL-30`, which no spec defines (LOCAL stops at 28). SPEC-15 lints
  only `specs/`. → Fix the comment or reserve the ID.

## 4. Sharpness

**S1. History inside requirements (SPEC-13), at scale.** 49 `*Changed:*` notes sit inside live
requirements: subtasks.md 13, chat-ui.md 11, agent-sessions.md 5, persistence.md 4, and others. Another
~57 live requirements say "used to", "no longer" or "today". Examples: SESS-6/SESS-18/SESS-22
(`specs/agent-sessions.md:28,131,171`), RESUME-7, LIMIT-5, UI-43/UI-48/UI-49, WTREE-5, DASH-9, DONE-1.
These notes are also why 70 live requirements cite retired IDs.
→ Move each `*Changed:*` note into the spec's intro or a "History" paragraph under Implementation, or
into the commit. Have the hygiene lint flag `*Changed:*` inside a requirement entry.

**S2. Requirements anchored to "today".** VISION-4 (`specs/image-input.md:34`, "sent what it is sent
today"), ISOL-12 (`:150`, "runs unjailed as it does today"), SUITE-6, VERIFY-8 and VERIFY-9. These
can't be tested once the code moves.
→ State the behaviour itself, e.g. VISION-4: "is sent the UPLOAD-10 path line and no image".

**S3. Requirements that are several requirements.** 56 live requirements run past 150 words. The longest
are UI-103 (`specs/chat-ui.md:281`, 286 words), STOP-2 (`specs/stopped-turns.md:30`, 270 words, one
sub-rule per stop kind), SESS-44, COMPACT-29, DEPLOY-19, DEPLOY-26, EXPL-24, SESS-6 (an event catalogue).
This breaks SPEC-12, and a test can only cite the whole blob.
→ Split them with new reserved IDs, e.g. STOP-2's five kinds, UI-103's three triggers and its
render/close rules. Keep event catalogues like SESS-6 as tables in Terms, with one requirement for the
broadcast contract.

**S4. Implementation in place of behaviour.** 158 live requirements name an `Elia…` module or function
(agent-sessions 17, deployment 16, persistence 14, projects 11). Some are the API under test, as in
STORE; many are prose ("The single spawn point is `Elia.Shell.execute/3`").
→ Where the requirement is about user-visible behaviour, move module names to `## Implementation`.

**S5. A class split with no behaviour behind it.** WS-1/WS-3 (`specs/workspace-policy.md:25`) separate
`:extension` from `:core`, but every caller accepts both (`lib/elia/skills.ex:204`). → Merge or justify.

**S6. Wrong cross-references (SPEC-15 in spirit; the lint can't see them).**
- SUBTASK-1 (`specs/subtasks.md:42`) cites APPR-5 for "a `spawn_task` call needs approval". APPR-5 is
  "no tool runs until every pending call is decided". APPR-7 says `spawn_task` is `always (SUBTASK-2)`,
  and SUBTASK-2 says nothing about approval. → Both should cite APPR-7.
- WTREE-6 cites STORE-34 (the done flag) for `updated_at`. → STORE-1.
- DEPLOY-6 (`specs/deployment.md:252`) cites "HOT-1–HOT-6", but HOT-1 is retired. The en-dash range is
  also outside TRACE's range syntax. → "HOT-2 to HOT-6".
- DEPLOY-8 (`:278`) rests on the retired GUARD-8, and PRIO-2 on the retired ISOL-7. Retired IDs count as
  defined, so these pass SPEC-15, but they point the reader to dead text. → Cite the live successor.

## 5. Duplication

**D1. The terminal mark is specified four times.** UI-111 (`specs/chat-ui.md:241`), ACTIVE-13
(`specs/active-chats.md:95`), PROJ-59 (`specs/projects.md:281`) and DASH-15 (`specs/dashboard.md:97`)
are near-verbatim (78% shingle overlap). Meanwhile the worktree mark (WTREE-1) is deliberately left off
the dashboard and the active list (`specs/chat-worktrees.md` Out of scope), so the "chat marks" across
surfaces are already inconsistent.
→ One requirement in UI ("every chat row, on every surface listed in UI-x, draws the marks: terminal,
worktree…"), plus one id-scheme rule. Each surface's spec keeps only its id prefix.

**D2. Rename in place is specified twice.** ACTIVE-10 (`specs/active-chats.md:76`) and UI-104
(`specs/chat-ui.md:302`), 62% overlap, with small drift: only UI-104 says the row's `title` attribute
stays the description. The menus repeat the same way: ACTIVE-8 and UI-103.
→ Define "a chat row's menu" and "rename in place" once (in TITLE, or a new "Chat rows" spec) and
reference it.

**D3. SPEC-17 and TRACE-8 are the same requirement** (94% overlap: the lint decides from the tree alone).
→ TRACE-8: "The traceability lint runs as SPEC-17 says." Or move both into one "corpus lints" rule.

**D4. `chat-ui.md` is 1,009 lines and over 110 IDs.** It holds sub-task cards, chat-list rows and
menus (UI-59 to UI-110, partly repeated in ACTIVE and DONE-2) and the composer. → Split out "Chat list",
but SPEC-1 ties a prefix to one file, so first decide whether a prefix may span two files.

## 6. Corpus structure

The index matches the disk, every row resolves, prefixes match, and no ID is defined twice (the lint passes).

- Undefined IDs cited outside specs: `LOCAL-30` (see §3). `CITE-77` and `LLM-01`/`LLM-02` are test
  fixtures and `docs/gpt-review/` notes, which is fine.
- Holes in numbering: UI-102 and DEPLOY-45. UI-101/102 were committed for the row menu in `94eba26`, then
  renumbered to UI-103/104 in `dbca08f` because UI-101 had been taken for the unjailed prompt. That is
  the race SPEC-19 exists for, and renumbering an ID already in the tree breaks SPEC-3. → No change now
  (the hole is a spent number, SPEC-22). But note in `docs/agents/` that a drafted spec is reserved before
  its docs commit.
- 9 retired IDs are still cited in `lib/` as the reason for live code: DEPLOY-10 (`lib/elia/store.ex:685`),
  PROJ-23 (3 places), PROJ-24, SERVE-6, SERVE-7, SESS-20, UI-44, UI-50 (`lib/elia_web/chat_status.ex:8-9`).
  → Each should cite the live requirement that now justifies the code. A cheap lint: no `lib/` comment
  cites a struck-through ID.
