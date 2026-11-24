# Command isolation

Status: Implemented

Every OS process Elia spawns for a tool call runs inside a bubblewrap jail: a
fresh mount namespace holding the workspace and the toolchain and nothing else,
and a fresh pid namespace whose `/proc` doesn't show the server. A command
therefore can't read the settings database with the provider API keys (CONF-1),
the saved conversations under `.elia/sessions` (STORE), or the user's
credentials (`~/.git-credentials`, `~/.ssh`, `~/.config/gh`, `~/.netrc`) — not
even when the command is code the model wrote itself, such as a test file it
wrote and then ran with the `shell` tool (VERIFY-11): the jail is what makes
that safe, not the approval prompt (APPR-7).

Without it the harness and the shell run as the same user, so the approval
prompt is the only safeguard (SHELL-7): a command that reads like a build step
can be one the model was talked into writing, and reading a key needs nothing
more than `cat`. The jail doesn't depend on the model behaving. It is a
per-chat setting, on by default, that the user can turn off for work that
genuinely needs the rest of the machine (ISOL-16).

## Requirements

### Where it applies

- **ISOL-1** Every process Elia runs for a tool call is jailed by default: the
  `shell` tool (SHELL-1), the suite a deploy runs (VERIFY-1, ISOL-14), a folder
  skill's script tools (FOLDER), and the `git` calls the harness itself makes in
  the live tree (DEPLOY-13, DEPLOY-18). All of them go through `Elia.Shell.run/2`; the
  `System.cmd("git", …)` calls in `Elia.Tasks` and `Elia.Deploy` move behind it,
  since they bypass it today. A git call that times out counts as a failure,
  like one that exits non-zero (ISOL-10).
- **ISOL-2** The jail is bubblewrap, run as the same user with no privileges:
  `--die-with-parent`, `--unshare-pid`, `--unshare-uts`, `--unshare-ipc`,
  `--unshare-cgroup-try`, `--proc /proc`, `--dev /dev`, `--tmpfs /tmp`, and
  `--chdir` to the directory the call runs in (WD-1), which is inside the
  workspace the jail holds (ISOL-13). The hostname is the host's, which bubblewrap
  inherits, so a process that derives a name from it behaves as it does outside
  — this host's commits use exactly that fallback (git's author identity is
  `user@host`, with no `user.name` configured anywhere).
- **ISOL-3** A bind is made at the same absolute path as its source, since
  bubblewrap doesn't rewrite paths: a symlink inside the workspace resolves
  inside the jail as it does outside, whether it is one the toolchain has
  (`/bin` on a merged-`/usr` host) or one a chat's own command made.
- **ISOL-4** The jail holds exactly what ISOL-13's profile lists, and, next to
  the workspace, only the read-only toolchain (`/usr`, `/lib`, `/lib64`, `/bin`,
  `/sbin`, `/etc`), `$HOME/.mix` read-write (mix archives live there), the
  browser cache the real-browser tests drive (`$HOME/.cache/ms-playwright`,
  read-only, when it exists) — browsers, not secrets — and the user-wide
  Playwright CLI (read-only, when it exists, ISOL-26). A workspace that is
  itself a linked git worktree — one a chat made inside its project's folder
  (DEPLOY-28) — comes with the repository's git directory behind its `.git`
  pointer file, which commits need (ISOL-3).
- **ISOL-5** Nothing else is bound, so nothing else exists inside. In
  particular the settings database (CONF-1) and everything under `$HOME` but
  what ISOL-4 lists — `~/.mix`, the browser cache and the Playwright CLI — are
  never bound, so a credential store is absent whatever path it has, and no
  command can reach it by a path of its own choosing.
- **ISOL-6** Only the workspace is bound, never its *parent*: a chat's own
  worktree — a directory inside the project's folder (DEPLOY-28) — is bound on
  its own, so the live tree around it, `.elia/sessions` and the other chats'
  worktrees aren't in the jail. When the workspace is the live tree itself
  (DEPLOY-1) the tree is bound read-write and `.elia` is masked with an empty
  tmpfs *after* that bind: bubblewrap applies its mounts in argument order, so
  the later mask wins.
