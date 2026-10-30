# LLM providers

Status: Implemented

Model calls go through a provider-neutral interface, so the agent loop never
depends on one vendor's API. The default provider is Anthropic's Messages API,
streamed over SSE. OpenRouter's OpenAI-compatible Chat Completions API gives
access to many other models.

## Requirements

### Neutral interface

- **LLM-1** A provider implements `stream(request, on_event)` and returns
  `{:ok, %{message, stop_reason, model, usage}}` or `{:error, reason}`.
- **LLM-2** A request has `messages` and optionally `system`, `tools`, `model`
  and `max_tokens`. A request can override the configured provider with
  `:provider`.
- **LLM-3** Streaming events are `{:text_delta, t}`, `{:reasoning_delta, t}`,
  `{:tool_call_started, %{id, name}}` and `{:notice, t}`.
- **LLM-4** Stop reasons are `:end_turn`, `:tool_use`, `:max_tokens`,
  `:refusal` and `:other`.
- **LLM-5** Messages have the role `:user`, `:assistant` or `:tool`, and
  content blocks of type `:text`, `:reasoning`, `:tool_call`, `:tool_result`
  or `:opaque`. `meta` is harness bookkeeping that is never sent to a
  provider.
- **LLM-6** Provider blocks carry `raw: {provider, map}`. A provider sends its
  own raw blocks back unchanged and drops reasoning and opaque blocks from
  other providers.

### Anthropic

- **LLM-7** Without an API key (CONF-5), `stream` returns
  `{:error, "No Anthropic API key: add one in Settings or set ANTHROPIC_API_KEY"}`
  and makes no request.
- **LLM-8** Requests use adaptive thinking, the configured effort, and
  automatic prompt caching (`cache_control: ephemeral`). The beta headers for
  fallbacks and thinking "updates" display are sent only when those features
  are on.
- **LLM-9** Tool results and a following user message are merged into one
  user turn. Messages left with no content are dropped.
- **LLM-10** Statuses 408, 429, 500, 502, 503, 504 and 529 are retried up to
  two times. The wait is `retry-after` (capped at 60s) if present, otherwise
  1s and then 2s. Other errors return the API's error message.
- **LLM-11** Tool input JSON that fails to parse becomes empty input, and the
  raw text is kept in `invalid_input` (see LOOP-6).
- **LLM-12** When the response contains a `fallback` block, a notice is
  emitted. Thinking and tool-call blocks before the last fallback are
  dropped, as are server tool calls that have no result.
- **LLM-13** An `error` event in the stream makes the call return an error.
- **LLM-14** API stop reasons map as: `end_turn` and `stop_sequence` →
  `:end_turn`; `max_tokens` and `model_context_window_exceeded` →
  `:max_tokens`; `tool_use`, `refusal` → same; anything else → `:other`.

- **LLM-28** Thinking blocks are bound to the system prompt they were created
  with, and the system prompt changes between turns (project instructions,
  skills). Requests therefore set
  `thinking.block_binding.prefix_mismatch_behavior` to `"drop_block"` and send
  the `thinking-binding-controls-2026-08-01` beta header, so the API drops
  stale thinking blocks instead of failing with a 400 `Invalid signature`.

### Registry

- **LLM-15** `Elia.LLM.providers/0` lists the registered providers as
  `%{key, name, module, billing_url}`: `"anthropic"` (`Elia.LLM.Anthropic`) and
  `"openrouter"` (`Elia.LLM.OpenRouter`).
- **LLM-16** Providers may implement `check_key/1` (CONF-6),
  `list_models/1` (MODEL-5, MODEL-6) and `balance/1` (LLM-25).

### OpenRouter

- **LLM-17** Without an API key (CONF-5), `stream` returns
  `{:error, "No OpenRouter API key: add one in Settings or set OPENROUTER_API_KEY"}`
  and makes no request.
- **LLM-18** Requests go to `POST /api/v1/chat/completions` with
  `stream: true`, a bearer token and an `X-Title: Elia` header. The system
  prompt is the first message with role `system`. Tools are sent as
  `function` tools with `parameters` set to the input schema. `max_tokens`
  and `reasoning.effort` are sent only when configured or requested.
