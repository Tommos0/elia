# Command isolation

Status: Draft

Every OS process Elia spawns for a tool call runs inside a bubblewrap jail: a
fresh mount namespace holding the workspace and the toolchain and nothing else,
and a fresh pid namespace whose `/proc` doesn't show the server. A command
therefore can't read the settings database with the provider API keys (CONF-1),
the saved conversations under `.elia/sessions` (STORE), or the user's
credentials (`~/.git-credentials`, `~/.ssh`, `~/.config/gh`, `~/.netrc`) — not
even when the command is code the model wrote itself, such as a test file run
by `run_tests` (VERIFY), which needs no approval (APPR-7).

Without it the harness and the shell run as the same user, so the approval
prompt is the only safeguard (SHELL-7): a command that reads like a build step
can be one the model was talked into writing, and reading a key needs nothing
more than `cat`. The jail doesn't depend on the model behaving. It is a
per-chat setting, on by default, that the user can turn off for work that
genuinely needs the rest of the machine (ISOL-16).

## Requirements

### Where it applies

- **ISOL-1** Every process Elia runs for a tool call is jailed by default: the
  `shell` tool (SHELL-1), `run_tests` (VERIFY-1), a folder skill's script tools
  (FOLDER), and the `git` calls the harness itself makes in a chat's workspace
  (DEPLOY-9, SUBTASK). All of them go through `Elia.Shell.run/2`; the
  `System.cmd("git", …)` calls in `Elia.Tasks` and `Elia.Deploy` move behind it,
  since they bypass it today. A git call that times out counts as a failure,
  like one that exits non-zero (ISOL-10).
- **ISOL-2** The jail is bubblewrap, run as the same user with no privileges:
  `--die-with-parent`, `--unshare-pid`, `--unshare-uts`, `--unshare-ipc`,
  `--unshare-cgroup-try`, `--proc /proc`, `--dev /dev`, `--tmpfs /tmp`, and
  `--chdir` to the workspace. The hostname is the host's, which bubblewrap
  inherits, so a process that derives a name from it behaves as it does outside
  — this host's commits use exactly that fallback (git's author identity is
  `user@host`, with no `user.name` configured anywhere).
- **ISOL-3** A bind is made at the same absolute path as its source, since
  bubblewrap doesn't rewrite paths: an absolute symlink inside the workspace —
  a chat worktree's `deps` (DEPLOY-5) — resolves inside the jail as it does
  outside.
- **ISOL-4** The jail holds exactly what ISOL-13's profile lists, and, next to
  the workspace, only the read-only toolchain (`/usr`, `/lib`, `/lib64`, `/bin`,
  `/sbin`, `/etc`), `$HOME/.mix` read-write (mix archives live there), the
  browser cache the real-browser tests drive (`$HOME/.cache/ms-playwright`,
  read-only, when it exists) — browsers, not secrets — and the user-wide
  Playwright CLI (read-only, when it exists, ISOL-26). For a
  chat worktree it also holds the repository's git directory read-write, which
  commits need: the worktree's `.git` is a pointer file into
  `<live>/.git/worktrees/<id>`, whose common dir is `<live>/.git` (ISOL-3).
- **ISOL-5** Nothing else is bound, so nothing else exists inside. In
  particular the settings database (CONF-1) and everything under `$HOME` but
  what ISOL-4 lists — `~/.mix`, the browser cache and the Playwright CLI — are
  never bound, so a credential store is absent whatever path it has, and no
  command can reach it by a path of its own choosing.
- **ISOL-6** A workspace's *parent* isn't bound either: a chat's worktree is
  bound on its own, so `.elia/sessions` and the other chats' worktrees aren't in
  the jail. When the workspace is the live tree itself (DEPLOY-14) the tree is
  bound read-write and `.elia` is masked with an empty tmpfs *after* that bind:
  bubblewrap applies its mounts in argument order, so the later mask wins.
