defmodule Elia.FakeLLM do
  @moduledoc """
  Scripted provider for tests. Queue turns with `push/1`; each turn is a
  `%Elia.LLM.Message{}` (streamed as text deltas) or a
  `fn request, on_event -> result end`. Requests are recorded for `requests/0`.
  """

  @behaviour Elia.LLM.Provider

  use Agent

  alias Elia.LLM.Message

  def start_link(_), do: Agent.start_link(fn -> {[], []} end, name: __MODULE__)

  def push(turn), do: Agent.update(__MODULE__, fn {turns, reqs} -> {turns ++ [turn], reqs} end)

  def requests, do: Agent.get(__MODULE__, fn {_, reqs} -> Enum.reverse(reqs) end)

  def assistant(blocks), do: %Message{role: :assistant, content: blocks}

  def tool_call(id, name, input), do: %{type: :tool_call, id: id, name: name, input: input}

  @impl true
  def stream(request, on_event) do
    turn =
      Agent.get_and_update(__MODULE__, fn
        {[turn | rest], reqs} -> {turn, {rest, [request | reqs]}}
        {[], reqs} -> {nil, {[], [request | reqs]}}
      end)

    case turn do
      nil ->
        {:error, "FakeLLM: no scripted turn"}

      fun when is_function(fun, 2) ->
        fun.(request, on_event)

      %Message{} = message ->
        for %{type: :text, text: text} <- message.content, do: on_event.({:text_delta, text})
        stop = if Message.tool_calls(message) == [], do: :end_turn, else: :tool_use
        {:ok, %{message: message, stop_reason: stop, model: "fake", usage: %{}}}
    end
  end
end
