defmodule EliaWeb.SpecRefs do
  @moduledoc """
  The requirement IDs an assistant message cites, each carrying the requirement's
  own text as a tooltip (`specs/spec-citations.md`, CITE-1 - CITE-13).

  A citation is a token some spec in the chat's workspace defines (CITE-1,
  CITE-4), in an inline code span or in the message's plain text, and the tooltip
  is what that requirement says (CITE-2). The element is built here and its text
  escaped (CITE-3), the citation stays the agent's own text (CITE-5), and a code
  block, a link and an image are left alone (CITE-6).

  The tooltip is this module's markup too (CITE-3, CITE-9): the statement, with
  the statement's own characters escaped, a link to where the requirement is
  written (CITE-10) and a link for every requirement the statement names
  (CITE-11). It travels on the citation as `data-tip`, which `EliaWeb.ChatLive`'s
  `.SpecTip` hook puts into the tooltip's element; the citation's `title` keeps
  the plain statement, which is the text a page whose bundle never loaded shows
  (CITE-13).
  """

  alias Elia.Specs
  alias EliaWeb.FileLinks

  # CITE-1: a requirement ID, as the corpus writes one (SPEC-1).
  @id ~r/\b[A-Z]+-\d+\b/

  # CITE-5: what marks a citation as having more to show — a dotted underline and
  # a `help` cursor, in `assets/css/app.css`.
  @class "spec-cite"

  # CITE-12: a link in the tooltip takes the pointer, where the tooltip around it
  # takes none (CITE-8) — its own markup's `style`, never a rule in assets/css,
  # for the same reason the tooltip's look is (`EliaWeb.ChatLive`, HOT-8).
  @link_style "pointer-events: auto; color: inherit; text-decoration: underline"

  @doc """
  The document with every citation in it marked (CITE-1). The context is a
  chat's (`EliaWeb.FileLinks.t()`), whose `root` is the workspace the corpus is
  read from (CITE-4); without one the document is left as it is.
  """
  @spec mark(MDEx.Document.t(), FileLinks.t() | nil) :: MDEx.Document.t()
  def mark(%MDEx.Document{} = doc, nil), do: doc

  def mark(%MDEx.Document{} = doc, %{root: root} = links) do
    context = %{requirements: Specs.requirements(root), links: links}
    %{doc | nodes: Enum.map(doc.nodes, &node(&1, context))}
  end

  # CITE-1, CITE-2: the IDs in a text node are citations, and the text around
  # them is escaped as it is.
  defp node(%MDEx.Text{literal: literal} = text, context) do
    case citations(literal, context) do
      nil -> text
      html -> %MDEx.Raw{literal: html}
    end
  end

  # CITE-1: an inline code span keeps its own element, with the citations inside
  # it, so the mention reads as code (as FLINK-1 keeps it).
  defp node(%MDEx.Code{literal: literal} = code, context) do
    case citations(literal, context) do
      nil -> code
      html -> %MDEx.Raw{literal: "<code>" <> html <> "</code>"}
    end
  end

  # CITE-6: a code block is content, not a citation, and neither is the text of a
  # link or an image's alt text.
  defp node(%MDEx.CodeBlock{} = block, _context), do: block
  defp node(%MDEx.Link{} = link, _context), do: link
  defp node(%MDEx.Image{} = image, _context), do: image

  defp node(%{nodes: nodes} = parent, context),
    do: %{parent | nodes: Enum.map(nodes, &node(&1, context))}

  defp node(other, _context), do: other

  # CITE-1, CITE-3, CITE-5: every ID the corpus defines becomes a span whose
  # `title` is that requirement's text and whose `data-tip` is the tooltip's
  # markup (CITE-9); the ID itself, and the text between the IDs, stays the
  # agent's own, escaped. A message that cites nothing is left as it is.
  defp citations(literal, %{requirements: requirements} = context) do
    {html, cited?} =
      @id
      |> Regex.split(literal, include_captures: true, trim: true)
      |> Enum.reduce({"", false}, fn part, {html, cited?} ->
        case Map.get(requirements, part) do
          nil -> {html <> escape(part), cited?}
          requirement -> {html <> citation(part, requirement, context), true}
        end
      end)

    if cited?, do: html
  end

  defp citation(id, requirement, context) do
    ~s(<span class="#{@class}" title="#{escape(requirement.text)}") <>
      ~s( data-tip="#{escape(tooltip(requirement, context))}">#{escape(id)}</span>)
  end

  # CITE-3, CITE-10, CITE-11: the tooltip's markup — the statement's own
  # characters, with the requirements it names as links, and after it the link to
  # where it is written. It is markup the browser parses, so everything in it
  # that is not a link built here is escaped for *that* layer (`named/2`,
  # `link/2`), and the whole of it is escaped once more as the attribute's own
  # value (`citation/3`): two escapes, one per layer, so a statement holding `<`
  # or an entity shows those characters and only its links are markup.
  defp tooltip(%{text: text, path: path, line: line}, context) do
    statement = named(text, context)

    case FileLinks.line_url(context.links, path, line) do
      nil -> statement
      href -> statement <> " " <> link("#{path}:#{line}", href)
    end
  end

  # CITE-11: a requirement the statement names is a link to its own file and
  # line, exactly as the requirement's own link is (CITE-10); a token the corpus
  # does not define stays the statement's own text (CITE-1) — and so does the
  # statement's text around them, escaped as the markup's own (CITE-3).
  defp named(statement, %{requirements: requirements} = context) do
    @id
    |> Regex.split(statement, include_captures: true, trim: true)
    |> Enum.map_join("", fn part ->
      case Map.get(requirements, part) do
        %{path: path, line: line} -> named_link(part, path, line, context)
        _ -> escape(part)
      end
    end)
  end

  defp named_link(id, path, line, context) do
    case FileLinks.line_url(context.links, path, line) do
      nil -> escape(id)
      href -> link(id, href)
    end
  end

  # CITE-3: a link's own two parts are the markup layer's too — its label is text
  # in it and its `href` an attribute of it, where a `&` of the query is an
  # entity's start to a parser.
  defp link(label, href),
    do: ~s(<a href="#{escape(href)}" style="#{@link_style}">#{escape(label)}</a>)

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
