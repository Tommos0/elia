# Settings and API keys

Status: Implemented

Provider API keys and the selected model are user settings, not workspace
data, so they live in a small on-disk database in the user's data directory
rather than in the repository. A Settings page lets the user enter, check and
remove a key for each provider.

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
- **CONF-4** Settings are outside the workspace, so they are never committed,
  checkpointed or rolled back.

### API keys

- **CONF-5** A provider's key is the stored key if there is one, otherwise
  the key from the provider's configuration (e.g. `ANTHROPIC_API_KEY`).
  `Elia.LLM.api_key/1` returns `{:stored | :env, key}` or `nil`.
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
  environment", or "Not set".
- **CONF-10** Each card has a password field and two submit buttons: Check
  (`#check-<key>`) verifies the entered key without storing it, Save
  (`#save-<key>`) verifies and stores it (CONF-7). The result shows inline as
  a success or error message.
- **CONF-11** A card with an active key (stored or from the environment) has
  a "Check current key" button (`#check-current-<key>`); a card with a stored
  key has a Remove button (`#remove-<key>`).
- **CONF-12** The page shows where the settings database lives.
- **CONF-13** The header links to `/settings` (`#settings-link`).

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
`delete_key/1`), `EliaWeb.SettingsLive`, `EliaWeb.Layouts`.

## Tests

`test/elia/settings_test.exs`, `test/elia_web/live/settings_live_test.exs`.
