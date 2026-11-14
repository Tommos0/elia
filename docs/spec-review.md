# Spec review: what is left

A review of all 55 files in `specs/` (August 2026), and the topics taken from it
so far. The corpus rules are now written down and enforced (SPEC,
`specs/spec-hygiene.md`) and every requirement is accounted for by a test or a
`No test:` line (TRACE, `specs/test-traceability.md`), so what follows is the
remainder: the topics not yet started, the smaller findings, and the places
where a rule is deliberately left to a reviewer.

Status: five topics are merged into `master`, four are open, and the rest are
notes worth acting on later.

## Done

| Topic | What changed | Where |
| --- | --- | --- |
| A. Spec hygiene + lint | The rules, `specs/README.md`'s `## Rules`, the lint, the `ISOL-26` duplicate renumbered to `ISOL-28` with all 18 citations moved, dangling cross-references dropped, `Status:` lines reduced to one word, sections renamed | SPEC-1..SPEC-18, `test/elia/spec_hygiene_test.exs` |
| B. Test traceability | Every `## Tests` section maps files to IDs; a missing file, an unaccounted requirement or a malformed `No test:` line fails the suite; three wrong test paths corrected | TRACE-1..TRACE-9, `test/elia/spec_tests_test.exs`, `test/support/spec_lint.ex` |
| B2. Citations | The 84 requirements no test cited: 70 now cite the test that exercises them, 7 small tests were added, 14 IDs became `No test:` lines, 6 mis-attributions corrected (one was a real bug: nothing tested SPEC-1) | test comments across `test/` |
| C. Approval table | `APPR-7` names all 23 built-in tools with their approval and who gets them; a test reads the table out of the spec and compares it with the registry | APPR-15..APPR-18, `test/elia/tool_approval_test.exs` |
| D. Saved chat shape | `STORE-1` is the table of the saved chat, `STORE-6` the table of a listed chat, both enforced against the code; requirements regrouped by topic | STORE-40..STORE-42, `test/elia/store_shape_test.exs` |
| E. Per-chat settings | One `settings` map, one write path, one `{:settings, …}` event, one snapshot field, for `model`, `auto_approve`, `jail`, `limits`, `effort`; the file keys untouched | SESS-41, SESS-42, rewritten SESS-6/7/14/15/16/17/30/31/40, LIMIT-2, CSET-3 |

## Open topics, in the order they are worth taking

### F. Who owns the deploy surface

