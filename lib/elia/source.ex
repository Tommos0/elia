defmodule Elia.Source do
  @moduledoc """
  The function definitions a workspace's own source holds
  (`specs/function-links.md`, FUNC-4 to FUNC-6, FUNC-9, FUNC-10): the module
  each file defines, and for every function its name, the arities it answers to
  and the line its definition starts on.

  A chat's source is its own workspace's (FUNC-4, PROJ-12) — the workspace a file
  mention resolves in (FLINK-5) — so a mention links the definition as that chat
  has it. Reading is cheap after the first time: the parsed definitions are kept
  while the files they were made from are unchanged (`Elia.Source.Cache`), as the
  spec corpus is (`Elia.Specs.Cache`, CITE-4).
  """

  alias Elia.Source.Cache

  # FUNC-9: the workspace's own source. `deps`, `_build` and `.elia` are
  # protected (WS-1), `node_modules` is a dependency's as `deps` is, and `tmp`
  # holds the worktrees a chat makes (DEPLOY-28) — copies of the tree, not the
  # tree itself.
  @skipped ~w(deps _build tmp node_modules)

  # FUNC-5
  @kinds [:def, :defp, :defmacro, :defmacrop, :defdelegate]

  @typedoc """
  A function's definition: the file it is written in, relative to the workspace
  root, and the 1-based line its head starts on (FUNC-5).
  """
  @type definition :: %{path: String.t(), line: pos_integer()}

  @doc """
  Every definition `root`'s own source holds, by `Module.name/arity` (FUNC-4,
  FUNC-6), each at the line it is written (FUNC-5). A module that several files
  define is the one whose path sorts first (FUNC-10).
  """
  @spec definitions(String.t()) :: %{String.t() => definition()}
  def definitions(root) when is_binary(root) do
    files = files(root)
    stamps = for path <- files, do: {path, stamp(path)}
    written_at = newest_mtime(stamps)

    # FUNC-4: an entry is reused only while the files are the same ones *and*
    # the read happened in a later second than the newest of them — see
    # `newest_mtime/1`.
    case Cache.fetch(root, stamps) do
      {read_at, definitions} when read_at > written_at -> definitions
      _ -> read(root, files, stamps)
    end
  end

  @doc """
  The definition of `name` with `arity` in `module`, as `root`'s own source has
  it (FUNC-4, FUNC-5), or `nil` when that module or that arity is not defined
  there.
  """
  @spec definition(String.t(), String.t(), String.t(), non_neg_integer()) :: definition() | nil
  def definition(root, module, name, arity)
      when is_binary(root) and is_binary(module) and is_binary(name) and is_integer(arity) do
    Map.get(definitions(root), "#{module}.#{name}/#{arity}")
  end

  # FUNC-10: a module is the one its first file defines, so a definition of it in
  # a later file is left out — the module is not that file's. Within one file
  # every `defmodule` of the module it names is kept.
  defp read(root, files, stamps) do
    {definitions, _modules} =
      files
      |> Enum.flat_map(&entries(&1, root))
      |> Enum.reduce({%{}, %{}}, fn {module, key, %{path: path} = definition}, {defs, modules} ->
        case Map.fetch(modules, module) do
          {:ok, ^path} -> {Map.put(defs, key, definition), modules}
          {:ok, _other} -> {defs, modules}
          :error -> {Map.put(defs, key, definition), Map.put(modules, module, path)}
        end
      end)

    Cache.put(root, stamps, {System.system_time(:second), definitions})
    definitions
  end

  # FUNC-9: every `.ex` and `.exs` file of the workspace's own source, by path.
  defp files(root), do: root |> collect([]) |> Enum.sort()

  defp collect(dir, acc) do
    case File.ls(dir) do
      {:ok, names} -> Enum.reduce(names, acc, &collect_entry(Path.join(dir, &1), &2))
      _ -> acc
    end
  end

  defp collect_entry(path, acc) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        if skipped?(path), do: acc, else: collect(path, acc)

      {:ok, %File.Stat{type: :regular}} ->
        if String.ends_with?(Path.basename(path), [".ex", ".exs"]), do: [path | acc], else: acc

      # A symlink is not followed, so no file outside the workspace is read
      # through one (as a mention of a path through one links nothing, FLINK-5).
      _ ->
        acc
    end
  end

  defp skipped?(path) do
    name = Path.basename(path)
    name in @skipped or String.starts_with?(name, ".")
  end

  # FUNC-5: what each definition of a file is — the module it is inside, the
  # function named by each head, the arities the head makes, and the line it
  # starts on.
  defp entries(path, root) do
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(source) do
      walk(ast, [], Path.relative_to(path, root))
    else
      # FUNC-9: a file nothing can be read or parsed from is left out of the
      # source, never an error in the transcript.
      _ -> []
    end
  end

  defp walk({:defmodule, _meta, [name, [do: body]]}, modules, file) do
    case module(name, modules) do
      nil -> walk(body, modules, file)
      module -> walk(body, [module | modules], file)
    end
  end

  defp walk({:__block__, _meta, statements}, modules, file),
    do: Enum.flat_map(statements, &walk(&1, modules, file))

  defp walk({kind, meta, [head | _]}, [module | _], file) when kind in @kinds do
    case head(head) do
      {name, arities} ->
        for arity <- arities do
          {module, "#{module}.#{name}/#{arity}", %{path: file, line: meta[:line]}}
        end

      nil ->
        []
    end
  end

  defp walk(_other, _modules, _file), do: []

  # FUNC-5: a head may carry a guard — `def f(a) when is_integer(a)` — and a head
  # written without parentheses has no argument list at all.
  defp head({:when, _meta, [head | _guard]}), do: head(head)

  defp head({name, _meta, args}) when is_atom(name) do
    case arities(args) do
      nil -> nil
      arities -> {name, arities}
    end
  end

  defp head(_other), do: nil

  # FUNC-6: a default argument is one parameter that gives the function every
  # arity from its own up to the whole list, so `def f(a, b \\ 1)` is `f/1` and
  # `f/2`, and `f/0` names nothing there.
  defp arities(nil), do: [0]

  defp arities(args) when is_list(args) do
    total = length(args)
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    Enum.to_list((total - defaults)..total)
  end

  defp arities(_args), do: nil

  # FUNC-5: a module is the one its `defmodule` names. `Elixir.` makes a name
  # absolute wherever it is written, and any other nested name is prefixed by the
  # module around it — `defmodule Inner` inside `Outer` is `Outer.Inner`.
  defp module({:__aliases__, _meta, parts}, modules) do
    case names(parts) do
      {:ok, ["Elixir" | absolute]} -> Enum.join(absolute, ".")
      {:ok, parts} -> Enum.join(Enum.reject([out(modules)], &is_nil/1) ++ parts, ".")
      :error -> nil
    end
  end

  defp module(_name, _modules), do: nil

  defp names(parts) when is_list(parts) and parts != [] do
    names = Enum.map(parts, &part/1)
    if Enum.all?(names, &is_binary/1), do: {:ok, names}, else: :error
  end

  defp names(_parts), do: :error

  defp part(name) when is_atom(name), do: Atom.to_string(name)
  defp part(_other), do: nil

  defp out([module | _]), do: module
  defp out([]), do: nil

  # FUNC-4: what a source is reused against — each file's size, inode and
  # modification time, as the spec corpus is (CITE-4).
  defp stamp(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime, inode: inode}} -> {size, mtime, inode}
      _ -> nil
    end
  end

  # The newest modification time among the source's files. A file written in the
  # same second as the read that took it carries that second as its mtime, and a
  # second write in that same second would leave the stamp looking unchanged, so
  # a read no later than that second is not trusted: it is read again until a
  # read lands in a later second, after which any write moves the mtime and is
  # seen (as the corpus is read, CITE-4).
  defp newest_mtime(stamps) do
    stamps
    |> Enum.map(fn
      {_path, {_size, mtime, _inode}} -> mtime
      _ -> 0
    end)
    |> Enum.max(fn -> 0 end)
  end
end