- **LLM-19** Assistant messages carry their text as `content` and tool calls
  as `tool_calls` with JSON-encoded `arguments`. Each tool result becomes its
  own `tool` message; error results are prefixed with `Error: `. Text in a tool-role message after the results becomes
  a following user message.
- **LLM-20** Streamed `content`, `reasoning` and `tool_calls` deltas emit
  `:text_delta`, `:reasoning_delta` and `:tool_call_started` events. Tool
  call fragments are joined by `index`.
- **LLM-21** `reasoning_details` are accumulated (fragments with the same
  `index` are joined) and kept as the raw data of a `:reasoning` block. They
  are sent back on that assistant message so models can continue their
  reasoning across tool calls.
- **LLM-22** Finish reasons map as: `stop` → `:end_turn`; `tool_calls` →
  `:tool_use`; `length` → `:max_tokens`; `content_filter` → `:refusal`;
  anything else → `:other`. An `error` object in a chunk, or a finish reason
  of `error`, makes the call return an error.
- **LLM-23** Statuses 408, 429, 500, 502, 503 and 504 are retried as in
  LLM-10. Other errors return the API's error message.
- **LLM-24** Tool arguments that fail to parse become empty input, with the
  raw text kept in `invalid_input` (as LLM-11).

### Credits

- **LLM-25** Providers may implement `balance/1`, which makes one
  authenticated request and returns `{:ok, balance}` or `{:error, message}`.
  A balance is `%{scope: :account | :key, used: float, total: float | nil,
  remaining: float | nil}` in USD. `Elia.LLM.balance/1` returns the balance
  for the provider's active key (CONF-5), `{:error, "No API key"}` without
  one, and `:unsupported` for a provider without `balance/1`.
- **LLM-26** OpenRouter's `balance/1` calls `GET /api/v1/credits`
  (`total_credits`, `total_usage`) for an `:account` balance, with
  `remaining = total - used`. If that is refused with 401 or 403 (the
  endpoint needs a management key) it falls back to `GET /api/v1/key` and
  returns a `:key` balance from `usage`, `limit` and `limit_remaining`
  (`total` and `remaining` are `nil` for a key without a limit). Other
  failures return `{:error, message}` like LLM-23.
- **LLM-27** Anthropic has no balance endpoint, so it doesn't implement
  `balance/1`. Each registry entry (LLM-15) has a `billing_url`, the web page
  where credits are added: `https://console.anthropic.com/settings/billing`
  and `https://openrouter.ai/settings/credits`.
- **LLM-28** Tool results and harness messages are always valid UTF-8, since
  they are JSON-encoded for both the provider and the browser. Each invalid
  byte, such as from a command printing a binary file, is replaced with U+FFFD.

## Configuration

```elixir
config :elia, Elia.LLM, provider: Elia.LLM.Anthropic

config :elia, Elia.LLM.Anthropic,
  api_key: System.get_env("ANTHROPIC_API_KEY"),   # a key saved in Settings wins
  model: "claude-opus-5-5",
  max_tokens: 64_000,
  effort: "high",
  thinking_display: "updates",   # "summarized" | "omitted" | nil
  fallbacks: "default",          # nil disables
  prices: %{}                    # extra/override picker prices, USD per MTok {in, out}

config :elia, Elia.LLM.OpenRouter,
  api_key: System.get_env("OPENROUTER_API_KEY"),  # a key saved in Settings wins
  model: "anthropic/claude-opus-5.5",
  max_tokens: nil,               # model default
  effort: nil                    # "low" | "medium" | "high"
```

Tests use `Elia.FakeLLM`.

## Implementation

`Elia.LLM`, `Elia.LLM.Provider`, `Elia.LLM.Message`, `Elia.LLM.Anthropic`,
`Elia.LLM.OpenRouter`, `Elia.LLM.SSE`.

## Tests

`test/elia/llm/anthropic_test.exs`, `test/elia/llm/open_router_test.exs`,
`test/elia/llm/message_test.exs`.
