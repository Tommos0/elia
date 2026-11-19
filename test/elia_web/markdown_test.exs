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

  @func_dir "markdown_funcs_fixture"

  @sample ~S"""
  defmodule Sample do
    def run(a, b \\ 1), do: {a, b}
  end
  """

  # FUNC-4: a mention resolves in the chat's own workspace (PROJ-12), so the
  # definitions are a module of this test's scratch workspace.
  defp source_root do
    root = Path.join(Workspace.root(), @func_dir)
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/sample.ex"), @sample)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp func_href, do: "/files?chat=markdownchat1&path=#{@func_dir}%2Flib%2Fsample.ex&line=2"

  @spec_file "cite_markdown_fixture.md"

  # CITE-4: a citation resolves in the chat's own workspace, so its corpus is a
  # spec of the scratch workspace a test chat works in (PROJ-12).
  defp spec_root do
    dir = Path.join(Workspace.root(), "specs")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, @spec_file), """
    # Citations fixture

    ## Requirements

    - **CITE-8** A requirement the reply cites.
    - **CITE-9** A requirement with `code` in it, and a second
      line that the tooltip joins.
    - **CITE-10** One holding <angle brackets>, an & and a "quote".
    - **CITE-11** One naming CITE-8 and CITE-9, with CITE-77 too.
    """)

    on_exit(fn ->
      File.rm(Path.join(dir, @spec_file))
      File.rmdir(dir)
    end)

    dir
  end

  # CITE-10, CITE-11: the Files page a citation's link opens — the requirement's
  # own spec file and line, in the chat's workspace (FLINK-5, EXPL-27).
  defp cite_href(line) do
    path = URI.encode_www_form("specs/#{@spec_file}")
    "/files?chat=markdownchat1&path=#{path}&line=#{line}"
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

  # FUNC-1, FUNC-2, FUNC-3, FUNC-8: an Elixir function a reply mentions becomes
  # a link to the line its definition is written at (FUNC-4) — in an inline code
  # span and in the prose alike, with `Elixir.` naming the same module — while an
  # arity the workspace doesn't define stays plain text.
  test "links the functions a reply mentions" do
    source_root()

    doc =
      doc(
        "`Sample.run/1` and Sample.run/2 and Elixir.Sample.run/1, not `Sample.run/0`.",
        links()
      )

    # FUNC-8: the code span keeps its own element, so the mention still reads as
    # code, and its label is the agent's own text.
    assert doc |> LazyHTML.query("a") |> LazyHTML.attribute("href") ==
             [func_href(), func_href(), func_href()]

    assert [code] = doc |> LazyHTML.query("a code") |> Enum.to_list()
    assert LazyHTML.text(code) == "Sample.run/1"
    # FUNC-4: an arity the workspace doesn't define is no link at all.
    assert LazyHTML.text(doc) =~ "Sample.run/0"
  end

  # FUNC-1: a code block is content, and a link's text and an image's alt text
  # are left alone — a mention is the reply's own text.
  test "a code block, a link and an image hold no function mention" do
    source_root()

    doc =
      doc("```\nSample.run/1\n```\n\n[`Sample.run/1`](/files) ![Sample.run/1](/x.png)\n", links())

    assert doc |> LazyHTML.query("pre a") |> Enum.count() == 0
    assert LazyHTML.text(LazyHTML.query(doc, "pre")) == "Sample.run/1\n"
    assert LazyHTML.attribute(LazyHTML.query(doc, "a"), "href") == ["/files"]
    assert doc |> LazyHTML.query("a a") |> Enum.count() == 0
    assert doc |> LazyHTML.query("img a") |> Enum.count() == 0
  end

  # FUNC-7: the mention adds no markup — the label is the agent's own characters,
  # escaped, so what a reply writes around one is text (UI-27).
  test "escapes a function mention's own text" do
    source_root()

    doc = doc("`<b>Sample.run/1</b>` and <b>raw</b>", links())

    assert doc |> LazyHTML.query("b") |> Enum.count() == 0
    assert LazyHTML.text(LazyHTML.query(doc, "code")) == "<b>Sample.run/1</b>"
    assert LazyHTML.attribute(LazyHTML.query(doc, "code a"), "href") == [func_href()]
  end

  # CITE-1, CITE-2, CITE-5: a requirement ID a reply cites carries that
  # requirement's own text as a tooltip — in an inline code span and in the
  # prose alike — while the citation stays the agent's own text. CITE-13: the
  # `title` keeps the plain statement, which is what a page whose bundle never
  # loaded shows.
  test "cites a requirement with its own text as a tooltip" do
    spec_root()

    doc = doc("See `CITE-9` and CITE-8, but not CITE-77 or NOPE-1.", links())

    assert doc |> LazyHTML.query("span.spec-cite") |> LazyHTML.attribute("title") == [
             "A requirement with `code` in it, and a second line that the tooltip joins.",
             "A requirement the reply cites."
           ]

    # CITE-1: an ID the corpus does not define is left as text, and CITE-5: the
    # citation's own text is unchanged — still code where the agent wrote code.
    assert LazyHTML.text(doc) == "See CITE-9 and CITE-8, but not CITE-77 or NOPE-1."
    assert LazyHTML.text(LazyHTML.query(doc, "code")) == "CITE-9"
  end

  # CITE-10, CITE-11, CITE-12: the tooltip a citation carries links the
  # requirement's own spec file and line and every requirement its statement
  # names, and a token the corpus does not define stays the statement's own text
  # (CITE-1). CITE-12: a link in it takes the pointer, where the tooltip around
  # it takes none (CITE-8).
  test "the tooltip links the requirement's file and line, and what it names" do
    spec_root()

    tip =
      doc("CITE-11", links())
      |> LazyHTML.query("span.spec-cite")
      |> LazyHTML.attribute("data-tip")
      |> hd()

    anchors = tip |> LazyHTML.from_fragment() |> LazyHTML.query("a")

    # CITE-10: the requirement's own link is its file and line. CITE-11: each
    # requirement the statement names is a link to its own.
    assert anchors |> Enum.map(&LazyHTML.text/1) == ["CITE-8", "CITE-9", "specs/#{@spec_file}:9"]
    assert LazyHTML.attribute(anchors, "href") == [cite_href(5), cite_href(6), cite_href(9)]

    assert LazyHTML.text(LazyHTML.from_fragment(tip)) ==
             "One naming CITE-8 and CITE-9, with CITE-77 too. specs/#{@spec_file}:9"

    assert anchors |> LazyHTML.attribute("style") |> Enum.all?(&(&1 =~ "pointer-events: auto"))
  end

  # CITE-3: the citation and its tooltip are escaped, so a requirement holding
  # markup adds none of it to the message (UI-27).
  test "escapes a citation and its tooltip" do
    spec_root()

    html = render("CITE-10", links())

    refute html =~ "<angle"
    assert html =~ "&lt;angle brackets&gt;"
    assert html =~ "&amp;"
    assert html =~ "&quot;quote&quot;"

    # CITE-13: the citation's `title` is the statement escaped as the attribute's
    # own value — one escape, one layer — which is what a browser shows (CITE-2).
    statement = "One holding &lt;angle brackets&gt;, an &amp; and a &quot;quote&quot;."
    assert html =~ ~s(title="#{statement}")

    # CITE-3, CITE-9: the tooltip is escaped once per layer — the markup the
    # browser parses it as, and the attribute it travels in — so what the browser
    # reads from `data-tip` holds the statement escaped *for that parse*, and
    # only the link to where the requirement is written (CITE-10) as markup. The
    # `<angle brackets>`, the `&` and the quote are characters in it: taken as
    # text, the tooltip is the statement itself.
    tip =
      doc("CITE-10", links())
      |> LazyHTML.query("span.spec-cite")
      |> LazyHTML.attribute("data-tip")
      |> hd()

    assert tip =~ "&lt;angle brackets&gt;"
    assert tip =~ ~s(<a href="/files?chat=markdownchat1&amp;path=)

    plain = ~s(One holding <angle brackets>, an & and a "quote". specs/#{@spec_file}:8)
    assert LazyHTML.text(LazyHTML.from_fragment(tip)) == plain
  end

  # CITE-6: a code block is content, and so are a link's text and an image's alt
  # text — a citation is the reply's own text, not text quoted from elsewhere.
  test "leaves a code block, a link and an image alone" do
    spec_root()

    doc = doc("```\nCITE-9\n```\n\n[`CITE-9`](/files) ![CITE-9](/x.png)\n", links())

    assert doc |> LazyHTML.query("span.spec-cite") |> Enum.count() == 0
    assert LazyHTML.text(LazyHTML.query(doc, "pre")) == "CITE-9\n"
    assert LazyHTML.text(LazyHTML.query(doc, "a")) == "CITE-9"
    assert doc |> LazyHTML.query("img") |> LazyHTML.attribute("alt") == ["CITE-9"]
  end
end