- ~~**ISOL-7** The dependency tree a chat's commands compile against stays the
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
  goes when the worktree goes (DEPLOY-10).~~ Retired: a chat's worktree holds
  its own copies of `deps` and `_build`, made by the chat itself when it makes
  the worktree (DEPLOY-29), so what it compiles is nobody else's and what it
  writes reaches no tree but its own. The overlay existed to keep a worktree's
  writes out of a tree it shared with every other chat and with the running
  server, and nothing is shared now. A dependency a chat adds is fetched into
  its own worktree (`mix deps.get` there), which is why a deploy fetches the
  trunk's dependencies in the live tree before its suite (DEPLOY-18) and
  installs the Node packages a chat added there before it builds the front end
  (DEPLOY-19). With the jail off (ISOL-16) there is no mount namespace at all,
  which for a tree a chat holds itself changes nothing.

  What the requirement's other two paragraphs said, as they stood:

  > Nothing compiles ahead of a command: there is no pre-compile and no `mix.lock`
  > bookkeeping, nothing compiles when a chat opens, and a chat that runs no
  > command in its worktree compiles nothing at all. (Creating a worktree does
  > copy the live tree's build output into it — a copy, not a compile, and the
  > worktree's own: BUILD-1, BUILD-2.) The first command that compiles the
  > dependencies pays for it, as part of that command: it is a tool call the chat
  > already shows as running (FEED), it needs no approval of its own, and it
  > answers to the command's own timeout (SHELL-3) — ten minutes for the deploy's
  > suite run (VERIFY-1, ISOL-14), and whatever the model asks for with the
  > `shell` tool.

  > A dependency the chat adds is fetched into its own layer, so it stays that
  > chat's until the change is deployed: the live tree gets it when the deploy
  > fetches it there (DEPLOY-18). With the jail off (ISOL-16) there is no mount
  > namespace to overlay in and commands in the worktree write the shared tree
  > directly, as before.
- **ISOL-8** The environment is cleared and rebuilt from an allowlist: `PATH`,
  `HOME`, `LANG`, `TERM`, plus `MIX_ENV` and `GIT_*` only where the caller sets
  them. Nothing is inherited, so a key in the server's own environment (CONF-5)
  reaches no command.
  *Changed:* a command in allowlist mode is given the proxy's address as well,
  `http_proxy`, `https_proxy` and `all_proxy` (NET-13), which is the one place
  the allowlist adds to the list.
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
- **ISOL-11** The jail itself doesn't restrict the network — what a command may
  reach is its chat's network setting (NET) — and it changes neither what a
  command may write inside its workspace nor what approval it needs (APPR, WS).
  It is a second line behind the approval prompt, not a replacement for it.
  *Changed:* the jail used to be the whole answer to what a command reaches, and
  left the wire alone; it still leaves it alone, and a chat's network mode is
  what limits it now.
- **ISOL-12** When there is no jail — bubblewrap not installed, user namespaces
  not permitted (ISOL-20) — a command runs unjailed as it does today and its
  result says the jail was skipped, so a run that wasn't isolated never looks
  like one that was. The chat UI says the same (UI-68). A harness caller that
  reads a command's output as a value takes that notice off first
  (`Elia.Shell.jail_skipped_notice/0`), so it never becomes part of a ref, a path
  or a count.
- ~~**ISOL-25** The file tools are confined to what the jail reaches (FILE-12,
  FILE-13): the trees a chat's commands can reach are the trees its file tools
  can read. What that is stays a property of the jail's profile (ISOL-13) and is
  asked for rather than reimplemented — `Elia.Shell.reachable?/2` says whether a
  jailed command in a given workspace can reach a path: the workspace, since a
  jail binds one tree and nothing around it (ISOL-13), and never a masked
  `.elia` (ISOL-6). The file tools run no process, so their confinement follows the jail
  decision (`Elia.Shell.wanted/1`: the chat's setting, ISOL-16, and the host's,
  ISOL-20) and not whether bubblewrap can build one (ISOL-12): a host that can't
  build the jail is still confined, and the chat's own setting is what turns the
  confinement off. A caller with no chat gets the default, which is on (ISOL-15).~~
  Retired: there are no file tools, so nothing but a command is confined, and a
  command's reach is the jail itself (ISOL-13, FILE).
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

- **ISOL-13** The jail holds one **workspace** — the tree a call belongs to, not
  the directory it happens to start in — bound read-write, and never that tree's
  parent (ISOL-6). What the jail also holds follows the workspace:

  | The call's workspace | Workspace | Repo git dir | `.elia` |
  | --- | --- | --- | --- |
  | the live tree: a chat's command or terminal (DEPLOY-1, TERM-2), the deploy's fetch and suite run (DEPLOY-18, ISOL-14) | rw | inside the tree | masked empty |
  | a worktree a chat made inside the live tree (DEPLOY-28): its own commands and its terminal | rw | in the tree that holds it, through the worktree's `.git` pointer file (ISOL-3, ISOL-4) | not bound |
  | another project's folder (PROJ-12) | rw | inside the folder | not bound |

  A chat's commands are therefore confined to one tree: the live tree it works
  in, or the worktree it made for itself inside that tree. The directory a call
  runs in (`--chdir`, the chat's working directory, WD) is not what the jail
  holds: a call that `cd`s into a subdirectory, and a folder skill's script that
  runs in its own folder (FOLDER-6), are still confined to the workspace they
  belong to, which is what lets such a script read the project it belongs to and
  nothing else. Elia's data is in no jail at all (ISOL-5, ISOL-6), and nothing a
  call can reach outside that one tree is bound.

- **ISOL-14** The deploy's fetch (`mix deps.get` in the live tree, DEPLOY-18)
  and its test run (`Elia.Deploy`, DEPLOY-5) are jailed in the live tree, and no
  chat's setting is involved: they run the merged trunk in the live tree, which
  needs write access there.
- **ISOL-15** The tool context carries the jail decision, like `:workspace`
  does, so the `shell` tool jails a call according to the chat
  it runs in. A caller with no chat — the deploy (ISOL-14) — gets the default,
  which is on.

### One mount at a time

Retired as a live concern: these requirements covered mounting a shared `deps`
tree as an overlay (ISOL-7). Nothing is mounted now — a worktree holds its own
copies of `deps` and `_build` (DEPLOY-29) — so no two jails can collide over a
mount. The measurements below are why the lock existed while one could, and the
requirements are kept as the record they were.

ISOL-7 had every command mount the worktree's dependency layer itself, and two
jails that mount the same layer at the same instant collide: one of them fails
with `Can't make overlay mount … No such file or directory` before its command
runs. 35 commands across 11 chats failed that way, every one of them in a step
that ran two or three shell commands (33 and 2) and never in a step that ran one
— 8.8% of the steps that run two or more lost one of their commands, and the
model was told a command had failed when none had run. Overlapping lifetimes are
not the problem: a mount started a moment after another succeeds while the first
is still up (measured on this host), so a terminal's session-long mount (TERM-7)
is harmless.

- ~~**ISOL-28** No two jails mount a worktree's dependency layer at the same
  instant. A jail that mounts one — a command's (ISOL-7) and a terminal
  session's (TERM-7) — takes a lock for that worktree before it starts and
  releases it as soon as the jail says it is up: bubblewrap's own `--info-fd`
  report for a command, and the session's first output for a terminal. The lock
  is held for the mount, not for the command, so a command that runs for minutes
  doesn't keep another jail from starting. A holder that dies without releasing
  is released with it, so a crashed command can't wedge the worktree. A caller
  that can't get the lock within its own timeout runs anyway, as it did before
  this requirement: a rare collision is better than a command that never runs.~~
  Retired: there is no layer to mount, so there is nothing to collide over and
  no lock to take (ISOL-7).

- ~~**ISOL-27** A jail that can't mount the layer is tried once more, and then
  runs with the shared `deps` bound read-only — the fallback ISOL-7 already takes
  when the layer can't be made — with its result saying the shared tree was
  read-only, as a skipped jail says it wasn't jailed (ISOL-12). A command that
  could not be run at all is never reported as one that ran and failed: the
  jail's own report of why it failed goes to the server's log, and the command
  runs, failing on its own write if it needed one, exactly as it does where the
  layer can't be made at all.~~ Retired: there is no layer and no read-only
  shared `deps` to fall back to (ISOL-7); a jail that can't be made at all is
  what ISOL-12 and ISOL-20 describe.

- ~~**ISOL-29** In a chat worktree's jail (`:worktree`, ISOL-13) the parts of the
  repository's git directory that decide what git runs are read-only: its
  `config`, its `hooks` directory and its `info` directory. Bound read-only over
  the read-write git directory (ISOL-4), each one that exists can be read and
  can't be written, replaced or removed from inside, so a command there cannot
  install a hook or set `core.hooksPath`, `core.fsmonitor`, a filter or an alias
  for a later git run in the live tree to pick up. The rest stays as ISOL-4
  says, because the chat's own git work needs it: objects, refs and logs,
  `packed-refs`, and the worktree's own `worktrees/<id>` (its `HEAD`, index and
  in-progress rebase or merge state), so a chat still commits, rebases, checks
  out and fast-forwards `master` (DEPLOY-13).~~ Retired: the profile it belonged
  to is gone (ISOL-13). A chat's commands run in the tree it works in, bound
  read-write, and a worktree it made inside that tree is part of it; what a git
  command inside the jail may write is ISOL-4's list and nothing narrower.

- **ISOL-30** Every git command the harness runs itself — `Elia.Deploy`'s, in
  the live tree — runs with hooks off and no filesystem
  monitor (`-c core.hooksPath=/dev/null -c core.fsmonitor=false`), so none of
  them runs code the repository's files name, whatever they hold. A chat's own
  git commands, which it runs through the `shell` tool, are unaffected.
  *Changed:* the harness used to run git in a child's worktree too, for the
  result of a task (the retired SUBTASK-9); the result is what the child said
  now, and no harness git command reads a child's branch.

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
- **ISOL-19** Turning the jail off loosens what a command reaches and nothing
  else: with the jail off a command runs on the whole machine (ISOL-20), where
  jailed it reached its workspace and the toolchain (ISOL-13); approval is
  unchanged (SHELL-1, APPR), the working directory and the workspace root are
  unchanged (WD), no tool is auto-approved, and turning it back on affects only
  calls that come later — a command already running isn't killed.
- **ISOL-20** A host can turn the jail off for every chat (`config :elia,
  Elia.Shell, jail: false`), which is what a machine without bubblewrap does.
  A chat's own setting can only turn it off, never force it on where the host
  says no.

### Asking for no jail

The chat's setting is the user's (ISOL-16). Work that needs the machine a jail
hides — the settings database, a credential, another tree — is one call's
business, and what the model can do about it is ask:

- **ISOL-31** A call may ask for no jail: the `shell` tool and `terminal_start`
  take `jail: false` in their input, and that call runs unjailed whatever the
  chat's setting is (ISOL-16). The request only loosens — `jail: true`, or none,
  leaves the chat's setting to decide, and a host with no jail (ISOL-20) runs
  the call unjailed anyway. It changes no setting: the chat's next call follows
  ISOL-16 as before, and a terminal started this way is unjailed for that
  session alone (TERM-40).
- **ISOL-32** A call that asks for no jail is always put to the user: it is
  never auto-approved, whatever the chat's auto-approved set holds (APPR-8,
  APPR-19), so the prompt — which says the command runs unjailed (UI-101) — is
  where the user sees what they are agreeing to.
