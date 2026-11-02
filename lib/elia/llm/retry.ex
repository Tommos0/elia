defmodule Elia.LLM.Retry do
  @moduledoc """
  Shared transport retry rule (LLM-30, LLM-31, LLM-35).

  A pooled connection that went stale while the app was idle fails with
  `Req.TransportError` reason `:closed`. A `GET` is safe to repeat, so Req's
  `:retry` option is set to `closed?/2`, with `max_retries: 2` and no delay.

  A streaming call can't use Req's retry: a stream that already emitted events
  must not be replayed, so the providers handle it themselves (LLM-30, LLM-35)
  and ask `retryable?/2` whether the failure is one they may retry.
  """

  @default_stream_idle_timeout :timer.seconds(90)

  @doc "Options to merge into a `GET` request's Req options."
  def get_options, do: [retry: &closed?/2, max_retries: 2, retry_delay: 0]

  @doc false
  def closed?(_request, %Req.TransportError{reason: :closed}), do: true
  def closed?(_request, _response_or_exception), do: false

  @doc """
  How long a streaming request may receive no data at all before it is cut off
  (LLM-34): 90 seconds unless configured otherwise with
  `config :elia, :stream_idle_timeout`.

  This is Req's `:receive_timeout`, which Finch applies to every chunk rather
  than to the whole response, so it is an idle timeout: a stream that keeps
  sending something — text, reasoning, even just a keep-alive comment — resets
  it and may run for hours, while one that goes silent is cut off.
  """
  @spec stream_idle_timeout() :: timeout()
  def stream_idle_timeout,
    do: Application.get_env(:elia, :stream_idle_timeout, @default_stream_idle_timeout)

  @doc """
  Whether a streaming call may be retried after `exception`, given whether any
  response data has been received yet (LLM-30, LLM-35).

  Yes for a connection that closed, or a stream that timed out, before a single
  byte arrived: nothing was streamed, so a fresh attempt can't repeat an event.
  No for every other transport error, and no for anything at all once data has
  arrived, since a partial stream cannot be replayed.
  """
  @spec retryable?(Exception.t(), boolean()) :: boolean()
  def retryable?(%Req.TransportError{reason: reason}, false)
      when reason in [:closed, :timeout],
      do: true

  def retryable?(_exception, _received?), do: false
end
