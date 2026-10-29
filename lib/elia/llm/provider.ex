defmodule Elia.LLM.Provider do
  @moduledoc """
  Behaviour for LLM providers.

  A provider turns a neutral `t:request/0` into one model turn, streaming
  progress through `on_event` and returning the complete assistant message.
  """

  alias Elia.LLM.Message

  @type tool_spec :: %{name: binary(), description: binary(), input_schema: map()}

  @type request :: %{
          required(:messages) => [Message.t()],
          optional(:system) => binary(),
          optional(:tools) => [tool_spec()],
          optional(:model) => binary(),
          optional(:max_tokens) => pos_integer(),
          optional(atom()) => term()
        }

  @type stop_reason :: :end_turn | :tool_use | :max_tokens | :refusal | :other

  @type response :: %{
          message: Message.t(),
          stop_reason: stop_reason(),
          model: binary() | nil,
          usage: map()
        }

  @typedoc "Events emitted while a turn streams."
  @type event ::
          {:text_delta, binary()}
          | {:reasoning_delta, binary()}
          | {:tool_call_started, %{id: binary(), name: binary()}}
          | {:notice, binary()}

  @callback stream(request(), on_event :: (event() -> any())) ::
              {:ok, response()} | {:error, term()}
end
