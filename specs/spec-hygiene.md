# Spec hygiene

Status: Implemented

The specs in `specs/` are the source of truth for Elia's behaviour, and code
comments, docs, tests and every chat cite them. Nothing checked the corpus
itself, and it had drifted: `ISOL-26` was defined twice in
`specs/command-isolation.md`, a citation named live requirements that mean
something else, a `Status:` line carried prose, and sections were named freely.
This spec writes down the rules the corpus mostly followed and adds one test
that reads `specs/` and fails on what a machine can decide. A violation is fixed
in the change that introduces it; the ones the corpus had are repaired here (see
Implementation).

Chats of a project run in parallel, and the next free number of a prefix was
read out of the corpus, which two chats drafting at once do at the same instant:
they take the same number and one of them has to renumber, which SPEC-3 forbids.
So the corpus gains one more rule — a chat reserves the numbers it is about to
use before it drafts — and `bin/reserve` is the helper that does it.

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

### Reserving a number

A reservation is a directory named for the number, under `elia-reservations/` in
the repository's git directory (`git rev-parse --git-common-dir`). Making it is
`mkdir`, which is atomic: of two chats that reach for the same number at the same
instant exactly one makes the directory and the other takes the next one, so a
number is never given to two chats. The git directory is the store because the
live tree and every worktree of a project share it — a worktree's `.git` file
names it, and the jail binds it (ISOL-4, ISOL-13) — it is outside the working
tree, so git never reports it, and a chat's jailed command reaches it. A
reservation holds nothing else: the directory is empty, and `bin/reserve` is its
only reader.

- **SPEC-19** A chat about to draft reserves the IDs it will use before it drafts
  — `bin/reserve <PREFIX> <count>` — and drafts with the numbers it is given: the
  next unused numbers of the prefix that no reservation holds (SPEC-3).
- **SPEC-20** Two chats reserving the same prefix at the same time are never
  given the same number: a number is reserved by one chat only, and a chat that
  loses the race takes the next one.
- **SPEC-21** Reservations live in the repository's git directory, so every
  worktree of a project and the live tree read the same ones and a chat's jailed
  command reaches them.
- **SPEC-22** A reservation is bookkeeping, not corpus: it is not committed, it
  appears in no `git status --porcelain`, and a reserved number that is never
  used stays unused.
- **SPEC-23** `bin/reserve <PREFIX> [<count>]` prints the IDs to use, one per
  line, and exits 0.
- **SPEC-24** `bin/reserve` given no prefix, a prefix that is not a requirement
  prefix, or a count that is not a positive whole number exits non-zero, says why
  on stderr, and reserves nothing.
- **SPEC-25** A chat that cannot reserve — no `bin/reserve`, no git repository, a
  store it cannot write — takes the next unused number of the prefix from the
  corpus (SPEC-3): reserving is an addition to that rule, never a prerequisite
  for drafting.

### Retirement

- **SPEC-5** A retired requirement stays in place, struck through (`~~`), keeps
  its ID, and says why in the same entry, after a marker: `Retired: …`,
  `Removed: …` or `Superseded by …`. A spec whose requirements are all retired
  says `Status: Retired`.

### Status

- **SPEC-6** The `Status:` line is exactly one of `Implemented`, `Draft`,
  `Planned` or `Retired` — the one word and nothing else. What the status needs
  to explain goes on the lines below it.
- **SPEC-7** A retired spec's index row says so.

### Index

- **SPEC-8** Every file in `specs/` other than `README.md`, and every file in
  `specs/plans/`, is listed in `specs/README.md`: a spec as a row of the index
  table with its prefix, a plan under the `## Plans` list.
- **SPEC-9** Every index row's link resolves to a file that is there, in
  `specs/` for a spec and in `specs/plans/` for a plan, and the row's prefix is
  the one the file's IDs use.

### Shape

- **SPEC-10** A spec is a title, a `Status:` line, a paragraph saying what the
  feature is and why, and a `## Requirements` section. The only other `##`
  sections it uses are `Configuration`, `Terms`, `Out of scope`, `Stored data`,
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
  requirement is defined in it, and required behaviour is never written there.

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
  requirement (SPEC-13), required behaviour under `Out of scope` (SPEC-14), and
  whether a change to a stored shape is backward compatible (SPEC-11).

## Implementation

- `bin/reserve` (SPEC-19 to SPEC-25): the corpus scan that finds the highest
  number a `specs/*.md` defines for a prefix, the store under the repository's
  git directory, and the numbers it prints. `AGENTS.md` and `specs/README.md` are
  where a chat reads the rule before it drafts, and `docs/agents/harness.md` says
  where the store is.
- `specs/README.md`: the rules above, beside the workflow and format it already
  states, and a `## Plans` list holding `specs/plans/`. `AGENTS.md` needs no
  change: it already points at `specs/README.md`, which owns the corpus.
- `test/support/spec_lint.ex`: the lint, `Elia.SpecLint` — `hygiene/1` for SPEC
  and `traceability/1` for TRACE (`specs/test-traceability.md`), sharing one
  reader of the corpus. It
  reads `specs/**/*.md` from the workspace root, takes each file's title,
  `Status:` line, `##` sections, requirement entries (`- **PREFIX-n**`, or
  `- ~~**PREFIX-n**` retired) and cited `PREFIX-n` tokens, and returns one
  message per violation of SPEC-1 to SPEC-10, SPEC-14 and SPEC-15. Fixtures — a
  few spec strings written to a `tmp` directory — cover each failure mode, so
  the lint is tested without breaking the corpus, and one test runs it against
  the real `specs/`.
