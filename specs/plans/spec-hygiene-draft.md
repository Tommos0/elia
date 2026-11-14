# Spec hygiene

Status: Planned

The specs in `specs/` are the source of truth for Elia's behaviour, and code
comments, docs, tests and every chat cite them. Nothing checks the corpus
itself, and it has drifted: `ISOL-26` is used twice in `command-isolation.md`, a
citation names live requirements that mean something else (`checkpoints.md`
cites `FILE-8` and `FOLDER-9` for retired checkpoint behaviour), a `Status:`
line carries prose, and sections are named freely. This spec writes down the
rules the corpus mostly follows and adds one test that reads `specs/` and fails
on what a machine can decide. A violation is fixed in the change that
introduces it, and the ones the corpus has today are repaired here (see
Implementation).

## Requirements

### Identity

- **SPEC-1** A spec's requirements are numbered `<PREFIX>-<n>`, `n` a positive
  integer and `<PREFIX>` the prefix its index row gives the file.
- **SPEC-2** Every `PREFIX-n` in `specs/` names exactly one requirement.
- **SPEC-3** A requirement's ID is never renumbered or respelled once it is in
  the tree: a duplicate is a defect, and the requirement added later takes the
  next unused number of its prefix.
- **SPEC-4** A retired requirement keeps its number, and that number is spent:
  no requirement added later takes it.

### Retirement

- **SPEC-5** A retired requirement stays in place, struck through (`~~`), keeps
  its ID, and says why in the same entry (`Retired: …` or `Removed: …`). A spec
  whose requirements are all retired says `Status: Retired`.

### Status

- **SPEC-6** The `Status:` line is exactly one of `Implemented`, `Draft`,
  `Planned` or `Retired` — the one word and nothing else. What the status needs
  to explain goes on the lines below it.
- **SPEC-7** A retired spec's index row says so.

### Index

- **SPEC-8** Every file in `specs/` other than `README.md`, and every file in
  `specs/plans/`, is listed in `specs/README.md`: a spec as a row of the index
  table with its prefix, a plan under a plans list.
- **SPEC-9** Every index row's link resolves to a file that is there, in `specs/`
  for a spec and in `specs/plans/` for a plan, and the row's prefix is the one
  the file's IDs use.

### Shape

- **SPEC-10** A spec is a title, a `Status:` line, a paragraph saying what the
  feature is and why, and a `## Requirements` section. The only other `##`
  sections it uses are `Configuration`, `Out of scope`, `Stored data`,
  `Implementation` and `Tests`. Subheadings within any of them are free.
- **SPEC-11** A spec whose change alters a shape that outlives the process — a
  saved chat, the settings database, a saved skill or workflow, any stored file
  — has a `## Stored data` section whose opening says which it is: backward
  compatible (the new code still reads what an older version wrote), or needs
  migration.

### A requirement

- **SPEC-12** A requirement is one testable statement of behaviour, in the
  present tense.
- **SPEC-13** A requirement holds only that statement: rationale, history,
  incidents, line numbers, chat ids, worktree names and measured timings belong
  in the intro, the section's prose, a doc or the commit.
- **SPEC-14** `Out of scope` lists what is deliberately not required: no
  requirement ID appears in it, and required behaviour is never written there.

### Cross-references

- **SPEC-15** A cross-reference is a `PREFIX-n` some spec defines (a retired
  requirement counts as defined), a bare prefix, or a range within one prefix —
  never a number that names a different requirement than the one meant.

### The lint

- **SPEC-16** The default test suite runs a spec-hygiene test that reads every
  `specs/**/*.md` and fails on each violation of SPEC-1 to SPEC-15 that the text
  can decide, naming the file and, where the violation has one, the offending ID
  and line.
- **SPEC-17** The lint decides from the tree and nothing else — no app, no
  browser, no network, no live workspace — so it runs in `mix test`, `bin/test`
  and `mix precommit` like any other test.
- **SPEC-18** What the text cannot decide is a review rule, not a lint failure:
  one statement per requirement (SPEC-12), rationale or history inside a
  requirement (SPEC-13), required behaviour under `Out of scope` (SPEC-14).

## Implementation

