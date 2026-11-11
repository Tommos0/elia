defmodule Elia.Terminal.Keys do
  @moduledoc """
  The notation the agent types into a terminal with (TERM-30, TERM-31): text as
  it is, `<Name>` for a key.

      iex> Elia.Terminal.Keys.parse("htop<Enter>")
      {:ok, [{:text, "htop"}, {:key, "Enter"}]}

      iex> Elia.Terminal.Keys.parse("<C-x><C-s>")
      {:ok, [{:key, "C-x"}, {:key, "C-s"}]}

  A name is tmux's own key name — `Enter`, `Escape`, `Up`, `F5`, `BSpace`,
  `PageUp`, `C-x`, `M-up`, `S-F1` — as tmux reads one: compared
  case-insensitively, with one or more of `C-`, `M-` and `S-` in front, in any
  order. The spellings tmux does *not* know but a model reaches for — `Esc`,
  `CR`, `RET`, `Backspace`, `PgUp`, `PgDn`, `Del`, `Ins` — are aliased to the
  names it does (checked against tmux 3.5a).

  A key is handed to tmux by name rather than turned into bytes here: tmux knows
  the pane's mode, so an app that has switched to application cursor keys
  (`ESC [ ? 1 h`) gets `ESC O A` for `<Up>` where one that has not gets
  `ESC [ A`, and the pane's keypad and modifier encodings are tmux's own.

  A `<...>` that is not name-shaped — prose, `<b>`, a single character — is
  text, which is why a `<` needs no escaping. One that *is* name-shaped and is
  not a name tmux knows is an error rather than text: tmux sends an unknown name
  literally, so `<PgUP>` reaching `send-keys` would type `<PgUP>` into the app
  rather than press a key (TERM-31).
  """

  @typedoc """
  One piece of a send, in the order it goes: a run of text, or one key, named
  the way tmux's `send-keys` takes it.
  """
  @type segment :: {:text, binary()} | {:key, binary()}

  # The key names tmux itself knows (TERM-30, TERM-31). Each was checked
  # against tmux 3.5a by sending it to a pane in raw mode: a name tmux knows
  # arrives as a key sequence, and one it does not arrives as its own letters.
  # Both spellings of the keys that have two are tmux's (`IC`/`Insert`,
  # `PPage`/`PageUp`, `NPage`/`PageDown`), and the keypad names are here because
  # an app like an editor uses them.
  @names ~w[
    F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12
    Up Down Left Right
    Home End IC Insert DC Delete PPage PageUp NPage PageDown
    Tab BTab Space BSpace Enter Escape
    KP0 KP1 KP2 KP3 KP4 KP5 KP6 KP7 KP8 KP9
    KPEnter KP/ KP* KP- KP+ KP. KP=
  ]

  # The spellings tmux does *not* know — `send-keys Esc` types the letters — but
  # that mean a key to anyone who has read a terminal's documentation.
  @aliases %{
    "esc" => "Escape",
    "cr" => "Enter",
    "ret" => "Enter",
    "return" => "Enter",
    "backspace" => "BSpace",
    "del" => "DC",
    "ins" => "IC",
    "pgup" => "PPage",
    "pgdn" => "NPage"
  }

  # The canonical spelling of a name, by its lowercase form: tmux compares key
  # names case-insensitively (`up`, `UP` and `Up` are one key), so the lookup is
  # what makes the notation agree with it.
  @lookup @names
          |> Map.new(&{String.downcase(&1), &1})
          |> Map.merge(@aliases)

  # What may sit in front of a name, and the order they are written back in
  # (tmux's own): `c-` is `C-`, and `<S-C-x>` is `<C-S-x>`.
  @modifier_prefixes %{?c => "C-", ?C => "C-", ?m => "M-", ?M => "M-", ?s => "S-", ?S => "S-"}

  # A single character may be named as a key when a modifier is in front of it
  # (`<C-x>`, `<C-?>`, `<M-1>`). Only characters that cannot mean anything to
  # tmux's own command parser are allowed, because the name goes to `send-keys`
  # on a line tmux reads: a `;` would end the command, a `"` would open a quote
  # and a trailing `\\` would swallow the line after it (TERM-31).
  @one_char ~r/^[A-Za-z0-9@?_^]$/

  # A name that is not a key, but looks like one: letters, digits and dashes,
  # starting with a letter — `<PgUP>`, `<Alt-x>`, `<Escapee>`. What does not
  # look like one is text (TERM-30), which is what keeps `<b>` and `<foo bar>`
  # from needing an escape and still catches a mistyped key (TERM-31).
  @name_shaped ~r/^[A-Za-z][A-Za-z0-9-]*$/

  # Every key name this module produces passes this, and nothing else does: no
  # whitespace, no quotes, no `;` — the characters that would make a `send-keys`
  # line mean something other than one command (TERM-31).
  @key_shape ~r/^([CMS]-)*[A-Za-z0-9@?_^]+$/

  @doc """
  Parses `keys` into what to send, in order (TERM-30).

  `{:error, message}` for an empty notation, and for a `<...>` that names a key
  tmux does not know (TERM-31).
  """
  @spec parse(binary()) :: {:ok, [segment()]} | {:error, binary()}
  def parse(keys) when is_binary(keys) do
    case scan(keys, []) do
      {:error, message} -> {:error, message}
      [] -> {:error, "keys is empty: there is nothing to send."}
      segments -> {:ok, Enum.reverse(segments)}
    end
  end

  @doc """
  Whether a segment is one `parse/1` can produce, and so may be given to tmux's
  `send-keys` (TERM-31).

  `parse/1` is the only thing that makes a segment, and this is the shape it
  guarantees: text is text, and a key name is one tmux's command parser cannot
  read as anything but a word.
  """
  @spec valid?(term()) :: boolean()
  def valid?({:text, text}) when is_binary(text), do: true
  def valid?({:key, name}) when is_binary(name), do: Regex.match?(@key_shape, name)
  def valid?(_segment), do: false

  ## Parsing

  defp scan(<<>>, acc), do: acc

  # A `<...>` is a key when it names one; a `<` with no `>` after it, or one
  # holding anything that is not a name, is text (TERM-30).
  defp scan(<<?<, rest::binary>>, acc) do
    case :binary.split(rest, ">") do
      [name, tail] ->
        case key(name) do
          {:key, tmux_name} -> scan(tail, [{:key, tmux_name} | acc])
          :text -> scan(tail, text(acc, "<" <> name <> ">"))
          {:error, message} -> {:error, message}
        end

      [_unclosed] ->
        text(acc, "<" <> rest)
    end
  end

  defp scan(<<byte, rest::binary>>, acc), do: scan(rest, text(acc, <<byte>>))

  # Runs of text are one segment, so a paste is one `send-keys` (TERM-13).
  defp text([{:text, text} | rest], more), do: [{:text, text <> more} | rest]
  defp text(acc, more), do: [{:text, more} | acc]

  defp key(name) do
    {modifiers, base} = split(name, [])

    case Map.fetch(@lookup, String.downcase(base)) do
      {:ok, known} ->
        {:key, canonical(modifiers, known)}

      :error ->
        cond do
          modifiers != [] and Regex.match?(@one_char, base) ->
            {:key, canonical(modifiers, base)}

          modifiers != [] ->
            {:error, unknown(name)}

          String.length(base) == 1 ->
            :text

          Regex.match?(@name_shaped, base) ->
            {:error, unknown(name)}

          true ->
            :text
        end
    end
  end

  # `C-`, `M-` and `S-` in any order and in any case, as tmux takes them.
  defp split(<<c, ?-, rest::binary>>, acc) when is_map_key(@modifier_prefixes, c) do
    split(rest, [Map.fetch!(@modifier_prefixes, c) | acc])
  end

  defp split(base, acc), do: {acc |> Enum.reverse() |> Enum.uniq() |> Enum.sort(), base}

  defp canonical([], name), do: name
  defp canonical(modifiers, name), do: Enum.join(modifiers) <> name

  defp unknown(name) do
    "`<#{name}>` is not a key name tmux knows, so it is not sent. A key is a " <>
      "tmux key name — Enter, Escape, Tab, BSpace, Space, Up, Down, Left, " <>
      "Right, Home, End, Insert, Delete, PageUp, PageDown, F1-F12 — with " <>
      "C-, M- or S- in front, as in <C-x> or <M-Up>. A <...> that is not a key " <>
      "name is text, so <b> and <foo bar> are text; this one looks like a key, " <>
      "and is refused rather than typed into the app (TERM-31)."
  end
end
