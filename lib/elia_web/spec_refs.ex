defmodule EliaWeb.SpecRefs do
  @moduledoc """
  The requirement IDs an assistant message cites, each carrying the requirement's
  own text as a tooltip (`specs/spec-citations.md`, CITE-1 - CITE-6).

  A citation is a token some spec in the chat's workspace defines (CITE-1,
  CITE-4), in an inline code span or in the message's plain text, and the tooltip
  is what that requirement says (CITE-2). The element is built here and its text
  escaped (CITE-3), the citation stays the agent's own text (CITE-5), and a code
  block, a link and an image are left alone (CITE-6).
  """

  alias Elia.Specs

  # CITE-1: a requirement ID, as the corpus writes one (SPEC-1).
  @id ~r/\b[A-Z]+-\d+\b/

  # CITE-5: what marks a citation as having more to show — a dotted underline and
  # a `help` cursor, in `assets/css/app.css`.
  @class "spec-cite"

  @doc """
  The document with every citation in it marked (CITE-1). The context is a
  chat's (`EliaWeb.FileLinks.t()`), whose `root` is the workspace the corpus is
  read from (CITE-4); without one the document is left as it is.
  """
  @spec mark(MDEx.Document.t(), EliaWeb.FileLinks.t() | nil) :: MDEx.Document.t()
  def mark(%MDEx.Document{} = doc, nil), do: doc

  def mark(%MDEx.Document{} = doc, %{root: root}) do
    requirements = Specs.requirements(root)
    %{doc | nodes: Enum.map(doc.nodes, &node(&1, requirements))}
  end

  # CITE-1, CITE-2: the IDs in a text node are citations, and the text around
  # them is escaped as it is.
  defp node(%MDEx.Text{literal: literal} = text, requirements) do
    case citations(literal, requirements) do
      nil -> text
      html -> %MDEx.Raw{literal: html}
    end
  end

  # CITE-1: an inline code span keeps its own element, with the citations inside
  # it, so the mention reads as code (as FLINK-1 keeps it).
  defp node(%MDEx.Code{literal: literal} = code, requirements) do
    case citations(literal, requirements) do
      nil -> code
      html -> %MDEx.Raw{literal: "<code>" <> html <> "</code>"}
    end
  end

  # CITE-6: a code block is content, not a citation, and neither is the text of a
  # link or an image's alt text.
  defp node(%MDEx.CodeBlock{} = block, _requirements), do: block
  defp node(%MDEx.Link{} = link, _requirements), do: link
  defp node(%MDEx.Image{} = image, _requirements), do: image

  defp node(%{nodes: nodes} = parent, requirements),
    do: %{parent | nodes: Enum.map(nodes, &node(&1, requirements))}

  defp node(other, _requirements), do: other

  # CITE-3, CITE-5: every ID the corpus defines becomes a span whose title is
  # that requirement's text; the ID itself, and the text between the IDs, stays
  # the agent's own, escaped. A message that cites nothing is left as it is.
  defp citations(literal, requirements) do
    {html, cited?} =
      @id
      |> Regex.split(literal, include_captures: true, trim: true)
      |> Enum.reduce({"", false}, fn part, {html, cited?} ->
        case Map.get(requirements, part) do
          nil -> {html <> escape(part), cited?}
          text -> {html <> citation(part, text), true}
        end
      end)

    if cited?, do: html
  end

  defp citation(id, text) do
    ~s(<span class="#{@class}" title="#{escape(text)}">#{escape(id)}</span>)
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
