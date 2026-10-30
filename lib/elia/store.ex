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

  @doc """
  Saves a chat. `opts[:model]` is the chat's model selection (MODEL-1), kept
  alongside the messages when given.
  """
  @spec save(binary(), [Message.t()], keyword()) :: :ok | {:error, term()}
  def save(id, messages, opts \\ []) do
    true = valid_id?(id)
    File.mkdir_p!(dir())
    path = path(id)
    tmp = path <> ".tmp"

    chat = %{version: 1, messages: messages, updated_at: DateTime.utc_now()}
    chat = if model = opts[:model], do: Map.put(chat, :model, model), else: chat
    data = :erlang.term_to_binary(chat)

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

  @doc "The chat's saved model selection, or `nil` (STORE-9)."
  @spec load_model(binary()) :: map() | nil
  def load_model(id) do
    with true <- valid_id?(id),
         {:ok, data} <- File.read(path(id)),
         %{model: %{} = model} <- decode(data) do
      model
    else
      _ -> nil
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

  defp ensure_app_loaded do
    unless :persistent_term.get({__MODULE__, :app_loaded}, false) do
      {:ok, modules} = :application.get_key(:elia, :modules)
      Code.ensure_all_loaded(modules)
      :persistent_term.put({__MODULE__, :app_loaded}, true)
    end
  end

  defp path(id), do: Path.join(dir(), id <> ".term")

  # `:safe` refuses atoms that don't exist yet. In dev, modules load lazily,
  # so after a restart atoms like `:tool_call` may not exist until the code
  # that defines them is loaded; load it all first (STORE-3).
  defp decode(data) do
    ensure_app_loaded()
    :erlang.binary_to_term(data, [:safe])
  rescue
    ArgumentError -> nil
  end
end
