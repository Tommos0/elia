# Validation record and remaining gates

[Method](METHOD.md) · [Sources](SOURCES.md) · [Machine results](../evidence/static-checks.json) · [Work packages](../ai/WORK-PACKAGES.md)

**No Elia application test, build, real-browser flow or real-jail reproduction was executed.** Elixir, Erlang and Mix were not installed in the review environment. The commands below establish narrower facts. “Unavailable” is an environment limitation, not a failing project test. Every finding's end-to-end runtime reproduction remains pending.

## Checks actually performed

| ID | Check | Recorded outcome | Interpretation |
| --- | --- | --- | --- |
| V01 | Runtime/tool availability | Elixir/Mix not found; Node v24.22.1, npm 11.9.0, Git 2.52.0, Python 3.12.14 available | Erlang was also absent on the earlier shell availability check; no BEAM runtime was provisioned |
| V02 | `mix precommit` invocation | Could not launch: executable missing | No compilation, formatting, dependency cleanup or test process ran |
| V03 | `sh -n` for all four `bin/` scripts | All exit 0 | Shell syntax only, not script behavior |
| V04 | Node module syntax parsing for four first-party asset JS files and `priv/static/sw.js` | All exit 0 | No import resolution, bundle generation, DOM or browser behavior tested |
| V05 | Strict JSON parsing of package metadata, lockfile and web manifest | All valid | `assets/tsconfig.json` is JSONC and intentionally excluded from strict JSON parsing |
| V06 | `sh bin/test --plan` | Exit 0; all 103 tracked `_test.exs` files assigned once; no extras/missing/duplicates | Test discovery/partition planning only; **zero tests executed** |
| V07 | Node package resolution in the fresh checkout | Both xterm packages return `MODULE_NOT_FOUND` | Supports the fresh-clone premise of DEV-01, not an observed Mix build failure |
| V08 | Generated symlink fixtures | Host read followed an external sentinel link; host write followed a directory alias to a protected-looking fixture | Filesystem semantics only; no Elia policy or bubblewrap path executed |
| V09 | Disposable Git reset fixture | Tracked source restored; ignored candidate asset remained; Git status clean | Git premise of DEP-01, not an Elia deployment reproduction |
| V10 | Source checkout status before/after | Clean and unchanged | Review artifacts and fixture mutations remained outside the clone |

Exact command arrays, stdout/stderr, booleans and inventory counts are in [static-checks.json](../evidence/static-checks.json). The [partition plan](../evidence/test-plan.txt) is the actual `--plan` output.

The first strict-JSON check included `tsconfig.json` and correctly rejected comments under strict JSON, which was inappropriate for that file's JSONC format. The check was corrected and rerun. This was a review-check correction, not a project defect or source change.

## Repository counts

| Metric | Count | How counted |
| --- | ---: | --- |
| Tracked paths | 339 | `git ls-files` at the pinned commit |
| Application `.ex` files | 93 | Tracked `lib/` paths ending in `.ex`; not a parsed module count |
| Application source lines | 29,326 | UTF-8 text line counts under `lib/`, including templates |
| Test files | 103 | Tracked `test/**/*_test.exs` paths |
| Test source lines | 32,686 | UTF-8 text lines under `test/`, including helpers |
| Approximate `test` declarations | 1,193 | Text regex at the beginning of lines; not executed-test count |
| Specification-directory Markdown files | 59 | Includes `specs/README.md` and the draft plan |

These are scope indicators. They establish neither test coverage percentage nor test success. Reading coverage is separately recorded in [the source ledger](source-ledger.json).

## Repeating the limited checks safely

Use a clean checkout of the exact reviewed SHA and choose an output directory outside it. From the extracted archive's `elia-review/` directory:

```sh
python3 verification/reproduce-static-checks.py \
  --repo /absolute/path/to/elia \
  --output /absolute/path/to/new-review-checks
```

The script rejects a different HEAD or dirty checkout. It reads source from Git objects, checks syntax, runs the known runner's `--plan`, and creates/removes disposable fixtures below the output directory. It does not fetch packages, start Elia or call a model. It checks Mix availability but **does not run `mix precommit` if Mix is installed**, because that alias can format/unlock files and execute the suite. The recorded unavailable-command branch reproduces this environment's V02 observation. The actual runtime gate is a separate, explicit task below.

Use a new output folder to keep the delivered evidence intact. Results can vary with OS/tool versions; review them rather than comparing only a single exit code. Node/npm/Git/Python are needed for the complete limited-check set.

## Runtime gates to execute next — not results of this review

| Lane | Execution outline | What it establishes |
| --- | --- | --- |
| Clean setup | In a disposable clone with isolated application state, follow the current literal README; record the missing npm dependency step before repairing it | DEV-01 baseline and clean-install acceptance |
| Required project gate | Run plain `mix precommit` in the approved implementation checkout, with no inherited `MIX_ENV` | Compile warnings, dependency/format checks and normal partitioned suite on that tree |
| Focused regressions | Run the specific source/test routes in [work packages](../ai/WORK-PACKAGES.md), with FakeLLM and deterministic process barriers | Each finding's actual observable behavior, including failure and recovery cases |
| Browser/transport | Install the documented browser prerequisites, build assets, then `ELIA_BROWSER_TESTS=1 mix test --only real_browser`; add real handshake coverage for W01 | Browser hooks, layout and transport behavior excluded from normal tests |
| Real isolation | Use a Linux host with working bubblewrap namespaces/overlay, verify tests do not skip the relevant branch, then execute A/B sentinel and readiness cases | Jail reachability and mount-lifetime outcomes |
| Deployment/restart | Disposable live/trunk fixture and isolated process/supervisor; inject failures and fetch actual served bytes | Bundle rollback and replacement-process acceptance |

Run these lanes sequentially through a shared test queue. The repository explicitly prohibits concurrent test invocations across worktrees because they share `/tmp/elia-test-pN`; the partitions inside one `bin/test` call are intended. Plain `mix test` and `mix precommit` exclude `real_browser` and `preview`. [Testing instructions](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/docs/agents/testing.md), [default exclusions](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/test_helper.exs), [precommit alias](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/mix.exs#L94-L101).

A future result should name command, exact SHA, environment, outcome and log location. Do not turn the pending acceptance descriptions in this archive into a claim that the test already exists or passes.

## Review-package checks

The final editorial pass reconciled IDs, priorities, conditional claims and the human/machine reading routes. Automated checks validate local Markdown links, pinned repository paths and cited line bounds, all JSON files, Python syntax, all finding-to-route assignments and the unchanged source checkout. [Package validation record](../evidence/package-validation.json).

The archive includes [a SHA-256 manifest](../MANIFEST.sha256) for every included file except the manifest itself. The completed zip is also checked for readable entries, safe relative member paths and matching manifest hashes before delivery. These checks validate the deliverable's consistency and transport, not application correctness.
