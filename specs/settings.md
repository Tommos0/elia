# Settings and API keys

Status: Implemented

Provider API keys and the selected model are user settings, not workspace
data, so they live in a small on-disk database in the user's data directory
rather than in the repository. A Settings page lets the user enter, check and
remove a key for each provider, start and stop the local llama.cpp server
(LOCAL-25), and deploy Elia's own code (DEPLOY-5): it is where the running
server is brought up to date with the trunk `master`. What the page holds is
grouped into four collapsible sections, collapsed on load (CONF-25).

## Requirements

### Storage

- **CONF-1** Settings are stored in a DETS table at
  `$XDG_DATA_HOME/elia/settings.dets`, or `~/.local/share/elia/settings.dets`
  when `XDG_DATA_HOME` is unset. `config :elia, Elia.Settings, path: ...`
  overrides the location.
- **CONF-2** When Elia creates the settings directory it uses mode `0700`;
  an existing directory is left as it is. The database file is set to mode
  `0600`, since it holds secrets.
- **CONF-3** Every write is synced to disk before it returns, so settings
  survive a crash or restart.
- **CONF-4** Settings are outside the workspace, so they are never committed.
- **CONF-28** Every settings operation — a read, a write, a delete and an
  update — is carried out by the settings process, so the operations on the
  database are applied one at a time, in one order.
- **CONF-29** An update of a key is one operation: the settings process reads
  the key, applies the caller's function to what it read and stores the result,
  and no other settings operation is applied in between. It returns the value it
  stored, so a caller that has to build on the stored value — a key generated
  when there is none, a value computed from the one in the store — uses an
  update rather than a read followed by a write.

### API keys

- **CONF-5** A provider's key is the stored key if there is one, otherwise
  the key from the provider's configuration (e.g. `ANTHROPIC_API_KEY`).
  `Elia.LLM.api_key/1` returns `{:stored | :env, key}` or `nil`. A provider
  that needs no key — the local server of LOCAL-2 — reports `nil` and is used
  anyway: nothing refuses it for lack of a key.
- **CONF-6** Checking a key makes one authenticated request to the provider
  (Anthropic: `GET /v1/models`; OpenRouter: `GET /api/v1/key`) and returns
  `:ok` or `{:error, message}`. A blank key is rejected without a request.
- **CONF-7** Saving a key checks it first and stores it only if the check
  passes. Keys are trimmed before checking and storing.
- **CONF-8** Removing a key deletes only the stored key; a configured key
  then applies again.

### Settings page

- **CONF-9** `/settings` shows a card per provider (`#provider-<key>`) with
  its status: "Saved" with the key masked to its last 4 characters, "From
  environment", or "Not set". A provider that needs no key (LOCAL-2) has the
  card of LOCAL-24 instead, since there is no key to enter or to check.
- **CONF-10** Each card has a password field and two submit buttons: Check
  (`#check-<key>`) verifies the entered key without storing it, Save
  (`#save-<key>`) verifies and stores it (CONF-7). The result shows inline as
  a success or error message.
- **CONF-11** A card with an active key (stored or from the environment) has
  a "Check current key" button (`#check-current-<key>`); a card with a stored
  key has a Remove button (`#remove-<key>`).
- **CONF-12** The page shows where the settings database lives.
- **CONF-13** The header links to `/settings` (`#settings-link`).

### Credits

- **CONF-14** A card with an active key (CONF-5) shows a credit line
  (`#balance-<key>`). For a provider with `balance/1` (LLM-25) it is loaded
  in the background when the page connects, and again after a key is saved or
  removed, and shows "Loading…", then the remaining and used amounts in USD,
  or the error message. An `:account` balance reads "$R remaining ($U used of
  $T)"; a `:key` balance reads "$U used" plus " · $R left of $L key limit"
  when the key has a limit. For a provider without `balance/1` it says the
  balance isn't available through the API and to see the billing page; one
  with no `billing_url` at all (LOCAL-7) says there is nothing to bill, since
  it runs on this machine.
- **CONF-15** Every card has an "Add credits" link (`#topup-<key>`) to the
  provider's `billing_url` (LLM-27) that opens in a new tab with
  `rel="noopener noreferrer"`. It shows whether or not a key is set. A
  provider with no `billing_url` (LOCAL-7) has no such link.
