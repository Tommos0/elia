defmodule Elia.LLM.Error do
  @moduledoc """
  A model call's failure (LLM-1, LLM-36).

  `message` is the text to show, exactly as a provider's plain message was, and
  `transient` says whether a retry may fix it (RETRY-6): a transport failure, a
  status the provider retries itself, an in-stream error the service calls
  overload. The agent loop retries only a transient one and reports anything
  else as it stands (LOOP-23, RETRY-1).

  It reads as its message wherever one is shown, so a stop's row carries the
  provider's sentence and nothing about the error's shape (STOP-2).
  """

  defstruct [:message, transient: false]

  @type t :: %__MODULE__{message: binary(), transient: boolean()}

  @doc "A failure a retry may fix (RETRY-6)."
  @spec transient(binary()) :: t()
  def transient(message), do: %__MODULE__{message: message, transient: true}

  @doc "A failure a retry cannot fix."
  @spec permanent(binary()) :: t()
  def permanent(message), do: %__MODULE__{message: message}
end

defimpl String.Chars, for: Elia.LLM.Error do
  def to_string(%{message: message}), do: message
end
