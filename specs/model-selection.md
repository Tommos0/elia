# Model selection

Status: Implemented

The user picks which provider and model Elia talks to from a picker on the
chat's settings page (CSET-5, `/c/<id>/settings`); the chat itself shows the
model in use in the link to that page (CSET-8). Anthropic models come from the
Anthropic integration; OpenRouter
models are fetched from OpenRouter's catalog, so new models show up without a
code change.

## Requirements

### Selection

- **MODEL-1** A selection is a provider key, a model id and the model's
  display name, plus its context length when the cached catalog knows it
  (CTX-7). Each chat has its own selection, saved with the chat (STORE-1), so
  it is chat-local and survives restarts. Choosing a model in one chat never
  changes another chat's model. The choice is broadcast on the chat's topic
  (SESS-6) so every tab showing that chat updates its picker.
- **MODEL-15** The most recent choice is also stored in the settings
  database (CONF-1) as the default for chats that have no selection of their
  own, so a new chat starts on the model last picked anywhere.
- **MODEL-2** With no chat selection and no stored default, the selection is
  the configured default provider (`config :elia, Elia.LLM, provider: ...`)
  with that provider's configured model.
- **MODEL-3** A session reads the chat's selection when a turn starts and uses
  that provider and model for every model call in the turn. Changing the
  selection mid-turn affects the next turn. Explicit `:llm` loop options are
  merged over it; an explicit `:provider` replaces the selection entirely.
- **MODEL-16** A chat with no selection of its own pins the model it resolves
  to (MODEL-15, or MODEL-2 when its provider is registered) when its first turn
  starts, so later choices in other
  chats don't change it. A saved selection whose provider is no longer
  registered is ignored in favour of MODEL-15/MODEL-2.
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

- **MODEL-9** The chat settings page's Model section (CSET-5) shows the
  selected model's name in a button
  (`#model-picker-button`), with a colour-coded badge naming its provider
  (`#selected-provider`). Clicking it opens a popover (`#model-picker`). The
  chat page shows the same name in its link to that page (CSET-8).
- **MODEL-10** The popover has a search field (`#model-search`) that filters
  models by name or id, case-insensitively, and lists models grouped by
  provider. Each group has a sticky header (`#group-<key>`) with the
  provider's badge and how it is reached; each model row also carries a
  small provider badge, so e.g. Claude via OpenRouter can't be mistaken for
  Claude direct. The selected model is marked.
- **MODEL-11** Catalogs load asynchronously; while loading the popover shows
  a loading state, and a failed load shows the error for that provider.
- **MODEL-12** Clicking a model selects it for this chat (MODEL-1) and closes
  the popover.
  Escape or clicking outside closes it without changing the selection.
- **MODEL-13** A provider without an active key (CONF-5) shows a link to
  `/settings` instead of selectable models — except one that needs no key at
  all (LOCAL-2), which offers its models with none.

## Implementation

`Elia.LLM` (`selection/1`, `select/3`, `models/1`), `Elia.LLM.Catalog`,
`Elia.Agent.Session`, `EliaWeb.ChatSettingsLive` (the picker, MODEL-9 to
MODEL-13).

## Tests

`test/elia/llm/catalog_test.exs`, `test/elia/agent_test.exs`,
`test/elia_web/live/model_picker_test.exs`.
