# LLM providers

Status: Implemented

Model calls go through a provider-neutral interface, so the agent loop never
depends on one vendor's API. The default provider is Anthropic's Messages API,
streamed over SSE. OpenRouter's OpenAI-compatible Chat Completions API gives
access to many other models. A `llama-server` on the machine is a third
provider, with no key and no network at all (LOCAL).

## Requirements

### Neutral interface

- **LLM-1** A provider implements `stream(request, on_event)` and returns
  `{:ok, %{message, stop_reason, model, usage}}` or `{:error, reason}`, where
  `reason` is the message to show (a binary) or an `Elia.LLM.Error` when the
  failure is one a retry may fix (LLM-36, RETRY-6).
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
- **LLM-33** A `tool_call` and its `tool_result` always go together, never
  split: in every history the harness stores, sends, or derives a view from,
  each `tool_call` is answered by exactly one `tool_result` carrying its `id`,
  in the message immediately after the assistant message that made the call,
  and no `tool_result` appears without the call it answers. Both APIs reject a
  history that breaks this (Anthropic on an unanswered `tool_use`, the
  OpenAI-compatible APIs on a `tool_calls` id without its `tool` message), so
  the harness never builds one: every unanswered call gets a result when a turn
  is stopped, crashes or the app restarts (SESS-8, SESS-12, SESS-21),
  compaction keeps a call and its result together — whole turns at a time
  (COMPACT-4) and the paired message when a pin touches one of them
  (COMPACT-21) — and the encoders keep them adjacent (LLM-9, LLM-19).

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

- **LLM-29** The shipped config sets `thinking_display: "summarized"`, so
  every thinking block carries a summary of the reasoning that the chat UI can
  show (UI-29). The code default stays `"updates"` (sparse progress notes, most
  blocks empty). `"summarized"` sends no `thinking-display-updates` beta
  header, and `"omitted"` returns no thinking text at all.

- **LLM-30** A connection that was closed before any response data arrived
  (`Req.TransportError` with reason `:closed`, shown as "socket closed") is
  retried at once on a fresh connection, up to two times, sharing the retry
  budget of LLM-10. It is typically a pooled connection that went stale while
  the app sat idle. Once any response data has been received the call is not
  retried, so no streamed event is ever emitted twice; it returns
  `{:error, "Anthropic API request failed: ..."}`. Other transport errors are
  not retried, except the stalled-stream timeout of LLM-35.
- **LLM-31** LLM-30 also applies to OpenRouter's streaming call (with an
  `OpenRouter API request failed: ...` error), and to the `GET` requests of
  both providers (model list, key check, balance; their errors keep their
  existing "... request failed: ..." wording). A `GET` has no streamed
  events, so it is retried on a closed connection (up to two times, at once)
  whatever has been received.

### Registry

- **LLM-15** `Elia.LLM.providers/0` lists the registered providers as
  `%{key, name, module, billing_url}`: `"anthropic"` (`Elia.LLM.Anthropic`),
  `"openrouter"` (`Elia.LLM.OpenRouter`) and `"llamacpp"`
  (`Elia.LLM.LlamaCpp`, the local server of LOCAL). `billing_url` is the page
  where credits are added, and is `nil` for a provider that has none (LOCAL-7).
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

- **LLM-37** A request whose model is in the Anthropic family (its id starts
  with `anthropic/`) carries one explicit prompt-cache breakpoint,
  `cache_control: %{"type" => "ephemeral"}`, on the system message: the
  encoding sends that message's `content` as a list holding a single text part
  with the same text and the breakpoint. A provider caches the prefix up to a
  breakpoint — the tools and the system prompt, which don't change from step to
  step — so a turn's later steps read that prefix from the cache instead of
  sending it again. Nothing else about the request changes: its messages,
  tools, model and text are what they were, and a breakpoint is a caching hint
  that cannot change an answer. A request with no system prompt, and every
  request to a model of any other family (which documents no such field, and
  would fail every step by rejecting it), is encoded exactly as before.
  `config :elia, Elia.LLM.OpenRouter, cache_control: false` turns breakpoints
  off for every model.

