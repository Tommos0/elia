# Test traceability

Status: Implemented

Each spec's `## Tests` section is the record of which test file covers which
requirement — a chat reads it to find the test for a behaviour, and the suite's
own hygiene depends on the record being true. Nothing checked it, and the corpus
had drifted both ways: six specs listed test files with no requirement IDs at
all, so nothing said which of their requirements was covered; a spec cited
`test/elia/harness_test.exs` long after that file was deleted, and one cited
`test/elia_web/channels/terminal_channel_test.exs` when the file lives at
`test/elia_web/terminal_channel_test.exs`; and requirements went unaccounted for
without anything noticing. This spec writes down the convention the corpus
mostly followed and adds a lint that makes it hold.

## Requirements

- **TRACE-1** A spec's `## Tests` section records which test files cover which
  requirements: a test file is named, and the requirement IDs it covers follow
  it in parentheses — `` `test/elia/store_test.exs` (STORE-29, STORE-34)``. Other
  prose may follow the parenthetical.
- **TRACE-2** Every requirement is accounted for: its ID appears in some spec's
  `## Tests` section, or on a `No test:` line in the `## Tests` section of the
  spec that defines it. Coverage may be recorded in another spec than the one
  that defines the requirement.
- **TRACE-3** A `No test:` line names the requirement IDs it exempts before an
  em dash and says after it why they are not tested
  (`No test: CLIENT-4 — tracking across nodes needs more than one node`).
- **TRACE-4** A `No test:` line names only requirements that the spec holding it
  defines.
- **TRACE-5** A retired requirement is exempt: nothing tests it, and no
  `No test:` line is needed for it.
- **TRACE-6** Every path a `## Tests` section names that starts with `test/`
  exists in the tree.
- **TRACE-7** The traceability lint fails on each violation of TRACE-2 to
  TRACE-6 that the text can decide, naming the spec file, the requirement ID and
  the line.
- **TRACE-8** The lint decides from the tree and nothing else — no app, no
  browser, no network, no live workspace — so it runs in `mix test`, `bin/test`
  and `mix precommit` like any other test.
- **TRACE-9** Whether a test really covers the requirement it claims, and
  whether a section attributes an ID to the right file, are review rules: the
  citation in the test (`# SHELL-3` in its name or a comment,
  `docs/agents/testing.md`) is the evidence, and the lint checks the accounting,
  not the quality.

## Implementation

- `test/support/spec_lint.ex`: one reader of the corpus, shared by both lints.
  `Elia.SpecLint.hygiene/1` is the SPEC one (`specs/spec-hygiene.md`), and
  `Elia.SpecLint.traceability/1` is this one: it takes each spec's `## Tests`
  section, reads every path in it that starts with `test/` (`@test_path`), and
  reads the requirement IDs of the section as one text, so a range whose two ends
  sit on different lines is still the range it is. A range is written
  `X-1 to X-4`,
  `X-1..X-4` or `X-1 - X-4`: an em dash is not a separator, because the corpus
  punctuates its prose with one. A `No test:` line is a line that starts with it
  after an optional `- `, and its reason is what follows the em dash.
- `test/elia/spec_tests_test.exs`: the lint's own tests — a fixture per failure
  mode (an unaccounted requirement, a file that is not there, a `No test:` line
  without a reason or for another spec's requirement, a retired requirement that
  needs no accounting, a range) and one test that runs the lint against the real
  `specs/`. `test/elia/spec_hygiene_test.exs` is unchanged apart from calling the
  moved module.
- `specs/README.md` states the rule beside the others, and `docs/agents/testing.md`
  and `AGENTS.md` say the lint exists.
- The repairs this change makes, none of them a new rule: every `## Tests`
  section that named a test file without saying which requirements it covers now
  says so, and the requirements that nothing tests are on `No test:` lines. Where
  the tree shows a test citing an ID, the section names that file; where a
  section's own prose already claimed a file covers the behaviour, the IDs that
  claim covers are attached to it; where neither, the requirement is on a
  `No test:` line with its reason. Three sections named a path that was not the
  one in the tree — `specs/terminal.md`'s channel test, `specs/checkpoints.md`'s
  fake checkpoints helper and `specs/guarded-files.md`'s retired test file — and
  now name the file that is there, or no path at all where the file is gone.
- No stored shape changes: the lint reads Markdown and test paths and writes
  nothing, so there is no `## Stored data` section and nothing to migrate.

## Tests

- `test/elia/spec_tests_test.exs` covers TRACE-1 and TRACE-2 with a requirement
  another spec's section cites and a range of IDs, and TRACE-2 to TRACE-6 with
  one fixture per failure mode: a requirement no section cites, a test file that
  is not in the tree, a `No test:` line that accounts for a requirement, one
  without a reason, one that names no requirement, and one for a requirement
  another spec defines. One test runs the lint against the real `specs/`, which
  is the gate the repairs above have to pass (TRACE-7, TRACE-8).
- No test: TRACE-9 — whether a test covers what it claims is what a reviewer
  reads the citations for.

## Out of scope

- Whether a test's citation is the right one, or a test covers a requirement
  well: TRACE-9 leaves that to review.
- The plans in `specs/plans/`, which have no requirement IDs.
- Requiring a `## Tests` section to consist only of bullets, or a named file to
  be a `_test.exs`: a section may name a helper under `test/support/`, and its
  prose may explain what the files hold.
- Linting `AGENTS.md`, `docs/`, `lib/` or a test file's own citations.
