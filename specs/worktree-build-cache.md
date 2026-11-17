# Worktree build cache

Status: Retired

Retired: this spec's behaviour was the harness seeding each chat worktree it
created with a copy of the live tree's `_build`. The harness creates no worktree
now (DEPLOY-1) — a chat makes its own, and copying the build output into it, with
`deps`, is one of the steps the instruction for that worktree carries (DEPLOY-28,
DEPLOY-29). The measurements below are what that step is for, which is why the
copy stayed in the instruction when the code went.

Measured in this tree while the requirement was live: a worktree that shares the
live tree's `deps` and holds no build output builds every dependency from source
— `mix compile` 35 s cold and `MIX_ENV=test mix compile` 33 s, of which the
dependencies are 29 s and 28 s and the worktree's own ~90 files 7 s and 6 s. Mix
reuses a dependency's compiled artifacts wherever it finds them (it decides
staleness by the source's path and content, not by a timestamp), so a worktree
that already has a `_build` built from those sources compiles in 5 s (dev) and
6 s (test). The copy is the worktree's own, which is what keeps a chat's compile
from racing with a deploy rewriting the live tree's `_build` (DEPLOY-5) and from
writing the artifacts the running server runs from, whether the jail is on or
off. The chat makes that copy itself now (DEPLOY-29).

## Requirements

- ~~**BUILD-1** Creating a chat's or a sub-task's worktree (DEPLOY-1, SUBTASK-23)
  also gives it build output to start from: `_build` is copied into the
  worktree, beside the `deps` link it already gets, so the first command that
  compiles there reuses the dependencies' compiled artifacts instead of building
  them. The copy is taken once, when the worktree is created; a worktree that
  already exists keeps the build output it has and nothing is copied into it
  again.~~ Retired: the harness creates no worktree to seed (DEPLOY-1). Copying
  the build output is a step of the instruction a chat's own worktree carries
  (DEPLOY-29), where it covers `deps` as well.
- ~~**BUILD-2** The copy is the worktree's own. A command compiling in a worktree
  writes only that worktree's `_build`, and the live tree's `_build` — the
  artifacts the running server runs from — is written by no chat, jailed
  (ISOL-13) or unjailed (ISOL-16), and two worktrees never share one.~~ Retired:
  the copy is a command in the chat's own worktree (DEPLOY-29), so what it
  writes is that worktree's, and the live tree's `_build` is still written by no
  chat.
- ~~**BUILD-3** Seeding is a copy, not a compile: no dependency is compiled and no
  `mix` command runs ahead of a chat's own command, so ISOL-7's rule stands. A
  live tree with no build output gives a worktree with none, and the first
  compile there is what it is today.~~ Retired: no harness step copies anything
  any more, and no `mix` command runs ahead of the chat's own (ISOL-7); the copy
  is the chat's own command (DEPLOY-29).
- ~~**BUILD-4** The copy saves only what Mix itself considers current. The
  dependency sources in a worktree are the same files at the same path as those
  the copy was built from (ISOL-7), so their artifacts are reused, while the
  worktree's own modules are compiled from the worktree's own sources. A
  worktree whose `mix.lock`, `mix.exs` or sources differ from what the copy
  holds compiles what differs: nothing about the copy makes changed code look
  current.~~ Retired: Mix's own staleness rules decide what a copied `_build`
  saves, exactly as they did when the harness copied it (DEPLOY-29).
- ~~**BUILD-5** Seeding never keeps a chat from working. A copy that fails — no
  space, no permission, no live build output — leaves the worktree created and
  the command that needed it running as it does today, with an empty `_build`.
  A command that compiles in a seeded worktree is otherwise unchanged: the same
  output, the same timeout, the same jail.~~ Retired: a copy that fails is a
  command of the chat's that failed, which the chat sees and answers
  (DEPLOY-30).
- ~~**BUILD-6** The copy lives inside the worktree, so it goes when the worktree
  goes (DEPLOY-10) and stays a protected path for the file tools (WS-1).~~
  Retired: the copy lives in the worktree the chat made and goes when the chat
  removes that worktree once its work is merged (DEPLOY-28); `_build` is still a
  protected path for the file tools (WS-1).

## Out of scope

- Layering or mounting `_build` as a shared lower layer: the copy is
  deliberately private to the tree it is in.
- A notice in the chat UI: the copy is a step of a tool call the chat already
  shows as running, so ISOL-23's indicator stays retired and no new one is
  added.
- Refreshing a tree's build output after it is created, or sharing one
  worktree's with another.

## Implementation

Removed with the harness's own worktree: `Elia.Deploy`'s seeding of a worktree
at creation (`add_worktree/4`, `link_deps/2`, `ensure_child_worktree/3`) and
`Elia.Deps`. What remains is the instruction (`AGENTS.md` and the
`self-modification` skill, DEPLOY-29) and `Elia.Workspace`'s protected paths,
which still cover `_build` (WS-1).

## Tests

None: every requirement here is retired (SPEC-5). What the instruction says is
tested by `test/elia/self_modification_test.exs` (DEPLOY-29).
