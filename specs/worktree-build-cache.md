# Worktree build cache

Status: Draft

A chat in Elia's own project works in its own git worktree, which shares the
live tree's `deps` (DEPLOY-1, ISOL-7) but holds no build output of its own. So
the first command that compiles there builds every dependency from source:
measured in this tree, `mix compile` takes 35 s cold and `MIX_ENV=test mix
compile` 33 s, of which the dependencies are 29 s and 28 s and the worktree's own
~90 files 7 s and 6 s. The dependency sources are the same files at the same path
in every worktree, and Mix reuses a dependency's compiled artifacts wherever it
finds them (it decides staleness by the source's path and content, not by a
timestamp): a worktree that already has a `_build` built from those sources
compiles in 5 s (dev) and 6 s (test).

So a worktree is seeded at creation with a copy of the live tree's build output.
The copy is the worktree's own: no mount, no shared layer, nothing that another
chat or a deploy can write while a command reads it. That is what keeps a chat's
compile from racing with a deploy rewriting the live tree's `_build` (DEPLOY-5)
— a lower layer that changes under a mounted overlay serves stale files silently
— and what keeps a chat from ever writing the artifacts the running server runs
from, whether the jail is on or off.

## Requirements

- **BUILD-1** Creating a chat's or a sub-task's worktree (DEPLOY-1, SUBTASK-23)
  also gives it build output to start from: `_build` is copied into the
  worktree, beside the `deps` link it already gets, so the first command that
  compiles there reuses the dependencies' compiled artifacts instead of building
  them. The copy is taken once, when the worktree is created; a worktree that
  already exists keeps the build output it has and nothing is copied into it
  again.
- **BUILD-2** The copy is the worktree's own. A command compiling in a worktree
  writes only that worktree's `_build`, and the live tree's `_build` — the
  artifacts the running server runs from — is written by no chat, jailed
  (ISOL-13) or unjailed (ISOL-16), and two worktrees never share one.
- **BUILD-3** Seeding is a copy, not a compile: no dependency is compiled and no
  `mix` command runs ahead of a chat's own command, so ISOL-7's rule stands. A
  live tree with no build output gives a worktree with none, and the first
  compile there is what it is today.
- **BUILD-4** The copy saves only what Mix itself considers current. The
  dependency sources in a worktree are the same files at the same path as those
  the copy was built from (ISOL-7), so their artifacts are reused, while the
  worktree's own modules are compiled from the worktree's own sources. A
  worktree whose `mix.lock`, `mix.exs` or sources differ from what the copy
  holds compiles what differs: nothing about the copy makes changed code look
  current.
- **BUILD-5** Seeding never keeps a chat from working. A copy that fails — no
  space, no permission, no live build output — leaves the worktree created and
  the command that needed it running as it does today, with an empty `_build`.
  A command that compiles in a seeded worktree is otherwise unchanged: the same
  output, the same timeout, the same jail.
- **BUILD-6** The copy lives inside the worktree, so it goes when the worktree
  goes (DEPLOY-10) and stays a protected path for the file tools (WS-1).

## Out of scope

- Layering or mounting `_build` as a shared lower layer: the copy is
  deliberately private, and `deps` keeps the overlay it has (ISOL-7).
- A notice in the chat UI: the copy happens with the worktree's creation, inside
  a tool call the chat already shows as running, so ISOL-23's indicator stays
  retired and no new one is added.
- Refreshing a worktree's build output after it is created, or sharing one
  worktree's with another.

## Implementation

- `Elia.Deploy` creates a worktree (`add_worktree/4`, `link_deps/2`); the seed
  belongs beside the `deps` link, and covers a sub-task's worktree too
  (`ensure_child_worktree/3`).
- `Elia.Deps` owns the per-worktree dependency layer; `remove_worktree/2` and
  `Elia.Deps.remove/2` already remove a worktree's own state.
- `Elia.Workspace`'s protected paths already cover `_build` (WS-1), so the file
  tools never write it.

## Tests

- `test/elia/deployment_test.exs` — seeding at creation, the idempotent second
  call, the private copy (a write in the worktree leaves the live tree's
  `_build` alone) and the failure path.
- `test/elia/deps_test.exs` — if the seed lives in `Elia.Deps` rather than
  `Elia.Deploy`.
