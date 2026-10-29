defmodule EliaWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias EliaWeb.Markdown

  defp render(text), do: text |> Markdown.to_html() |> Phoenix.HTML.safe_to_string()
  defp doc(text), do: text |> render() |> LazyHTML.from_fragment()
  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  # UI-25
  test "renders GitHub-flavoured Markdown" do
    doc =
      doc("""
      # Title

      Some **bold**, *italic*, ~~gone~~ and `code`.

      - one
      - [x] done

      1. first

      > quoted

      | a | b |
      |---|---|
      | 1 | 2 |

      ```elixir
      x = 1
      ```

      [link](https://example.com) and https://elixir-lang.org
      """)

    for selector <-
          ~w(h1 strong em del p>code ul li ol blockquote table td pre>code input[type=checkbox]) do
      assert count(doc, selector) >= 1, "expected #{selector}"
    end

    hrefs = doc |> LazyHTML.query("a") |> LazyHTML.attribute("href")
    assert hrefs == ["https://example.com", "https://elixir-lang.org"]
  end

  # UI-26
  test "single newlines become line breaks" do
    assert count(doc("line one\nline two"), "p > br") == 1
  end

  # UI-27
  test "raw HTML and unsafe URLs are not rendered" do
    html =
      render("hi <script>alert(1)</script> <b onclick=\"x\">b</b>\n\n<iframe src=\"x\"></iframe>")

    refute html =~ "<script"
    refute html =~ "<iframe"
    refute html =~ "onclick"

    doc = doc("[x](javascript:alert(1)) ![i](javascript:alert(1))")
    assert LazyHTML.attribute(LazyHTML.query(doc, "a"), "href") == [""]
    assert LazyHTML.attribute(LazyHTML.query(doc, "img"), "src") == [""]
  end
end
