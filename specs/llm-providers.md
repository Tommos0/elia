# LLM providers

Status: Implemented

Model calls go through a provider-neutral interface, so the agent loop never
depends on one vendor's API. The default provider is Anthropic's Messages API,
streamed over SSE.

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

- **LLM-7** Without an API key, `stream` returns
  `{:error, "ANTHROPIC_API_KEY is not set"}` and makes no request.
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

## Configuration

```elixir
config :elia, Elia.LLM, provider: Elia.LLM.Anthropic

config :elia, Elia.LLM.Anthropic,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model: "claude-opus-5-5",
  max_tokens: 64_000,
  effort: "high",
  thinking_display: "updates",   # "summarized" | "omitted" | nil
  fallbacks: "default"           # nil disables
```

Tests use `Elia.FakeLLM`.

## Implementation

`Elia.LLM`, `Elia.LLM.Provider`, `Elia.LLM.Message`, `Elia.LLM.Anthropic`,
`Elia.LLM.SSE`.

## Tests

`test/elia/llm/anthropic_test.exs`.