- **ISOL-33** A `shell` call that asked for no jail says so in its result,
  before the output, where the chat's setting would otherwise have jailed it
  (ISOL-16, ISOL-20): `[jail: off at this call's request]`, in the shape of the
  notice a skipped jail has (ISOL-12).

### Telling the model

- **ISOL-21** The `shell` tool's description and the skill's instructions say
  that a command runs in a jail by default, that the jail holds the workspace
  and the toolchain and nothing else, and that the settings database, the saved
  conversations and the user's credentials aren't in it — so a command that
  can't find them is expected, not broken (SHELL-8, SHELL-9). They say too that
  a chat whose jail the user turned off (ISOL-16) runs commands unjailed. They
  say that a call may ask for no jail of its own (`jail: false`, ISOL-31) and
  that such a call is the user's to allow every time (ISOL-32).

### The harness's own steps

- ~~**ISOL-22** The harness's worktree administration — `git worktree add`,
  `remove` and `prune` — runs as a harness step under a profile that leaves
  `.elia` reachable (ISOL-13), because a chat's
  worktree is created *inside* `.elia/worktrees`. Under `:live_tree` the mask
  would swallow the new worktree and the command would still exit 0, having
  written nowhere the harness can see. Nothing the model wrote goes into these
  steps and their arguments are the harness's, fixed at the call site. This is
  the one place a jailed process has `.elia` in reach, and it is a deliberate
  trade: while such a step runs, the saved conversations are (ISOL-5, ISOL-6).~~
  Retired: the harness administers no worktree (DEPLOY-1). A chat makes its own
  with `git worktree add` through the `shell` tool, at a path inside its
  project's folder that its `.gitignore` covers (DEPLOY-28) — a path the jail it
  runs in already reaches (ISOL-13) — so no harness step ever needs `.elia` in
  reach, and the mask holds for every jailed process there is (ISOL-6).
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

