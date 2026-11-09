defmodule EliaWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias Elia.{Projects, Workspace}
  alias EliaWeb.{FileLinks, Markdown}

  @dir "markdown_links_fixture"

  defp render(text), do: text |> Markdown.to_html() |> Phoenix.HTML.safe_to_string()
  defp doc(text), do: text |> render() |> LazyHTML.from_fragment()
  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  # FLINK-1, FLINK-5: a mention resolves in the workspace the chat works in; a
  # test chat has no worktree, so it is the project's folder (PROJ-12).
  defp render(text, links), do: text |> Markdown.to_html(links) |> Phoenix.HTML.safe_to_string()
  defp doc(text, links), do: text |> render(links) |> LazyHTML.from_fragment()

  defp links, do: FileLinks.context(Projects.harness(), "markdownchat1")

  defp mention_root do
    root = Path.join(Workspace.root(), @dir)
    File.rm_rf!(root)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "note.txt"), "hi\n")
    File.write!(Path.join(root, "a & b.txt"), "x\n")
    File.write!(Path.join(root, "x<b>y.ex"), "x\n")
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

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

  # FLINK-1: a path in a reply's inline code becomes a link to that file's own
  # Files page, and its label stays the code the agent wrote.
  test "links the files a reply mentions" do
    mention_root()

    doc =
      doc(
        "See `#{@dir}/note.txt:12` and `#{@dir}/nothing_here.txt`.",
        links()
      )

    assert [link] = doc |> LazyHTML.query("a") |> Enum.to_list()

    assert LazyHTML.attribute(link, "href") == [
             "/files?chat=markdownchat1&path=#{@dir}%2Fnote.txt"
           ]

    # FLINK-2, FLINK-7: the suffix stays in the label, which is still code.
    assert [code] = link |> LazyHTML.query("code") |> Enum.to_list()
    assert LazyHTML.text(code) == "#{@dir}/note.txt:12"
    # FLINK-5: a path the Files page could not show stays plain text.
    assert LazyHTML.text(doc) =~ "#{@dir}/nothing_here.txt"
  end

  # FLINK-1: a fenced code block is content — a path in it is not a mention.
  test "a code block keeps its text" do
    mention_root()

    doc = doc("```\n#{@dir}/note.txt\n```\n", links())
    assert LazyHTML.attribute(LazyHTML.query(doc, "pre a"), "href") == []
    assert LazyHTML.text(LazyHTML.query(doc, "pre")) == "#{@dir}/note.txt\n"
  end

  # FLINK-1: a link's own text, and an image's alt text, are left alone — a
  # link inside a link is not a link.
  test "leaves the text of a link and an image alone" do
    mention_root()

    doc =
      doc(
        "[`#{@dir}/note.txt`](/files) ![`#{@dir}/note.txt`](/x.png)",
        links()
      )

    assert [link] = doc |> LazyHTML.query("a") |> Enum.to_list()
    assert LazyHTML.attribute(link, "href") == ["/files"]
    assert doc |> LazyHTML.query("a a") |> Enum.count() == 0
    assert doc |> LazyHTML.query("img a") |> Enum.count() == 0
  end

  # FLINK-6: the label is the agent's own text, escaped, and the URL is
  # percent-encoded, so a path with `&` or `<` renders as text (UI-27).
  test "escapes a mention's text and encodes its URL" do
    mention_root()

    doc = doc("`#{@dir}/x<b>y.ex` and `#{@dir}/a & b.txt`", links())
    assert LazyHTML.query(doc, "b") |> Enum.count() == 0

    hrefs = doc |> LazyHTML.query("a") |> LazyHTML.attribute("href")
    assert Enum.count(hrefs) == 2
    refute Enum.any?(hrefs, &String.contains?(&1, "<"))

    labels = doc |> LazyHTML.query("a code") |> Enum.map(&LazyHTML.text/1)
    assert labels == ["#{@dir}/x<b>y.ex", "#{@dir}/a & b.txt"]

    assert hrefs
           |> hd()
           |> String.trim_leading("/files?")
           |> URI.decode_query()
           |> Map.get("path") ==
             "#{@dir}/x<b>y.ex"
  end
end
