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
- HTTP: use `Req`. **Avoid** `:httpoison`, `:tesla` and `:httpc`.

## Project conventions

- There's no database or Ecto. Saved conversations are files in `.elia/sessions/` (`Elia.Store`). Don't add a database without asking.
- LLM calls go through `Elia.LLM` and the `Elia.LLM.Provider` behaviour. Providers are `lib/elia/llm/anthropic.ex` and `lib/elia/llm/open_router.ex`.
- Tools are `Elia.Tool` structs (`run`, `approval`). Skills are registered in `Elia.Skills`.
- A chat in Elia's own project works in its own git worktree, never in the live tree the server runs from (`Elia.Deploy`), and its code reaches the running app only through a deploy. See `docs/agents/harness.md`.

## Mix

- Read the docs and options with `mix help task_name` before using a task.
- `mix precommit` (compile with warnings as errors, `deps.unlock --unused`, `format`, `test`) must pass before you finish.
- Run it as `MIX_ENV=test mix precommit`: the harness's shell inherits `MIX_ENV=dev`, and the alias's `preferred_envs: [precommit: :test]` only applies when `MIX_ENV` is unset. Plain `mix precommit` then runs the tests in the dev env, where `test/test_helper.exs` cannot fetch `config :elia, :workspace` (`config/test.exs` wasn't loaded).
- `mix deps.clean --all` is almost never needed. Avoid it.