Three specs state the same deploy record and its page: `specs/deployment.md`
(DEPLOY-19, DEPLOY-20, DEPLOY-24..DEPLOY-26 — the steps, the record, going
back), `specs/settings.md` (CONF-19..CONF-24 — what the section shows, the
spinner, the elapsed clock, the rollback control, the `/recover` note) and
`specs/recovery.md` (RECOVER-10..RECOVER-15 — the plain-HTML page for when that
section's own UI is what broke). A change to the deploy record has to find all
three, and the same behaviour is stated twice in different words.

Constraint worth knowing: a requirement cannot simply be moved into the spec
that should own it, because SPEC-9 ties a file's IDs to its index row's prefix,
and renumbering is forbidden. So F is a text change, not a move:

- state the boundary in each of the three (deployment owns what a deploy does
  and what it records; settings owns the page that shows it; recovery owns the
  page that reaches the app when that page is broken);
- delete the sentences two of them both state, leaving one statement each, with
  a cross-reference from the other;
- add a `## Out of scope` line to each naming what the other two own, so the
  next feature has an obvious home.

### G. A stopped child turn is invisible to its parent

`SUBTASK-16`, `SUBTASK-17` and `SUBTASK-31` say a turn the user stops in a
sub-task's chat ends that turn and not the task: no result is recorded, the
saved status stays `"running"`, the entry is held and the parent's `await_task`
keeps waiting with no deadline of its own. `list_tasks` therefore reports
`"running"` while nothing runs, and the only place that shows the child is
stalled is the child's own transcript.

This is deliberate — `AGENTS.md` records it as a rule, and the alternative (a
`"cancelled"` result) was removed on purpose — but it is worth one more look:

- should `list_tasks` report a stopped child differently (`stopped`, or
  `running` with `since`), so a parent can tell "still working" from "nobody is
  working on it";
- should the parent's task card say so (UI-44), or is the child's own page the
  only honest place;
- what a parent should do when `await_task` has waited an hour on a child whose
  turn was stopped at the start.

Any answer changes SUBTASK-16/31, UI-44 and `list_tasks`' output, so it wants a
decision before a draft.

### H. `chat-ui.md` is 87 requirements and 37KB

It states routing, the chat list and its paging, the transcript, tool cards,
the composer, the layout, Markdown, reasoning, compaction's annotations,
sub-tasks' cards and the compact view. Two problems: a reader cannot find the
part they need, and every feature that touches the chat page edits the same
file.

Splitting it (a transcript spec, a chat-list spec) is the obvious fix and the
prefix rule is the obstacle: the IDs are `UI-n`, and a new file needs its own
prefix, which would mean renumbering — forbidden. The workable options are
(a) leave the file and add a table of contents plus subheadings that group the
requirements by view (no ID changes), or (b) split the file and keep the `UI`
prefix for both halves, which needs a deliberate exception in SPEC-9 (one
prefix, two files) rather than a renumbering.

### I. One place for the security posture

Six specs carry their own "Out of scope: access control" paragraph
(`client-sessions.md`, `system-dashboard.md`, `log-viewer.md`,
`file-explorer.md`, `terminal.md`, and `recovery.md`'s RECOVER-13), each saying
the app has no login and anyone who can reach it can approve commands, read
files, open a terminal in any chat's workspace and, in a jailed chat, still
write that workspace.

Put together that is a threat model nobody has stated in one place, and it is
re-argued in every spec that touches it. What it wants is one short spec (a
`SEC` prefix) recording the posture and the deliberate choices:

- no authentication, and why (a single-user machine behind the user's own
  network, a tunnel or an auth proxy);
- that the jail bounds a command's reach but not who may run one (ISOL-11);
- that `/recover` and its POST are guarded by same-origin only (RECOVER-13);
- the one place a jailed process can reach `.elia` (the harness's worktree
  administration, ISOL-22) and why that is accepted;
- what a deployment behind an auth proxy has to exclude (`/sw.js`, PWA's Out of
  scope) and what it must not (`/recover`).

The six existing out-of-scope paragraphs then point at it instead of restating
it.

## Smaller findings, not yet a topic

1. **A spec's `## Configuration` block is not checked by anything.** Two drifted
   this way: `skills.md`'s `builtin:` list named 6 of the 10 built-in skills
   (fixed), and `SKILL-7` had been missing the `terminal` skill since TERM
   landed (fixed during C). A lint that compares a spec's configuration block
   with the application's env would close the class; the alternative is a
   review rule, which is what let it drift.
2. **TRACE counts a browser test like a unit test.** A requirement covered only
   by `test/elia_web/browser/…` is accounted for by TRACE-2, though the default
   suite does not run it (BROWSER-5). A marker for "browser only" would be more
   honest about what a green `mix test` proves.
3. **Plans are outside TRACE** (`specs/plans/`), so a plan may cite an ID no spec
   defines without failing anything. SPEC-8 only checks that a plan is listed.
4. **Partial coverage, recorded while closing the 84 citations.** These claim a
   test that exists but asserts less than the requirement says — each is a
   small, real gap rather than a mis-citation: LOOP-10 (concurrency is not
   asserted, only the order of one tool message), LOOP-11 (`:done` status
   never), SESS-5 ("messages with empty content are dropped"), UI-8
   (right-alignment), UI-21 (Shift+Enter, the growing input), SKILL-2 (built-ins
   before folder skills), FOLDER-4 (`input_schema` and `timeout_seconds`
   defaults), STORE-8 (the `.git-ignore` half), PROJ-13 and WS-4 (both rest on
   one test's "whatever project a chat belongs to"), VERIFY-1 (`MIX_ENV=test`
   indirectly, through the run's output).
5. **The `No test:` lines are now the corpus' list of untested behaviour**, and
   it is worth reading once as a whole: `chat-ui.md` has nine (UI-5, UI-11,
   UI-12, UI-13, UI-17, UI-22, UI-23, UI-24, UI-49 — most are a few lines of
   `Phoenix.LiveViewTest` each, and were left out because they needed a page of
   their own state, not because they are untestable), `agent-sessions.md` has
   three (SESS-1, SESS-9, SESS-13), plus BROWSER-9, CLIENT-4, EXPL-14, ISOL-11,
   PWA-5, PRIO-9, SHELL-7 (an approved command escapes the workspace policy —
   asserted nowhere), and the reviewer-decided ones (SPEC-11..14, SPEC-18,
   TRACE-9).
6. **Review rules are now the only unenforced part of the corpus**: SPEC-18
   lists them (one statement per requirement, rationale outside one, required
   behaviour never under `Out of scope`, whether a stored shape needs a
   migration) and TRACE-9 adds whether a citation is the right one. A periodic
   read is what keeps them; there is no test that can.
7. **The suite was intermittently red on `master`** for a while — different
   tests each run (`task_ui_test.exs`'s chat-status tests, once the deployment
   tests), all passing alone. Another chat fixed it (`7bbc87f test: fix the two
   flakes the gate fails on`), and one flake of this review's own was fixed
   along the way: B2's `reload_skills` test asserted a clean registry, which any
   other test's leftover folder skill can break.

## Process notes

- Two sub-tasks drafted their own specs at the user's explicit request (A and
  B), which is a deliberate exception to `AGENTS.md`'s "sub-tasks implement
  only". Both were reviewed, amended and approved before merging; the exception
  is not a precedent for the topics above.
- The exception that mattered in practice was scope, not authorship: the A
  sub-task was told to draft only and implemented anyway. Its work was sound,
  and was reviewed and repaired (`## Terms` allowed and the deployment glossary
  restored), but a brief that says "draft only" needs the parent to check the
  branch before the report is believed.