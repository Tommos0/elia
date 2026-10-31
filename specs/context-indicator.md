# Context indicator

Status: Implemented

Each chat shows, at the top of the transcript, how large the request context
is — the tokens the model is about to (or just did) see: the system prompt,
tool definitions and the whole conversation. When the selected model's context
window is known, the indicator also shows it and the percentage used. Clicking
the indicator opens a breakdown listing what makes up the context — messages,
files, skills, tool definitions and more — each with an estimated token count.

## Requirements

- **CTX-1** The chat page shows a context indicator above the transcript with
  the estimated token size of the current request context.
- **CTX-2** When the selected model's context window is known, the indicator
  also shows the window size and the percentage of it used, rendered as a
  coloured progress bar.
- **CTX-3** The estimate derives locally from the exact pieces sent to the
  model: the system prompt (agent instructions, the project instructions from
  the chat's project's `AGENTS.md` when present, and each skill's
  instructions),
  the tool definitions, and every message (user text, assistant text,
  reasoning, tool calls and tool results). Each text or payload belongs to
  exactly one bucket, so the bucket totals sum to the overall estimate (which
  includes the provider adjustment, CTX-10, when there is one).
- **CTX-4** Clicking the indicator toggles a breakdown panel (`#context-breakdown`)
  that lists the parts of the context with their estimated tokens and an item
  count: System prompt (with an "Agent instructions" child, a "Project
  instructions" child when `AGENTS.md` is injected (SKILL-10), and one "Skill:
  <name>" child per skill), Tool definitions, Messages (with User, Assistant
  and Reasoning children), Files, Shell and Other tools.
- **CTX-5** `read_file`, `write_file` and `edit_file` tool calls and results
  count under Files; `shell` calls and results under Shell; any other tool
  under Other tools.
- **CTX-6** After each model request, the session records the provider's
  reported input usage and broadcasts it; the breakdown panel shows it as the
  provider-reported figure. For Anthropic this is `input_tokens` plus the
  prompt-cache reads and writes (`cache_read_input_tokens`,
  `cache_creation_input_tokens`), since cached tokens are still in the
  context; otherwise `prompt_tokens`. A reset of the conversation (e.g. a
  refused turn rolled back) clears the figure.
- **CTX-7** The context window size comes from the model catalog when cached
  (never triggering a network fetch, nor waiting on one in flight); otherwise
  the context length stored with the chat's selection (MODEL-1); otherwise a built-in
  default for Anthropic models; otherwise it is omitted from the indicator.
  When the cached catalog reports a length the stored selection lacks (e.g. a
  model selected before lengths were stored), it is saved with the stored default
  selection (MODEL-15) so the window survives the catalog cache expiring.
- **CTX-8** The indicator and breakdown stay in sync with the conversation:
  they update as messages arrive, when the conversation is reset, when skills
  are reloaded, and when the model selection or its catalog changes. The
  estimate is updated incrementally per message rather than recomputed on
  every render.
- **CTX-9** A reasoning block that carries a provider signature (Anthropic
  `thinking` blocks) is estimated as the larger of its visible text and its
  signature. The signature holds the model's full, encrypted thinking, which
  the API counts as input even when the visible text is empty or a summary.
  The signature is base64, so it is sized as 3 bytes per 4 characters at about
  4 bytes per token (`ceil(length * 3 / 16)`). Blocks without a signature are
  estimated from their text, as before.
- **CTX-10** The local estimate is calibrated against the provider's report.
  With each usage report the session records `estimated_input_tokens`, its
  estimate for the history that request sent. The difference between the
  CTX-6 figure and that estimate becomes the context's adjustment, shown in the
  breakdown as a "Provider adjustment" bucket when non-zero and included in the
  total. Later messages and skill changes are estimated on top of it, so the
  total stays anchored to the last report as the conversation grows. A negative
  adjustment is capped so the total never drops below zero. A usage report
  without both figures, or a reset of the conversation, clears the adjustment.

## Implementation

`Elia.LLM.Context`, `Elia.LLM.Tokens`, `Elia.LLM` (`context_window/0`),
`Elia.LLM.Catalog` (`peek/1`), `Elia.Agent.Session`, `Elia.Agent.Loop`,
`EliaWeb.ChatLive`.

## Tests

`test/elia/llm/tokens_test.exs`, `test/elia/llm/context_test.exs`,
`test/elia/llm/catalog_test.exs`, `test/elia_web/live/chat_live_test.exs`.