- **ISOL-7** The dependency tree a chat's commands compile against stays the
  live tree's: a chat worktree holds no dependency of its own — its `deps` is a
  symlink to the live tree's (DEPLOY-1) — so every worktree and the
  live tree compile the same sources. A compile can need to write inside that
  tree: `deps/phoenix` copies its installer templates into its own
  `priv/templates`, and `mix deps.get` unpacks a dependency the chat added. So
  for a chat's own commands the tree is mounted as an **overlay** (ISOL-13): the
  live tree's `deps` is the read-only lower layer and the worktree gets a
  writable upper layer of its own, under the live tree's data dir (DEPLOY-2). A
  command's write therefore succeeds and lands in that worktree's layer: what
  the live tree and every other chat compile against is unchanged by any
  command, and two worktrees never write the same file. The layer sits under
  the masked `.elia` (ISOL-6), so nothing inside the jail can reach it, and it
  goes when the worktree goes (DEPLOY-10).

  Nothing runs ahead of a command: there is no pre-compile and no `mix.lock`
  bookkeeping, nothing starts when a chat opens, and a chat that runs no command
  in its worktree compiles nothing at all. The first command that compiles the
  dependencies pays for it, as part of that command: it is a tool call the chat
  already shows as running (FEED), it needs no approval of its own, and it
  answers to the command's own timeout (SHELL-3) — ten minutes for `run_tests`
  (VERIFY-1), and whatever the model asks for with the `shell` tool.

  A dependency the chat adds is fetched into its own layer, so it stays that
  chat's until the change is deployed: the live tree gets it when the deploy
  fetches it there (DEPLOY-18). With the jail off (ISOL-16) there is no mount
  namespace to overlay in and commands in the worktree write the shared tree
  directly, as before.
- **ISOL-8** The environment is cleared and rebuilt from an allowlist: `PATH`,
  `HOME`, `LANG`, `TERM`, plus `MIX_ENV` and `GIT_*` only where the caller sets
  them. Nothing is inherited, so a key in the server's own environment (CONF-5)
  reaches no command.
- **ISOL-24** A command never builds in the environment the server happens to
  run in: `MIX_ENV` is absent whichever path it takes. A jailed command has
  none (ISOL-8), and an unjailed one (ISOL-12, ISOL-16) runs in a shell that
  unsets it — a port's environment can only add to the inherited one, so this is
  the only way — unless the caller passes a value itself. The server's own
  `MIX_ENV` (`bin/serve`'s, RESTART-8) is a property of the server, not of the
  commands it runs: inherited, it would make `mix` build in the server's `dev`
  even where the command's own project asks for another environment
  (`preferred_envs`, which Mix only honours when `MIX_ENV` is unset — so
  `mix precommit` would compile and test in `dev`). The harness's own steps that
  need `MIX_ENV=test` set it themselves (VERIFY-1) and are unaffected.
- **ISOL-9** The pid namespace and its fresh `/proc` mean the server process
  isn't visible and neither is its memory. (This host runs with
  `ptrace_scope=0`, so unjailed any command could read it.)
- **ISOL-10** A jailed command is otherwise unchanged: `bash -c` where bash is
  installed and POSIX `sh -c` otherwise, empty stdin, its own process group, the
  same timeout, output truncation and `[exit: …]` result (SHELL-2..SHELL-5). That
  process group is the runtime's doing — the VM starts a port program as its own
  session and process group leader — so the group kill on timeout reaches the
  command and everything it started. No `setsid` goes in front of it: `setsid`
  forks when it is already a group leader, and the pid the port reports would
  then be the wrapper's, in whose group the command is not. On timeout the jail
  is killed, which takes its whole pid namespace with it; with the jail off
  (ISOL-16, ISOL-20) the process-group kill does the work.
- **ISOL-11** The jail doesn't restrict the network, and it changes neither what
  a command may write inside its workspace nor what approval it needs (APPR,
  WS). It is a second line behind the approval prompt, not a replacement for it.
