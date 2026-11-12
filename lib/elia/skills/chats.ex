defmodule Elia.Skills.Chats do
  @moduledoc """
  Reading earlier chats (spec: `specs/chat-history.md`). The built-in skill
  `chats` gives a chat `list_chats`, `read_chat` and `search_chats`, so the
  agent can consult the chats the user has had before this one — what was
  decided, which paths were used, what was already tried.

  They read Elia's own saved chats (STORE-1) through the harness, the way
  `list_tasks` reads a sub-task (SUBTASK-26) — no command is run and no
  approval is asked — so they work in a chat whose jail is on too (HIST-1,
  ISOL-16), where `.elia/sessions` is out of reach of the shell and the file
  tools (FILE-12, ISOL-6).
  """

  @behaviour Elia.Skill

  alias Elia.LLM.Message

  # How many chats a listing, a lookup by title and a search consider, the same
  # order as the chat list's own `Store.list/1` call (UI-4): more chats than
  # this are older than anything a turn needs to consult.
  @scan 1_000

  @list_default 20
  @list_max 100
  @read_default 100
  @read_max 200
  @search_default 20
  @search_max 100

  # HIST-6: what one message shows of itself before it is cut.
  @text_cap 2_000
  @result_cap 1_000
  # HIST-9: how much of the matched text a snippet carries, and how far it
  # reaches back before the match.
  @snippet 200
  @snippet_before 60
  # HIST-8: how many candidate chats an ambiguous `query` names.
  @candidates 10

  @impl true
  def name, do: "chats"

  @impl true
  def description,
    do: "Look at earlier chats: list them, read one's transcript, search across them."

  @impl true
  def instructions do
    """
    Chats other than this one are saved, and you can look at them: \
    `list_chats` lists them newest first, `read_chat` returns one chat's \
    transcript, and `search_chats` finds a phrase across them. Work from an \
    earlier chat — a decision, a path, what was already tried — can be \
    recovered this way instead of asked about again.

    A chat is named by its id, the one in its URL (`/c/<id>`). The tools read \
    Elia's own saved chats through the harness — not with a command and not \
    with the file tools — so they work in a chat whose jail is on too: \
    `.elia/sessions` is out of reach of both there, and its files are Erlang \
    terms rather than text in any case. They only read: nothing you do with \
    them changes a chat, no session is started for a chat you read, and none \
    of them asks for approval.

    What you read is the chat as it was last saved, so a chat that is running \
    now may not have its current turn in its file yet. Start with \
    `list_chats` when you have only a topic: each entry says whether the chat \
    is done, was interrupted by a restart, or is a sub-task, and how many \
    messages it holds, which is usually enough to tell whether it is the one \
    you want.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "list_chats",
        description:
          "List chats other than this one, newest first, as JSON: each chat's `id`, " <>
            "`title`, `created_at`, `updated_at`, `project`, `status` and how many " <>
            "`messages` it holds. `query` keeps the chats whose title or description " <>
            "contains it and `project` those of one project. Use it to find the id to " <>
            "read.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "Only chats whose title or description contains this text"
            },
            "project" => %{"type" => "string", "description" => "Only chats of this project id"},
            "limit" => %{
              "type" => "integer",
              "description" => "How many chats, newest first (default 20, at most 100)"
            }
          },
          "required" => []
        },
        # HIST-10: reading a saved chat changes nothing on the machine, so it
        # never needs approval, like `list_tasks` (SUBTASK-26).
        approval: :never,
        run: fn input, _ctx -> list_chats(input) end
      },
      %Elia.Tool{
        name: "read_chat",
        description:
          "Read a chat's saved transcript, by `id` or by `query` when it matches " <>
            "exactly one chat's title. The result is the chat's messages in order, with " <>
            "its tool calls and their results; a long chat is read in pieces with " <>
            "`offset` and `limit`.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => "The chat's id (as in /c/<id>)"},
            "query" => %{
              "type" => "string",
              "description" => "Or a phrase matching exactly one chat's title"
            },
            "offset" => %{
              "type" => "integer",
              "description" => "First message to show, 1-based (default 1)"
            },
            "limit" => %{
              "type" => "integer",
              "description" => "How many messages (default 100, at most 200)"
            }
          },
          "required" => []
        },
        approval: :never,
        run: fn input, _ctx -> read_chat(input) end
      },
      %Elia.Tool{
        name: "search_chats",
        description:
          "Search the saved chats for a phrase, ignoring case, newest chats first, as " <>
            "JSON: the `id` and `title` of each chat with a match, and the matching " <>
            "message's `index`, `role` and a `snippet` of the text around the match.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "The text to search for"},
            "limit" => %{
              "type" => "integer",
              "description" => "How many matches (default 20, at most 100)"
            }
          },
          "required" => ["query"]
        },
        approval: :never,
        run: fn input, _ctx -> search_chats(input) end
      }
    ]
  end

  ## list_chats (HIST-2, HIST-3)

  defp list_chats(input) do
    query = blank_to_nil(input["query"])
    project = blank_to_nil(input["project"])
    limit = clamp(input["limit"], @list_default, @list_max)
    running = MapSet.new(Elia.Agent.running())

    chats =
      Elia.Store.list(@scan)
      |> Enum.filter(&Elia.Store.valid_id?(&1.id))
      |> Enum.filter(&matching?(&1, query, project))
      |> Enum.take(limit)
      |> Enum.map(&listed(&1, running))

    {:ok, Jason.encode!(chats)}
  end

  defp matching?(entry, query, project) do
    (is_nil(project) or Map.get(entry, :project_id) == project) and
      (is_nil(query) or contains?(entry.title, query) or
         contains?(Map.get(entry, :description) || "", query))
  end

  defp listed(entry, running) do
    %{
      "id" => entry.id,
      "title" => entry.title,
      "created_at" => iso(entry.created_at),
      "updated_at" => iso(entry.updated_at),
      "project" => Map.get(entry, :project_id),
      "status" => status(entry, running),
      "messages" => entry.id |> Elia.Store.load() |> length()
    }
  end

  # HIST-3: what the chat as a whole is in, read from its saved file — and from
  # the registry, for one that is working right now.
  defp status(entry, running) do
    cond do
      MapSet.member?(running, entry.id) -> "working"
      is_binary(Map.get(entry, :task_status)) -> entry.task_status
      Map.get(entry, :done) == true -> "done"
      Map.get(entry, :interrupted) == true -> "interrupted"
      true -> "open"
    end
  end

  ## read_chat (HIST-4 - HIST-8)

  defp read_chat(input) do
    with {:ok, id} <- chat_to_read(input), do: transcript(id, input)
  end

  # HIST-4, HIST-8: the chat to read is the given `id`, or the one chat whose
  # title a `query` matches.
  defp chat_to_read(input) do
    id = blank_to_nil(input["id"])
    query = blank_to_nil(input["query"])

    cond do
      id -> check_id(id)
      query -> by_title(query)
      true -> {:error, "Give the chat's `id`, or a `query` that matches one chat's title."}
    end
  end

  defp check_id(id) do
    cond do
      not Elia.Store.valid_id?(id) ->
        {:error,
         "#{inspect(id)} is not a valid chat id: 1-64 characters of letters, digits, `_` " <>
           "and `-`."}

      not Elia.Store.exists?(id) ->
        {:error, "No saved chat has the id #{inspect(id)}. Use `list_chats` to find one."}

      true ->
        {:ok, id}
    end
  end

  defp by_title(query) do
    matches =
      Elia.Store.list(@scan)
      |> Enum.filter(&Elia.Store.valid_id?(&1.id))
      |> Enum.filter(&contains?(&1.title, query))

    case matches do
      [%{id: id}] ->
        {:ok, id}

      [] ->
        {:error,
         "No saved chat's title matches #{inspect(query)}. Use `list_chats` to see the " <>
           "chats there are."}

      many ->
        named = Enum.take(many, @candidates)

        {:error,
         "#{length(many)} chats' titles match #{inspect(query)}; name the one you want by " <>
           "`id`:\n" <>
           Enum.map_join(named, "\n", &"#{&1.id}  #{&1.title}") <>
           left_out(length(many))}
    end
  end

  defp left_out(count) when count <= @candidates, do: ""
  defp left_out(count), do: "\n[+#{count - @candidates} more]"

  defp transcript(id, input) do
    case Elia.Store.entry(id) do
      nil ->
        {:error, "No saved chat has the id #{inspect(id)}. Use `list_chats` to find one."}

      entry ->
        messages = Elia.Store.load(id)

        case page(messages, input) do
          {:error, message} -> {:error, message}
          {:ok, first, shown} -> {:ok, report(entry, messages, first, shown)}
        end
    end
  end

  # HIST-4, HIST-7: the messages asked for, or an error naming what the chat
  # holds. A chat with no messages reads as its header alone.
  defp page(messages, input) do
    total = length(messages)
    offset = whole(input["offset"], 1)
    limit = clamp(input["limit"], @read_default, @read_max)

    cond do
      total == 0 -> {:ok, 0, []}
      offset < 1 or offset > total -> {:error, offset_error(offset, total)}
      true -> {:ok, offset, Enum.slice(messages, offset - 1, limit)}
    end
  end

  defp offset_error(offset, total) do
    "`offset` #{offset} is not a message of this chat: it holds #{total} " <>
      "#{if total == 1, do: "message", else: "messages"} (1-#{total})."
  end

  # HIST-5, HIST-6, HIST-7: the header, the messages asked for, and what is
  # left of the chat.
  defp report(entry, messages, first, shown) do
    total = length(messages)
    last = first + length(shown) - 1

    header = [
      "# #{entry.title} (#{entry.id})",
      "created #{iso(entry.created_at)}, updated #{iso(entry.updated_at)}, " <>
        "project #{Map.get(entry, :project_id) || "none"}, " <>
        "#{status(entry, MapSet.new(Elia.Agent.running()))}, #{total} messages",
      "[messages #{first}-#{max(last, 0)} of #{total}]"
    ]

    lines =
      for {message, index} <- Enum.with_index(shown, first),
          line <- render(index, message),
          do: line

    Enum.join(header ++ lines ++ more(total, last), "\n")
  end

  defp more(total, last) do
    if last < total,
      do: ["[+#{total - last} more messages: read again with offset=#{last + 1}]"],
      else: []
  end

  # HIST-6: one message is one line, `[<index>] <role>: <text>`, with its tool
  # calls and results as further lines below it.
  defp render(index, %Message{} = message) do
    [
      "[#{index}] #{role(message)}: #{message |> text() |> cut(@text_cap)}"
      | Enum.flat_map(message.content, &block_line/1)
    ]
  end

  defp text(%Message{content: content}) do
    case content |> Enum.filter(&match?(%{type: :text}, &1)) |> Enum.map_join("\n", & &1.text) do
      "" -> "(no text)"
      text -> text
    end
  end

  defp block_line(%{type: :tool_call, name: name, input: input}),
    do: ["  → #{name} #{Jason.encode!(input)}"]

  defp block_line(%{type: :tool_result, content: content} = result),
    do: ["  ← #{if result[:is_error], do: "[error] ", else: ""}#{cut(content, @result_cap)}"]

  defp block_line(_block), do: []

  defp role(%Message{role: :user, meta: meta}) do
    if Map.get(meta, :harness, false), do: "user (harness)", else: "user"
  end

  defp role(%Message{role: role}), do: to_string(role)

  ## search_chats (HIST-9)

  defp search_chats(input) do
    case blank_to_nil(input["query"]) do
      nil ->
        {:error, "Give a non-blank `query` to search for."}

      query ->
        limit = clamp(input["limit"], @search_default, @search_max)
        {:ok, query |> String.downcase() |> find_matches(limit) |> Jason.encode!()}
    end
  end

  # HIST-9: newest chats first, message order within a chat, stopping as soon
  # as there are `limit` matches.
  defp find_matches(needle, limit) do
    Elia.Store.list(@scan)
    |> Enum.filter(&Elia.Store.valid_id?(&1.id))
    |> Enum.reduce_while([], fn entry, found ->
      found = found ++ matches(entry, needle)

      if length(found) >= limit,
        do: {:halt, Enum.take(found, limit)},
        else: {:cont, found}
    end)
  end

  defp matches(entry, needle) do
    entry.id
    |> Elia.Store.load()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {message, index} ->
      case searchable(message, needle) do
        nil ->
          []

        text ->
          [
            %{
              "id" => entry.id,
              "title" => entry.title,
              "index" => index,
              "role" => role(message),
              "snippet" => snippet(text, needle)
            }
          ]
      end
    end)
  end

  # HIST-9: what a message is searched in — its text, its tool results and its
  # tool calls' input — the first block of it that matches.
  defp searchable(%Message{content: content}, needle) do
    Enum.find_value(content, fn block ->
      case searchable_text(block) do
        text when is_binary(text) -> if contains?(text, needle), do: text
        _none -> nil
      end
    end)
  end

  defp searchable_text(%{type: :text, text: text}), do: text
  defp searchable_text(%{type: :tool_result, content: content}), do: content
  defp searchable_text(%{type: :tool_call, input: input}), do: Jason.encode!(input)
  defp searchable_text(_block), do: nil

  # HIST-9: the text around the first match, cut to `@snippet` characters with
  # an ellipsis where it was cut off. The match is found in the folded text and
  # measured in the text as it is; folding can change a byte length (a few
  # non-ASCII letters do), so a position that doesn't land on a character
  # boundary falls back to the start of the text.
  defp snippet(text, needle) do
    case :binary.match(String.downcase(text), needle) do
      :nomatch ->
        String.slice(text, 0, @snippet)

      {at, _length} ->
        window(text, binary_part(text, 0, at))
    end
  end

  defp window(text, before_the_match) do
    if String.valid?(before_the_match) do
      start = max(String.length(before_the_match) - @snippet_before, 0)
      prefix = if start > 0, do: "…", else: ""
      suffix = if start + @snippet < String.length(text), do: "…", else: ""
      prefix <> String.slice(text, start, @snippet) <> suffix
    else
      # A byte offset into the folded text that isn't a boundary here: the
      # position is unusable, so the text is shown from its start.
      String.slice(text, 0, @snippet)
    end
  end

  ## Shared

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp contains?(text, needle) when is_binary(text),
    do: String.contains?(String.downcase(text), String.downcase(needle))

  defp contains?(_text, _needle), do: false

  defp cut(text, cap) do
    if String.length(text) <= cap,
      do: text,
      else: String.slice(text, 0, cap) <> "…[+#{String.length(text) - cap} more characters]"
  end

  # HIST-2, HIST-4, HIST-9: a call asks for at most `max` and gets the default
  # when it asks for nothing; a value that isn't a whole number is the default
  # too, as for an unset one.
  defp clamp(value, _default, max) when is_integer(value), do: value |> min(max) |> max(1)
  defp clamp(_value, default, _max), do: default

  defp whole(value, _default) when is_integer(value), do: value
  defp whole(_value, default), do: default

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
