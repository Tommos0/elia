# Elixir and Mix

Read this before writing or changing Elixir code.

## Elixir

- Lists don't support index access via `mylist[i]`. Use `Enum.at/2`, pattern matching, or `List`.
- Variables are immutable. Bind the result of `if`/`case`/`cond` to a variable. You can't rebind inside the block:

      # INVALID: the assignment is lost
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- Elixir has no `else if` / `elsif`. Use `cond` or `case`.
- **Never** nest multiple modules in one file.
- **Never** use map access (`changeset[:field]`) on structs. Use `struct.field` or an API such as `Ecto.Changeset.get_field/2`.
- Use `Time`, `Date`, `DateTime` and `Calendar` from the standard library. Don't add a dependency for dates unless asked (parsing is the exception: `date_time_parser`).
- Never call `String.to_atom/1` on user input.
- Predicates end in `?` and don't start with `is_`. Reserve `is_thing` for guards.
- `DynamicSupervisor` and `Registry` need a name in the child spec (`{DynamicSupervisor, name: Elia.MySup}`).
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure. You'll usually want `timeout: :infinity`.
- `:ets.foldl/3` is OTP's `(function, accumulator, table)` — **not** Elixir's pipe-friendly order (`table |> :ets.foldl(fun, acc)`). The wrong order raises `ArgumentError` that a `rescue` can swallow into an empty result, so a table that looks empty is worth checking against the argument order first.
- Some module attributes are Elixir's own and cannot be used as your own:
  `@file` is the source file's path, so a module attribute named `@file` never
  holds what you set it to and reading it warns *undefined module attribute
  `@file`*. Name it something else (`@env_file`).
- HTTP: use `Req`. **Avoid** `:httpoison`, `:tesla` and `:httpc`.

## Project conventions

- There's no database or Ecto. Saved conversations are files in `.elia/sessions/` (`Elia.Store`). Don't add a database without asking.
- LLM calls go through `Elia.LLM` and the `Elia.LLM.Provider` behaviour. The adapters are `lib/elia/llm/anthropic.ex`, `lib/elia/llm/open_router.ex`, `lib/elia/llm/openai.ex` (any OpenAI-compatible endpoint) and `lib/elia/llm/llama_cpp.ex` (the local one, `specs/llamacpp-provider.md`).
- Tools are `Elia.Tool` structs (`run`, `approval`). Skills are registered in `Elia.Skills`.
- A chat in Elia's own project works in the live tree the server runs from, and makes its own git worktree inside it before it changes code, merging that branch into the trunk itself; its code reaches the running app only through a deploy (`Elia.Deploy`). See `docs/agents/harness.md`.

## Stored data

Read this before deciding whether a change can break old data (`AGENTS.md` says when the question has to be answered and what to say about it).

- What outlives the process: the saved chats in `.elia/sessions/` (`Elia.Store` — a chat's messages, its `cwd` (STORE-46), the done flag (STORE-19), a sub-task's metadata (STORE-16..STORE-18), its `settings` map (SESS-41)), the settings database, folder skills and their `tools.json`, and `AGENTS.md` itself. Nothing else in the tree is user data.
- The cheap way to stay backward compatible is to read a saved chat for the keys it has and rewrite nothing (`test/elia/store_test.exs` loads a file an earlier version wrote, carrying a `status`, `title`, `brief`, `parent_call_id` or `start_commit`).
- Where a key is *added* to a map a long-lived process holds — a session's `settings` (SESS-41, SESS-47), a compaction state, task metadata — an old state reads the new key at its default (`Elia.Agent.Session.settings/1`). A hot reload keeps that state (DEPLOY-6), so a missing default is a `KeyError` on mount, which 500s every chat with a live session; a restart builds the sessions afresh and is safe without it.
- When the new code cannot read the old shape, say so in the spec or the commit message and migrate it: a read-time fallback, a one-off rewrite of the stored files, and a test that loads a fixture written in the old shape. Don't go looking through the user's own files to check — the question is about the shapes the code reads and writes.

## Mix

- Read the docs and options with `mix help task_name` before using a task.
- `mix precommit` (compile with warnings as errors, `deps.unlock --unused`, `format`, `test`) must pass before you finish — unless the change is one you judge safe without a run (a docs, spec or comment edit, a rename with nothing behind it), in which case skip it and say in your last message why it was safe to skip (`AGENTS.md`).
- Run it as plain `mix precommit`: since a command never inherits the server's `MIX_ENV` (ISOL-24, `Elia.Shell`), the alias's `preferred_envs: [precommit: :test]` applies and it compiles and tests in `test`. A `MIX_ENV` set explicitly on the command overrides that preference, so don't set one.
- `credo` is a `dev`/`test` dependency and **advisory**: `mix credo` runs by
  hand (about 6 seconds, 57 checks over ~270 files) and is deliberately not in
  the `precommit` gate (SUITE-8), so it can never fail a commit.
  Its default run reports no findings as of 2026-11-26 — the 60 it reported
  were refactored away in eight sub-tasks (deep nesting, cyclomatic complexity,
  one-condition `cond`s and single-clause `with`s, `Enum.filter |> filter` and
  `Enum.map |> join`) — so a finding it reports in a change you are making is
  usually yours to look at rather than an old one. `mix credo --strict` still
  reports the low-priority `AliasUsage`, `AliasOrder` and `StringSigils` ones,
  which nobody has chased. Security
  advisories need no dependency of their own: Hex 2.6 audits the lock by itself
  on every `mix deps.get`, and `mix hex.audit` runs the same check on demand —
  both exit non-zero for a retired package or an advisory. `mix_audit` was
  considered and left out: it would add `yaml_elixir` and `yamerl` for what Hex
  already does.
- `mix credo --format=json` written to a file is not valid JSON when `mix`
  compiles a dependency on the way: the compile output comes before the JSON, so
  cut to the first `{` (`sed -n '/^{/,$p'`) before feeding it to `jq`.
- `dialyxir` is the same kind of thing, and **advisory** too: `mix dialyzer`
  runs by hand, never in the `precommit` gate (SUITE-8). Its PLT lives in
  `_build/dialyzer` (`plt_local_path`/`plt_core_path` in `mix.exs`), so it is
  not committed; the first run builds the PLT (about 2½ minutes here on 4
  cores) and a warm run takes about 13 seconds. It reports ~28 warnings today,
  so read them rather than expecting exit 0.
- Dialyzer is an OTP application, not an Elixir library: `dialyxir` only drives
  `:dialyzer`, and **no hex package provides that app** — the registry has
  `dialyxir`, `dialyzex`, `dialyze`, `dialyzer_html` and `dialyzer_json`, all
  wrappers. Debian ships the app as the separate `erlang-dialyzer` package, so
  `sudo apt install erlang-dialyzer` on the host is what makes `mix dialyzer`
  run at all; a chat cannot install it (`/usr` is read-only in the jail, with
  no package lists). `:code.lib_dir(:dialyzer)` returning `{:error, :bad_name}`
  is how you tell it is missing.
- In a jailed call that audit reaches `repo.hex.pm` through the harness proxy
  (it is in the project's allowlist, NET-28), while Hex's own version check
  cannot reach `hex.pm` and prints `Failed to check for new Hex version` with
  `{:could_not_establish_ssl_tunnel, {…, 403, …}}`. That line is expected noise,
  not a failure. Fetching a dependency at all needs `repo.hex.pm` allowed: a
  jail has no route out of its own and no `$HOME` to keep a hex cache in, so a
  fetch starts from nothing every call.
- `mix deps.clean --all` is almost never needed. Avoid it.
