defmodule EliaWeb.ChatMenuTest do
  @moduledoc """
  The composer toolbar's chat menu (UI-97): its trigger, what the panel holds,
  what stays outside it, and how it shuts again — the model in use as text
  (CSET-8), the jail warning beside the trigger (CSET-9) and the Focus toggle
  in the bar (CSET-10).
  """
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM}

  setup do
    start_supervised!(FakeLLM)
    # The suite runs with the host's jail off (config/test.exs); this case wants
    # a host that has one, so the warning's absence means something.
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, jail: true)
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    %{id: id}
  end

  defp open(view), do: view |> element("#chat-menu-button") |> render_click()

  # UI-97: one icon-only trigger says what it opens and whether the panel is
  # open, and the panel is shut until it is asked for.
  test "the toolbar has a chat menu trigger, shut until it is pressed", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#chat-menu-button[aria-haspopup='true'][aria-expanded='false']")
    assert has_element?(view, "#chat-menu-button[title]")
    refute has_element?(view, "#chat-menu")

    # Icon-only: the trigger shows its glyph and no label of its own.
    trigger = view |> element("#chat-menu-button") |> render()
    assert trigger =~ "hero-ellipsis-horizontal"
    refute trigger =~ "Chat settings"

    open(view)

    assert has_element?(view, "#chat-menu-button[aria-expanded='true']")
    assert has_element?(view, "#chat-menu")
  end

  # UI-97: the panel opens upward, since the toolbar sits at the bottom of the
  # screen, and holds the model in use, the settings link, the terminal link and
  # the done control, in that order.
  test "the panel opens upward and holds the chat's own controls", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    open(view)

    panel = view |> element("#chat-menu") |> render()
    assert panel =~ "bottom-full", "the panel does not open upward (UI-97)"

    positions =
      for id <- ["chat-settings-model", "chat-settings-link", "chat-terminal-link", "done-toggle"] do
        assert has_element?(view, "#chat-menu ##{id}")
        {index, _} = :binary.match(panel, ~s(id="#{id}"))
        index
      end

    assert positions == Enum.sort(positions), "the menu's entries are not in UI-97's order"
  end

  # CSET-8, UI-97: the model in use is shown as text — the badge and the name,
  # with no control of its own — so what is answering is readable while the
  # menu is open.
  test "the panel shows the model in use as text", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    open(view)

    assert has_element?(view, "#chat-menu #chat-settings-model")
    refute has_element?(view, "#chat-menu a#chat-settings-model")
    refute has_element?(view, "#chat-menu button#chat-settings-model")

    panel = view |> element("#chat-menu") |> render()
    assert panel =~ "data-provider", "the model's provider badge is missing from the menu"
  end

  # CSET-10, UI-97: the Focus toggle acts on the transcript the user is reading,
  # so it stays in the bar, outside the menu.
  test "the Focus toggle stays in the toolbar, outside the menu", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#view-toggle", "Focus")
    refute has_element?(view, "#chat-menu #view-toggle")

    open(view)
    refute has_element?(view, "#chat-menu #view-toggle")
    assert has_element?(view, "#view-toggle", "Focus")
  end

  # CSET-9, UI-97: a warning inside a shut menu is not a warning, so the jail's
  # stays in the bar beside the trigger, whether the menu is open or not.
  test "the jail warning stays in the toolbar, outside the menu", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    refute has_element?(view, "#jail-warning")

    :ok = Agent.set_jail(id, false)
    render(view)

    assert has_element?(view, "#jail-warning", "credentials")
    refute has_element?(view, "#chat-menu #jail-warning")

    open(view)
    refute has_element?(view, "#chat-menu #jail-warning")
  end

  # UI-97: a second press, a click outside it and Escape all shut the panel
  # again — and the toolbar reads as shut once it is.
  test "the menu shuts on a second press, a click away and Escape", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    open(view)
    assert has_element?(view, "#chat-menu")
    open(view)
    refute has_element?(view, "#chat-menu")
    assert has_element?(view, "#chat-menu-button[aria-expanded='false']")

    # A click outside the panel sends the same event the browser's click-away
    # binding does.
    open(view)
    render_click(view, "close_menu", %{})
    refute has_element?(view, "#chat-menu")

    # Escape, wherever the keyboard is: the window's own keydown binding.
    open(view)
    render_keydown(view, "close_menu", %{"key" => "Escape"})
    refute has_element?(view, "#chat-menu")
  end
end
