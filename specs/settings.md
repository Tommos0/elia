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

### Deployment

- **CONF-19** `/settings` has a "Deployment" section (`#deployment`) that says,
  in `#deploy-status`, what the live tree's deploy state is: how many commits on
  the trunk are not deployed yet, that `live` is already at the trunk when
  there is nothing to deploy, or why the live tree isn't set up for deployment
  (DEPLOY-14). When the running app is behind `live` — a deploy that merged and
  never loaded (DEPLOY-17) — the section says so, with the revision the app is
  running and that Hot reload will bring it up to date, rather than reporting
  that there is nothing to deploy. When it is set up for deployment the section
  has two buttons, "Hot reload" (`#deploy-reload`) and "Restart"
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

### Sections

- **CONF-25** `/settings` groups what it holds into four collapsible sections,
  in this order: "Appearance" (`#appearance`, CONF-17), "LLM providers"
  (`#providers` — the provider cards of CONF-9 and the local model server
  section of LOCAL-25), "Deployment" (`#deployment`, CONF-19) and "Push
  notifications" (`#push-section`, PUSH-2). Each is collapsed when the page
  loads: only its header is shown — an icon, the section's title, a one-line
  description and a chevron — and clicking that header expands the section and
  collapses it again, without a round trip to the server. Nothing about the
  open state is stored or sent, so every load — a reload, a reconnect, a page
  that comes back after a restart deploy (CONF-22) — starts with all four
  collapsed.
- **CONF-26** What a collapsed section holds is in the page all the same, so
  its controls keep their ids (CONF-9–CONF-11, CONF-17, CONF-19, PUSH-2–PUSH-8)
  and their state: a check that is running, a deploy in flight and the push
  section's own reading of the browser (PUSH-20) are the same whether or not
  the section is expanded, and expanding one after something happened in it
  shows it as it is. The settings database location (CONF-12) stays outside the
  sections and is always visible.

## Configuration

```elixir
config :elia, Elia.Settings, path: "/custom/path/settings.dets"
```

Tests use a scratch file under the system temp directory.

## Out of scope

- Encrypting keys at rest; the file mode keeps other users out.
- Multiple keys per provider.

## Implementation

`Elia.Settings`, `Elia.LLM` (`api_key/1`, `check_key/2`, `save_key/2`,
`delete_key/1`, `balance/1`), `Elia.Deploy` (the deploy, DEPLOY-5; its steps,
record and rollback, DEPLOY-21–DEPLOY-26), `Elia.Deploy.Runner` (the operation
in flight, DEPLOY-22), `EliaWeb.SettingsLive`, `EliaWeb.Layouts`.

## Tests

`test/elia/settings_test.exs`, `test/elia_web/live/settings_live_test.exs`.
