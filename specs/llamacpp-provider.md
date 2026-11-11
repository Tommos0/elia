# llama.cpp local provider

Status: Draft

A `llama-server` from the user's own llama.cpp checkout is a third provider
(LLM-15), next to Anthropic and OpenRouter: it needs no API key, no account and
no network, so a chat can run entirely on the machine. Because it speaks the
OpenAI-compatible Chat Completions API, it shares its encoding with OpenRouter
(LLM-10). Elia can also start and stop the server itself, from Settings, from a
`.gguf` file the user picks — so a local model is one button away, and the way
it was launched is visible when it fails.

## Requirements

### The provider

- **LOCAL-1** `Elia.LLM.LlamaCpp` implements `Elia.LLM.Provider` (LLM-1).
  Requests go to `POST <base_url>/v1/chat/completions` with `stream: true`, and
  the response is decoded as OpenRouter's is (LLM-19 to LLM-24): text and
  reasoning deltas, tool calls joined by index, the same stop-reason mapping.
- **LOCAL-2** The provider needs no API key: with none stored or configured it
  still streams, and nothing in the app refuses it for lack of one (CONF-5).
  An `Authorization: Bearer <key>` header is sent only when a key is set, for a
  server started with its own `--api-key`.
- **LOCAL-3** The base URL is `config :elia, Elia.LLM.LlamaCpp, base_url:`,
  `LLAMA_CPP_BASE_URL`, else `http://127.0.0.1:8080`. A base URL saved in
  Settings (LOCAL-24) wins over both.
- **LOCAL-4** `list_models/1` reads `GET <base_url>/v1/models` and returns one
  model per listed id, with the id as its name. `GET <base_url>/props` is read
  as well, when it answers: `default_generation_settings.n_ctx` gives the
  model's context length (CTX-7), and `model_path` gives its file name.
- **LOCAL-5** A `GET` that fails — no server listening, a timeout, a bad
  status — is not an error to shout about: `list_models/1` returns the
  configured model on its own, as Anthropic's does without a key (MODEL-6),
  and the picker shows the connection error beside it.
- **LOCAL-6** `default_model/0` is the configured `model`, else the running
  server's first model id, else `"local"`.
- **LOCAL-7** The provider has no credits, so it implements no `balance/1`
  (LLM-25) and its registry entry has no `billing_url` (LLM-15).
- **LOCAL-8** A failure that a retry could fix is marked transient as LLM-36
  requires — a transport error (a server that is restarting, a connection
  refused), a status in the retry list of LLM-23 once retried, and a stream
  error object naming the service's own trouble. A connection refused is
  reported as
  `"No llama.cpp server at <base_url>: start one in Settings"`, which names the
  fix rather than the syscall.
- **LOCAL-9** A stream that stops receiving data is cut off by the idle timeout
  of LLM-34 and retried as LLM-35 requires, exactly as for the other two
  providers.

### Shared encoding

- **LOCAL-10** The OpenAI-compatible encoding — request building, SSE parsing,
  tool-call assembly, reasoning deltas, stop reasons, error extraction — lives
  in `Elia.LLM.OpenAI` and is used by both `Elia.LLM.OpenRouter` and
  `Elia.LLM.LlamaCpp`. Extracting it must not change OpenRouter's behaviour:
  LLM-18 to LLM-24 still hold, and their tests still pass unchanged.

### The server process

- **LOCAL-11** Elia runs at most one `llama-server` at a time, under its own
  supervisor, and never more than one on a given port. Starting while one is
  already running is refused with a message saying so.
- **LOCAL-12** The process is started through `Elia.Priority.spawn_argv/3`
  (PRIO-7), so it runs below the server's own CPU and I/O priority (PRIO-1,
  PRIO-4) like every other process Elia spawns. It is not jailed: it must
  read a `.gguf` outside the workspace and listen on a port.
- **LOCAL-13** The command is `<binary> -m <model> --host <host> --port <port>`
  plus `-c <context>` when a context size is set, `-t <threads>` when a thread
  count is set, `--jinja` when the chat template is to be applied (needed for
  tool calls), and `--api-key <key>` when the server is to require one
  (LOCAL-2). `extra_args` are appended as given.
- **LOCAL-14** Every field of LOCAL-13 — binary, model, host, port, context,
  threads, jinja, key, extra args — comes from `Elia.Settings` (CONF-1) when
  saved there, else from `config :elia, Elia.LLM.LlamaServer`: `binary`
  (`LLAMA_SERVER_BIN`, else `llama-server` on `PATH`), `models_dir`
  (`LLAMA_MODELS_DIR`), `model`, `host` (`127.0.0.1`), `port` (`8080`),
  `context`, `threads`, `jinja` (on), `api_key`.
- **LOCAL-15** A start is refused, with a message naming what to set, when the
  binary is not found (LOCAL-20), the model is not set, or the model path is
  not a readable file.
