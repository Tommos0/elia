defmodule Elia.SystemStats do
  @moduledoc """
  Host and VM metrics for the System page, read from Linux `/proc` and `df`.

  `sample/1` takes a point-in-time snapshot. Rates (CPU usage, network
  throughput) need two snapshots: see `cpu_usage/2` and `net_rates/2`. Any
  section whose source is missing or unreadable is `nil` (SYS-1).
  """

  # SYS-4
  @pseudo_fs ~w(tmpfs devtmpfs efivarfs squashfs overlay proc sysfs)

  @doc """
  Takes a snapshot. `proc` is the procfs root, overridable for tests.
  """
  def sample(proc \\ "/proc") do
    read = &read(proc, &1, &2)

    %{
      at: System.monotonic_time(:millisecond),
      cpu: read.("stat", &parse_stat/1),
      memory: read.("meminfo", &parse_meminfo/1),
      load: read.("loadavg", &parse_loadavg/1),
      uptime: read.("uptime", &parse_uptime/1),
      net: read.("net/dev", &parse_net_dev/1),
      kernel: read.("sys/kernel/osrelease", &String.trim/1),
      cpu_model: read.("cpuinfo", &parse_cpu_model/1),
      disks: disks(),
      host: hostname(),
      vm: vm()
    }
  end

  defp read(proc, file, parse) do
    case File.read(Path.join(proc, file)) do
      {:ok, text} -> parse.(text)
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  CPU usage between two `/proc/stat` samples as `%{total: pct, cores: [pct]}`,
  or `nil` when either sample is missing (SYS-2).
  """
  def cpu_usage(nil, _), do: nil
  def cpu_usage(_, nil), do: nil

  def cpu_usage(prev, cur) do
    %{
      total: busy_pct(prev.total, cur.total),
      cores: Enum.zip_with(prev.cores, cur.cores, &busy_pct/2)
    }
  end

  defp busy_pct({busy0, total0}, {busy1, total1}) do
    case total1 - total0 do
      dt when dt > 0 -> min(100.0, max(0.0, (busy1 - busy0) / dt * 100))
      _ -> 0.0
    end
  end

  @doc """
  Per-interface byte rates between two samples, as
  `[%{name, rx, tx}]` sorted by name (SYS-5). `nil` without both samples.
  """
  def net_rates(%{net: prev, at: t0}, %{net: cur, at: t1})
      when is_map(prev) and is_map(cur) and t1 > t0 do
    seconds = (t1 - t0) / 1000

    cur
    |> Enum.filter(fn {name, _} -> Map.has_key?(prev, name) end)
    |> Enum.map(fn {name, {rx, tx}} ->
      {rx0, tx0} = prev[name]
      %{name: name, rx: max(rx - rx0, 0) / seconds, tx: max(tx - tx0, 0) / seconds}
    end)
    |> Enum.sort_by(& &1.name)
  end

  def net_rates(_, _), do: nil

  @doc "Status for a percentage (SYS-9)."
  def level(pct) when is_number(pct) and pct >= 90, do: :critical
  def level(pct) when is_number(pct) and pct >= 75, do: :high
  def level(_), do: :normal

  @doc "Binary-unit byte formatting (SYS-10)."
  def format_bytes(n) when is_number(n) and n < 1024, do: "#{round(n)} B"

  def format_bytes(n) when is_number(n) do
    {value, unit} =
      Enum.reduce_while(~w(KiB MiB GiB TiB), {n / 1, "B"}, fn unit, {v, _} = acc ->
        if v >= 1024, do: {:cont, {v / 1024, unit}}, else: {:halt, acc}
      end)

    "#{:erlang.float_to_binary(value, decimals: 1)} #{unit}"
  end

  def format_bytes(_), do: "—"

  @doc "Formats seconds as e.g. `3d 4h 12m`."
  def format_duration(seconds) when is_number(seconds) do
    s = trunc(seconds)
    d = div(s, 86_400)
    h = div(rem(s, 86_400), 3600)
    m = div(rem(s, 3600), 60)

    cond do
      d > 0 -> "#{d}d #{h}h #{m}m"
      h > 0 -> "#{h}h #{m}m"
      true -> "#{m}m"
    end
  end

  def format_duration(_), do: "—"

  ## Parsers (public for tests)

  @doc false
  def parse_stat(text) do
    lines =
      for "cpu" <> _ = line <- String.split(text, "\n"),
          [id | fields] = String.split(line),
          do: {id, busy_total(fields)}

    case lines do
      [{"cpu", total} | cores] -> %{total: total, cores: Enum.map(cores, &elem(&1, 1))}
      _ -> nil
    end
  end

  # user nice system idle iowait irq softirq steal; guest time is already in user.
  defp busy_total(fields) do
    values = fields |> Enum.take(8) |> Enum.map(&String.to_integer/1)
    idle = Enum.at(values, 3, 0) + Enum.at(values, 4, 0)
    total = Enum.sum(values)
    {total - idle, total}
  end

  @doc false
  def parse_meminfo(text) do
    kb =
      for line <- String.split(text, "\n"),
          [key, value | _] <- [String.split(line, [":", " "], trim: true)],
          into: %{},
          do: {key, String.to_integer(value) * 1024}

    with %{"MemTotal" => total, "MemAvailable" => available} <- kb do
      swap_total = Map.get(kb, "SwapTotal", 0)

      %{
        total: total,
        available: available,
        used: total - available,
        cached: Map.get(kb, "Cached", 0) + Map.get(kb, "Buffers", 0),
        swap_total: swap_total,
        swap_used: swap_total - Map.get(kb, "SwapFree", 0)
      }
    else
      _ -> nil
    end
  end

  @doc false
  def parse_loadavg(text) do
    case String.split(text) do
      [a, b, c | _] -> Enum.map([a, b, c], &String.to_float/1)
      _ -> nil
    end
  end

  @doc false
  def parse_uptime(text) do
    case Float.parse(text) do
      {seconds, _} -> seconds
      :error -> nil
    end
  end

  @doc false
  def parse_net_dev(text) do
    for line <- String.split(text, "\n"),
        [name, counters] <- [String.split(line, ":", parts: 2)],
        name = String.trim(name),
        name != "lo",
        fields = String.split(counters),
        length(fields) >= 9,
        into: %{} do
      {name, {String.to_integer(Enum.at(fields, 0)), String.to_integer(Enum.at(fields, 8))}}
    end
  end

  @doc false
  def parse_cpu_model(text) do
    Enum.find_value(String.split(text, "\n"), fn
      "model name" <> rest -> rest |> String.split(":", parts: 2) |> List.last() |> String.trim()
      _ -> nil
    end)
  end

  @doc false
  def parse_df(text) do
    for line <- text |> String.split("\n", trim: true) |> Enum.drop(1),
        [device, type, size, used, avail, _cap | mount] <- [String.split(line)],
        type not in @pseudo_fs,
        size = String.to_integer(size),
        size > 0 do
      used = String.to_integer(used)

      %{
        device: device,
        type: type,
        mount: Enum.join(mount, " "),
        size: size * 1024,
        used: used * 1024,
        # df's own capacity: used / (used + available), reserved blocks excluded.
        pct: used / max(used + String.to_integer(avail), 1) * 100
      }
    end
  end

  ## Sources

  defp disks do
    # df exits non-zero when one mount is unreadable but still lists the rest.
    case System.cmd("df", ["-kPT"]) do
      {out, _} -> parse_df(out)
    end
  rescue
    _ -> nil
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> nil
    end
  end

  defp vm do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    %{
      memory: :erlang.memory(:total),
      processes: :erlang.system_info(:process_count),
      schedulers: :erlang.system_info(:schedulers_online),
      uptime: uptime_ms / 1000,
      elixir: System.version(),
      otp: to_string(:erlang.system_info(:otp_release))
    }
  end
end
