# Chat worktrees

Status: Implemented

A chat in Elia's own project makes itself a git worktree before it changes code
(DEPLOY-28) and, until now, removed it again as soon as its work was merged: the
tree the chat had been working in went the moment the chat was done, so a chat
resumed soon after had to make a new one and rebuild what was in it, and the
worktree of a chat that was deleted was left behind for nobody. This feature
keeps a finished chat's worktree for a while, shows in a chat whether it still
has one, and has the server sweep the ones nothing needs any more after at least
an hour.

## Requirements

### A chat says whether it has one

- **WTREE-1** A chat whose worktree exists shows a mark in the row the chat list
  draws it with (UI-59), beside the status indicator and in place of nothing:
  the id `<scope>chat-worktree-<chat id>`, the scope being the one the row's
  other ids carry (UI-59), with a worktree icon and the `title` "Worktree". A
  chat with no worktree shows no such mark, and either way the status the row
  shows is the one it showed before (UI-59, UI-80).
- **WTREE-2** The chat's own page shows the same mark in its header: in a task
  chat's header (UI-48), beside the status it draws, with the id
  `task-header-worktree`, and in an ordinary chat's title header (UI-96), with
  the id `chat-worktree-header`.
- **WTREE-3** A chat has a worktree when
  `<the folder of its project>/tmp/worktrees/<its chat id>` is a directory
  (DEPLOY-28, PROJ-12): the live tree for a chat of Elia's own project (DEPLOY-3,
  DEPLOY-2) and the project's folder for a chat of another (PROJ-12). That fact
  is read from the filesystem, since the worktree is one the chat's own command
  made and not one the harness made for it (DEPLOY-1).
- **WTREE-4** The chats that have a worktree are held by `Elia.Worktrees` and
  read by the views (WTREE-1, WTREE-2) without a filesystem call of their own,
  and the set is refreshed by the sweep (WTREE-10): a worktree a command made is
  marked within one interval and one a command removed stops being marked within
  one, with no restart.

### A finished chat keeps its worktree

- **WTREE-5** A chat that has merged its branch into the trunk (DEPLOY-13) leaves
  its worktree and its branch where they are: it removes neither. Removing a
  finished chat's worktree is the sweep's step (WTREE-6) rather than the chat's,
  and a sub-task's no more than its parent's (SUBTASK-23).
- **WTREE-6** A chat's worktree is removed when the chat is marked done (DONE-1, STORE-34),
  the chat's saved `updated_at` is at least the minimum age ago (STORE-1) and no turn of that chat is running (SESS-19).
- **WTREE-7** A worktree whose chat no longer exists is removed once the
  worktree's own directory has not been modified for the minimum age: deleting a
  chat deletes the chat and nothing else (STORE-23), so its worktree is left for
  the sweep.
- **WTREE-8** A worktree with uncommitted changes is left where it is: `git
  status --porcelain` in it printing anything — a modified file, a file git does
  not ignore — keeps it, so nothing a chat left uncommitted is discarded.
- **WTREE-9** The branch `chat/<chat id>` is deleted only when that chat's
  worktree was removed and its commits are already in the trunk
  (`git merge-base --is-ancestor "chat/<chat id>" master`); a branch holding work
  that has not landed stays.
- **WTREE-10** The sweep runs on an interval of its own, over every folder a chat
  of this installation works in — the live tree (DEPLOY-3) and the folder of each
  registered project (PROJ-3, PROJ-4) — so a worktree made in another project's
  tree is swept too.
  An interval of `0` runs no timer at all: the server still scans when it
  comes up (WTREE-4) and `sweep/1` is still there to call, which is what a
  test run does rather than a sweep firing under the tests.
- **WTREE-11** Every worktree a sweep removes is written to the server
  log (LOG-1), with the branch it deleted or left, and so is a removal that
  failed, with what git said.
- **WTREE-12** A chat that is not done keeps its worktree however old it is: the
  sweep removes only what WTREE-6 and WTREE-7 name, so an idle chat — a turn that
  ended without the chat being marked done — still has its tree when it is
  resumed.

## Configuration

`config :elia, Elia.Worktrees`:

- `interval_ms` — how often the sweep runs (WTREE-10), default `60_000`;
  `0` runs no timer (`config/test.exs` sets it).
- `min_age_ms` — the minimum age of WTREE-6 and WTREE-7, default `3_600_000`.

## Out of scope

- The dashboard's chat rows and the header's active chats list: the mark belongs
  to the chat list's own row and to the chat page's header (WTREE-1, WTREE-2).
- A control that removes a worktree now, or a page that lists them (WTREE-11 says
  what the log carries).

## Stored data

None: the sweep reads the `done` flag and the `updated_at` a saved chat already
carries (STORE-1, STORE-34) and writes nothing, so a chat saved before this
feature is swept by the same rule as any other.

## Implementation

- `Elia.Worktrees` — the set of chats with a worktree (WTREE-3, WTREE-4) and the
  sweep (WTREE-6 to WTREE-12); a child of `Elia.Application`.
- `EliaWeb.ChatStatus` — the mark, beside `terminal_mark/1` (UI-111).
- `EliaWeb.ChatList` — the row's mark (WTREE-1).
- `config/config.exs` — the interval and the minimum age (Configuration).
- `EliaWeb.ChatLive` — the header's mark (WTREE-2).
- `AGENTS.md` and `specs/deployment.md` (DEPLOY-28) — the recipe ends at the
  merge (WTREE-5).

## Tests

- `test/elia/chat_worktrees_test.exs` (WTREE-3 to WTREE-12).
- `test/elia_web/live/chat_list_test.exs` (WTREE-1).
- `test/elia_web/live/chat_live_test.exs` (WTREE-2).
- `test/elia/self_modification_test.exs` (WTREE-5).