- **CONF-16** A "Refresh" button (`#refresh-balance-<key>`) next to the credit
  line of a provider with `balance/1` reloads the balance.

### Appearance

- **CONF-17** `/settings` has an "Appearance" section (`#appearance`) holding
  the theme toggle (`#theme-toggle`) with its system, light and dark buttons.
- **CONF-18** The app header has no theme toggle; it is only on the Settings
  page.
- **CONF-30** The Appearance section holds a UI scale control (`#ui-scale`)
  beside the theme toggle: a slider (`#ui-scale-range`) whose range is 80% to
  150% in steps of 5, a readout (`#ui-scale-value`) of the scale in whole
  percent, and a reset button (`#ui-scale-reset`) that returns the scale to
  100%.
- **CONF-31** The scale applies to the page as a whole: it sets the root
  element's font size, so everything the app sizes in `rem` — text, controls,
  spacing and the chat transcript — scales together.
- **CONF-32** The scale is the browser's own preference: it is kept in
  `localStorage` under `elia:ui-scale` as the whole percentage, so no request
  carries it to the server and no key of the settings database (CONF-1) holds
  it.
- **CONF-33** The stored scale is applied before the page is first painted, so
  no page is drawn at one scale and then jumps to another, and it is the scale
  a reload, a move to another page of the app and a page that comes back after
  a restart deploy (CONF-22) shows.
- **CONF-34** The settings page shows the stored scale: on load the slider sits
  at it and the readout shows it, a slider moved applies the new scale at once
  with the readout following it, and a reset applies 100% and puts both back
  there.
- **CONF-35** A stored scale that is missing, not a number or outside 80 to 150
  is read as 100%.

### Deployment

- **CONF-19** `/settings` has a "Deployment" section (`#deployment`) that says,
  in `#deploy-status`, what the live tree's deploy state is: how many commits on
  the trunk are not deployed yet, that `live` is already at the trunk when
  there is nothing to deploy, or why the live tree isn't set up for deployment
  (DEPLOY-14). When the running app is behind `live` — a deploy that merged and
  never loaded (DEPLOY-17) — the section says so, with the revision the app is
  running and that Hot reload will bring it up to date, rather than reporting
  that there is nothing to deploy. When it is set up for deployment the section
  has two deploy buttons, "Hot reload" (`#deploy-reload`) and "Restart"
  (`#deploy-restart`), each that deploy mode (DEPLOY-6, DEPLOY-7).
- **CONF-20** A deploy runs in the background (DEPLOY-15), so the page stays
  responsive and the deploy outlives it: while one runs, the button for that
  mode shows a spinner and both are disabled, and a click while one runs is
  ignored — state that comes from the runner (DEPLOY-16), so a page that mounts
  mid-deploy shows it too. The result of the last deploy — what was merged and
  what loaded on success, the error (test output truncated) on a test failure
  or a refusal — is shown in the section as `#deploy-result`, and is still
  there for a page that mounts after the deploy ended; the deploy status
  (CONF-19) is refreshed when it changes.
- **CONF-21** While an operation runs the section shows what it is doing, from
  the runner (DEPLOY-21, DEPLOY-22): the steps that have finished, with how long
  each took, the step it is on now, and how long the whole operation has been
  running. A page that mounts or is reloaded in the middle of one — including
  by the deploy's own asset change (DEPLOY-12, HOT-9) — shows the same, rather
  than only a spinner on the button (CONF-20). The list is `#deploy-steps`, each
  finished step a row naming it (through `Elia.Deploy.step_label/1`, so the two
  pages that render steps cannot disagree) with its duration; the step it is on
  is `#deploy-step` and the elapsed time is `#deploy-elapsed`.
- **CONF-22** The section reports the last operation from the record
  (DEPLOY-23) as well as from the runner (CONF-20), so a page that comes back
  after a **restart** deploy (DEPLOY-7) — whose result died with the process
  the runner lived in — still says what the deploy did, and where it stopped
  when it did not finish. The runner's own result, when there is one, is the
  newer of the two.
