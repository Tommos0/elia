defmodule EliaWeb.Markdown do
  @moduledoc """
  Renders assistant text as GitHub-flavoured Markdown (UI-25..UI-27).

  Raw HTML is left out and unsafe URLs are dropped, so the output is safe to
  insert into the page as-is. The paths the agent mentions become links to the
  Files page when a chat's `EliaWeb.FileLinks` context is given (FLINK-1).
  """

  alias EliaWeb.FileLinks

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
  Renders `text` to safe HTML. With a chat's `FileLinks` context (FLINK-1) every
  path it mentions that the Files page could show is linked (FLINK-5).
  """
  @spec to_html(String.t(), FileLinks.t() | nil) :: Phoenix.HTML.safe()
  def to_html(text, links \\ nil) when is_binary(text) do
    with {:ok, doc} <- MDEx.parse_document(text, @options),
         {:ok, html} <- doc |> FileLinks.link(links) |> MDEx.to_html(@options) do
      Phoenix.HTML.raw(html)
    else
      _ -> Phoenix.HTML.html_escape(text)
    end
  end
end
