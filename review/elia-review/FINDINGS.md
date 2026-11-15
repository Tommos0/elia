# Findings index

[Start](README.md) · [Human summary](SUMMARY.md) · [AI routes](ai/ROUTING-INDEX.md) · [Machine findings](evidence/findings.json)

**17 findings: 6 P1, 11 P2.** P1 means resolve before relying on the affected boundary/workflow; P2 means a concrete defect to schedule. All are high-confidence source deductions with runtime reproduction pending. V07–V09 are narrowly scoped local checks, not application tests. W01 has explicit known-ID and browser/proxy reachability preconditions. No CVSS or blanket security certification is implied.

## P1 — first repair group

| ID | Finding | Trigger/qualification | Detail | Owner route |
| --- | --- | --- | --- | --- |
| SEC-01 | Host-side AGENTS.md reads can disclose files outside the jail | A workspace instruction symlink targets a readable host text file; a following prompt is constructed. | [Report](review/SECURITY.md) | [A](ai/ROUTING-INDEX.md) |
| SEC-02 | Approved file aliases can mutate protected/shared targets | A reachable alias points into protected Git metadata or the live dependency tree; the ordinary approval policy permits the file action, including per-chat auto-approval. | [Report](review/SECURITY.md) | [A](ai/ROUTING-INDEX.md) |
| CORE-01 | External-project children receive Elia's global workspace | spawn_task runs from a non-harness project whose folder differs from Elia's root. | [Report](review/CORE.md) | [C](ai/ROUTING-INDEX.md) |
| CORE-02 | A dead session can leave its unlinked loop and tools running | A session terminates/crashes while the application and its independent task supervisor remain up. | [Report](review/CORE.md) | [D](ai/ROUTING-INDEX.md) |
| W01 | Terminal transport does not enforce browser origin/session proof | An unrelated origin knows an existing terminal chat ID and browser/proxy policy permits reaching the endpoint. | [Report](review/WEB.md) | [E](ai/ROUTING-INDEX.md) |
| DEP-01 | Rejected deploy can leave served generated bundles damaged | Candidate asset generation changes/removes output then fails; generated assets are ignored as in the real checkout. | [Report](review/DEPLOYMENT-AND-SETUP.md) | [G](ai/ROUTING-INDEX.md) |

## P2 — focused reliability and usability work

| ID | Finding | Trigger/qualification | Detail | Owner route |
| --- | --- | --- | --- | --- |
| SEC-03 | Overlay mount lock remains held throughout the command | Two commands need the same worktree dependency overlay while the first command remains running. | [Report](review/SECURITY.md) | [B](ai/ROUTING-INDEX.md) |
| SEC-04 | Folder-tool jail mounts the skill directory instead of the workspace | A real jailed folder script needs project files outside its own skill folder. | [Report](review/SECURITY.md) | [B](ai/ROUTING-INDEX.md) |
| CORE-03 | Decodable malformed chat shapes crash shared load/list paths | A valid encoded term contains invalid chat fields, such as messages:nil. | [Report](review/CORE.md) | [D](ai/ROUTING-INDEX.md) |
| CORE-04 | A failed save clears the only dirty/shutdown-retry signal | A final save fails, storage recovers, and a session closes without a later mutation. | [Report](review/CORE.md) | [D](ai/ROUTING-INDEX.md) |
| W02 | Terminal Start and its warning use stale or prospective jail state | Jail changes in another tab after a terminal page mounts, or an existing terminal outlives a preference change. | [Report](review/WEB.md) | [E](ai/ROUTING-INDEX.md) |
| W03 | Push initialization and subscription changes lose concurrent updates | Concurrent first key requests, subscriptions, or registration racing with endpoint cleanup. | [Report](review/WEB.md) | [F](ai/ROUTING-INDEX.md) |
| W04 | Unavailable project root crashes the Files page fallback | A registered external folder is moved, removed, unreadable or unmounted. | [Report](review/WEB.md) | [F](ai/ROUTING-INDEX.md) |
| DEV-01 | Documented clean setup omits required Node package installation | Fresh checkout without assets/node_modules follows the README mix setup sequence. | [Report](review/DEPLOYMENT-AND-SETUP.md) | [G](ai/ROUTING-INDEX.md) |
| DEP-02 | Restart availability does not check for an external supervisor | Deployment-ready tree is launched directly with mix phx.server and no restarting supervisor. | [Report](review/DEPLOYMENT-AND-SETUP.md) | [G](ai/ROUTING-INDEX.md) |
| LLM-01 | Slow manual/turn-start summaries block the session and callers | Eligible nonempty aged-out history requires a summary taking longer than the default five-second call timeout. | [Report](review/LLM-AND-COMPACTION.md) | [D](ai/ROUTING-INDEX.md) |
| LLM-02 | Nonnumeric SSE error codes raise during error handling | An HTTP-200 error chunk has a symbolic/invalid string code; current providers emitting it was not established. | [Report](review/LLM-AND-COMPACTION.md) | [H](ai/ROUTING-INDEX.md) |

## How to use a finding

The linked report gives the exact source chain, contrary evidence/tests considered, proposed reproduction, repair direction and acceptance criteria. The [machine index](evidence/findings.json) carries the same IDs with source paths/line ranges and test routes. Findings are proposals for investigation and repair, not pre-approved code changes.

A useful fix should fail the new acceptance case against this snapshot, pass after the change, and preserve the related spec invariants. If a reproduction refutes the source reasoning, record that refutation rather than patching toward the review by assumption. [Validation](meta/VALIDATION.md) separates actual results from future checks; [Open questions](review/OPEN-QUESTIONS.md) keeps weaker leads out of this count.