- **A script tool's own request.** A folder skill's script tool (FOLDER-6)
  follows the chat's setting as it does today; asking for no jail is the `shell`
  tool's and `terminal_start`'s (ISOL-31).
- **The jail's own network rules.** A per-command filter of the host's network
  is not what limits a chat: a restriction is a namespace of the command's own
  beside the jail (NET-13, NET-16), and the jail's argv is unchanged by it
  (ISOL-11). The prompt stays an egress channel whatever a command may reach,
  since whatever it prints is sent to the provider; what the jail protects is
  the secrets.
- **A uid per command.** A uid boundary is the stronger form of this: it holds
  even for a path a bind list forgets, and it isolates the credentials git
  itself needs. It needs a second user, a sudoers rule and group-shared
  worktrees; the mount namespace gets the secrets out of reach with no
  deployment change, so it comes first.
- **Which tools need approval.** With the jail on, a test suite the model wrote
  runs where it can't reach a secret, so APPR-7 is left as it is.
- **A worktree jail that can't move `master`.** A chat fast-forwards the trunk
  itself from its own jailed shell (`git push . HEAD:master`, DEPLOY-13), so its
  jail keeps `refs/heads` writable, `master` included, and `packed-refs` with
  it. What the user reviews is the fast-forward that lands there and the deploy
  that follows it (DEPLOY-5), not who may write the ref. Taking `master` out of
  a jail's reach needs the merge to move into a harness tool the chat calls,
  which changes DEPLOY-13, and is a change of its own.