- **CONF-23** The section offers going back to a revision the app has run
  (DEPLOY-25, DEPLOY-26): as `#deploy-rollback` it names the newest kept
  revision that is not the one running — its short sha and when it was loaded —
  and has a control per load mode, `#deploy-rollback-reload` and
  `#deploy-rollback-restart`, each disabled while an operation runs, the way the
  deploy buttons are (CONF-20). The section also says `#recover-note` the
  address of the recovery page (`/recover`, RECOVER-10), for when this page's
  own UI is what a deploy broke.
- **CONF-24** The elapsed time (CONF-21) comes from the clock rather than from
  what the runner last reported, and the page keeps it current itself: while an
  operation runs, `#deploy-elapsed` is re-rendered about once a second, so it
  counts on with no reload, no click and nothing new from the runner, and it
  stops moving once the operation has ended. A page that mounts while one runs
  (CONF-21) counts from the runner's own start time (DEPLOY-22), the same as
  the value it renders first.
- **CONF-36** The Deployment section has a "Skip tests" checkbox
  (`#deploy-skip-tests`) beside the deploy buttons (CONF-19): checking it makes
  the next deploy — either button — one that leaves the live tree's suite out
  (DEPLOY-40), and the section says what that means, that the trunk is loaded
  without its tests having run. It is unchecked whenever the page loads, since
  nothing about it is stored — neither in the settings database (CONF-1) nor in
  the browser — so a reload, a new visit and a page that comes back after a
  restart deploy (CONF-22) all start with the tests running. It is disabled
  while an operation runs, the way the buttons are (CONF-20).
- ~~**CONF-37** Where the live tree's repository has an `origin` remote (DEPLOY-43)
  the Deployment section offers pushing the trunk to it (DEPLOY-41): a "Push"
  button, `#deploy-push`, beside the deploy buttons but a secondary control
  rather than a third deploy mode (its title says it pushes `master` to
  `origin`), and beside it `#deploy-origin`, which says how the trunk stands
  against `origin` — how many commits `origin` does not have yet, that it has
  them all, or that nothing has been pushed from this tree yet — or, when there
  is no `origin` remote, what is missing instead, and then there is no button. A
  push needs neither a deploy nor `live`, so this control is offered whether or
  not the live tree is set up for deployment (DEPLOY-14), unlike the deploy
  buttons (CONF-19), and it is offered while a deploy runs as well, since it is
  not one.~~ Retired: a push belongs to the project whose repository it sends to
  and is offered on that project's own page, one control per configured remote
  (PROJ-56 to PROJ-58).
- ~~**CONF-38** A push from the section runs in the background, off the page's own
  process, so the page stays responsive: while one runs the button is disabled
  and shows a spinner, and a click while one runs does nothing. Its result is
  reported in a line of its own, `#deploy-push-result` — what the push did, or
  git's refusal (DEPLOY-41) — beside `#deploy-origin` and separately from a
  deploy's result (CONF-20) and steps (CONF-21), which a push does not touch. It
  belongs to the page and is stored nowhere, so a page that mounts reports none,
  and leaving the page while a push runs stops it — the only thing it leaves is
  git's own state, the branch on `origin` as it was or as pushed — and the
  tree's own `origin/master` catches up on the next push (DEPLOY-43).~~ Retired:
  the project's own page offers and reports a push now (PROJ-58).

### Sections

- **CONF-25** `/settings` groups what it holds into four collapsible sections,
  in this order: "Appearance" (`#appearance`, CONF-17), "LLM providers"
  (`#providers` — the provider cards of CONF-9 and the local model server
  section of LOCAL-25), "Deployment" (`#deployment`, CONF-19) and "Push
  notifications" (`#push-section`, PUSH-2). Each is collapsed when the page
  loads: only its header is shown — an icon, the section's title, a one-line
  description and a chevron — and clicking that header expands the section and
  collapses it again, without a round trip to the server. Nothing about the
  open state is stored or sent, so every load — a reload, a page that comes
  back after a restart deploy (CONF-22) — starts with all four collapsed, and
  what a re-render the user did not ask for leaves is the browser's own state
  (CONF-27).
- **CONF-26** What a collapsed section holds is in the page all the same, so
  its controls keep their ids (CONF-9–CONF-11, CONF-17, CONF-19,
  PUSH-2–PUSH-8) and their state: a check that is running, a deploy in
  flight and the push section's own reading of the browser (PUSH-20) are the
  same
  whether or not the section is expanded, and expanding one after something
  happened in it shows it as it is. The settings database location (CONF-12)
  stays outside the sections and is always visible.