- **LLM-38** The shipped reasoning-effort default is `"medium"` rather than
  `"high"` on one provider and unset on the other
  (`config :elia, Elia.LLM.Anthropic, effort: "medium"` and the Anthropic
  adapter's code default; `config :elia, Elia.LLM.OpenRouter, effort:
  "medium"`), since most of a turn's steps are a lookup and a read rather than
  a decision. OpenRouter sends the configured `reasoning.effort` only for a
  model in the Anthropic family, as in LLM-37, so a model that documents no
  such field is sent the request it was sent before; an effort the request
  itself names (LLM-39) is still sent whatever the model is, since the caller
  named it. `effort: nil` sends none, as before.

- **LLM-39** A request's own `:effort` overrides the configured effort on both
  providers: `Elia.LLM.Anthropic` sends `request[:effort]` when the request has
  one, and the configured value only without it (it read only the configured
  value before), while the OpenAI-compatible encoding already prefers the
  request's. It is what carries a chat's own reasoning effort into the request
  (SESS-40, CSET-13).

### Streaming timeouts

- **LLM-34** A streaming model request uses an idle timeout of 90 seconds by
  default (`config :elia, :stream_idle_timeout`), not 10 minutes, so a stream
  that stops receiving data is cut off and the turn fails in a minute and a
  half instead of ten. It is an *idle* timeout — Req's `receive_timeout`, which
  Finch applies per chunk — not a cap on the whole answer: any byte, a text or
  reasoning delta as much as an SSE keep-alive comment, resets it, so a slow
  but live stream runs as long as it needs. Both providers send it.
- **LLM-35** A streaming call that ends in a transport timeout
  (`Req.TransportError` with reason `:timeout`) *before any response data
  arrived* — the stalled stream LLM-34 cuts off — is retried at once on a
  fresh connection, up to two times, sharing the retry budget of LLM-10
  (Anthropic) and LLM-23 (OpenRouter). Once any response data has been received
  the call is not retried, since a partial stream cannot be replayed without
  emitting its events twice; it returns `{:error, "… API request failed: …"}`,
  as for a closed connection (LLM-30, LLM-31). Both providers' streaming calls
  follow this rule; its two decisions (retry a stall that received nothing,
  retry nothing once data has arrived) live in `Elia.LLM.Retry`.

### Transient failures

- **LLM-36** A streaming call's failure is marked transient — returned as
  `{:error, %Elia.LLM.Error{transient: true}}` (LLM-1) so a turn may try again
  (RETRY-6) — when a retry could fix it: a transport error (`Req.TransportError`,
  which is what a stalled or closed connection raises), a status in the
  provider's own retry list once those retries are spent (LLM-10, LLM-23), and
  an in-stream `error` event the service reports as its own trouble — Anthropic's
  `overloaded_error`, `api_error` and `rate_limit_error`, OpenRouter's `error`
  object with a code in its retry list. Every other failure stays a plain
  message, including the one a stream error names as the request's fault. The
  `GET` calls (LLM-31) keep their messages as they are.

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
  `balance/1`. Each registry entry (LLM-15) with credits has a `billing_url`,
  the web page where they are added:
  `https://console.anthropic.com/settings/billing` and
  `https://openrouter.ai/settings/credits`. A provider with none — the local
  server of LOCAL-7 — has a `nil` one.

### Encoding

- **LLM-32** Tool results and harness messages are always valid UTF-8, since
  they are JSON-encoded for both the provider and the browser. Each invalid
  byte, such as from a command printing a binary file, is replaced with U+FFFD.

## Configuration

```elixir
config :elia, Elia.LLM, provider: Elia.LLM.Anthropic

config :elia, Elia.LLM.Anthropic,
  api_key: System.get_env("ANTHROPIC_API_KEY"),   # a key saved in Settings wins
  model: "claude-opus-5-5",
  max_tokens: 64_000,
  effort: "medium",              # LLM-38: was "high"
  thinking_display: "updates",   # "summarized" | "omitted" | nil
  fallbacks: "default",          # nil disables
  prices: %{}                    # extra/override picker prices, USD per MTok {in, out}

config :elia, Elia.LLM.OpenRouter,
  api_key: System.get_env("OPENROUTER_API_KEY"),  # a key saved in Settings wins
  model: "anthropic/claude-opus-5.5",
  max_tokens: nil,               # model default
  effort: "medium",              # "low" | "medium" | "high" (LLM-38; Anthropic family only)
  cache_control: true            # prompt-cache breakpoint (LLM-37; Anthropic family only)

# LLM-34: how long a stream may receive no data at all before it is cut off.
config :elia, :stream_idle_timeout, 90_000
```

The effort default and the cache breakpoint are request-time only: neither is
stored, so no settings value changes meaning. The chat's own effort (CSET-13,
SESS-40) is a new field in a saved chat (STORE-37): a chat saved before it has
no `effort` key, which reads as no effort of its own (STORE-38), so the
configured default applies and every older file is read exactly as it was — no
migration.

