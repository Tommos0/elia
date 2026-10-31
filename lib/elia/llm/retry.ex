defmodule Elia.LLM.Retry do
  @moduledoc """
  Shared transport retry rule for `GET` requests (LLM-31).

  A pooled connection that went stale while the app was idle fails with
  `Req.TransportError` reason `:closed`. A `GET` is safe to repeat, so Req's
  `:retry` option is set to `closed?/2`, with `max_retries: 2` and no delay.
  """

  @doc "Options to merge into a `GET` request's Req options."
  def get_options, do: [retry: &closed?/2, max_retries: 2, retry_delay: 0]

  @doc false
  def closed?(_request, %Req.TransportError{reason: :closed}), do: true
  def closed?(_request, _response_or_exception), do: false
end