- **CONF-27** A section keeps the open or collapsed state the user gave it while
  the page the server renders is patched: the open state belongs to the browser
  (CONF-25), so a re-render the user did not ask for — the elapsed-time tick of
  a running operation (CONF-24), the local model server's own status (LOCAL-26),
  the re-render a reconnect leaves behind — changes nothing about it, and only
  the section's own header expands or collapses it.

## Configuration

```elixir
config :elia, Elia.Settings, path: "/custom/path/settings.dets"
```

Tests use a scratch file under the system temp directory.

## Out of scope

- Encrypting keys at rest; the file mode keeps other users out.
- Multiple keys per provider.

## Stored data

The database is a DETS set from a key to a value (CONF-1): the API keys and
base URLs (`{:api_key, provider}`, `{:base_url, provider}`, CONF-5), the
selected model (`:model`, MODEL-15) and, for push, the subscriptions
(`push_subscriptions`, PUSH-3) and the VAPID key pair (`push_vapid_keys`,
PUSH-1). Carrying the operations out in one process (CONF-28) and updating a
key as one operation (CONF-29) adds no key and changes no value's shape, so a
table an older version wrote is read and written as it is: backward compatible,
with no migration. The UI scale (CONF-30) is the browser's own `localStorage`
rather than the table (CONF-32), so it adds no key here either.

## Implementation

`Elia.Settings` carries every operation out in its own process and owns the
read-modify-write of `update/3` (CONF-28, CONF-29); the writers that build on
what is stored use it rather than a read followed by a write — `Elia.Push.keys/0`
(PUSH-25), `Elia.Push.Subscriptions` (PUSH-26) and the context length
`Elia.LLM.context_window/1` adds to a stored selection (CTX-7).

`Elia.Settings`, `Elia.LLM` (`api_key/1`, `check_key/2`, `save_key/2`,
`delete_key/1`, `balance/1`), `Elia.Deploy` (the deploy, DEPLOY-5; its steps,
record and rollback, DEPLOY-21–DEPLOY-26), `Elia.Deploy.Runner` (the operation
in flight, DEPLOY-22), `EliaWeb.SettingsLive` (whose collapsible sections keep
the browser's own `open` state out of a patch, `JS.ignore_attributes/1`),
`EliaWeb.Layouts`.

The UI scale (CONF-30–CONF-35) is applied the way the theme is: the page head
sets a preference before anything is painted, and it reads `elia:ui-scale`
there to set the root font size; the `#ui-scale` control on the settings page
reads and writes the same key.

## Tests

- `test/elia/settings_test.exs` (the database and its file, the directory mode,
  a write that is synced, the stored and configured keys, checking one, removing
  one, and the one order every operation is carried out in, an update applied
  with the value it read — CONF-1 to CONF-8, CONF-28, CONF-29).
- `test/elia_web/live/settings_live_test.exs` (the page, a card per provider,
  checking, saving and removing a key, the credits line and its refresh,
  appearance and its UI scale control, the Deployment section, the checkbox
  that leaves the suite out (CONF-36), its steps,
  the elapsed time, the collapsible sections — CONF-7 to CONF-36).
- `test/elia_web/browser/settings_sections_test.exs` (the four sections in a
  real browser: all four collapsed on load, a header expanding and collapsing
  one, and an open one that a re-render the user did not ask for leaves open —
  CONF-25, CONF-27).
- `test/elia_web/browser/ui_scale_test.exs` (the UI scale in a real browser: a
  page scaled before it is painted, the slider scaling it, the scale a reload
  and a move to another page keep, the reset, and a stored value that cannot be
  read — CONF-31 to CONF-35).
- `test/elia/command_isolation_test.exs` (the settings path is outside what a
  jailed command reaches, CONF-1).
- `test/elia/deployment_test.exs` (the deploy the page starts, CONF-19).
- `test/elia/llm/open_router_test.exs` (where the credit line's number comes
  from, CONF-14).
- `test/elia_web/recovery_test.exs` (the last operation the section reports,
  CONF-22).
- `test/elia_web/browser/push_test.exs` (the push section among the four,
  CONF-25).
