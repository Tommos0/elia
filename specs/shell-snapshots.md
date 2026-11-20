# Shell snapshots

Status: Implemented

Every `shell` tool call is bracketed by a snapshot of the git work tree its
working directory belongs to: a commit of the tree as it stands when the call
starts and one of it as it finishes, both taken then, so the chat can show what
that call did without the agent having to say so — and never what moved the
tree between the chat's calls: the user's own edits, a deploy, another chat, or
another worktree of the same git. The commit is built through a temporary index
and kept under a ref of its own, so the tree's branch, index, stash and working
files are as they were and `git log` shows nothing of it. The pair travels on
the call's own tool result, saved with the chat; what the model is sent stays
the command's output and exit status, so a snapshot costs the agent no context.
The harness does this for every call in every chat, which is why no instruction
to show a diff is needed anywhere.
A snapshot holds the tree's files, so a call that moves only the tree's git — a
checkout, a commit, a stash, a branch it creates — is shown as the content that
changed under it, and as nothing where no content changed.
A diff a card shows is highlighted as a diff by the file viewer's own client
hook, so its lines are told apart by colour (SNAP-13).
Each file a card lists is opened on its own, a toggle per file rather than one
diff for the whole call: it shows that file's own part of the pair's diff and
the lines that part adds and removes (SNAP-15, SNAP-16).

## Requirements

- **SNAP-1** A snapshot of a git work tree is a commit holding that tree as it stands, built through a temporary index, so the tree's own index, HEAD, current branch, stash and working files are as they were.
- **SNAP-2** A snapshot is reachable from exactly one ref, `refs/elia/snapshots/<milliseconds>-<short tree sha>`, and from nothing else, so `git log`, `git branch` and `git status` show nothing of it while the objects it holds stay reachable.
- **SNAP-3** A snapshot holds the tree's untracked files and leaves out what the tree's own ignore rules exclude.
- **SNAP-4** A snapshot of a tree equal to that tree's newest snapshot reuses it: no ref is added, and the two calls answer the same commit.
- **SNAP-5** A `shell` call's pair starts at a snapshot of the tree taken as that call starts, whether or not the tree has one already, so what moved the tree since its last snapshot is not shown as that call's change.
- **SNAP-6** Every `shell` tool call records, on its own tool result, the pair of snapshots bracketing it: the snapshot taken of the tree its working directory belongs to as the call started, and the snapshot taken of it when the call finished.
- **SNAP-7** The pair is saved with the chat, and a tool result saved before it existed reads as a call with no pair.
- **SNAP-8** The pair changes nothing else about a call: its result content is the command's output and exit status, which is what the model is sent.
- **SNAP-9** A working directory that is not in a git work tree, and a snapshot that fails or takes longer than `timeout`, leave the call's own result unchanged and unblocked: the call records no pair.
- **SNAP-10** The chat shows a call's changed files — each path with its status, as added, modified, deleted or renamed — when the call's pair differs, and shows no files when it does not.
- **SNAP-11** The pair carries its diff, which a card shows, cut at `max_diff` characters with a marker saying it was cut.
- **SNAP-12** A pair's files and diff are read from its two snapshots when the call finishes and saved with the pair, so a call's card shows what it changed after later calls have moved the tree on, and reads no git of its own.
- **SNAP-13** The card shows a diff's lines told apart by colour: the element carries the file viewer's client hook (EXPL-13) with the language `diff` named on it, so a file header, a hunk header, an added line and a removed line each read as themselves.
- **SNAP-14** An added line and a removed line of a diff the card shows carry a tinted background besides their colour, which comes from the daisyUI theme variables (EXPL-14), so both follow the light/dark toggle.
- **SNAP-15** Each file a call's card lists is a toggle of its own: opening it shows the part of the pair's diff that changes that path and no other file's lines, and a file the pair's diff holds no part of has no toggle.
- **SNAP-16** Each file a call's card lists shows how many lines its own part of the pair's diff adds to it and removes from it, counted from that part.
- **SNAP-17** The tree a call is snapshotted in is the work tree its working directory belongs to, so a chat that made a linked worktree of its own (DEPLOY-28) is compared with that worktree's state and never with the tree that holds it or a sibling worktree of it.

## Configuration

    config :elia, Elia.Snapshot,
      max_diff: 20_000,   # characters of a pair's diff the card shows
      timeout: 30_000     # milliseconds one snapshot may take

## Out of scope

- Rolling a tree back to a snapshot, and any tool that lists, reads or deletes
  them: a snapshot is for showing what a call changed.
- Pruning snapshot refs, which accumulate in a tree's git until its own gc
  drops what nothing refers to any more.
- Deciding whether a call will write before it runs: every call is snapshotted.
- Snapshotting any tool other than `shell`.
- Showing what a call did to the tree's git rather than to its files — a branch
  it created, a commit, a stash: a pair holds the tree's files (SNAP-1).

## Stored data

A `:tool_result` block in a saved chat carries an optional `:snapshot` key: the
pair's two `refs/elia/snapshots/...` names, the files that differ between them
with the status of each, and their diff. A chat saved before this existed has
none and reads as a call with no pair, so the change is backward compatible and
needs no migration. The refs themselves are written into the tree's own git
(SNAP-2); the state the chat's own git shows is not among what a snapshot
changes (SNAP-1).

## Implementation

`Elia.Snapshot` takes a snapshot of a tree as it stands — the one a call starts
at and the one it ends at (SNAP-5) — reads a pair's changed files and diff with
`git`, and cuts the diff it carries into each file's own part with the lines
that part adds and removes (`files_with_diffs/1`, SNAP-15, SNAP-16). The agent
loop brackets each `shell` call with the pair (`Elia.Agent.Loop`), which rides
on that call's tool result and is saved with the chat; the chat's tool card
renders it (`lib/elia_web/live/chat_live.ex`), whose diff the file viewer's own
`Highlight` hook colours as a diff (EXPL-13, EXPL-14). `Elia.Preview`'s sample
chat carries one, so a preview shows the card (PREVIEW-10).

## Tests

- `test/elia/snapshot_test.exs` — SNAP-1 to SNAP-5, SNAP-11, SNAP-12, SNAP-15 to SNAP-17
- `test/elia/agent_test.exs` — SNAP-6, SNAP-8, SNAP-9
- `test/elia/store_test.exs` — SNAP-7
- `test/elia_web/live/chat_live_test.exs` — SNAP-10, SNAP-11, SNAP-13, SNAP-15, SNAP-16
- No test: SNAP-14 — the tint comes from the daisyUI theme variables in
  `assets/css/app.css`, which a reviewer reads rather than a test.
- `test/elia/preview_test.exs` — SNAP-6, SNAP-10, through the sample chat a
  preview seeds