- **ISOL-12** When there is no jail — bubblewrap not installed, user namespaces
  not permitted (ISOL-20) — a command runs unjailed as it does today and its
  result says the jail was skipped, so a run that wasn't isolated never looks
  like one that was. The chat UI says the same (UI-68). A harness caller that
  reads a command's output as a value takes that notice off first
  (`Elia.Shell.jail_skipped_notice/0`), so it never becomes part of a ref, a path
  or a count.
- **ISOL-25** The file tools are confined to what the jail reaches (FILE-12,
  FILE-13): the trees a chat's commands can reach are the trees its file tools
  can read. What that is stays a property of the jail's profile (ISOL-13) and is
  asked for rather than reimplemented — `Elia.Shell.reachable?/2` says whether a
  jailed command in a given workspace can reach a path: the workspace, plus, for
  a chat worktree, the trees the profile also binds, and never a masked `.elia`
  (ISOL-6). The file tools run no process, so their confinement follows the jail
  decision (`Elia.Shell.wanted/1`: the chat's setting, ISOL-16, and the host's,
  ISOL-20) and not whether bubblewrap can build one (ISOL-12): a host that can't
  build the jail is still confined, and the chat's own setting is what turns the
  confinement off. A caller with no chat gets the default, which is on (ISOL-15).
- **ISOL-26** The jail reaches the user-wide Playwright CLI, so a jailed
  `mix test --only real_browser` and `bin/preview` work (BROWSER-2): the npm
  global packages `$HOME/.local/lib/node_modules/playwright` and
  `playwright-core` beside it — the CLI and the library it loads — are bound
  read-only, each when it exists, at the same absolute path as outside
  (ISOL-3). The directory that holds them (`$HOME/.local/lib`, from
  `:elia, :playwright_dir`) is where the config points the driver too, so the
  path a jailed run resolves is the path the driver was told to use. Nothing
  else of `$HOME/.local` is bound: `~/.local/bin`, `~/.local/share` and the
  rest stay absent, as ISOL-5 says. A host with no such install binds nothing
  and a browser run fails with the message BROWSER-10 names.

### Profiles

- **ISOL-13** The jail has three bind profiles:

  | Profile | For | Workspace | Shared `deps` | Repo git dir | `.elia` |
  | --- | --- | --- | --- | --- | --- |
  | `:worktree` | a chat's tool calls, when it works in its own worktree (DEPLOY-1) | rw | overlay: read-only lower, the worktree's own upper (ISOL-7) | rw | not bound |
  | `:deps_sync` | the harness's own steps in the live tree: the `git worktree` commands that create, remove or prune a worktree (ISOL-22). The name is historical — nothing syncs dependencies any more (ISOL-7) | rw | rw | rw | not bound |
  | `:live_tree` | a chat that works in the live tree (DEPLOY-14), the deploy's fetch (DEPLOY-18) and its suite run (ISOL-14) | rw | rw, inside the tree | inside the tree | masked empty |

- **ISOL-14** The deploy's fetch (`mix deps.get` in the live tree, DEPLOY-18)
  and its test run (`Elia.Deploy`, DEPLOY-5) are jailed with `:live_tree`, and no
  chat's setting is involved: they run the merged trunk in the live tree, which
  needs write access there.
- **ISOL-15** The tool context carries the jail decision, like `:workspace`
  does, so the shell tools and `run_tests` jail a call according to the chat
  they run in. A caller with no chat — the deploy (ISOL-14) — gets the default,
  which is on.

### One jail for a step's commands

ISOL-7 has every command mount the worktree's dependency layer itself, so two
commands that a step runs at once mount the same layer at the same instant and
one of them fails before it runs: 35 such commands across 11 chats, every one of
them in a step that ran two or three shell commands (33 and 2), and never in a
step that ran one — 8.8% of the steps that run two or more lose one of their
commands. The model is told one of its commands failed and no command ran, which
costs the round trip as well as the command.

