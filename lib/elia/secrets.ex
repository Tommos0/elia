defmodule Elia.Secrets do
  @moduledoc """
  A project's secrets: the variables of the `.env` file in the project's folder
  (`specs/project-secrets.md`).

  The file is read and never written. Its variables are what a command of a chat
  in that project gets in its environment (SECRET-5) and what the section naming
  the project's secrets in the system prompt lists (SECRET-12); its values are
  what `redact/2` takes out of a model request (SECRET-6), together with the API
  keys Elia holds for its providers (SECRET-7).

  Redaction is best effort: a value is matched as it stands, so an encoding of it
  is not covered (SECRET-11).
  """

  alias Elia.LLM
  alias Elia.LLM.Message

  # SECRET-1: the file is the project's own, in its folder (PROJ-1) — for Elia's
  # own project the live tree's (PROJ-3), however the chat works in it
  # (SECRET-3).
  @env_file ".env"

  # SECRET-7: a value shorter than this is redacted only when its name says it is
  # a secret, so an ordinary short setting (`PORT=4000`) does not turn every
  # `4000` in a transcript into a redaction.
  @min_length 8
  @name_words ~w(api auth cert credential key pass private salt secret signature token)

  @variable ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  ## The file

  @doc """
  A project's variables, in the order they first appear in its `.env`, each with
  the value of its last assignment (SECRET-1) — `[]` for a project with no file,
  one that cannot be read and one that holds no assignment (SECRET-2).
  """
  @spec variables(map() | nil) :: [{binary(), binary()}]
  def variables(project) do
    case folder(project) do
      nil -> []
      folder -> read(Path.join(folder, @env_file))
    end
  end

  @doc "The variables of one `.env` file, as `variables/1` reads them."
  @spec read(Path.t()) :: [{binary(), binary()}]
  def read(path) do
    case File.read(path) do
      {:ok, text} -> parse(text)
      {:error, _reason} -> []
    end
  end

  @doc """
  The names of a project's secrets, in order — what the system prompt names and
  never their values (SECRET-12).
  """
  @spec names(map() | nil) :: [binary()]
  def names(project), do: Enum.map(variables(project), &elem(&1, 0))

  @doc """
  The values to redact, longest first (SECRET-9), each with the name it is
  reported as in the placeholder (SECRET-6, SECRET-7).
  """
  @spec secrets(map() | nil) :: [{binary(), binary()}]
  def secrets(project) do
    from_file =
      for {name, value} <- variables(project), redactable?(name, value), do: {value, name}

    (from_file ++ provider_keys())
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(fn {value, _name} -> -byte_size(value) end)
  end

  ## Redaction

  @doc """
  `request` with every exact occurrence of a secret's value replaced by
  `[redacted:<name>]` (SECRET-6, SECRET-8).

  The whole request is covered — the system prompt, the tool definitions and
  every message's text, reasoning, tool call inputs and tool results, and the
  provider's own raw form of a block, which an adapter sends back as it came
  (LLM-5). What is redacted is the request alone: the transcript keeps the text
  a message or a result actually held (SECRET-10).
  """
  @spec redact(map(), map() | nil) :: map()
  def redact(request, project) do
    case secrets(project) do
      [] -> request
      secrets -> walk(request, %{regex: regex(secrets), names: Map.new(secrets)})
    end
  end

  @doc """
  One string with its secrets redacted (SECRET-6) — `redact/2`'s own step, for a
  caller that holds text rather than a request.
  """
  @spec redact_text(binary(), map() | nil) :: binary()
  def redact_text(text, project) do
    case secrets(project) do
      [] -> text
      secrets -> replace(text, %{regex: regex(secrets), names: Map.new(secrets)})
    end
  end

  # SECRET-9: one pass over the text, longest value first, so a value that
  # contains another is matched whole, neither is left half redacted, and a
  # placeholder a replacement wrote is never itself redacted.
  defp regex(secrets) do
    pattern = secrets |> Enum.map(&Regex.escape(elem(&1, 0))) |> Enum.join("|")

    case Regex.compile(pattern) do
      {:ok, regex} -> regex
      {:error, _reason} -> nil
    end
  end

  defp replace(text, %{regex: nil}), do: text

  defp replace(text, %{regex: regex, names: names}) do
    Regex.replace(regex, text, fn value -> "[redacted:#{Map.get(names, value, value)}]" end)
  end

  # SECRET-8: everything a request carries, walked rather than enumerated, so a
  # shape this module does not know about is still covered. A struct is left as
  # it is (only `%Message{}` is part of a request, and its `meta` is never sent,
  # LLM-5); a picture's own bytes are left alone (VISION-8).
  defp walk(%Message{} = message, secrets) do
    %{message | content: Enum.map(message.content, &walk(&1, secrets))}
  end

  defp walk(map, secrets) when is_map(map) and not is_struct(map) do
    if image?(map) do
      Map.new(map, fn {key, value} ->
        if data?(key), do: {key, value}, else: {key, walk(value, secrets)}
      end)
    else
      Map.new(map, fn {key, value} -> {key, walk(value, secrets)} end)
    end
  end

  defp walk(struct, _secrets) when is_struct(struct), do: struct

  defp walk(tuple, secrets) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&walk(&1, secrets)) |> List.to_tuple()
  end

  defp walk(list, secrets) when is_list(list), do: Enum.map(list, &walk(&1, secrets))
  defp walk(text, secrets) when is_binary(text), do: replace(text, secrets)
  defp walk(other, _secrets), do: other

  defp image?(map), do: Map.get(map, :type) == :image or Map.get(map, "type") == "image"
  defp data?(key), do: key in [:data, "data"]

  ## What is a secret

  defp redactable?(_name, ""), do: false
  defp redactable?(_name, value) when not is_binary(value), do: false
  defp redactable?(name, value), do: byte_size(value) >= @min_length or secret_name?(name)

  defp secret_name?(name) do
    down = String.downcase(name)
    Enum.any?(@name_words, &String.contains?(down, &1))
  end

  # SECRET-7: the keys Elia holds for its providers are secrets whatever their
  # length — there is no doubt what they are — and the name the placeholder
  # reports is the variable the provider's own documentation uses.
  defp provider_keys do
    for %{key: key} <- LLM.providers(),
        value = key_value(key),
        is_binary(value) and String.trim(value) != "",
        do: {value, String.upcase(key) <> "_API_KEY"}
  end

  defp key_value(key) do
    case LLM.api_key(key) do
      {_source, value} -> value
      nil -> nil
    end
  end

  ## Parsing

  defp folder(%{folder: folder}) when is_binary(folder) and folder != "", do: folder
  defp folder(_project), do: nil

  # SECRET-1: a repeated name takes the value of its last line, and keeps the
  # place of its first — the order the names are listed in (SECRET-12).
  defp parse(text) do
    pairs = text |> String.split("\n") |> Enum.flat_map(&assignment/1)
    values = Map.new(pairs)

    pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.map(&{&1, Map.fetch!(values, &1)})
  end

  defp assignment(line) do
    line = line |> String.trim() |> strip_export()

    cond do
      line == "" -> []
      String.starts_with?(line, "#") -> []
      true -> put_assignment(line)
    end
  end

  defp strip_export("export " <> rest), do: String.trim_leading(rest)
  defp strip_export(line), do: line

  defp put_assignment(line) do
    case String.split(line, "=", parts: 2) do
      [name, value] -> variable(String.trim(name), String.trim(value))
      _no_value -> []
    end
  end

  defp variable(name, value) do
    if Regex.match?(@variable, name), do: [{name, unquote_value(value)}], else: []
  end

  # A value's matching quotes are not part of it; anything else is left as it is,
  # including a quote that is only at one end.
  defp unquote_value(<<quote, rest::binary>>) when quote in [?", ?'] do
    if String.ends_with?(rest, <<quote>>) do
      binary_part(rest, 0, byte_size(rest) - 1)
    else
      <<quote>> <> rest
    end
  end

  defp unquote_value(value), do: value
end
