defmodule Elia.Skills.Chats do
  @moduledoc """
  Reading earlier chats (spec: `specs/chat-history.md`; what a search itself
  does, `specs/chat-search.md`). The built-in skill `chats` gives a chat
  `list_chats`, `read_chat` and `search_chats`, so the agent can consult the
  chats the user has had before this one — what was decided, which paths were
  used, what was already tried.

  They read Elia's own saved chats (STORE-1) through the harness — no command
  is run and no approval is asked — so they work in a chat whose jail is on too
  (HIST-1, ISOL-16), where `.elia/sessions` is out of reach of a command
  (ISOL-6).
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
  # SEARCH-10: how much of the matched text a snippet carries, and how far it
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

    `search_chats` reads its `query` as terms split on whitespace: every one \
    of them has to be there — in a message's text, in a tool result or in a \
    tool call's input, as a substring — and a chat's title counts as well as \
    its messages, so a chat whose title holds every term is reported before \
    one whose title does not.

    A chat is named by its id, the one in its URL (`/c/<id>`). The tools read \
    Elia's own saved chats through the harness — not with a command — so they \
    work in a chat whose jail is on too: `.elia/sessions` is out of a \
    command's reach there, and its files are Erlang terms rather than text in \
    any case. They only read: nothing you do with them changes a chat, no \
    session is started for a chat you read, and none of them asks for approval.

    What you read is the chat as it was last saved, so a chat that is running \
    now may not have its current turn in its file yet. Start with \
    `list_chats` when you have only a topic: each entry says whether the chat \
    is done, was interrupted by a restart, or is a sub-task, and how many \
    messages it holds, which is usually enough to tell whether it is the one \
    you want.

    `list_chats` takes a `children` argument when what you want is the chats \
    of a task rather than the recent ones: `true` keeps this chat's own \
    sub-tasks, and `"all"` keeps those together with their own children. Each \
    listed chat's `parent` names the chat that spawned it, or is `null` for a \
    chat nothing spawned.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "list_chats",
        description:
          "List chats other than this one, newest first, as JSON: each chat's `id`, " <>
            "`title`, `created_at`, `updated_at`, `project`, `parent`, `status` and how " <>
            "many `messages` it holds. `query` keeps the chats whose title or description " <>
            "contains it and `project` those of one project. `children` keeps this chat's " <>
            "own sub-tasks (`true`), or those together with their own children " <>
            "(`\"all\"`). Use it to find the id to read.",
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
            },
            "children" => %{
              "type" => ["boolean", "string"],
              "description" =>
                "`true` keeps only this chat's own sub-tasks; `\"all\"` keeps those " <>
                  "together with their own children. Absent or `false`: nothing is " <>
                  "filtered by parent."
            }
          },
          "required" => []
        },
        # HIST-10: reading a saved chat changes nothing on the machine, so it
        # never needs approval, as `read_chat` and `search_chats` never do.
        approval: :never,
        run: fn input, ctx -> list_chats(input, ctx) end
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
          "Search the saved chats for a query of terms — every one of them has to be " <>
            "there, in a message or in a chat's title — ignoring case, as JSON: the " <>
            "`id` and `title` of each chat with a match, and the matching message's " <>
            "`index`, `role` and a `snippet` of the text around the match. A chat whose " <>
            "title holds every term comes first, then the newest chats, then the " <>
            "earliest messages.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "The terms to search for, split on whitespace"
            },
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

  defp list_chats(input, ctx) do
    query = blank_to_nil(input["query"])
    project = blank_to_nil(input["project"])
    limit = clamp(input["limit"], @list_default, @list_max)
    children = children_ids(input["children"], ctx[:session_id])
    running = MapSet.new(Elia.Agent.running())

    chats =
      Elia.Store.list(@scan)
      |> Enum.filter(&Elia.Store.valid_id?(&1.id))
      |> Enum.filter(&matching?(&1, query, project))
      |> Enum.filter(&of_group?(&1, children))
      |> Enum.take(limit)
      |> Enum.map(&listed(&1, running))

    {:ok, Jason.encode!(chats)}
  end

  # HIST-2, STORE-18: the ids a `children` filter keeps, or `nil` when it
  # filters nothing by parent — which is what absent, `false` and any value
  # that isn't one of the two do, so a listing is every chat, as before the
  # filter existed. A call whose tool context names no chat has no sub-tasks to
  # keep, so the filter keeps none of them.
  defp children_ids(value, id) do
    cond do
      value not in [true, "all"] -> nil
      not is_binary(id) -> MapSet.new()
      value == true -> id |> Elia.Store.children() |> MapSet.new(& &1.id)
      true -> descendants(id, MapSet.new())
    end
  end

  defp of_group?(_entry, nil), do: true
  defp of_group?(entry, ids), do: MapSet.member?(ids, entry.id)

  # Every chat below `id`, their own children included, however deep the tree
  # is. Depth is one today — a child has no `spawn_task` (SUBTASK-1) — and the
  # walk is written for a tree anyway.
  defp descendants(id, seen) do
    Enum.reduce(Elia.Store.children(id), seen, fn child, seen ->
      if MapSet.member?(seen, child.id),
        do: seen,
        else: descendants(child.id, MapSet.put(seen, child.id))
    end)
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
      # HIST-2, STORE-17: whose child this chat is, or `null` for a chat
      # nothing spawned.
      "parent" => Map.get(entry, :parent_id),
      "status" => status(entry, running),
      "messages" => entry.id |> Elia.Store.load() |> length()
    }
  end

  # HIST-3: what the chat as a whole is in, read from its saved file — and from
  # the registry, for one that is working right now. A sub-task chat has no
  # status of its own (STORE-17, SUBTASK-34): it reads as the chat it is.
  defp status(entry, running) do
    cond do
      MapSet.member?(running, entry.id) -> "working"
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

  ## search_chats (SEARCH-7 - SEARCH-11)

  defp search_chats(input) do
    case blank_to_nil(input["query"]) do
      nil ->
        # SEARCH-11: a query is required, and a blank one is the same as none.
        {:error, "Give a non-blank `query` to search for."}

      query ->
        limit = clamp(input["limit"], @search_default, @search_max)
        terms = terms(query)
        entries = candidates()

        # SEARCH-4, SEARCH-5: the index is brought up to date with the chats a
        # search considers before anything is looked up in it, so a chat saved,
        # replaced or deleted anywhere is searched as it is now, and this first
        # search is the one that builds it.
        Elia.Store.Index.refresh(entries)

        result =
          entries
          |> find_matches(terms)
          |> Enum.take(limit)
          |> report(terms)

        {:ok, Jason.encode!(result)}
    end
  end

  # SEARCH-7: a query is split into terms on whitespace, and each is folded the
  # way the index is, so it is found whatever its case.
  defp terms(query), do: query |> String.downcase() |> String.split(~r/\s+/, trim: true)

  # The chats a search considers: the newest `@scan`, as a listing and a
  # lookup by title consider (UI-4).
  defp candidates do
    Elia.Store.list(@scan) |> Enum.filter(&Elia.Store.valid_id?(&1.id))
  end

  # SEARCH-8, SEARCH-9: the matches of every chat, ordered with a chat whose
  # title holds every term before one whose title does not, then the way the
  # chats are listed — the newer chat first (STORE-12) — and the earlier
  # message within a chat.
  defp find_matches(_entries, []), do: []

  defp find_matches(entries, terms) do
    # SEARCH-8: a message matches when every term appears in it, so the messages
    # holding the query are the ones every term's own messages have in common.
    holding =
      terms
      |> Enum.map(&MapSet.new(Elia.Store.Index.term(&1)))
      |> Enum.reduce(&MapSet.intersection/2)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    found = Enum.flat_map(entries, &matches_of(&1, terms, holding))
    {by_title, rest} = Enum.split_with(found, & &1.titled)
    by_title ++ rest
  end

  # SEARCH-8: the matches of one chat — the messages holding every term and no
  # other, or, when none of them does and its title holds every term, one match
  # of its own, of its first message.
  defp matches_of(entry, terms, holding) do
    with identity when not is_nil(identity) <- Elia.Store.identity(entry.id),
         index when not is_nil(index) <- Elia.Store.Index.fetch(entry.id, identity) do
      titled = Enum.all?(terms, &String.contains?(index.title, &1))

      case holding |> Map.get(entry.id, []) |> Enum.sort() do
        [] -> if titled and index.messages > 0, do: [match(entry, 1, titled, true)], else: []
        indexes -> Enum.map(indexes, &match(entry, &1, titled, false))
      end
    else
      _ -> []
    end
  end

  defp match(entry, index, titled, by_title),
    do: %{id: entry.id, title: entry.title, index: index, titled: titled, by_title: by_title}

  # SEARCH-6, SEARCH-10: one match per message, the snippet of the text around
  # its first match — or, for the match SEARCH-8 makes of a title, the message's
  # text from its start. Only the chats a match is reported from are decoded.
  defp report(matches, terms) do
    messages = decoded(Enum.map(matches, & &1.id))

    Enum.flat_map(matches, fn match ->
      case messages[match.id][match.index] do
        nil ->
          []

        message ->
          [
            %{
              "id" => match.id,
              "title" => match.title,
              "index" => match.index,
              "role" => role(message),
              "snippet" => snippet(match, message, terms)
            }
          ]
      end
    end)
  end

  # A chat is decoded once, however many of its messages are reported.
  defp decoded(ids) do
    ids
    |> Enum.uniq()
    |> Map.new(fn id ->
      indexed =
        id
        |> Elia.Store.load()
        |> Enum.with_index(1)
        |> Map.new(fn {message, index} -> {index, message} end)

      {id, indexed}
    end)
  end

  # SEARCH-10: what a message shows of itself, and the match a title alone
  # makes shows it from its start.
  defp snippet(%{by_title: true}, message, _terms), do: from_start(text(message))

  defp snippet(_match, message, terms) do
    case matched_text(message, terms) do
      nil -> from_start(text(message))
      text -> window(text, first_match(String.downcase(text), terms))
    end
  end

  # SEARCH-7, SEARCH-10: the first block of a message that holds a term, and
  # where that term first appears in it, in the folded text.
  defp matched_text(message, terms) do
    Enum.find(Elia.Store.Index.searchable_texts(message), &any_term?(&1, terms))
  end

  defp any_term?(text, terms), do: Enum.any?(terms, &contains?(text, &1))

  defp first_match(folded, terms) do
    terms
    |> Enum.flat_map(fn term ->
      case :binary.match(folded, term) do
        :nomatch -> []
        {at, _length} -> [at]
      end
    end)
    |> Enum.min(fn -> 0 end)
  end

  # SEARCH-10: the text around the match, cut to `@snippet` characters with an
  # ellipsis where it was cut off. The match is found in the folded text and
  # measured in the text as it is; folding can change a byte length (a few
  # non-ASCII letters do), so a position that doesn't land on a character
  # boundary falls back to the start of the text.
  defp window(text, at) do
    before_the_match = binary_part(text, 0, at)

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

  defp from_start(text) do
    if String.length(text) > @snippet,
      do: String.slice(text, 0, @snippet) <> "…",
      else: text
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

  # HIST-2, HIST-4, SEARCH-11: a call asks for at most `max` and gets the
  # default when it asks for nothing; a value that isn't a whole number is the
  # default too, as for an unset one.
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