- **ISOL-26** The commands of one step share one jail. The command calls of a
  step (LOOP-10) — the `shell` tool (SHELL-1), `run_tests` (VERIFY-1), a folder
  skill's script tools (FOLDER) — that need the same profile (ISOL-13) run under
  one bubblewrap process, which mounts the worktree's dependency layer (ISOL-7)
  once instead of once per command. Each command is still its own process inside
  it, with its own `cd`, environment, output, `[exit: …]` result, truncation and
  timeout (SHELL-2..SHELL-5): a command that reaches its own timeout is killed on
  its own and its step-mates still report what they did. A killing that belongs
  to the turn rather than to one command — the user's stop (SESS-22), or the
  jail's own outer deadline (SHELL-3, VERIFY-1) — ends every command in it, and
  the results say so. The step's commands therefore share one `/tmp` tmpfs
  (ISOL-2) and one pid namespace, seeing each other's processes and files there
  for as long as the step runs; nothing survives into a later step, so the
  isolation between steps is unchanged. A call that needs another profile —
  `:deps_sync`, `:live_tree`, another project (PROJ-12), an unjailed call
  (ISOL-16) — can't share the jail and keeps one of its own.

- **ISOL-27** A jail that can't mount the worktree's dependency layer (ISOL-7)
  is tried once more, and then runs with the shared `deps` bound read-only — the
  fallback ISOL-7 already takes when the layer can't be made — with its result
  saying the shared tree was read-only, as a skipped jail says it wasn't jailed
  (ISOL-12). A command that could not be run at all is never reported as one that
  ran and failed. This is what covers a layer another jail in the same worktree
  holds — a chat's terminal session (TERM-7) — and any other mount failure: the
  command then fails on its own write and says what it could not write, exactly
  as it does where the layer can't be made at all.

### The per-chat setting

- **ISOL-16** Every chat has a jail setting, on by default: a chat whose file
  carries no value is jailed (STORE-26). It is saved with the chat (STORE-25),
  broadcast when it changes (SESS-30), so it survives a restart, and the user
  turns it off and on for one chat from that chat's settings page (UI-67,
  CSET-5).
- **ISOL-17** While a chat's jail is off, each approval prompt in that chat says
  the command runs unjailed (UI-69), so the state is visible at the moment it
  matters.
- **ISOL-18** The setting belongs to one chat. A sub-task starts with a copy of
  its parent's setting when it is spawned (SUBTASK-30) and its own from then on:
  changing either chat afterwards never affects the other.
- **ISOL-19** Turning the jail off loosens the file tools and nothing else: with
  the jail off the file tools may read outside the workspace again, with the
  user's approval (FILE-12, FILE-4), and nothing else reaches further —
  approval, the workspace policy's classes and the writes it refuses are
  unchanged (WS-1, FILE-5), no tool is auto-approved, and turning it back on
  affects only calls that come later — a command already running isn't killed.
- **ISOL-20** A host can turn the jail off for every chat (`config :elia,
  Elia.Shell, jail: false`), which is what a machine without bubblewrap does.
  A chat's own setting can only turn it off, never force it on where the host
  says no.

### Telling the model

- **ISOL-21** The `shell` tool's description and the skill's instructions say
  that a command runs in a jail by default, that the jail holds the workspace
  and the toolchain and nothing else, and that the settings database, the saved
  conversations and the user's credentials aren't in it — so a command that
  can't find them is expected, not broken (SHELL-8, SHELL-9). They say too that
  a chat whose jail the user turned off (ISOL-16) runs commands unjailed.

### The harness's own steps

