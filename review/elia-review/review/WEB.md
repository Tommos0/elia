[Start](../README.md) · [Findings index](../FINDINGS.md) · [Routing index](../ai/ROUTING-INDEX.md)

# Web, terminal UI, and push review

Reviewed commit: `5be0bd873bd2716529de25541efb1825495cd12e` of `Tommos0/elia`.

This is a read-only, source-based review. No Elixir suite, browser session, real push delivery, or exploit was executed in this track. Confidence describes the source reasoning, not runtime verification. The source ledger is [source ledger](../meta/web-sources.json).

## Reading route

For an orchestrator, read the four-row table and the implementation boundaries below. Send a terminal specialist to W01–W02, a persistence/push specialist to W03, and a LiveView specialist to W04. The lower-priority notes are follow-up leads rather than prerequisites to those four tasks.

| ID | Priority | Finding | Evidence status | Main owner |
| --- | --- | --- | --- | --- |
| W01 | P1, conditional security exposure | Terminal transport accepts cross-origin connections without requiring a validated browser session | Confirmed configuration and code path; browser reachability and known chat ID are preconditions | Web transport/security |
| W02 | P2 | An already-open terminal page can start using an obsolete jail setting; its warning can also misdescribe a running terminal | Confirmed static state flow | Terminal UI + session boundary |
| W03 | P2 | Push key initialization and subscription changes are non-atomic read/modify/write operations | Confirmed concurrent interleavings; not stress-tested | Settings/push persistence |
| W04 | P2 | Files page crashes when the selected project's root directory is unavailable | Confirmed error-to-Enumerable flow; not run | File explorer LiveView |

Priorities follow the [package definitions](../FINDINGS.md): P1 means resolve before relying on the affected boundary/workflow; P2 means a concrete defect to schedule. These are development priorities, not vulnerability scores.

## Architecture and strengths worth retaining

The ordinary browser routes use Phoenix's session, CSRF protection, and secure browser headers. LiveViews are the control surface; the terminal deliberately uses a separate Phoenix channel for byte streams. The recovery plug precedes the router and renders independent HTML, so a broken asset bundle need not block rollback. Push separates browser subscriptions, cryptography, notification decisions, and delivery. These boundaries are understandable and give focused ownership to future subagents. Sources: [router](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/router.ex), [endpoint](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/endpoint.ex), [recovery](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/recovery.ex), [push](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/push.ex).

Specific strengths:

- Markdown is parsed with unsafe rendering disabled, then escaped on a parser/conversion failure; tests cover raw HTML and `javascript:` URLs. This is a useful explicit boundary around model-produced text. [Implementation](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/markdown.ex), [tests](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia_web/markdown_test.exs).
- Terminal output is base64-encoded bytes rather than assumed UTF-8, and the channel has explicit overflow/rejoin behavior. Retain both when tightening authorization. [Channel](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/terminal_channel.ex), [client](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/assets/js/terminal.js).
- Push cryptography has an RFC 8291 known-answer test and a test that independently verifies the VAPID signature. Keep these tests; they are stronger evidence than testing only round trips through the same implementation. [Tests](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/push_crypto_test.exs).
- The service worker deliberately avoids caching/proxying application traffic. The UI makes an unavailable push worker explicit rather than leaving an indefinite spinner. [Worker](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/priv/static/sw.js), [push requirements](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/push-notifications.md).

