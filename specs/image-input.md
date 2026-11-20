# Image input

Status: Implemented

Some models can see pictures. A picture reaches such a model as the picture
itself, not only as the line naming its path (UPLOAD-10), so the agent can read
a screenshot, a photo or a chart rather than be told about it. It reaches it
because the agent looked: the harness offers a call that reads one picture of
the chat's own workspace and records it on its result, and the request is given
that picture in the result's own turn (VISION-12, VISION-14). Whether a picture
is sent is therefore the agent's decision and not the upload's (VISION-15): an
attachment is a file like any other, and all a message carries is the line
naming its path. Every picture is read from the chat's workspace when the
request is built (VISION-3), so the saved chat keeps paths and no picture, and
a model that cannot see pictures is asked exactly what it is asked today.

## Requirements

- ~~**VISION-1** A user message carrying an image attachment is sent with the
  image itself: the request the model is given carries the file's bytes as an
  `:image` content block (LLM-5) in that message's own turn, in the order the
  files were attached, after the text the user wrote and the line naming the
  paths (UPLOAD-10).~~ Retired: an attachment is no longer sent by itself, and
  what the agent looks at is sent in the result's own turn instead (VISION-12,
  VISION-15).
- **VISION-2** A file is an image when its extension is `.png`, `.jpg`,
  `.jpeg`, `.webp` or `.gif`, whatever its case, and its first bytes are that
  format's signature; the media type sent is that format's (`image/png`,
  `image/jpeg`, `image/webp`, `image/gif`). A file that fails either test is not
  sent as an image.
- **VISION-3** An image is read when a request is built, not when the call or
  the message is saved: the saved chat keeps the path a look recorded
  (VISION-12) and no image bytes.
- **VISION-4** An image is sent only to a model that accepts images (VISION-7).
  A model that does not is sent what it is sent today: the line naming the paths
  (UPLOAD-10), and no image — a look on such a model is refused (VISION-13).
- **VISION-5** An image that cannot be read — a path that leaves the chat's
  workspace, a file that isn't there, isn't a regular file or can't be read, or
  one whose bytes aren't the format its extension names (VISION-2) — is left
  out of the request and the turn goes on, the result keeping the path it
  recorded.
- **VISION-6** The images one request carries are bounded: each at most 5 MB and
  all of them together at most 15 MB, taken from the newest message first, so an
  image over either bound is left out (VISION-5) while the rest are sent.
- **VISION-7** A model accepts images when its catalog entry says so (MODEL-7):
  OpenRouter reports it as `architecture.input_modalities` listing `image`, and
  every Anthropic model accepts them (its Models API reports no such field); a
  model of the local llama.cpp provider (LOCAL) does not, since Elia starts that
  server without a projector. The answer for a chat's model is the catalog's
  when the cache holds it, else the capability recorded with the chat's
  selection, else the provider's own — read back for a request without a catalog
  fetch, as the context window is (CTX-7). The capability is recorded with the
  selection when a model is chosen (MODEL-1), from the provider's catalog
  whatever the age of the cache: its cached answer, or one fetched for the
  choice, so a picker whose list went stale cannot leave it unrecorded.
- **VISION-8** Each provider encodes an `:image` block its own way: Anthropic as
  a base64 image content block carrying the media type, beside the result's own
  tool-result block in the same message, and the OpenAI-compatible encoding
  (LLM-19, LOCAL-1) as a user message that follows it, whose `content` is a
  list of parts — its text and one `image_url` part per image, each a `data:`
  URL.
- **VISION-9** An image stays in the request view (COMPACT-2) as long as the
  message carrying it does: every step of a turn and every later turn that sends
  that message sends the image again, and a message that leaves the view
  (COMPACT) takes its image with it.
- **VISION-10** The context estimate counts each picture a request will carry
  (CTX-3) at a fixed estimate per image, in the bucket of the message that
  carries it (CTX-4) — the User bucket for an attachment (UPLOAD-11), the Other
  tools bucket for a result that recorded a look (VISION-12) — so the breakdown
  still sums to the total. It is counted from the path alone — the estimate
  reads no file — so the pictures count whether or not the request ends up
  sending them (VISION-4, VISION-5).
- **VISION-11** A choice whose catalog cannot be read is still made: the
  selection carries no capability, and the provider's own answer applies until
  that model is chosen again (VISION-7).
- **VISION-12** The harness offers a call that looks at a picture: it names a
  path in the chat's workspace, reads that file, and records on its result the
  path, the media type and the size it read (LLM-6, LLM-32), while its text says
  which picture it saw.
- **VISION-13** A look that cannot be answered fails, as an error result saying
  which it was: a path that leaves the chat's workspace, a file that isn't there,
  isn't a regular file or can't be read, a file that isn't an image (VISION-2),
  one larger than the bound for a single image (VISION-6), or a model that
  accepts no images (VISION-4, VISION-7).
- **VISION-14** A result that recorded a look is sent with the picture itself:
  the request the model is given carries the file's bytes as an `:image` content
  block (LLM-5) in that result's own turn, after the blocks it already has.