- **ISOL-22** The harness's worktree administration — `git worktree add`,
  `remove` and `prune` — runs as a harness step under a profile that leaves
  `.elia` reachable (ISOL-13), because a chat's
  worktree is created *inside* `.elia/worktrees`. Under `:live_tree` the mask
  would swallow the new worktree and the command would still exit 0, having
  written nowhere the harness can see. Nothing the model wrote goes into these
  steps and their arguments are the harness's, fixed at the call site. This is
  the one place a jailed process has `.elia` in reach, and it is a deliberate
  trade: while such a step runs, the saved conversations are (ISOL-5, ISOL-6).
- ~~**ISOL-23** While a worktree's sync (ISOL-7) is in flight the chat says so
  (UI-70), covering a sync a chat started in the background and one a command is
  waiting for; for the latter it doubles as the command's "what am I waiting
  for". The indicator goes when the sync ends, whether it succeeded or failed. A
  failure leaves the chat usable: the command the sync was owed still runs, its
  result says the sync failed and a command that does need the dependencies
  fails with its own error.~~ Removed: nothing runs ahead of a command any more
  (ISOL-7). A command that compiles its worktree's dependencies is the command
  itself, and the chat already shows it as running (FEED) — there is no sync
  left to indicate.

## Configuration

```elixir
config :elia, Elia.Shell,
  jail: true,                 # false: no jail on this host, whatever a chat says
  bwrap: "/usr/bin/bwrap"     # resolved from PATH when unset
```

The suite runs with `jail: false` (`config/test.exs`), so it needs no
bubblewrap; the isolation tests turn the jail on per call and skip where
bubblewrap is missing (ISOL-12).

## Out of scope

- **Network isolation.** `--unshare-net` is one flag away, but a fresh network
  namespace has `lo` down and no route out, which breaks anything that talks to
  a local server or fetches dependencies — and the prompt itself is an egress
  channel, since whatever a command prints is sent to the provider. What the
  jail protects is the secrets, not the wire.
- **A uid per command.** A uid boundary is the stronger form of this: it holds
  even for a path a bind list forgets, and it isolates the credentials git
  itself needs. It needs a second user, a sudoers rule and group-shared
  worktrees; the mount namespace gets the secrets out of reach with no
  deployment change, so it comes first.
- **Which tools need approval.** With the jail on, `run_tests` runs
  model-written code where it can't reach a secret, so APPR-7 is left as it is.
- **Hex's own store (future work).** A jailed command gets no Hex store to keep.
  `$HOME` inside the jail is a fresh empty directory holding only the binds
  (ISOL-4), so the store Hex makes — `~/.hex/cache.bin`, the registry, and
  `~/.hex/packages/<repo>/<package>.tar` — is created for one command and goes
  with its mount namespace. Fetching still works (the network is reachable,
  ISOL-11: a jailed `mix hex.package fetch jason 1.4.4` downloads into that
  store), at the cost of fetching the registry and the packages again in every
  command that fetches — including a chat that adds a dependency (ISOL-7), which
  fetches it afresh in each command that builds it. A future fix gives a chat's
  commands somewhere to keep one: bind the shared `~/.hex` read-write for the
  `:worktree` profile, or keep a store per worktree under the data dir (DEPLOY-2)
  and remove it with the worktree (DEPLOY-10). Hex 2.6.0 names no variable that
  would move its store — its `HEX_*` variables are cooldown, HTTP timeout,
  repo-origin verification, offline, lock policy and registry verification — so
  a store of our own would have to be bound at that path. Mix's path variables
  are a separate matter: `MIX_DEPS_PATH` moves the deps directory and
  `MIX_BUILD_PATH` the build directory (both verified on Elixir 1.18.3), which
  is what a per-worktree deps directory would use instead of the overlay
  (ISOL-7).
- **Sanitising the shared dependency tree**, and `mix deps.get` for a project
  other than Elia's own — that project's `deps` is inside its workspace and
  writable there (ISOL-4).