The application explicitly chooses a single-user, reachable-means-trusted model, with external access control left to an operator/proxy. That choice itself is not reported as a defect here. See [terminal out-of-scope policy](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/terminal.md#L263-L265) and [recovery context](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/recovery.md#L79-L82). W01 concerns another website acting through the user's browser, which is a separate boundary.

## W01 — Require origin/session proof on the terminal transport

**Priority:** P1 for an environment where an unrelated web origin can reach the terminal endpoint. **Confidence:** high in the code path; conditional exploitability. **Requirements:** TERM-12 and TERM-13 define the transport; a new explicit browser-origin requirement would be appropriate. The present terminal spec does not promise per-user authorization.

### Evidence and trigger

The default dev endpoint disables origin checking in [config/dev.exs:9–15](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/config/dev.exs#L9-L15). The documented operating mode uses this dev environment. [TerminalSocket.connect/3:16–17](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/terminal_socket.ex#L16-L17) ignores both connection parameters and connection information and always accepts. [TerminalChannel:22–43](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/terminal_channel.ex#L22-L43) permits a join by an existing chat ID and sends decoded input directly to its terminal.

The CSRF parameter sent by the legitimate JS client is not sufficient protection. Phoenix's source for the pinned `1.8.16` dependency shows that disabled origin checking is a no-op, and an absent/invalid cookie or CSRF token produces `connect_info.session = nil`; it does not reject the socket by itself. This application's `connect/3` ignores that nil value. Primary framework evidence: [origin check](https://github.com/phoenixframework/phoenix/blob/v1.8.16/lib/phoenix/socket/transport.ex#L345-L356), [session extraction](https://github.com/phoenixframework/phoenix/blob/v1.8.16/lib/phoenix/socket/transport.ex#L515-L526). Version evidence: [mix.lock](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/mix.lock#L22).

The attacker must know an existing terminal's chat ID and must be able to initiate a browser WebSocket to the endpoint. Chat IDs are random; this review does not claim they are guessable or that browser local-network protections can always be bypassed. A proxy may add its own effective protection. Given these preconditions, an unrelated origin can join the byte channel, read its screen/output, and inject terminal input. The terminal's own confinement still applies; an intentionally unjailed terminal has wider impact.

### Remediation and acceptance

Configure an explicit allowed-origin policy for supported localhost and proxy deployments, and reject terminal socket connections lacking a validated session/CSRF proof or an equivalent short-lived purpose-scoped token. Keep the supported single-user model if desired. Document trusted proxy/origin configuration rather than universally disabling it.

Add a transport-level test, because the existing [channel tests](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia_web/terminal_channel_test.exs) create sockets directly and bypass the HTTP/WebSocket handshake. Verify a foreign Origin and a missing/invalid CSRF/session are rejected, a legitimate same-origin connection still joins, and the supported reverse-proxy origin works. Use a harmless temporary terminal for an end-to-end test and test byte handling and overflow after the change. No live exploit was attempted during this review.

## W02 — Use the current jail setting when starting, and actual terminal state when labeling

**Priority:** P2. **Confidence:** high, static. **Requirements:** TERM-7, TERM-9, TERM-20; CSET-4 and ISOL-16 provide the settings context.

### Evidence and trigger

[TerminalLive:27–45](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/live/terminal_live.ex#L27-L45) snapshots the agent's jail setting during mount and subscribes only to terminal status. [Start:63–71](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/live/terminal_live.ex#L63-L71) later passes that cached value into `Terminal.start/2`. The only state update handler is terminal status, followed by a catch-all that ignores other messages: [99–103](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/live/terminal_live.ex#L99-L103).

A reproducible sequence is: turn Jail off for a chat; open its terminal page without starting; turn Jail on through a second tab; return to the first tab and press Start. The first tab still supplies `jail: false`. `Terminal.start` passes its options through, and [Terminal.Session:169–187](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/terminal/session.ex#L169-L187) uses that value to build shell arguments. This is a newly started terminal using an obsolete policy, not an expectation that an existing OS process can be retroactively jailed.

There is a related display problem: a terminal already running unjailed can remain so after the chat setting changes. A fresh page derives the warning from the chat setting rather than `status.jail`, although the terminal exposes its actual jail choice in [session status:749–761](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/terminal/session.ex#L749-L761). Thus the warning may disappear while the existing terminal remains unjailed. [Warning markup](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/live/terminal_live.ex#L160-L180).

### Remediation and acceptance

Obtain an authoritative snapshot at the Start boundary and use its current setting. Subscribe to settings updates for accurate prospective UI state. While a terminal exists, label its actual running confinement separately from the setting for the next terminal. Define explicitly what changing Jail does to a running terminal; preserve current lifetime semantics unless a deliberate spec change says otherwise.

Add a two-view test for the stale Start sequence and a test where an unjailed terminal exists while the chat preference is now on. Verify the newly started process uses the current preference, and the warning for an existing process matches its actual status. The existing [terminal LiveView tests](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia_web/live/terminal_live_test.exs) cover start/stop and an existing terminal, but do not exercise a settings change in another tab or assert the actual jail warning in that case.

## W03 — Make push state mutations atomic

**Priority:** P2. **Confidence:** high, static interleaving. **Requirements:** PUSH-1, PUSH-3, PUSH-4, PUSH-7, PUSH-16.

### Evidence and trigger

The settings process owns the DETS table, but reads and writes run directly from callers; it does not serialize a caller's read/modify/write transaction. [Settings:11–12,33–45](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/settings.ex#L11-L45).

`Push.keys` looks up the key and, if absent, generates a new pair and stores it. These are separate operations: [44–51](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/push.ex#L44-L51), [155–159](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/push.ex#L155-L159). Every Settings page mount requests a public key: [SettingsLive:57–61](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/live/settings_live.ex#L57-L61).

Two first callers can both observe no key, generate A/B, store A then B, and each return its own public key. A browser that subscribes using A no longer matches the persisted VAPID private key B. The exact returned key must be the durable winner, regardless of caller timing.

Subscriptions repeat the same pattern at the collection level: [save/remove/clear:41–59](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/push/subscriptions.ex#L41-L59). Two registrations can each read an empty list and overwrite each other. A browser registration racing with 410 cleanup can restore a removed endpoint or lose the newly registered endpoint. Delivery tasks make the latter interleaving possible even for one user with one browser performing registration.

### Remediation and acceptance

Introduce an atomic settings update/get-or-create operation and perform both the decision and the write within one serialized owner. Alternatively use a correct atomic insert-if-absent plus reread for key generation and separate records or another transactional mechanism for subscriptions. Merely putting each `get` and `put` behind separate GenServer calls does not make the pair atomic.

Use deterministic concurrency tests with barriers: simultaneous key initialization must return one identical pair matching persisted state; independent subscriptions must both survive; an update racing with a removal must respect the chosen operation ordering; clear must not be undone by a stale writer. Current tests verify sequential reuse and sequential multiple-device storage, not these interleavings: [key tests](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/push_test.exs), [subscription tests](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/push_subscriptions_test.exs). Preserve existing DETS keys and stored shapes or include a migration decision.

## W04 — Handle an unavailable file-explorer root without enumerating an error atom

**Priority:** P2. **Confidence:** high, static. **Requirements:** EXPL-9, EXPL-15.

### Evidence and trigger

In [FilesLive:39–45](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/live/files_live.ex#L39-L45), a failed listing retries the project root but extracts tuple element 1 without checking whether the retry succeeded. If the root itself is unavailable, `Explorer.list` returns `{:error, :not_found}` or another error; the assigned `entries` is therefore an atom. [The template:260–265](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/live/files_live.ex#L260-L265) enumerates it and cannot render.

A normal trigger is an external project's folder being renamed, deleted, or temporarily unmounted after registration. `Projects.get` retains the registered folder and does not require it still to exist: [Projects:48–51](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/projects.ex#L48-L51), [read/validation:133–155](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/projects.ex#L133-L155). The page's attempt to show a helpful path error instead becomes a crash/reconnect failure.

### Remediation and acceptance

Pattern-match the fallback result, always assign a list to `entries`, and display the unavailable project/root error while keeping the project picker usable. Avoid silently switching to another project's files. Add a LiveView test that registers a temporary project, removes or renames its root, and then visits `/files?project=<id>`. Also cover an unreadable root if the test environment can model it reliably. Existing missing-path coverage assumes that the root remains available: [FilesLive tests:98–110](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia_web/live/files_live_test.exs#L98-L110).

## Secondary notes and focused follow-up

These are intentionally excluded from the four-item primary shortlist.

1. **Invalid push public-key points are not contained per device.** [Subscription validation:65–91](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/push/subscriptions.ex#L65-L91) checks decoded length, not whether the 65-byte value is a valid P-256 point. [Crypto.encrypt:108–120](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/push/crypto.ex#L108-L120) passes it directly to `:crypto.compute_key`; [delivery:120–149](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/push.ex#L120-L149) has no per-subscription exception boundary. A targeted test should use a correctly sized invalid point, e.g. the uncompressed marker `0x04` followed by 64 zero bytes, followed by a valid device, and require a failure tally plus delivery to the valid device. Existing crypto tests use wrong-length values. This review did not execute the Erlang crypto call, so retain this as a high-confidence follow-up rather than a reproduced failure. Malformed `https://` endpoint strings deserve the same validation/containment test.
2. **The recovery page skips frame protections.** [Endpoint:68–73](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/endpoint.ex#L68-L73) serves it before the router's secure headers; [respond:433–442](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/recovery.ex#L433-L442) sets no frame policy. A foreign page could frame the recovery UI when browser/proxy policies allow it; a user click in that frame produces a same-origin form submission. Consider adding `frame-ancestors 'none'` / appropriate frame denial directly to this independent response and a header test. This is a conditional clickjacking-hardening observation, not an origin-check bypass established by an executed test.
3. **Image-viewer keyboard accessibility needs a focused browser check.** The `.ZoomImage` hook moves focus to Close but does not trap Tab or restore the opener on close: [ChatLive:711–803](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/live/chat_live.ex#L711-L803). Check keyboard-only opening, Tab/Shift-Tab containment, Escape, and return focus. IMG-5 asks for focus on the close button while open; current behavior covers initial focus but not continued keyboard traversal. Treat accessible image activation and modal focus as a planned UX change with explicit requirements.
4. **Push documentation has implementation drift.** The [spec implementation section](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/push-notifications.md#L158-L163) says cryptography comes from a `web_push` package; the implementation is local `Elia.Push.Crypto` using OTP `:crypto`, and `mix.exs` has no such dependency. Correct this to keep agent routing accurate.

## Implementation boundaries for delegated work

- W01 owns transport configuration, `TerminalSocket`, handshake tests, and operator origin documentation. Coordinate any endpoint/config edits with the deployment reviewer; do not silently change all LiveView/proxy behavior.
- W02 owns `TerminalLive` and its tests. The shell/jail implementation need not change to fix a cached UI policy. Coordinate with the terminal runtime reviewer before changing existing-terminal lifetime semantics.
- W03 owns a small atomic Settings API plus its push consumers and tests. Settings contains other secrets and preferences; avoid broad storage replacement. Explicitly state that unchanged on-disk shapes need no migration, or document the migration if a different subscription representation is chosen.
- W04 is localized to FilesLive and its error-state tests. Preserve Explorer's existing containment policy and the selected project's identity.

For each follow-up, follow the repository's spec-first approval workflow before behavior changes. Tests must be serialized across worktrees, as `docs/agents/testing.md` requires. The work in this report is review only and does not approve a spec change or an implementation.