- **A chat's commands and the tree that runs.** Every chat works in the live
  tree itself (DEPLOY-1), written read-write, `.git` and all, so what stands
  between a chat's half-done edit and the running app is the worktree the chat
  makes for the work (DEPLOY-28) and the suite a deploy runs before it loads
  (DEPLOY-5, DEPLOY-24). The jail confines where a command may write, not
  whether the tree that runs is a good one; the mask over `.elia` (ISOL-6) is
  what keeps Elia's own data out of its reach. ISOL-30 still keeps the
  harness's own git from running a hook or monitor a command left behind.
- **Hex's own store (future work).** A jailed command gets no Hex store to keep.
  `$HOME` inside the jail is a fresh empty directory holding only the binds
  (ISOL-4), so the store Hex makes — `~/.hex/cache.bin`, the registry, and
  `~/.hex/packages/<repo>/<package>.tar` — is created for one command and goes
  with its mount namespace. Fetching still works (the network is reachable,
  ISOL-11: a jailed `mix hex.package fetch jason 1.4.4` downloads into that
  store), at the cost of fetching the registry and the packages again in every
  command that fetches — including a chat that adds a dependency (DEPLOY-29),
  which fetches it afresh in each command that builds it. A future fix gives a
  chat's commands somewhere to keep one: bind the shared `~/.hex` read-write for
  the live tree's profile, or keep a store beside the worktree a chat made
  itself (DEPLOY-28) and remove it with it. Hex 2.6.0 names no variable that
  would move its store — its `HEX_*` variables are cooldown, HTTP timeout,
  repo-origin verification, offline, lock policy and registry verification — so
  a store of our own would have to be bound at that path. Mix's path variables
  are a separate matter: `MIX_DEPS_PATH` moves the deps directory and
  `MIX_BUILD_PATH` the build directory (both verified on Elixir 1.18.3), which
  the copies a chat makes for its own worktree make unnecessary (DEPLOY-29).
- **Sanitising a worktree's dependencies**, and `mix deps.get` for a project
  other than Elia's own — that project's `deps` is inside its workspace and
  writable there (ISOL-4).
- **A host whose kernel can't mount an overlay in a user namespace.** Retired
  with the overlay (ISOL-7): nothing mounts one now. Such a host's cost is what
  it always was — a worktree the chat copied `deps` and `_build` into itself
  (DEPLOY-29), which it could not have done if the copy had to be a mount.
- **One jail per chat, shared with its terminal.** One bubblewrap process for a
  chat's whole life would save a bubblewrap start per command and cover the
  terminal session too (TERM-7). Retired with ISOL-28's lock: there is no mount
  left to amortise, and a jail per command keeps one step's commands out of
  reach of another's, which one long-lived jail would give up.