- **A host whose kernel can't mount an overlay in a user namespace.** The
  overlay is the mechanism ISOL-7 rests on: without it a jailed compile has
  nowhere to write inside the shared `deps`, and such a host would need the
  pre-compile back, or a deps directory of the worktree's own (`MIX_DEPS_PATH`
  puts one there, at the cost of fetching into every worktree). Not built: the
  overlay mounts here (bubblewrap 0.12 on kernel 6.12, verified by mounting one
  in a namespace), and a host where it doesn't deserves a deliberate answer
  rather than a silent fallback.
- **One jail per chat, shared with its terminal** (the next step if a jail per
  step, ISOL-26, is not enough). One bubblewrap process for a chat's whole life
  would mount the layer once and cover the terminal session too (TERM-7), and
  save a bubblewrap start and mount per command. It needs supervision (a jail
  that dies is the whole chat's commands failing), a lifecycle tied to the
  worktree (DEPLOY-10), a way to end one command without ending the jail, and a
  decision about what the chat's commands may see of each other across steps —
  which ISOL-26 deliberately keeps out of reach.
- Seccomp filters, cgroup limits, and capping what a jailed command may write
  inside its own workspace.

## Implementation

`Elia.Shell` (the bubblewrap argv, the profiles, the environment allowlist, and
what a jailed command can reach — ISOL-25; `run/2` takes `:jail` and
`:profile`; and the shared jail of ISOL-26: one bubblewrap per step's commands,
with a protocol inside it giving each command its own output, status, deadline
and exit, `Elia.Agent.Loop` starting it with the step and ending it with the
step), `Elia.Skills.Shell`, `Elia.Skills.Folder`
and `Elia.Harness` (pass the chat's setting from the tool context),
`Elia.Skills.Files` (confines the file tools to the jail's reach, FILE-12),
`Elia.Agent.Session` (the setting, its event, its save), `Elia.Store`
(`save/3`'s `jail:`, `load_jail/1`), `Elia.Tasks` and `Elia.Deploy` (spawn `git`
through `Elia.Shell.run/2`, and the deploy's own fetch of the trunk's
dependencies, DEPLOY-18), `Elia.Deps` (a worktree's dependency layer: where it
lives, and its removal with the worktree, ISOL-7, DEPLOY-10),
`Elia.Tasks` (copy the parent's setting to the child, SUBTASK-30),
`EliaWeb.ChatLive` (the switch).

## Tests

`test/elia/shell_test.exs` (the argv, the profiles, the environment allowlist,
what a jailed command can reach, the fallback when bubblewrap is missing, and
the shared jail of ISOL-26: two commands of one step run under one jail with a
result each, one command's timeout doesn't end its step-mate, a step's jail is
gone before the next step runs, and a jail that can't mount the layer says the
shared tree was read-only — ISOL-27),
`test/elia/deps_test.exs` (a worktree's dependency layer: its path, its creation
and its removal, ISOL-7, DEPLOY-10),
`test/elia/command_isolation_test.exs`
(the settings path and `$HOME` absent, the browser cache and the user-wide
Playwright CLI bound read-only, ISOL-4, ISOL-26, the server pid not in `/proc`, the
workspace writable, a command writing inside the shared `deps` and leaving it
unchanged, a timeout still cleaning up, and the two shell commands of one step
both running under one jail — ISOL-26), `test/elia/harness_test.exs`
(`run_tests` jailed), `test/elia/deployment_test.exs` (the worktree
administration and the deploy's fetch, DEPLOY-18),
`test/elia/tasks_git_test.exs` (the harness's git calls),
`test/elia/self_modification_test.exs` (the file
tools' confinement, FILE-12, FILE-13),
`test/elia/store_test.exs` and `test/elia/tasks_test.exs` (the setting and its
inheritance), `test/elia_web/live/jail_test.exs` (UI-67..UI-69).

A test that needs the jail's effect skips when bubblewrap isn't available
(ISOL-12); the ones that build the argv don't.
