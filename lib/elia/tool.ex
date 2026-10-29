defmodule Elia.Tool do
  @moduledoc """
  A callable tool exposed to the model.

  `run` receives the decoded input map (and, for arity 2, a context map with
  `:session_id` and `:turn_id`) and returns `{:ok, output}` or
  `{:error, output}`; both outputs are strings sent back to the model.

  `approval` is `:required`, `:never`, or a function of `(input, ctx)`
  returning one of those or `{:deny, reason}`. Calls that need approval
  pause the agent until the user decides.
  """

  @type result :: {:ok, binary()} | {:error, binary()}
  @type decision :: :required | :never | {:deny, binary()}

  @type t :: %__MODULE__{
          name: binary(),
          description: binary(),
          input_schema: map(),
          run: (map() -> result()) | (map(), map() -> result()),
          approval: :required | :never | (map(), map() -> decision())
        }

  @enforce_keys [:name, :description, :input_schema, :run]
  defstruct [:name, :description, :input_schema, :run, approval: :never]

  @spec approval(t(), map(), map()) :: decision()
  def approval(%__MODULE__{approval: fun}, input, ctx) when is_function(fun, 2),
    do: fun.(input, ctx)

  def approval(%__MODULE__{approval: approval}, _input, _ctx), do: approval

  @spec call(t(), map(), map()) :: result()
  def call(%__MODULE__{run: run}, input, _ctx) when is_function(run, 1), do: run.(input)
  def call(%__MODULE__{run: run}, input, ctx), do: run.(input, ctx)

  @doc "Checks required keys and primitive types from a flat JSON schema."
  @spec validate(t(), map()) :: :ok | {:error, binary()}
  def validate(%__MODULE__{input_schema: schema}, input) when is_map(input) do
    properties = schema["properties"] || %{}

    missing = Enum.reject(schema["required"] || [], &Map.has_key?(input, &1))

    wrong_type =
      for {key, value} <- input,
          type = get_in(properties, [key, "type"]),
          not type_matches?(type, value),
          do: "#{key} must be a #{type}"

    case Enum.map(missing, &"#{&1} is required") ++ wrong_type do
      [] -> :ok
      errors -> {:error, "Invalid input: " <> Enum.join(errors, ", ")}
    end
  end

  defp type_matches?("string", v), do: is_binary(v)
  defp type_matches?("integer", v), do: is_integer(v)
  defp type_matches?("number", v), do: is_number(v)
  defp type_matches?("boolean", v), do: is_boolean(v)
  defp type_matches?("object", v), do: is_map(v)
  defp type_matches?("array", v), do: is_list(v)
  defp type_matches?(_, _), do: true
end
