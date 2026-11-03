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
  `/sbin`, `/etc`), `$HOME/.mix` read-write (mix archives live there) and the
  browser cache the real-browser tests drive (`$HOME/.cache/ms-playwright`,
  read-only, when it exists) — browsers, not secrets. For a
  chat worktree it also holds the repository's git directory read-write, which
  commits need: the worktree's `.git` is a pointer file into
  `<live>/.git/worktrees/<id>`, whose common dir is `<live>/.git` (ISOL-3).
- **ISOL-5** Nothing else is bound, so nothing else exists inside. In
  particular the settings database (CONF-1) and everything under `$HOME` but
  `~/.mix` are never bound, so a credential store is absent whatever path it
  has, and no command can reach it by a path of its own choosing.
- **ISOL-6** A workspace's *parent* isn't bound either: a chat's worktree is
  bound on its own, so `.elia/sessions` and the other chats' worktrees aren't in
  the jail. When the workspace is the live tree itself (DEPLOY-14) the tree is
  bound read-write and `.elia` is masked with an empty tmpfs *after* that bind:
  bubblewrap applies its mounts in argument order, so the later mask wins.
- **ISOL-7** The shared dependency tree stays read-only where a command could
  reach it: a chat worktree's `deps` is the live tree's (DEPLOY-5) and is bound
  read-only (ISOL-13). A compile can need to write there — `deps/phoenix`
  copies `installer/templates/*.eex` into its own `priv/templates` — so the
  harness keeps it compiled itself: before the first jailed command in a
  worktree — one it just created, or one that predates this feature — and again
  whenever that worktree's `mix.lock` changes, it runs `mix deps.get` and
  `MIX_ENV=test mix deps.compile` in the worktree under the `:deps_sync`
  profile. `deps.get` finds the lock's dependencies already present in the
  shared tree and needs no network; only a changed `mix.lock` fetches. What it
  remembers is one value per worktree, the `mix.lock` it last synced with. This
  is a harness step, not a tool call: it needs no approval and the model doesn't
  choose it.

  It doesn't hold up the start of a chat: it runs in the background, and the
  first jailed command in a worktree that isn't synced yet waits for it, so no
  command ever compiles against a half-synced tree. Two syncs of the same `deps`
  never run at once: they would write the same files in the shared tree — a
  compile writes into a dependency's own tree, a fetch into the hex cache — and a
  file torn that way breaks every worktree that compiles against it. A failure
  isn't remembered (nothing is written), so the next command tries again.
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
  need `MIX_ENV=test` set it themselves (VERIFY-1, ISOL-7) and are unaffected.
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

### Profiles

- **ISOL-13** The jail has three bind profiles:

  | Profile | For | Workspace | Shared `deps` | Repo git dir | `.elia` |
  | --- | --- | --- | --- | --- | --- |
  | `:worktree` | a chat's tool calls, when it works in its own worktree (DEPLOY-1) | rw | ro | rw | not bound |
  | `:deps_sync` | the harness's own steps: `mix deps.get` / `deps.compile` (ISOL-7) and the `git worktree` commands that create, remove or prune a worktree (ISOL-22) | rw | rw | rw | not bound |
  | `:live_tree` | a chat that works in the live tree (DEPLOY-14) and the deploy's suite run (ISOL-14) | rw | rw, inside the tree | inside the tree | masked empty |

- **ISOL-14** The deploy's test run (`Elia.Deploy`, DEPLOY-5) is jailed with
  `:live_tree`, and no chat's setting is involved: it runs the merged trunk's
  suite in the live tree, which needs write access there.
- **ISOL-15** The tool context carries the jail decision, like `:workspace`
  does, so the shell tools and `run_tests` jail a call according to the chat
  they run in. A caller with no chat — the deploy (ISOL-14) — gets the default,
  which is on.

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
- **ISOL-19** Turning the jail off loosens nothing else: approval, the workspace
  policy and the file tools are unchanged, no tool is auto-approved, and turning
  it back on affects only calls that come later — a command already running
  isn't killed.
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
  `remove` and `prune`, and the dependency compile of ISOL-7 — runs as a harness
  step under a profile that leaves `.elia` reachable (ISOL-13), because a chat's
  worktree is created *inside* `.elia/worktrees`. Under `:live_tree` the mask
  would swallow the new worktree and the command would still exit 0, having
  written nowhere the harness can see. Nothing the model wrote goes into these
  steps and their arguments are the harness's, fixed at the call site. This is
  the one place a jailed process has `.elia` in reach, and it is a deliberate
  trade: while such a step runs, the saved conversations are (ISOL-5, ISOL-6).
- **ISOL-23** While a worktree's sync (ISOL-7) is in flight the chat says so
  (UI-70), covering a sync a chat started in the background and one a command is
  waiting for; for the latter it doubles as the command's "what am I waiting
  for". The indicator goes when the sync ends, whether it succeeded or failed. A
  failure leaves the chat usable: the command the sync was owed still runs, its
  result says the sync failed and a command that does need the dependencies
  fails with its own error.

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
- **Sanitising the shared dependency tree**, and `mix deps.get` for a project
  other than Elia's own — that project's `deps` is inside its workspace and
  writable there (ISOL-4).
- Seccomp filters, cgroup limits, and capping what a jailed command may write
  inside its own workspace.

## Implementation

`Elia.Shell` (the bubblewrap argv, the profiles, the environment allowlist;
`run/2` takes `:jail` and `:profile`), `Elia.Skills.Shell`, `Elia.Skills.Folder`
and `Elia.Harness` (pass the chat's setting from the tool context),
`Elia.Agent.Session` (the setting, its event, its save), `Elia.Store`
(`save/3`'s `jail:`, `load_jail/1`), `Elia.Tasks` and `Elia.Deploy` (spawn `git`
through `Elia.Shell.run/2`, and sync a worktree's deps before the first jailed
command in it), `Elia.DepsSync` (the sync itself),
`Elia.Tasks` (copy the parent's setting to the child, SUBTASK-30),
`EliaWeb.ChatLive` (the switch).

## Tests

`test/elia/shell_test.exs` (the argv, the profiles, the environment allowlist,
the fallback when bubblewrap is missing), `test/elia/command_isolation_test.exs`
(the settings path and `$HOME` absent, the server pid not in `/proc`, the
workspace writable, a timeout still cleaning up), `test/elia/harness_test.exs`
(`run_tests` jailed), `test/elia/deployment_test.exs` (the `:deps_sync` step),
`test/elia/deps_sync_test.exs` and `test/elia/tasks_git_test.exs` (the sync and
the harness's git calls),
`test/elia/store_test.exs` and `test/elia/tasks_test.exs` (the setting and its
inheritance), `test/elia_web/live/jail_test.exs` (UI-67..UI-69).

A test that needs the jail's effect skips when bubblewrap isn't available
(ISOL-12); the ones that build the argv don't.
