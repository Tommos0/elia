defmodule Elia.Tool do
  @moduledoc """
  A callable tool exposed to the model.

  `run` receives the decoded input map (and, for arity 2, a context map with
  `:session_id` and `:turn_id`) and returns `{:ok, output}` or
  `{:error, output}`; both outputs are strings sent back to the model.

  `approval` is `:required`, `:never`, or a function of `(input, ctx)`
  returning one of those or `{:deny, reason}`. Calls that need approval
  pause the agent until the user decides.

  `asks_user` marks a tool whose call is put to the user instead of running
  straight away: the loop waits for their answer and hands it to the tool as
  `ctx[:answer]` when it runs (LOOP-21, ASK-1).
  """

  @type result :: {:ok, binary()} | {:error, binary()}
  @type decision :: :required | :never | {:deny, binary()}

  @type t :: %__MODULE__{
          name: binary(),
          description: binary(),
          input_schema: map(),
          run: (map() -> result()) | (map(), map() -> result()),
          approval: :required | :never | (map(), map() -> decision()),
          asks_user: boolean()
        }

  @enforce_keys [:name, :description, :input_schema, :run]
  defstruct [:name, :description, :input_schema, :run, approval: :never, asks_user: false]

  @spec approval(t(), map(), map()) :: decision()
  def approval(%__MODULE__{approval: fun}, input, ctx) when is_function(fun, 2),
    do: fun.(input, ctx)

  def approval(%__MODULE__{approval: approval}, _input, _ctx), do: approval

  @spec call(t(), map(), map()) :: result()
  def call(%__MODULE__{run: run}, input, _ctx) when is_function(run, 1), do: run.(input)
  def call(%__MODULE__{run: run}, input, ctx), do: run.(input, ctx)

  @doc """
  Checks required keys and primitive types from a flat JSON schema, and, for an
  array, the type of its items and any `maxItems` (LOOP-8).
  """
  @spec validate(t(), map()) :: :ok | {:error, binary()}
  def validate(%__MODULE__{input_schema: schema}, input) when is_map(input) do
    properties = schema["properties"] || %{}

    missing =
      for key <- schema["required"] || [], not Map.has_key?(input, key), do: "#{key} is required"

    wrong =
      Enum.flat_map(input, fn {key, value} ->
        property = properties[key] || %{}
        type = property["type"]

        if type_matches?(type, value),
          do: array_errors(key, value, property),
          else: ["#{key} must be a #{type}"]
      end)

    case missing ++ wrong do
      [] -> :ok
      errors -> {:error, "Invalid input: " <> Enum.join(errors, ", ")}
    end
  end

  # LOOP-8: an array's items have a type of their own, and a schema can cap how
  # many there are (ASK-1 asks for at most six options).
  defp array_errors(key, value, property) when is_list(value) do
    bad_items =
      case property["items"] do
        %{"type" => type} ->
          Enum.any?(value, &(not type_matches?(type, &1))) &&
            "every item of #{key} must be a #{type}"

        _ ->
          false
      end

    max = property["maxItems"]

    too_many =
      (is_integer(max) and length(value) > max) && "#{key} must have at most #{max} items"

    Enum.filter([bad_items, too_many], &is_binary/1)
  end

  defp array_errors(_key, _value, _property), do: []

  defp type_matches?("string", v), do: is_binary(v)
  defp type_matches?("integer", v), do: is_integer(v)
  defp type_matches?("number", v), do: is_number(v)
  defp type_matches?("boolean", v), do: is_boolean(v)
  defp type_matches?("object", v), do: is_map(v)
  defp type_matches?("array", v), do: is_list(v)
  defp type_matches?(_, _), do: true
end