- **LOCAL-16** Status is one of `:stopped`, `:starting`, `:running`,
  `:stopping`, `:failed`, and carries the base URL, the model, the OS pid and,
  since the server's output is what explains a failure, the last lines of it.
  `:external` is reported when the health check (LOCAL-17) answers but the
  process is not Elia's own — a `llama-server` the user started. Stopping
  leaves an external server alone.
- **LOCAL-17** After a start, `GET <base_url>/health` is polled until it
  answers 200, which is what makes the status `:running`; a process that exits
  before that becomes `:failed`, with its captured output as the reason.
  `:starting` is reported while the poll runs.
- **LOCAL-18** Stopping terminates the process and its whole tree, as the
  terminal's stop does (TERM-3), and the port is free afterwards. A process
  that has already exited is reported as stopped.
- **LOCAL-19** A server Elia started stops when the app shuts down: it is
  supervised, and it belongs to no chat.
- **LOCAL-20** Where the binary is missing the status says so in terms of the
  fix — the setting to fill in and what to build — as `Elia.Terminal` does when
  tmux is absent (TERM-29).
- **LOCAL-21** `.gguf` files in the models directory (LOCAL-14) are listed as
  choices for the model field, so a model on disk can be picked rather than
  typed. A missing directory is not an error; the field is typed into instead.
- **LOCAL-22** Starting a server clears the provider's catalog cache
  (MODEL-8), so the model the server has just loaded appears in the picker
  (LOCAL-4) without waiting for the ten minutes to pass.
- **LOCAL-23** A start is refused, without spawning anything, when something
  else already answers on the port (LOCAL-11) or when the port is not a valid
  port number.

### Settings page

- **LOCAL-24** The local provider's card (CONF-9) holds the base URL as a text
  field, a Check button (`#check-llamacpp`) that makes `GET
  <base_url>/health` and reports the server it found — how many models it
  lists (LOCAL-4) — or the connection error, a Save button (`#save-llamacpp`)
  that stores the URL once a server answers there, and a Remove button
  (`#remove-url-llamacpp`) that puts the configured URL back. It has no
  API-key field and no key Remove: there is no key to store (LOCAL-2), and its
  status reads "No key needed".
- **LOCAL-25** `/settings` has a "Local model server" section
  (`#local-server`) with a field for each of binary, models directory, model,
  host, port, context, threads, extra args and jinja, a Start button
  (`#start-local-server`), a Stop button (`#stop-local-server`), a Save button
  and a Reset button (`#reset-local-server`), each shown only where it applies.
- **LOCAL-26** The section shows the status: the state as a badge
  (`#local-server-badge`), and (`#local-server-status`) the URL Elia would talk
  to, the model, and the command it runs, so a refused start or a crash is
  explained by what is on the page.
- **LOCAL-27** The section shows the server's last output lines
  (`#local-server-log`), refreshed while it runs, truncated to a bounded
  number of lines (config `log_lines`, default 200).
- **LOCAL-28** Saving the settings of LOCAL-25 stores them in the settings
  database (CONF-1) and they survive a restart. Values equal to the configured
  default are stored as easily as any other; "Reset" (`#reset-local-server`)
  clears the stored ones so the configuration applies again.

## Configuration

```elixir
config :elia, Elia.LLM, provider: Elia.LLM.Anthropic

config :elia, Elia.LLM.LlamaCpp,
  base_url: System.get_env("LLAMA_CPP_BASE_URL") || "http://127.0.0.1:8080",
  model: nil,          # else the running server's first model
  max_tokens: nil,     # model default
  api_key: nil         # only for a server started with its own --api-key

config :elia, Elia.LLM.LlamaServer,
  binary: System.get_env("LLAMA_SERVER_BIN"),   # else llama-server on PATH
  models_dir: System.get_env("LLAMA_MODELS_DIR"),
  model: nil,          # a .gguf path
  host: "127.0.0.1",
  port: 8080,
  context: nil,        # -c
  threads: nil,        # -t
  jinja: true,         # --jinja, needed for tool calls
  api_key: nil,        # --api-key
  extra_args: [],
  log_lines: 200,      # how much of the server's output is kept
  startup_timeout: 60_000
```

## Out of scope

- Downloading a `.gguf` from Hugging Face on Elia's behalf.
- GPU backends and offload flags (`-ngl`); the settings of LOCAL-13 are what a
  CPU build needs.
- Agent tools to start or stop the server; it is done from Settings.
- Running more than one local server, or a server per chat.

## Implementation

`Elia.LLM.LlamaCpp`, `Elia.LLM.OpenAI` (LOCAL-10),
`Elia.LLM.LlamaServer` (the supervised process, LOCAL-11 to LOCAL-23),
`Elia.LLM` (the registry, the keyless provider), `EliaWeb.SettingsLive`.

## Tests

`test/elia/llm/llama_cpp_test.exs` (LOCAL-1 to LOCAL-9),
`test/elia/llm/open_ai_test.exs` (LOCAL-10, and OpenRouter's own tests stay
green), `test/elia/llm/llama_server_test.exs` (LOCAL-11 to LOCAL-23, with a
stub binary so no real model is loaded),
`test/elia_web/live/settings_live_test.exs` (LOCAL-24 to LOCAL-28).
