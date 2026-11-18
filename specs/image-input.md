# Image input

Status: Implemented

Some models can see pictures. An image the user attaches to a message is sent to
such a model as the picture itself, not only as the line naming its path
(UPLOAD-10), so the agent can read a screenshot, a photo or a chart rather than
be told about it. The file is the one the user uploaded, read from the chat's
workspace when the request is built (UPLOAD-6): the saved chat keeps the paths
it already keeps and no picture, and a model that cannot see pictures is asked
exactly what it is asked today, so attaching an image never costs a turn.

## Requirements

- **VISION-1** A user message carrying an image attachment is sent with the
  image itself: the request the model is given carries the file's bytes as an
  `:image` content block (LLM-5) in that message's own turn, in the order the
  files were attached, after the text the user wrote and the line naming the
  paths (UPLOAD-10).
- **VISION-2** An attachment is an image when its extension is `.png`, `.jpg`,
  `.jpeg`, `.webp` or `.gif`, whatever its case, and its first bytes are that
  format's signature; the media type sent is that format's (`image/png`,
  `image/jpeg`, `image/webp`, `image/gif`). A file that fails either test is not
  sent as an image.
- **VISION-3** An image is read when a request is built, not when the message is
  appended: the saved chat keeps the paths of UPLOAD-11 and no image bytes.
- **VISION-4** An image is sent only to a model that accepts images (VISION-7).
  A model that does not is sent the message as it is today: the line naming the
  paths, and no image.
- **VISION-5** An image that cannot be read — a path that leaves the chat's
  workspace, a file that isn't there, isn't a regular file or can't be read, or
  one whose bytes aren't the format its extension names (VISION-2) — is left out
  of the request and the turn goes on, the message keeping the line naming its
  path.
- **VISION-6** The images one request carries are bounded: each at most 5 MB and
  all of them together at most 15 MB, taken from the newest message first, so an
  image over either bound is left out (VISION-5) while the rest are sent.
- **VISION-7** A model accepts images when its catalog entry says so (MODEL-7):
  OpenRouter reports it as `architecture.input_modalities` listing `image`, and
  every Anthropic model accepts them (its Models API reports no such field); a
  model of the local llama.cpp provider (LOCAL) does not, since Elia starts that
  server without a projector. The capability is recorded with the chat's
  selection when a model is chosen (MODEL-1) and read back for a request without
  a catalog fetch, as the context window is (CTX-7).
- **VISION-8** Each provider encodes an `:image` block its own way: Anthropic as
  a base64 image content block carrying the media type, and the
  OpenAI-compatible encoding (LLM-19, LOCAL-1) as a user message whose `content`
  is a list of parts — its text and one `image_url` part per image, each a
  `data:` URL.
- **VISION-9** An image stays in the request view (COMPACT-2) as long as the
  message carrying it does: every step of a turn and every later turn that sends
  that message sends the image again, and a message that leaves the view
  (COMPACT) takes its image with it.
- **VISION-10** The context estimate counts each image attachment a message
  carries (CTX-3) at a fixed estimate per image, in that message's own User
  bucket (CTX-4), so the breakdown still sums to the total. It is counted from
  the attachment's path alone — the estimate reads no file — so the images count
  whether or not the request ends up sending them (VISION-4, VISION-5).

## Terms

- **image attachment** — a file a message carries (UPLOAD-11) whose extension
  names an image format and whose bytes are that format (VISION-2).

## Out of scope

- An image the agent reads with a tool, or one it makes itself — a preview
  screenshot (PREVIEW): the images a request carries are the ones a user message
  carries (VISION-1).
- Showing an attached image as a picture in the transcript: a chip stays a link
  to the Files page (UPLOAD-12, EXPL-8).
- Saying in the composer or the transcript whether an image was sent to the
  model or left out (VISION-4, VISION-5).
- Converting, resizing or compressing an image: a file is kept as the user
  handed it over (UPLOAD), and one over a bound is left out rather than shrunk.
- Images in a tool result, an image fetched from a URL, and any other input
  than a file the user attached: video, and the pages of a PDF.

## Stored data

Backward compatible, with nothing to migrate. The one stored shape that changes
is the model selection (MODEL-1, MODEL-15), which gains whether its model
accepts images (VISION-7): a chat's settings map and the stored default are maps
that already carry such values, and a selection written before this feature has
no such key, which reads as unknown and falls back to the catalog cache and then
to the provider's own default, so an older file loads as it did. A message
stores no image (VISION-3): the bytes of a file the user attached are read from
the chat's workspace and never enter `.elia`, so the saved transcript keeps the
shape it has.

## Implementation

`Elia.LLM.Images` (the formats and their signatures, reading a file and the
bounds — VISION-2, VISION-3, VISION-5, VISION-6), `Elia.Agent.Loop` (the
request it builds, and the images it takes from the request view —
VISION-1, VISION-4, VISION-9) and `Elia.Agent.Session` (whether the turn's model
accepts images), `Elia.LLM.Anthropic` and `Elia.LLM.OpenAI` (the encodings —
VISION-8), `Elia.LLM.Message` (the `:image` block), `Elia.LLM.Tokens` (the
estimate — VISION-10), `Elia.LLM.Provider` (the model's capability),
`Elia.LLM.Anthropic`, `Elia.LLM.OpenRouter` and `Elia.LLM.LlamaCpp` (the
capability each catalog reports) and `Elia.LLM` (the capability of a chat's
selection — VISION-7).

## Tests

- `test/elia/llm/images_test.exs` (the formats and their signatures, the file a
  message carries read from the workspace, the path that leaves it, the bounds
  and the order they take the newest first — VISION-2, VISION-3, VISION-5,
  VISION-6).
- `test/elia/agent_test.exs` (the request the loop builds: the image in its own
  turn, after the text and the path line, a model that accepts none, a file that
  is gone, and the image a later step of the same turn sends again — VISION-1,
  VISION-4, VISION-9).
- `test/elia/llm/anthropic_test.exs` and `test/elia/llm/open_ai_test.exs` (the
  encoding each provider gives an `:image` block — VISION-8).
- `test/elia/llm/catalog_test.exs` and `test/elia/llm/images_test.exs` (the
  capability each provider's catalog reports and the one a chat's selection
  resolves to without a fetch — VISION-7).
- `test/elia/llm/context_test.exs` (an image counted in the User bucket, so the
  breakdown still sums to the total — VISION-10).
