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

  @typedoc "A model offered in the picker. Prices are USD per million tokens."
  @type model :: %{
          required(:id) => binary(),
          required(:name) => binary(),
          optional(:context_length) => pos_integer() | nil,
          optional(:prompt_price) => float() | nil,
          optional(:completion_price) => float() | nil
        }

  @callback stream(request(), on_event :: (event() -> any())) ::
              {:ok, response()} | {:error, term()}

  @doc "The model used when a request names none."
  @callback default_model() :: binary()

  @doc "Makes one authenticated request to verify `api_key`."
  @callback check_key(api_key :: binary()) :: :ok | {:error, binary()}

  @doc "Models available with `api_key` (which may be `nil`)."
  @callback list_models(api_key :: binary() | nil) :: {:ok, [model()]} | {:error, binary()}

  @optional_callbacks default_model: 0, check_key: 1, list_models: 1
end
