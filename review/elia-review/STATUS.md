# Review status — what the tree has done since the snapshot

[Start](README.md) · [17 findings](FINDINGS.md) · [Open questions](review/OPEN-QUESTIONS.md) · [Checksums](MANIFEST.sha256)

**This note is not part of the review as delivered.** The review was written at
`5be0bd8` on 15 November 2026, and its own documents are left exactly as it wrote
them: no finding is renumbered, none is quietly dropped, and no finding text is
edited — a fixed finding reads here as open in the document that made it. This
file records what the code has done about them since, checked against the source
at `master` `87835fb` on 21 November 2026 rather than inferred from commit
messages.

## All 17 findings are closed

Every fix below is in both `master` and `live`, with a test, and with a
specification of its own wherever the behaviour had none.

| Finding | Fix | Spec and requirement |
| --- | --- | --- |
| SEC-01, SEC-02 | `e113c74` — a path is judged by where it lands, not how it is written | `specs/file-tools.md` (WS-7 to WS-9, SKILL-17, SKILL-18, FILE-39 to FILE-42) |
| SEC-03, SEC-04 | `0c0289a` — the jail holds the workspace, one profile, and `ELIA_CHAT_ID` | `specs/command-isolation.md` (ISOL-6, ISOL-13; the per-worktree overlay, the read-only fallback and their mount lock are retired with ISOL-7, ISOL-27 to ISOL-29) |
| CORE-01 | `e79b905` — a sub-task of another project works in that project, not in Elia's tree | `specs/agent-sessions.md` (SESS-23) |
| CORE-02 | `e749d27` — a session's loop and its tools end with the session | `specs/agent-sessions.md` (SESS-45) |
| CORE-03 | `4f3b43f` — contain a malformed saved chat so one bad file can't take out the listing | `specs/persistence.md` (STORE-48, STORE-49) |
| CORE-04 | `018157b` — a failed save keeps the chat unsaved and is retried | `specs/agent-sessions.md`, `specs/persistence.md` (SESS-46, STORE-47) |
| W01 | `9336067` — bind socket handshakes to this server's origin | `specs/socket-origin.md` (SOCK-1 to SOCK-5) |
| W02 | `b63cf6f` — the terminal page starts and warns from the jail as it is now | `specs/terminal.md` (TERM-37 to TERM-39) |
| W03 | `fb6e555` — serialize settings operations and update as one read-modify-write | `specs/settings.md`, `specs/push-notifications.md` (CONF-28, CONF-29, PUSH-25, PUSH-26) |
| W04 | `dec6ce4` — the Files page reports an unavailable project folder | `specs/file-explorer.md`, `specs/projects.md` (EXPL-9, EXPL-19, PROJ-27) |
| DEP-01 | `2019926` — a deploy stages its bundle and promotes it only when the deploy is committed to | `specs/deployment.md` (DEPLOY-31, DEPLOY-32) |
| DEP-02 | `2019926` — a restart needs something that will bring the server back | `specs/deployment.md`, `specs/auto-restart.md` (DEPLOY-33, RESTART-12) |
| DEV-01 | `2019926` — the README's first run installs the Node packages, and says what Node is for | `specs/deployment.md` (DEPLOY-34, DEPLOY-35) |
| LLM-01 | `a9d16c4` — fold a summary in a worker of the session's | `specs/compaction.md` (COMPACT-40 to COMPACT-46) |
| LLM-02 | `50a6b53` — an SSE error code that names no status is no status | `specs/llm-providers.md` (LLM-36) |

Two of them are worth knowing about beyond the table:

- **W01 was fixed, not accepted.** The review's own WEB and SECURITY text describes
  the terminal socket as accepting anything and dev turning the endpoint's origin
  check off, which is how it read at `5be0bd8`. `docs/REVIEW.md`'s S1 entry, which
  had recorded cross-site terminal access as an accepted risk, now records the
  origin fix, and S2 — there is no authentication — is its own accepted record
  (`00312dc`). The binding says a page came from this server; it does not say who
  is using it, and `specs/terminal.md` still puts access control out of scope.
- **SEC-02's approval policy is unchanged.** An ordinary file action still goes
  through approval or per-chat auto-approval; what changed is that a protected or
  outside referent is refused as that referent rather than offered as an ordinary
  path.

## The documentation drift rows are corrected

`3e24d9c` fixed the three rows the review's testing report lists: the push
implementation notes (the crypto is local `Elia.Push.Crypto`, not the `web_push`
package it named), the sub-agent plan (it described the retired task model and
now describes what is built — the result `{"task_id", "summary"}`, the inherited
auto-approval), and the spec index and sub-task introduction (phases 1 to 4 are
built, not future work). The README's "no recovery page" statement and its page
table were corrected at `ca9fe2e`, and its Node paragraph with DEV-01 above.

## Two extras raised outside the 17 are closed

- `961adfa` — a boot records the revision it comes up on (DEPLOY-36).
  `Elia.Deploy.record_loaded/3` documented that the runner recorded it at boot,
  and nothing called it there.
- `4f97e55` — a project folder that is itself a symlink is browsed rather than
  reported unreadable (EXPL-20; the error it produced was EXPL-19).

## Still open

Five of the review's seven [open questions](review/OPEN-QUESTIONS.md) are still
live. None of them was a finding and none has a specification:

- **#2, one malformed push device.** `Elia.Push.deliver/1` still reduces over the
  stored subscriptions with no boundary around one device, and
  `Elia.Push.Crypto.encrypt` still hands a subscription's key to
  `:crypto.compute_key`. Whether a correctly sized but invalid P-256 point raises
  is still untested, and the review's fixture — the uncompressed marker and 64
  zero bytes beside a valid device — is still not written.
- **#3, framing of `/recover`.** `EliaWeb.Recovery.respond/4` still sets the
  content type and `no-store` and no frame policy, and whether embedding recovery
  has any supported use is still undecided.
- **#5, a runtime-incompatible jail.** Still no host matrix: a missing binary,
  namespace creation that is present but forbidden, an unsupported overlay, a
  working overlay, and an explicitly disabled jail.
- **#6, what rollback must restore.** DEP-01 made the *bundle* a staged
  promotion; the dependencies a deploy installs are still the follow-up the
  review describes, and a rollback that fails still resets tracked files only.
- **#7, unmeasured integrations and performance.** Still no live provider, real
  browser lane, real push delivery or running-server profile recorded.

Question 1 — whether W01's transport was reachable in practice — is moot: the
transport now refuses a connection that is not this server's own page. Question
4 is a contract to preserve rather than work to do: a stopped child turn still
leaves its task running, with the parent waiting (SUBTASK-16, SUBTASK-17).

## One piece of advice that has gone stale

The review tells an orchestrator that only one process may run the suite, since
the partitions' scratch paths were shared across worktrees. A run now has its own
run directory, settings database and temporary directory (SUITE-1, SUITE-11), so
concurrent runs in one worktree or several no longer collide. What is still
shared is the endpoint port a browser run or `bin/preview` binds, which each run
must set for itself.
