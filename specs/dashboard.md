# Dashboard

Status: Implemented

`/` — the app's start URL (PWA-1) and the target of the header logo — is a home
screen rather than a jump straight into the most recent chat: it shows what
needs the user, where they left off, their projects, the machine's health and
whether the trunk is deployed. Opening a chat stays one tap away, and the chat
list's entry point moved to `/chats` (UI-77), which resumes the chat the user
left off in exactly as `/` used to (UI-1, UI-71).

## Requirements

### Home

- **DASH-1** `GET /` renders the dashboard (`EliaWeb.DashboardLive`) and nothing
  else: it starts no session, creates no chat and writes nothing, so opening the
  app again and again leaves no empty "New chat" behind (STORE-22). Its page
  title, and its heading, is "Home".
- **DASH-2** The dashboard uses the standard page layout, so its header carries
  the logo — which goes to `/`, the dashboard itself — and, like the other pages
  with no chat list of their own, the "Chats" link (`#chats-link`) to `/chats`
  (UI-32). The dashboard has no chat list, so it has no drawer toggle (UI-36)
  and no sidebar.

### Where you left off

- **DASH-3** A "Continue" card (`#continue`) shows the chat the user left off
  in — `Elia.Store.latest/0` (STORE-29), the most recently started chat that
  isn't a task chat (STORE-17) — with its title (`#continue-title`), its
  project's name (`#continue-project`), when it was started in relative form
  (UI-34: a `<time>` whose `datetime` is the start time and whose `title` is the
  exact date and time, refreshed every minute) and its status indicator
  (`#continue-status`, following the same rules as the sidebar's, UI-59),
  linking to `/c/<id>` (`#continue-link`).
- **DASH-4** With no chat saved, the card says "No chats yet"
  (`#continue-empty`) instead of a chat, and a "New chat" button (`#new-chat`)
  starts a chat in the default project (PROJ-8) by linking to
  `/p/<default project id>/new` (PROJ-26). The button is there whether or not
  there is a chat to continue.

### Needs attention

- **DASH-5** A "Needs attention" card (`#attention`) has one row
  (`#attention-<chat id>`) per chat that wants the user: a tool call awaiting
  approval (SESS-4, `awaiting_approval`), a turn paused at a limit (SESS-27,
  `paused`), or a turn an app restart cut short (STORE-31, `interrupted`). Task
  chats are included (UI-47). Each row links to the chat (`/c/<id>`) and names
  the reason in words — "Needs approval", "Paused at a limit", "Interrupted by a
  restart" — with the chat's title and project.

  Every chat that blocks a turn (awaiting approval or paused) is listed, and
  interrupted chats are listed up to five, with "and N more"
  (`#attention-more`) naming the rest. The rows that block a turn come first,
  then the interrupted ones, newest first. The card is right on first render —
  from `Elia.Agent.awaiting_approval/0`, `Elia.Agent.paused/0` and the listed
  chats' `interrupted` (STORE-31) — and follows `{:chat_status, id, status}`
  (SESS-19) live, exactly as the sidebar's status indicators do (UI-47, UI-59).
  With nothing waiting it says "Nothing needs you right now."
  (`#attention-empty`) rather than showing an empty card.
- **DASH-6** A row is a link to the chat only: stopping, approving or continuing
  is done in the chat itself, with that chat's own controls.

### Recent chats

- **DASH-7** A "Recent chats" card (`#recent-chats`) lists the eight most
  recently started chats (STORE-12) — task chats included, shown with their task
  title and status (STORE-17) — newest first, each row (`#recent-<id>`) linking
  to `/c/<id>` with the chat's title, its project's name, its start time in
  relative form (UI-34) and its status (`#recent-status-<id>`, UI-59's rules,
  which include the task statuses of UI-46). With no chat saved it says "No
  chats yet" (`#recent-empty`). An "All chats" link (`#all-chats`) goes to
  `/chats` (UI-77).
- **DASH-8** The card's rows and status indicators are refreshed when a
  `{:chat_status, id, status}` event arrives (SESS-19), so a turn that starts or
  ends, a task chat that appears and a chat that starts waiting for approval all
  show without a reload (UI-6, UI-49), and the relative times refresh every
  minute (UI-34).

### Projects

- **DASH-9** A "Projects" card (`#projects`) has one row
  (`#dash-project-<id>`) per project (`Elia.Projects.list/0`, PROJ-23's list),
  with its name, its folder (shown truncated with the whole path in the `title`)
  and how many chats it has (`#dash-project-chats-<id>`), a "New chat" link
  (`#dash-project-new-<id>`) to `/p/<id>/new` (PROJ-26), and a single link
  (`#all-projects`) to `/projects`.

### Machine and deployment

- **DASH-10** A "System" card (`#system-card`) shows the machine's health —
  CPU usage, memory used of total, the 1-minute load average, and the Erlang
  VM's memory and process count — from `Elia.SystemStats` (SYS-1, SYS-2, SYS-3),
  refreshed every 2 seconds while connected (SYS-7), formatting percentages and
  bytes as the System page does (SYS-9, SYS-10). A section whose source is
  missing reads "Unavailable" (SYS-1) while the others still render, and a link
  (`#dash-system-link`) goes to `/system` (SYS-11).
- **DASH-11** A "Deploy" card (`#deploy-card`) reports the deploy state from
  `Elia.Deploy.status/0` (DEPLOY-17), refreshed when the page mounts and every
  10 seconds while connected: "N commits to deploy" (`#deploy-pending`) when the
  trunk is ahead of `live` (one commit reads "1 commit to deploy"), "Up to date"
  (`#deploy-ok`) when it isn't, a note that the running app is behind `live` and
  a restart loads it (`#deploy-behind`, DEPLOY-15) when it is, and the reason
  and its one-time fix (`#deploy-error`) when the live tree isn't set up for
  deployment (DEPLOY-14). It links to `/settings` (`#deploy-settings-link`),
  where deploying happens (CONF-19).

## Out of scope

- A second chat list: the dashboard shows recent chats and needs-attention
  rows, while listing every chat, grouping them by project and deleting them
  stays on the chat page's sidebar (UI-4, UI-64) and on the chat list's entry
  point `/chats` (UI-77).
- Per-chat actions on the dashboard: stopping a turn, approving a call, resuming
  a paused chat, deploying and the rest stay where they are, one tap away.
- Configurable widgets, drag-to-rearrange, or a per-user dashboard.

## Implementation

`EliaWeb.DashboardLive`, `EliaWeb.Router` (the `/` route and the `/chats` route
of UI-77), `EliaWeb.Layouts`, `Elia.Store.latest/0` (STORE-29),
`Elia.Projects`, `Elia.Agent` (statuses), `Elia.SystemStats` (DASH-10) and
`Elia.Deploy.status/0` (DASH-11).

## Tests

`test/elia_web/live/dashboard_test.exs`,
`test/elia_web/live/chat_live_test.exs` (what `/chats` opens, UI-77).