- `specs/README.md`: the rules above, beside the workflow and format it already
  states, and a `## Plans` list holding `specs/plans/`. `AGENTS.md` needs no
  change: it already points at `specs/README.md`, which owns the corpus.
- `test/elia/spec_hygiene_test.exs`: the lint. It reads
  `Path.wildcard("specs/**/*.md")` from the workspace root, takes each file's
  title, `Status:` line, `##` sections, requirement lines (`- **PREFIX-n**`, or
  `- ~~**PREFIX-n**` retired) and cited `PREFIX-n` tokens, and asserts SPEC-16
  and SPEC-17. Fixtures — a few spec strings written to a `tmp` directory —
  cover each failure mode, so the lint is tested without breaking the corpus.
- The repairs this change makes, none of them a rule:
  - `ISOL-26` is used twice in `specs/command-isolation.md`: line 141 (the
    Playwright CLI bind, added in `e034357`, 2026-11-12) and line 185 (the mount
    lock, added in `9bf6184`, 2026-11-13). The lock is the newer requirement, so
    it takes the next unused `ISOL` number, `ISOL-28` (SPEC-3), and every
    citation of the lock changes with it: `specs/command-isolation.md` 185, 322,
    333, 354, 363; `AGENTS.md` 14; `docs/performance-review.md` 58, 67, 133,
    241, 258, 261; `lib/elia/application.ex` 38; `lib/elia/shell.ex` 290, 375,
    429; `lib/elia/shell/lock.ex` 3; `lib/elia/terminal/session.ex` 190, 318,
    352; `test/elia/command_isolation_test.exs` 268, 290, 305;
    `test/elia/shell_lock_test.exs` 2, 9; `test/elia/shell_test.exs` 320, 362.
    The Playwright bind keeps `ISOL-26`, which `specs/browser-tests.md` 94,
    `config/config.exs` 40, `docs/agents/testing.md` 64, `lib/elia/shell.ex`
    190, 485 and four test files already cite.
  - `specs/checkpoints.md` 15 and 28 cite `FILE-8` and `FOLDER-9` as retired
    checkpoint behaviour; both are live requirements about `edit_file` and
    script-tool output. The sentence stops naming them (`SHELL-6` stays, being
    the retired one) — SPEC-15.
  - `specs/subtasks.md` 3 and `specs/verification.md` 3 put prose on the
    `Status:` line: one word there, the rest below — SPEC-6.
  - `specs/chat-history.md` `## Data` (108) becomes `## Stored data`, the name
    `specs/step-timing.md` 77 already uses — SPEC-10, SPEC-11.
  - `specs/deployment.md` `## Terms` (26) and `## Specs to amend` (249),
    `specs/recovery.md` `## Retired requirements` (82) and `specs/subtasks.md`
    `## Out of scope (later phases of the plan)` (294) use sections outside
    SPEC-10's list: fold the terms into the intro, the specs to amend into
    `## Implementation`, the retired requirements into `## Requirements` in
    place, and drop `Out of scope`'s qualifier.
  - `specs/plans/subagents.md` gets its row in the plans list — SPEC-8.

## Tests

- `test/elia/spec_hygiene_test.exs` covers SPEC-16 and SPEC-17 with one fixture
  per failure mode: a duplicate ID within a prefix, a retired number reused, a
  `Status:` line with prose, a `Status:` line that isn't one of the four, a spec
  file missing from the index, a plan missing from the plans list, an index row
  whose file is gone, an index prefix that differs from the file's IDs, a
  `PREFIX-n` no spec defines, a `##` section outside SPEC-10's list, a
  requirement ID under `Out of scope`, and a retirement without a reason.
- One test runs the same lint against the real `specs/`: that is the gate the
  repairs above have to pass.
- SPEC-12, SPEC-13 and SPEC-14's prose half have no test, by SPEC-18.

## Out of scope

- The order of requirements within a section: `SESS-30` between `SESS-16` and
  `SESS-17` stays, and the lint says nothing about order.
- The corpus' prose: no rewriting, no splitting `chat-ui.md`, and no citation
  fixes in code and docs beyond the repairs named above.
- Whether code matches a requirement: each spec's own `## Tests` owns that.
- Linting `AGENTS.md`, `docs/`, `lib/` or `test/`, and checking that a spec's
  `## Tests` names a file that exists.
