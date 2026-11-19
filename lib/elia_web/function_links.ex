defmodule EliaWeb.FunctionLinks do
  @moduledoc """
  The Elixir functions an assistant message mentions, as links to the line their
  definition is written at (`specs/function-links.md`, FUNC-1 - FUNC-8).

  A mention is a token `Module.name/arity` (FUNC-2, FUNC-3), in an inline code
  span or in the reply's plain text, and it becomes a link only when the chat's
  workspace defines that function at that arity (FUNC-4, FUNC-5): the Files page
  opened at the line its definition starts on (EXPL-27). Every other mention
  stays plain text, so a link never leads to a page that shows an error.
  """

  alias Elia.Source
  alias EliaWeb.FileLinks

  # FUNC-2, FUNC-3: `<Module>.<name>/<arity>`, with Elixir's own `Elixir.`
  # prefix naming the same module.
  @mention ~r/(?:\bElixir\.)?\b(?<module>[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\.(?<name>[a-z_][A-Za-z0-9_]*[?!]?)\/(?<arity>\d+)\b/

  @doc """
  The Files page URL for `mention` at the line its definition is written
  (FUNC-4), or `nil` when the chat's workspace does not define that function
  (FUNC-4, FUNC-5).
  """
  @spec url(FileLinks.t() | nil, String.t()) :: String.t() | nil
  def url(nil, _mention), do: nil

  def url(%{root: root} = links, mention) do
    case split(mention) do
      {:ok, module, name, arity} ->
        case Source.definition(root, module, name, arity) do
          %{path: path, line: line} when is_integer(line) -> FileLinks.line_url(links, path, line)
          _ -> nil
        end

      :error ->
        nil
    end
  end

  @doc """
  The document with every function mention in it linked (FUNC-1). A token inside
  a fenced code block is content, not a mention, and neither is the text of a
  link or an image's alt text, so no link lands inside another.
  """
  @spec link(MDEx.Document.t(), FileLinks.t() | nil) :: MDEx.Document.t()
  def link(%MDEx.Document{} = doc, nil), do: doc

  def link(%MDEx.Document{} = doc, links) do
    # A message that names no function reads no source at all (FUNC-4): the
    # workspace's definitions are only paid for when a mention is there to resolve.
    if mentioned?(doc) do
      %{doc | nodes: Enum.flat_map(doc.nodes, &nodes(&1, links))}
    else
      doc
    end
  end

  # FUNC-1: a mention in the reply's plain text is a link beside the text around
  # it, which stays text — the renderer escapes it, so it is the agent's own
  # characters (FUNC-7) — and the message's other passes still see it.
  defp nodes(%MDEx.Text{literal: literal} = text, links) do
    case text_parts(literal, links) do
      nil -> [text]
      parts -> parts
    end
  end

  # FUNC-1, FUNC-8: an inline code span keeps its own element, so the mention
  # still reads as code (as FLINK-1 keeps a file mention). A span that is the
  # mention is the code inside the link; one that only holds a mention keeps the
  # code element around the link's markup.
  defp nodes(%MDEx.Code{literal: literal} = code, links) do
    case url(links, String.trim(literal)) do
      nil ->
        case code_parts(literal, links) do
          nil -> [code]
          html -> [%MDEx.Raw{literal: html}]
        end

      href ->
        [%MDEx.Link{nodes: [code], url: href}]
    end
  end

  defp nodes(%MDEx.CodeBlock{} = block, _links), do: [block]
  defp nodes(%MDEx.Link{} = link, _links), do: [link]
  defp nodes(%MDEx.Image{} = image, _links), do: [image]

  defp nodes(%{nodes: nodes} = parent, links),
    do: [%{parent | nodes: Enum.flat_map(nodes, &nodes(&1, links))}]

  defp nodes(other, _links), do: [other]

  # FUNC-1, FUNC-4: whether the message names a function at all — a code block is
  # content, and a link's text and an image's alt text are left alone.
  defp mentioned?(%MDEx.Text{literal: literal}), do: Regex.match?(@mention, literal)
  defp mentioned?(%MDEx.Code{literal: literal}), do: Regex.match?(@mention, literal)
  defp mentioned?(%MDEx.CodeBlock{}), do: false
  defp mentioned?(%MDEx.Link{}), do: false
  defp mentioned?(%MDEx.Image{}), do: false
  defp mentioned?(%{nodes: nodes}), do: Enum.any?(nodes, &mentioned?/1)
  defp mentioned?(_other), do: false

  defp text_parts(literal, links) do
    {nodes, linked?} =
      literal
      |> parts()
      |> Enum.reduce({[], false}, fn part, {nodes, linked?} ->
        case url(links, part) do
          nil -> {[%MDEx.Text{literal: part} | nodes], linked?}
          href -> {[%MDEx.Link{nodes: [%MDEx.Text{literal: part}], url: href} | nodes], true}
        end
      end)

    if linked?, do: Enum.reverse(nodes)
  end

  defp code_parts(literal, links) do
    {html, linked?} =
      literal
      |> parts()
      |> Enum.reduce({"", false}, fn part, {html, linked?} ->
        case url(links, part) do
          nil -> {html <> escape(part), linked?}
          href -> {html <> ~s(<a href="#{escape(href)}">#{escape(part)}</a>), true}
        end
      end)

    if linked?, do: "<code>" <> html <> "</code>"
  end

  defp parts(literal), do: Regex.split(@mention, literal, include_captures: true, trim: true)

  # FUNC-2, FUNC-3: the module, the function name and the arity a mention names —
  # the whole token and nothing less, so a token that only holds one is text.
  defp split(mention) do
    with [matched, module, name, arity] <- Regex.run(@mention, mention),
         true <- matched == mention do
      {:ok, String.replace_prefix(module, "Elixir.", ""), name, String.to_integer(arity)}
    else
      _ -> :error
    end
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
