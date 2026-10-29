defmodule EliaWeb.Markdown do
  @moduledoc """
  Renders assistant text as GitHub-flavoured Markdown (UI-25..UI-27).

  Raw HTML is left out and unsafe URLs are dropped, so the output is safe to
  insert into the page as-is.
  """

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

  @doc "Renders `text` to safe HTML."
  @spec to_html(String.t()) :: Phoenix.HTML.safe()
  def to_html(text) when is_binary(text) do
    case MDEx.to_html(text, @options) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      {:error, _} -> Phoenix.HTML.html_escape(text)
    end
  end
end
