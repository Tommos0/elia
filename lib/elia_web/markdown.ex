defmodule EliaWeb.Markdown do
  @moduledoc """
  Renders assistant text as GitHub-flavoured Markdown (UI-25..UI-27).

  Raw HTML is left out and unsafe URLs are dropped, so the output is safe to
  insert into the page as-is. The paths the agent mentions become links to the
  Files page when a chat's `EliaWeb.FileLinks` context is given (FLINK-1), the
  Elixir functions it mentions become links to the line their definition is
  written at (`specs/function-links.md`, FUNC-1), and the requirement IDs it
  cites carry the requirement's text as a tooltip
  (`specs/spec-citations.md`, CITE-1).
  """

  alias EliaWeb.{FileLinks, FunctionLinks, SpecRefs}

  @options [
    extension: [
      strikethrough: true,
      table: true,
      autolink: true,
      tasklist: true
    ],
    render: [hardbreaks: true, unsafe: false],
    syntax_highlight: nil
  ]

  @doc """
  Renders `text` to safe HTML. With a chat's `FileLinks` context every path it
  mentions that the Files page could show is linked (FLINK-1, FLINK-5), every
  function it mentions that the chat's workspace defines is linked at the line
  it is written (FUNC-1, FUNC-4), and every requirement ID it cites shows that
  requirement's text as a tooltip (CITE-1).
  """
  @spec to_html(String.t(), FileLinks.t() | nil) :: Phoenix.HTML.safe()
  def to_html(text, links \\ nil) when is_binary(text) do
    with {:ok, doc} <- MDEx.parse_document(text, @options),
         {:ok, html} <-
           doc
           |> FunctionLinks.link(links)
           |> FileLinks.link(links)
           |> SpecRefs.mark(links)
           |> MDEx.to_html(@options) do
      Phoenix.HTML.raw(html)
    else
      _ -> Phoenix.HTML.html_escape(text)
    end
  end
end