- **VISION-15** An attachment is not sent as a picture by itself: a message that
  carries one names its path (UPLOAD-10), and nothing of the picture reaches the
  model unless a look asks for it (VISION-12), so what a message carries is the
  same whether the model can see pictures or not.
- **VISION-16** The transcript shows what a call looked at: the call's card
  shows the picture itself, from the chat's own workspace, and it opens in the
  image viewer (IMG-1) like any other, from the saved chat as well as from a
  call just made.
- **VISION-17** What the agent is told about a look names what it is for: the
  tool's description says that it reads one picture of the chat's workspace, and
  the instructions that a picture there — a screenshot the user uploaded
  (UPLOAD-10), or one the agent made itself (PREVIEW) — is looked at with the
  tool when the answer may depend on what is in it.

## Terms

- **image attachment** — a file a message carries (UPLOAD-11) whose extension
  names an image format and whose bytes are that format (VISION-2).
- **look** — a call that reads one picture of the chat's workspace and records
  it on its result (VISION-12).

## Out of scope

- Showing an attached image as a picture in the transcript: a chip stays a link
  to the Files page (UPLOAD-12, EXPL-8).
- Saying in the composer or the transcript whether an image was sent to the
  model or left out (VISION-4, VISION-5).
- Converting, resizing or compressing an image: a file is kept as the user
  handed it over (UPLOAD), and one over a bound is left out rather than shrunk.
- An image fetched from a URL, a page of a PDF and a video: a look reads a file
  of the chat's workspace (VISION-12).
- A look nobody asked for: nothing looks at a picture but the agent's own call,
  so an attachment is a file like any other (VISION-15).

## Stored data

Backward compatible, with nothing to migrate. The one stored shape that changes
is the model selection (MODEL-1, MODEL-15), which gains whether its model
accepts images (VISION-7): a chat's settings map and the stored default are maps
that already carry such values, and a selection written before this feature has
no such key, which reads as unknown and falls back to the catalog cache and then
to the provider's own default, so an older file loads as it did. Choosing that
model again records the capability (VISION-7); nothing is rewritten when a file
loads. A message
stores no image (VISION-3): the bytes of a file the user attached are read from
the chat's workspace and never enter `.elia`, so the saved transcript keeps the
shape it has. A call's result gains the key that records the picture it looked
at (VISION-12), which no provider is sent (LLM-6) and an older version of Elia
reads and ignores.

## Implementation

`Elia.Skills.Image` (the call that looks, and the file it reads — VISION-12,
VISION-13, VISION-17), `Elia.LLM.Images` (the formats and their signatures,
reading a file and the bounds — VISION-2, VISION-3, VISION-5, VISION-6),
`Elia.Agent.Loop` (the request it builds, and the pictures it takes from the
request view — VISION-4, VISION-9, VISION-14, VISION-15) and `Elia.Agent.Session`
(whether the turn's model accepts images), `Elia.LLM.Anthropic` and
`Elia.LLM.OpenAI` (the encodings — VISION-8), `Elia.LLM.Message` (the `:image`
block, and the key a result carries — VISION-12), `Elia.LLM.Tokens` (the
estimate — VISION-10), `Elia.LLM.Provider` (the model's capability),
`Elia.LLM.Anthropic`, `Elia.LLM.OpenRouter` and `Elia.LLM.LlamaCpp` (the
capability each catalog reports), `Elia.LLM.Catalog` (the catalog a choice asks
when its cache no longer holds one), `Elia.LLM` (the capability of a chat's
selection — VISION-7, VISION-11) and `EliaWeb.ChatLive` (the card of a call that
looked — VISION-16).

## Tests

- `test/elia/llm/images_test.exs` (the formats and their signatures, the file a
  look recorded read from the workspace when the request is built, the path that
  leaves it, the bounds and the order they take the newest first — VISION-2,
  VISION-3, VISION-5, VISION-6).
- `test/elia/skills/image_test.exs` (the call that looks: the picture recorded
  on its result, and each refusal — a path that leaves the workspace, a file
  that isn't there, one that isn't an image, one over the bound, and a model
  that accepts none — VISION-12, VISION-13, VISION-17).
- `test/elia/agent_test.exs` (the request the loop builds: the picture in the
  result's own turn, a model that accepts none, a file that is gone, an
  attachment that is not sent by itself, and the picture a later step of the
  same turn sends again — VISION-4, VISION-9, VISION-14, VISION-15).
- `test/elia/llm/anthropic_test.exs` and `test/elia/llm/open_ai_test.exs` (the
  encoding each provider gives an `:image` block — VISION-8).
- `test/elia/llm/catalog_test.exs` and `test/elia/llm/images_test.exs` (the
  capability each provider's catalog reports, the one a chat's selection
  resolves to without a fetch, the one a model chosen from a cold cache records,
  and the choice a catalog that cannot be read still makes — VISION-7,
  VISION-11).
- `test/elia/llm/context_test.exs` (a picture counted in the bucket of the
  message that carries it, so the breakdown still sums to the total —
  VISION-10).
- `test/elia_web/live/chat_live_test.exs` (the card of a call that looked: the
  picture itself, and it opens in the image viewer — VISION-16).