Tests use `Elia.FakeLLM`.

## Implementation

`Elia.LLM`, `Elia.LLM.Provider`, `Elia.LLM.Message`, `Elia.LLM.Error`,
`Elia.LLM.Anthropic`, `Elia.LLM.OpenRouter`, `Elia.LLM.OpenAI` (the
OpenAI-compatible encoding that both of them share, LOCAL-10),
`Elia.LLM.LlamaCpp` and `Elia.LLM.LlamaServer` (LOCAL), `Elia.LLM.Retry`,
`Elia.LLM.SSE`.

## Tests

- `test/elia/llm/message_test.exs` (the request, the streaming events, the stop
  reasons and the message roles — LLM-2 to LLM-5, LLM-32).
- `test/elia/llm/anthropic_test.exs` (the request body and thinking, merged
  tool results, the retried statuses, unparsable tool input, a fallback notice,
  the stop reasons, a signed thinking block and the display setting, a
  connection closed before data arrived, the key that is missing — LLM-7 to
  LLM-12, LLM-14, LLM-28 to LLM-31, LLM-38, LLM-39).
- `test/elia/llm/open_router_test.exs` (the OpenAI-compatible call, its
  streamed deltas, finish reasons and retries, the model family it routes
  around, the balance endpoint, the key that is missing — LLM-6, LLM-17 to
  LLM-27, LLM-31, LLM-37 to LLM-39).
- `test/elia/llm/open_ai_test.exs` (the shared encoding, LLM-21, LLM-37,
  LOCAL-10).
- `test/elia/llm/retry_test.exs` (the retry schedule, LLM-31).
- `test/elia/llm/catalog_test.exs` (the providers it lists, LLM-15).
- `test/elia/settings_test.exs` (a provider's own key check, LLM-16).
- `test/elia/step_timing_test.exs` (a provider's `stream/2` as a step drives
  it, LLM-1).
- `test/elia/llm/stream_timeout_test.exs` (the stream idle timeout and the
  stalled-stream retry over a real socket, since a `Req.Test` plug never applies
  `receive_timeout` — LLM-30, LLM-34, LLM-35).
- The pairing rule (LLM-33) is covered where it is kept:
  `test/elia/llm/compaction_test.exs` (a call and its result are kept or dropped
  together) and `test/elia/agent_test.exs` (an error event in the stream,
  LLM-13; a stopped turn, a crash and an app restart each close every
  unanswered call, SESS-8, SESS-12, SESS-21).
- `test/elia/llm/llama_cpp_test.exs` (the local provider, LOCAL-1 to LOCAL-9).
