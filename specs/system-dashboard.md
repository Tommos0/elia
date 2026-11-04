# System dashboard

Status: Implemented

A System page shows the health of the machine Elia runs on: CPU, memory,
disks, network, load and the Erlang VM. It answers "is this box OK right
now?" without opening a terminal.

## Requirements

### Collection

- **SYS-1** Host metrics come from Linux `/proc` and `df`. Each section
  (CPU, memory, load, uptime, disks, network) is collected independently: a
  missing or unreadable source makes that section show "Unavailable" while
  the others still render.
- **SYS-2** CPU usage is the share of non-idle time (idle + iowait count as
  idle) between two consecutive samples of `/proc/stat`, overall and per
  core. With fewer than two samples, usage is unknown.
- **SYS-3** Memory comes from `/proc/meminfo`: used is `MemTotal -
  MemAvailable`; swap used is `SwapTotal - SwapFree`.
- **SYS-4** Disks come from `df -kPT`. Pseudo filesystems (`tmpfs`,
  `devtmpfs`, `efivarfs`, `squashfs`, `overlay`, `proc`, `sysfs`) and
  zero-size filesystems are excluded. Each disk shows its mount point,
  device, type, used, size and percentage used.
- **SYS-5** Network rates are bytes per second received and sent per
  interface, from the difference between two samples of `/proc/net/dev`
  divided by the elapsed time. The loopback interface is excluded. Counters
  that go backwards (interface reset) count as zero.
- **SYS-6** The page also shows the load averages (1, 5, 15 min) next to the
  core count, system uptime, hostname, kernel release, CPU model, and Erlang
  VM stats: total memory, process count, scheduler count, VM uptime and the
  Elixir and OTP versions.

### System page

- **SYS-7** `/system` shows the metrics above and refreshes every 2 seconds
  while connected, without a reload.
- **SYS-8** The page keeps the last 60 overall CPU and memory readings and
  draws each as a sparkline.
- **SYS-9** Percentages (CPU, memory, swap, disks) have a status: below 75%
  is normal, 75% to below 90% is "High", 90% and above is "Critical". High
  and critical values show their label as text, not only as a colour.
- **SYS-10** Byte counts are shown in binary units (B, KiB, MiB, GiB, TiB)
  with one decimal above bytes; rates add "/s".
- **SYS-11** The app header has a "System" link to `/system`.
- **SYS-12** `/system` is as wide as the screen, never wider: its rows of cards
  — the tiles (SYS-7), the CPU-cores and memory row, and the interfaces and VM
  row — are the screen's width on a phone, one column of them, rather than
  growing to their contents. The page's own scroll area (`#system-scroll`) has
  no horizontal overflow at a phone width.

## Out of scope

- Non-Linux hosts (sections show "Unavailable").
- History beyond the page's own 60 readings, alerts, or per-process lists.
- Access control: like Sessions, anyone who can reach the app sees it.

## Implementation

`Elia.SystemStats` (collection and parsing), `EliaWeb.SystemLive`.

## Tests

`test/elia/system_stats_test.exs`, `test/elia_web/live/system_live_test.exs`,
`test/elia_web/browser/small_screen_layout_test.exs` (SYS-12 at a phone width).
