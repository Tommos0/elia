defmodule Elia.Store do
  @moduledoc """
  Saves conversations as Erlang term files under `.elia/sessions/`.

  Terms (rather than JSON) keep provider-specific raw blocks exact, which
  matters because they are echoed back to the provider unchanged.
  """

  alias Elia.LLM.Message

  @id_format ~r/^[A-Za-z0-9_-]{1,64}$/

  def dir, do: Path.join(Elia.Workspace.data_dir(), "sessions")

  def valid_id?(id), do: is_binary(id) and Regex.match?(@id_format, id)

  @spec save(binary(), [Message.t()]) :: :ok | {:error, term()}
  def save(id, messages) do
    true = valid_id?(id)
    File.mkdir_p!(dir())
    path = path(id)
    tmp = path <> ".tmp"

    data =
      :erlang.term_to_binary(%{version: 1, messages: messages, updated_at: DateTime.utc_now()})

    with :ok <- File.write(tmp, data), do: File.rename(tmp, path)
  end

  @spec load(binary()) :: [Message.t()]
  def load(id) do
    with true <- valid_id?(id),
         {:ok, data} <- File.read(path(id)),
         %{messages: messages} <- decode(data) do
      messages
    else
      _ -> []
    end
  end

  @doc "Saved conversations, most recently updated first."
  def list(limit \\ 50) do
    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".term"))
        |> Enum.map(fn file -> {file, File.stat!(Path.join(dir(), file), time: :posix).mtime} end)
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.take(limit)
        |> Enum.map(fn {file, mtime} ->
          id = Path.rootname(file)
          %{id: id, title: title(load(id)), updated_at: mtime}
        end)

      {:error, _} ->
        []
    end
  end

  def delete(id), do: if(valid_id?(id), do: File.rm(path(id)), else: {:error, :invalid_id})

  @doc "Display title for a conversation: its first user message, truncated."
  def title(messages) do
    case Enum.find(messages, &(&1.role == :user and not Map.get(&1.meta, :harness, false))) do
      nil -> "New chat"
      message -> message |> Message.text_content() |> String.slice(0, 60)
    end
  end

  defp path(id), do: Path.join(dir(), id <> ".term")

  defp decode(data) do
    :erlang.binary_to_term(data, [:safe])
  rescue
    ArgumentError -> nil
  end
end
