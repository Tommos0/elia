defmodule Elia.Terminal.KeysTest do
  @moduledoc """
  The notation the agent types into a terminal with (TERM-30, TERM-31): text as
  it is, `<Name>` for a key, and what a name tmux does not know does. No tmux is
  needed: what this module makes of the notation is what is checked, and
  `test/elia/terminal_test.exs` checks what tmux makes of the result.
  """
  use ExUnit.Case, async: true

  alias Elia.Terminal.Keys

  # TERM-30: text is text and a name in angle brackets is a key, in the order
  # they were written — which is the order they reach the app.
  test "text is text and a name in angle brackets is a key" do
    assert Keys.parse("htop<Enter>") == {:ok, [{:text, "htop"}, {:key, "Enter"}]}
    assert Keys.parse("<C-x><C-s>") == {:ok, [{:key, "C-x"}, {:key, "C-s"}]}

    assert Keys.parse("<Escape>:wq<Enter>") ==
             {:ok, [{:key, "Escape"}, {:text, ":wq"}, {:key, "Enter"}]}

    assert Keys.parse("no keys here") == {:ok, [{:text, "no keys here"}]}
    assert Keys.parse(" ") == {:ok, [{:text, " "}]}
  end

  # TERM-30: a name is tmux's, read as tmux reads one — case-insensitively, with
  # C-, M- or S- in front in any order, and a single character may carry one.
  test "a name is a tmux key name, in any case, with modifiers in front" do
    assert Keys.parse("<up>") == {:ok, [{:key, "Up"}]}
    assert Keys.parse("<UP>") == {:ok, [{:key, "Up"}]}
    assert Keys.parse("<BSpace>") == {:ok, [{:key, "BSpace"}]}
    assert Keys.parse("<F12>") == {:ok, [{:key, "F12"}]}
    assert Keys.parse("<m-up>") == {:ok, [{:key, "M-Up"}]}
    assert Keys.parse("<S-F1>") == {:ok, [{:key, "S-F1"}]}
    assert Keys.parse("<C-x>") == {:ok, [{:key, "C-x"}]}
    assert Keys.parse("<C-?>") == {:ok, [{:key, "C-?"}]}
    assert Keys.parse("<S-C-x>") == {:ok, [{:key, "C-S-x"}]}
    assert Keys.parse("<M-C-S-x>") == {:ok, [{:key, "C-M-S-x"}]}
  end

  # TERM-30: the spellings tmux does not know but that mean the same keys are
  # taken as those keys, so `<Esc>` is Escape rather than the word "Esc".
  test "the familiar spellings of a key are that key" do
    assert Keys.parse("<Esc>") == {:ok, [{:key, "Escape"}]}
    assert Keys.parse("<ESC>") == {:ok, [{:key, "Escape"}]}
    assert Keys.parse("<RET>") == {:ok, [{:key, "Enter"}]}
    assert Keys.parse("<CR>") == {:ok, [{:key, "Enter"}]}
    assert Keys.parse("<Backspace>") == {:ok, [{:key, "BSpace"}]}
    assert Keys.parse("<PgUp>") == {:ok, [{:key, "PPage"}]}
    assert Keys.parse("<PGUP>") == {:ok, [{:key, "PPage"}]}
    assert Keys.parse("<PgDn>") == {:ok, [{:key, "NPage"}]}
    assert Keys.parse("<Del>") == {:ok, [{:key, "DC"}]}
    assert Keys.parse("<Ins>") == {:ok, [{:key, "IC"}]}
  end

  # TERM-30: a `<...>` that is not a key name is text, which is what keeps a `<`
  # from needing an escape in prose, in HTML and in a redirect.
  test "a <...> that is not a key name is text" do
    assert Keys.parse("echo <b>hi</b>") == {:ok, [{:text, "echo <b>hi</b>"}]}
    assert Keys.parse("<foo bar>") == {:ok, [{:text, "<foo bar>"}]}
    assert Keys.parse("sort < file") == {:ok, [{:text, "sort < file"}]}
    assert Keys.parse("<>") == {:ok, [{:text, "<>"}]}
    assert Keys.parse("2<55>") == {:ok, [{:text, "2<55>"}]}
  end

  # TERM-31: tmux sends a name it does not know as literal text, so a typo would
  # be typed into the app. A `<...>` that looks like a key name and is not one is
  # refused instead, with what a name may be.
  test "a key name tmux does not know is refused, not typed" do
    for name <- ["Entr", "Escapee", "Alt-x", "Ctrl-x", "PgDown", "C-Foo", "C-;"] do
      assert {:error, message} = Keys.parse("<#{name}>")
      assert message =~ name
      assert message =~ "not a key name"
      assert message =~ "C-, M- or S-"
    end
  end

  # TERM-30: nothing to send is said rather than sent.
  test "an empty notation is refused" do
    assert {:error, message} = Keys.parse("")
    assert message =~ "nothing to send"
  end

  # TERM-31: a key name reaches a line tmux parses, so only a segment this
  # notation makes may be sent — text is text, and a name is a word of letters,
  # digits and the few characters that cannot mean anything else to tmux.
  test "only a segment the notation makes may be sent" do
    assert Keys.valid?({:text, "a b; rm -rf /"})
    assert Keys.valid?({:text, ""})
    assert Keys.valid?({:key, "C-x"})
    assert Keys.valid?({:key, "C-M-S-F12"})
    assert Keys.valid?({:key, "C-?"})

    refute Keys.valid?({:key, "x; kill-server"})
    refute Keys.valid?({:key, "x \"quoted\""})
    refute Keys.valid?({:key, "C-x\nkill-server"})
    refute Keys.valid?({:key, "x\\"})
    refute Keys.valid?({:text, 42})
    refute Keys.valid?(:nonsense)
  end
end