- The repairs this change makes, none of them a rule:
  - `ISOL-26` was defined twice in `specs/command-isolation.md`: once for the
    Playwright CLI bind, once for the mount lock added later. The lock is the
    newer requirement, so it takes the next unused `ISOL` number, `ISOL-28`
    (SPEC-3), and every citation of the lock changes with it:
    `specs/command-isolation.md` (the definition and its four citations),
    `docs/performance-review.md`, `lib/elia/application.ex`,
    `lib/elia/shell.ex`, `lib/elia/shell/lock.ex`,
    `lib/elia/terminal/session.ex`, `test/elia/command_isolation_test.exs`,
    `test/elia/shell_lock_test.exs` and `test/elia/shell_test.exs`. The
    Playwright bind keeps `ISOL-26`, which `specs/browser-tests.md`,
    `config/config.exs`, `docs/agents/testing.md`, `lib/elia/shell.ex` and four
    test files already cite. `AGENTS.md`'s batching rule cited the lock's number
    for the jail's own `/tmp` and pid namespace, which is `ISOL-2` and `ISOL-9`,
    and cites those.
  - `specs/checkpoints.md` cited `FILE-8` and `FOLDER-9` as retired checkpoint
    behaviour; both are live requirements about `edit_file` (retired since, with
    the file tools) and script-tool
    output. The sentence stops naming them (`SHELL-6` stays, being the retired
    one) — SPEC-15.
  - `specs/subtasks.md` and `specs/verification.md` put prose on the `Status:`
    line: one word there, the rest below — SPEC-6.
  - `specs/chat-history.md`'s `## Data` became `## Stored data`, the name
    `specs/step-timing.md` already used — SPEC-10, SPEC-11.
  - `specs/deployment.md`'s `## Terms` moved into its intro and its
    `## Specs to amend` into `## Implementation`, `specs/recovery.md`'s
    `## Retired requirements` folded into `## Requirements` in place, and
    `specs/subtasks.md`'s `## Out of scope (later phases of the plan)` dropped
    its qualifier — SPEC-10.
  - `specs/plans/subagents.md`, referenced by `specs/subtasks.md` but in no
    list, got its row in the plans list — SPEC-8.

## Stored data

Backward compatible: the store is `<git dir>/elia-reservations/<PREFIX>-<n>/`, an
empty directory per reserved number, written and read by `bin/reserve` alone. No
part of the app reads it, and a tree that has none has no reservations, which is
what the script reads it as (SPEC-25).

## Tests

- `test/elia/reserve_script_test.exs` (the numbers printed, a prefix nobody has
  used, a reserved number skipped, concurrent reservations, two worktrees of one
  repository, the store out of `git status`, the corpus fallback and the refusals
  — SPEC-19, SPEC-20, SPEC-22 to SPEC-25).
- `test/elia/command_isolation_test.exs` (a jailed command in a chat worktree
  reaches the store through its `.git` pointer file — SPEC-21).
- `test/elia/spec_hygiene_test.exs` covers SPEC-16 and SPEC-17 with one fixture
  per failure mode: a duplicate ID within a prefix (SPEC-2), a retired number
  reused (SPEC-3, SPEC-4), a `Status:` line with prose and one outside the four
  (SPEC-6), a spec file missing from the index and a plan missing from the plans
  list (SPEC-8), an index row whose file is gone (SPEC-9), an index prefix that
  differs from the file's IDs (SPEC-9), a file whose requirements use two
  prefixes (SPEC-1), a retired spec whose row doesn't say so (SPEC-7), a
  retirement with a reason and one without (SPEC-5), a `##`
  section outside SPEC-10's list (SPEC-10), a requirement defined under
  `Out of scope` (SPEC-14), and a `PREFIX-n` no spec defines (SPEC-15).
- One test runs the same lint against the real `specs/`: that is the gate the
  repairs above have to pass (SPEC-16).
- No test: SPEC-11, SPEC-12, SPEC-13, SPEC-14's prose half, SPEC-18 — they are
  what a reviewer decides, not what the text can.

## Out of scope

- The order of requirements within a section: `SESS-30` between `SESS-16` and
  `SESS-17` stays, and the lint says nothing about order.
- The corpus' prose: no rewriting, no splitting `chat-ui.md`, and no citation
  fixes in code and docs beyond the repairs named above.
- Whether code matches a requirement: each spec's own `## Tests` owns that.
- Linting `AGENTS.md`, `docs/`, `lib/` or `test/`.
- Checking that every requirement is accounted for by a test or a `No test:`
  line, and that a `## Tests` section names a file that exists:
  `test-traceability.md` (TRACE) owns that.
- The harness reserving for a chat: a chat runs `bin/reserve` itself, and one
  that forgets takes the corpus' next free number as before (SPEC-25).
- Releasing a reservation: the store keeps a number until the corpus defines it
  (SPEC-22), and a chat that reserved one it did not use may `rmdir` that
  directory itself — `bin/reserve` only ever takes numbers, never gives one
  back.
