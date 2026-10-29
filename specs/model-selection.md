# Model selection

Status: Implemented

The user picks which provider and model Elia talks to from a picker in the
chat composer. Anthropic models come from the Anthropic integration; OpenRouter
models are fetched from OpenRouter's catalog, so new models show up without a
code change.

## Requirements

### Selection

- **MODEL-1** The selection is a provider key, a model id and the model's
  display name, plus its context length when the cached catalog knows it
  (CTX-7), stored in the settings database (CONF-1), so it is global and
  survives restarts. A change is broadcast so open chats update their picker.
- **MODEL-2** With no stored selection, the selection is the configured
  default provider (`config :elia, Elia.LLM, provider: ...`) with that
  provider's configured model.
- **MODEL-3** A session reads the selection when a turn starts and uses that
  provider and model for every model call in the turn. Changing the selection
  mid-turn affects the next turn. Explicit `:llm` loop options are merged
  over it; an explicit `:provider` replaces the selection entirely.
- **MODEL-4** Selecting a provider key that isn't registered, or a blank model
  id, is rejected.

### Catalog

- **MODEL-5** OpenRouter models come from `GET /api/v1/models` (no key
  needed). Only models that list `tools` in `supported_parameters` are
  offered, since Elia's agent loop needs tool calls. Models are sorted by
  name.
- **MODEL-6** Anthropic models come from `GET /v1/models` when a key is
  available. Without a key, or if the request fails, the configured model is
  offered on its own.
- **MODEL-7** Each model has `id`, `name` and, when known, `context_length`
  and prompt/completion prices per million tokens.
- **MODEL-14** The Anthropic Models API has no prices, so Anthropic models get
  them from a built-in table of Anthropic's published first-party rates,
  merged with `config :elia, Elia.LLM.Anthropic, prices: %{id => {in, out}}`.
  A dated snapshot id (`<alias>-YYYYMMDD`) uses its alias's price. Models in
  neither table show no price.
- **MODEL-8** Catalog results are cached for 10 minutes per provider. Failed
  fetches are not cached. Saving or removing a key clears that provider's
  cache.

### Picker

- **MODEL-9** The composer shows the selected model's name in a button
  (`#model-picker-button`), with a colour-coded badge naming its provider
  (`#selected-provider`). Clicking it opens a popover (`#model-picker`).
- **MODEL-10** The popover has a search field (`#model-search`) that filters
  models by name or id, case-insensitively, and lists models grouped by
  provider. Each group has a sticky header (`#group-<key>`) with the
  provider's badge and how it is reached; each model row also carries a
  small provider badge, so e.g. Claude via OpenRouter can't be mistaken for
  Claude direct. The selected model is marked.
- **MODEL-11** Catalogs load asynchronously; while loading the popover shows
  a loading state, and a failed load shows the error for that provider.
- **MODEL-12** Clicking a model selects it (MODEL-1) and closes the popover.
  Escape or clicking outside closes it without changing the selection.
- **MODEL-13** A provider without an active key (CONF-5) shows a link to
  `/settings` instead of selectable models.

## Implementation

`Elia.LLM` (`selection/0`, `select/2`, `models/1`), `Elia.LLM.Catalog`,
`Elia.Agent.Session`, `EliaWeb.ChatLive`.

## Tests

`test/elia/llm/catalog_test.exs`, `test/elia/agent_test.exs`,
`test/elia_web/live/model_picker_test.exs`.