- Seccomp filters, cgroup limits, and capping what a jailed command may write
  inside its own workspace.

## Implementation

`Elia.Shell` (the bubblewrap argv, the one profile and what it holds, the
environment allowlist, and
what a jailed command can reach — ISOL-13; `run/2` takes `:jail`),
`Elia.Terminal.Session` (a session's jail is the same argv),
`Elia.Skills.Shell` (the chat id a command is given, `ELIA_CHAT_ID`, SHELL-14),
`Elia.Skills.Folder`
and `Elia.Harness` (pass the chat's setting from the tool context),
`Elia.Agent.Session` (the setting, its event, its save), `Elia.Store`
(`save/3`'s `jail:`, `load_jail/1`), `Elia.Deploy` (spawns `git`
through `Elia.Shell.run/2`, and the deploy's own fetch of the trunk's
dependencies, DEPLOY-18),
`Elia.Skills.Tasks` (copy the parent's setting to the child, SUBTASK-30),
`EliaWeb.ChatLive` (the switch).

Removed with the worktree plumbing: `Elia.Deps` (a worktree's dependency layer —
nothing layers dependencies any more, DEPLOY-29), `Elia.Shell.Lock` (the
per-worktree mount lock — no two jails mount anything now, ISOL-28),
`Elia.Shell`'s `:worktree` and `:deps_sync` profiles and its read-only `deps`
fallback (ISOL-13, ISOL-22, ISOL-27), `Elia.Terminal.Session`'s side of the
lock, and `Elia.Deploy`'s worktree administration.

## Tests

- `test/elia/shell_test.exs` (the bubblewrap argv and the mounting of the jail,
  the profile and what it holds, the environment allowlist, what a jailed
  command can reach, the fallback when bubblewrap is missing —
  ISOL-1 to ISOL-3, ISOL-5, ISOL-6, ISOL-8 to ISOL-10, ISOL-12 to ISOL-14,
  ISOL-20, ISOL-24).
- `test/elia/command_isolation_test.exs`
  (the settings path and `$HOME` absent, the browser cache and the user-wide
  Playwright CLI bound read-only, ISOL-4, ISOL-26, the server pid not in `/proc`, the
  workspace writable, a command writing inside its workspace's `deps` and
  leaving the live tree's unchanged (DEPLOY-29), a timeout still cleaning up, and
  `Elia.Harness.run_tests/3` jailed, and a call that asks for no jail running
  outside it whatever the chat's setting (ISOL-31) — ISOL-1, ISOL-3, ISOL-5,
  ISOL-6, ISOL-8 to ISOL-10, ISOL-15).
- `test/elia/deployment_test.exs` (the deploy's fetch, DEPLOY-18; the jail the
  deploy's own commands run in, ISOL-13, ISOL-14, ISOL-20; a hook and an
  fsmonitor the repository names not run by the harness's own git, ISOL-30).
- `test/elia/self_modification_test.exs` (the classes a path falls in, the
  real location it is judged by, and a path with none — WS-1 to WS-3, WS-5 to
  WS-8; that a class decides nothing about what a command may write, ISOL-13,
  ISOL-15, ISOL-16, ISOL-20).
- `test/elia/agent_test.exs` and `test/elia/tasks_test.exs` (the setting, what
  the tool context carries, and a child that inherits it — ISOL-15, ISOL-16,
  ISOL-18).
- `test/elia/store_test.exs` (the setting saved and loaded, ISOL-16).
- `test/elia/skills/shell_test.exs` (the tool's description and the skill's
  instructions say the command is jailed and that a call may ask for no jail,
  ISOL-21; the request's forced approval and the notice its result carries —
  ISOL-32, ISOL-33).
- `test/elia/auto_approve_test.exs` (a call that asks for no jail waiting for
  the user's own decision where its tool is auto-approved — ISOL-32).
- `test/elia_web/live/jail_test.exs` (the switch, the prompts it changes, and
  the chat that owns the setting — ISOL-16, ISOL-17, ISOL-19, ISOL-20, UI-67 to
  UI-69).
- No test: ISOL-11 — that the jail leaves the network alone is read from the
  profile's own argv (ISOL-13), which no test asserts.

A test that needs the jail's effect skips when bubblewrap isn't available
(ISOL-12); the ones that build the argv don't.
