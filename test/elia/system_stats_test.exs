defmodule Elia.SystemStatsTest do
  use ExUnit.Case, async: true

  alias Elia.SystemStats

  @stat """
  cpu  100 0 100 700 100 0 0 0 0 0
  cpu0 50 0 50 350 50 0 0 0 0 0
  cpu1 50 0 50 350 50 0 0 0 0 0
  intr 12345
  """

  @stat_later """
  cpu  200 0 200 800 200 0 0 0 0 0
  cpu0 150 0 50 350 50 0 0 0 0 0
  cpu1 50 0 150 450 150 0 0 0 0 0
  """

  # SYS-2
  test "cpu usage counts idle and iowait as idle, overall and per core" do
    prev = SystemStats.parse_stat(@stat)
    cur = SystemStats.parse_stat(@stat_later)

    assert %{total: total, cores: [core0, core1]} = SystemStats.cpu_usage(prev, cur)
    assert_in_delta total, 50.0, 0.01
    assert_in_delta core0, 100.0, 0.01
    assert_in_delta core1, 100 / 3, 0.01
  end

  # SYS-2
  test "cpu usage is unknown with a single sample" do
    assert SystemStats.cpu_usage(nil, SystemStats.parse_stat(@stat)) == nil
  end

  # SYS-3
  test "memory used is total minus available, swap used is total minus free" do
    meminfo = """
    MemTotal:       1000 kB
    MemFree:         100 kB
    MemAvailable:    400 kB
    Buffers:          10 kB
    Cached:           90 kB
    SwapTotal:       200 kB
    SwapFree:        150 kB
    """

    assert %{total: 1_024_000, used: 614_400, cached: 102_400, swap_used: 51_200} =
             SystemStats.parse_meminfo(meminfo)
  end

  # SYS-4
  test "df parsing skips pseudo and zero-size filesystems" do
    df = """
    Filesystem     Type  1024-blocks    Used Available Capacity Mounted on
    udev           devtmpfs  8045672       0   8045672       0% /dev
    tmpfs          tmpfs     1614656    1196   1613460       1% /run
    /dev/nvme0n1p2 ext4    100     25        75      25% /
    /dev/sdb1      ext4    200    180        20      90% /mnt/my disk
    none           fuse        0       0         0       -  /mnt/empty
    """

    assert [root, data] = SystemStats.parse_df(df)
    assert %{mount: "/", device: "/dev/nvme0n1p2", type: "ext4", size: 102_400} = root
    assert_in_delta root.pct, 25.0, 0.01
    assert data.mount == "/mnt/my disk"
    assert_in_delta data.pct, 90.0, 0.01
  end

  # SYS-5
  test "network rates exclude loopback and clamp counter resets" do
    dev = fn rx, tx ->
      """
      Inter-|   Receive                                                |  Transmit
       face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
          lo: 999 1 0 0 0 0 0 0 999 1 0 0 0 0 0 0
        eth0: #{rx} 1 0 0 0 0 0 0 #{tx} 1 0 0 0 0 0 0
      """
    end

    prev = %{at: 0, net: SystemStats.parse_net_dev(dev.(1000, 5000))}
    cur = %{at: 2000, net: SystemStats.parse_net_dev(dev.(3000, 10))}

    assert [%{name: "eth0", rx: 1000.0, tx: +0.0}] = SystemStats.net_rates(prev, cur)
    assert SystemStats.net_rates(nil, cur) == nil
  end

  # SYS-1
  test "missing sources make only their section unavailable" do
    dir = Path.join(System.tmp_dir!(), "elia-proc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "loadavg"), "0.50 0.25 0.10 1/100 1234\n")
    File.write!(Path.join(dir, "stat"), "garbage\n")

    sample = SystemStats.sample(dir)
    assert sample.load == [0.5, 0.25, 0.1]
    assert sample.cpu == nil
    assert sample.memory == nil
    assert sample.net == nil
    assert sample.uptime == nil
    assert is_map(sample.vm)
  end

  # SYS-6
  test "samples the live host and VM" do
    sample = SystemStats.sample()
    assert sample.vm.processes > 0
    assert sample.vm.elixir == System.version()
  end

  # SYS-9
  test "levels" do
    assert SystemStats.level(74.9) == :normal
    assert SystemStats.level(75) == :high
    assert SystemStats.level(89.9) == :high
    assert SystemStats.level(90) == :critical
    assert SystemStats.level(nil) == :normal
  end

  # SYS-10
  test "formats bytes in binary units" do
    assert SystemStats.format_bytes(512) == "512 B"
    assert SystemStats.format_bytes(1536) == "1.5 KiB"
    assert SystemStats.format_bytes(5 * 1024 ** 3) == "5.0 GiB"
    assert SystemStats.format_bytes(3 * 1024 ** 4) == "3.0 TiB"
  end
end
