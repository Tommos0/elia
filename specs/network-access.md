# Network access

Status: Implemented

A chat's commands reach whatever the machine reaches: the jail keeps the secrets
out of their hand (ISOL-5) and leaves the wire alone (ISOL-11), and an approval
prompt says nothing about where a command may connect. This spec gives every
chat a network setting beside its jail setting (ISOL-16) — unrestricted; an
allowlist of hosts, reached only through a proxy the harness serves; or no
network at all. A chat starts allowlisted (NET-1), and the list it is limited by
holds two parts: the entries its own setting names, which are that chat's alone,
and its project's (NET-28, NET-36), which every chat of the project reaches. The
model can ask for a host to be allowed — for the chat or for its project — and
the request is put to the user in the chat that waits on it (NET-30, NET-32).

The limit is built where the jail is (ISOL-2, ISOL-13): a network namespace of
the command's own, with no route to any host. Egress is then a property of the
namespace rather than a filter somewhere on the machine — none mode adds
nothing, and allowlist mode adds one way out: a relay on the command's own
loopback that carries its connections to the proxy the harness serves. Two things follow from having no route out, and they are the
design rather than a limitation to fix later. A restricted command resolves no
names of its own, so an allowlisted host is resolved by the proxy. And only a
client that speaks to a proxy gets out, because the environment's `http_proxy`,
`https_proxy` and `all_proxy` are the only address it has: a command that opens
its own sockets, uses ssh or talks to a database server reaches nothing. What the
proxy sees is what an HTTP proxy sees — the host and port of a CONNECT request or
of an absolute-URI request, and the bytes after it, TLS included but not
decrypted — so an allowlist is by host name, which is what the user writes.

## Terms

- **The proxy** is the harness's process, outside the jail, that decides whether
  a request may leave and forwards the bytes when it may.
- **The relay** is the process inside the restricted namespace that carries the
  command's loopback TCP to the proxy, over a Unix socket bound into the jail.

## Requirements

### The setting

- **NET-1** A chat's network setting is one of three modes — unrestricted,
  allowlist and none. A chat whose saved file names no mode — one that has never
  been saved, one saved empty as it was started (STORE-22), and one written
  before this setting existed — starts allowlisted where a limit can be built
  for it and unrestricted where it can't (NET-20, NET-25). Unrestricted is a
  mode a chat has by choosing it, and one that chooses it keeps it across a
  restart (STORE-53, STORE-54).
- **NET-2** The setting is saved with the chat (STORE-53) and loaded with it
  (STORE-54), so it survives a restart.
- **NET-3** A change to it is carried by the chat's `{:settings, settings}`
  event like its other settings (SESS-41, CSET-3), so every view of the chat
  follows it.
- **NET-4** A sub-task starts with a copy of its parent's mode and its own from
  then on (SUBTASK-30, ISOL-18), so changing either chat afterwards never
  affects the other; a child in its parent's project reaches the same hosts,
  since it copies its parent's own entries (NET-37) and shares its project's
  (NET-28).
- **NET-5** A change of mode applies to the commands and terminals that start
  after it: one already running keeps the network it started with (ISOL-19).
- **NET-6** A change to a project's allowlist or to the entries a chat names of
  its own applies to the next request a running command makes, because the proxy
  reads the chat's effective setting — its mode, its own entries and its
  project's — when it decides (NET-14, NET-36).

### The allowlist

- **NET-7** An entry of the allowlist is a host name (`api.example.com`), a `*.`
  suffix (`*.example.com`), or either of those with a port
  (`api.example.com:443`); it is matched against a request's host ignoring case.
- **NET-8** A `*.` suffix entry matches a host that ends with `.` followed by
  the suffix, and not the bare suffix: `*.example.com` matches `api.example.com`
  and not `example.com`.
- **NET-9** An entry with no port matches a request to any port, and one with a
  port matches that port only.
- **NET-10** An empty allowlist reaches nothing: in allowlist mode with no
  entry every request is refused.
- **NET-11** A host list is saved only when every entry is one of NET-7's forms:
  a list holding an entry that is not one changes nothing and the page shows the
  message for it (PROJ-50).
- **NET-36** A chat's setting carries entries of its own beside its mode (NET-1),
  and its commands and terminals reach them together with its project's (NET-28),
  each judged as NET-7 to NET-9 judge one: in allowlist mode a request is
  forwarded when it matches either list (NET-14). An entry a chat names of its
  own is that chat's alone — another chat of the same project, and one started in
  it later, does not reach it.
- **NET-37** A sub-task starts with a copy of its parent's own entries as well as
  its mode (NET-4, ISOL-18), and the two lists are separate from then on: a host
  allowed in either chat afterwards changes what that chat reaches and not what
  the other does (NET-36).

### The chat's list and the project's

- **NET-28** The list a chat is limited by holds the entries its own setting
  names and the entries of its project (PROJ-49): every chat of a project — a
  sub-task included — reaches the project's entries, an entry a chat names of its
  own is that chat's alone (NET-36), and a chat in allowlist mode applies both
  (NET-14). A project's list starts empty and so does a chat's, so a new chat
  reaches nothing until a host is allowed (NET-10).
- ~~**NET-29** A chat file written before this change, whose setting holds hosts
  of its own, keeps reaching them: when its session starts the entries it holds
  are added to its project's list if they are not there, and the chat's setting
  is left with its mode (NET-28).~~ Removed: the entries a chat's file holds are
  the chat's own and stay there (NET-36), so there is nothing to move into its
  project's list.

### Asking for a host

- **NET-30** The built-in `network` skill (SKILL-7) carries one tool,
  `request_network_host`, whose input is `host` (a string, required) and `reason`
  (a string, required). The tool never needs approval (APPR-7).
- **NET-31** A call to `request_network_host` does not run when the model makes
  it: the turn puts the request to the user and waits for the answer (LOOP-21),
  so the session's status is `:awaiting_input` while it is open (ASK-3, SESS-34)
  and the answer reaches the tool as `ctx[:answer]` (ASK-2). The user may answer
  in their own words (ASK-4), and a request in a sub-task is answered in that
  chat (ASK-9).
- **NET-32** The request is a card in the chat's transcript (`#answer-<call_id>`,
  as a question's card is, UI-75): it names the host and the reason, and offers a
  button per decision — `Allow for chat`, `Allow for project` and `Deny` —
  beside the field for an answer of the user's own. The card is
  shown in the compact view (UI-61), and the chat is not shown as idle while the
  request is open (UI-59, UI-62).
- **NET-33** An answer that allows the host for the chat adds it to the entries
  the chat names of its own if it is not already there, and one that allows it
  for the project adds it to the project's list (PROJ-49, NET-28, NET-36); each
  result says which list the host is now in and that the command may be run
  again. Any other answer changes nothing and the result says the host is not
  allowed, with the user's answer verbatim. An answer that allows a host which is
  not one of NET-7's forms adds nothing and the result says so.
- **NET-34** A chat whose mode is not allowlist is told so in the result: the
  host is in the list the answer chose, and its own mode still limits what it
  reaches (NET-1).
- **NET-39** An answer that allows the host without naming a list — `allow`, or
  `yes` in the user's own words — is read as allowing it for the chat, and the
  result says which list the host went into (NET-33, NET-36): the project's list
  is filled only by an answer that names the project (NET-32), so a wider
  allowance is never spent by a word the user did not choose.

### What a command gets

- **NET-12** In unrestricted mode a command's network is the host's and the
  jail's argv is what it was (ISOL-11).
- **NET-13** In allowlist mode a command's process tree runs in a network
  namespace of its own, with no route to any host but the proxy (NET-14) and a
  loopback private to that command (NET-17); it reaches the proxy through the
  relay, over a Unix socket the jail binds into the namespace, and its
  environment carries `http_proxy`, `https_proxy` and `all_proxy` pointing at
  the proxy's address on that loopback (ISOL-8).
- **NET-14** The proxy forwards a request whose host the chat's allowlist names
  (NET-7 to NET-9) and refuses one it does not, with a refusal the client
  reports (403), so a refused request never reaches the host.
- **NET-15** The proxy resolves the host of a request it forwards, so a
  restricted command needs no name resolution of its own: the jail has no DNS
  (ISOL-5).
- **NET-16** In none mode a command's process tree runs in the same namespace
  with nothing to reach: its environment carries no proxy address (NET-13).
- **NET-17** In both restricted modes a command reaches a server it starts
  itself on its namespace's loopback (`127.0.0.1`), and that loopback is the
  command's own: it shares it with no other command and with nothing outside its
  namespace (NET-13).
- **NET-18** The limit covers every process the harness runs for a chat: a tool
  call's command (SHELL-1), a folder skill's script tool (FOLDER-6), and the
  chat's terminal session for its whole life (TERM-7).
- **NET-19** A caller with no chat — the deploy's fetch and suite run
  (ISOL-14) — runs unrestricted, as it does for the jail (ISOL-15).
- **NET-20** Where the limit cannot be built a command runs with the host's
  network as if the mode were unrestricted, and its result says the network
  limit was skipped (ISOL-12): the chat's jail is off (ISOL-16), the host has no
  bubblewrap (ISOL-12), or the jail holds no `elixir` (ISOL-4) to run the relay
  with (NET-13). A relay that starts and never listens says so as its own
  notice, and that command has the network its namespace has, which is none.
- **NET-21** A command's namespace, its relay and the proxy serving it end with
  it, so a timeout, a stopped turn or an ended terminal leaves no process and no
  socket behind (SHELL-3).

### The pages

- **NET-22** The chat settings page has a Network section with one control per
  mode — `#network-unrestricted`, `#network-allowlist`, `#network-none` — the
  chat's current mode marked, and a line saying what applies in words
  (`#network-state`).
- **NET-23** Choosing a mode applies it at the moment it is clicked, like a
  switch rather than the page's one Save (CSET-4, CSET-7).
- **NET-24** In allowlist mode the section lists the project's entries, one per
  line as text (`#network-hosts`), and links to the projects page
  (`#network-hosts-link`) where they are changed (PROJ-50).
- **NET-25** Where the limit cannot be built (NET-20) the section says so and
  its control is disabled (`#network-unavailable`), rather than showing a chat
  as limited where it is not (UI-68).
- ~~**NET-26** The chat page says when the chat's network is limited, beside its
  jail warning in the composer toolbar (`#network-warning`, CSET-9), naming the
  mode in words (UI-100); in allowlist mode it names what the chat reaches — its
  project, whose entries it reaches, and the chat's own entries when it names any
  (NET-28, NET-36).~~ Removed: the composer's network notice is gone; the mode
  and its entries are set and read on the chat settings page (NET-22 to NET-25,
  NET-38).
- **NET-38** The chat settings page's Network section lists the entries the chat
  names of its own in a field (`#chat-network-hosts`) holding them one per line,
  with a Save (`#save-chat-network-hosts`) that applies them to the chat when it
  is pressed; a list holding an entry that is not one of NET-7's forms changes
  nothing and the section shows the message for it (`#chat-network-hosts-error`,
  NET-11, CSET-7). Beside it the section shows the project's entries and the link
  to the projects page (NET-24).

### Telling the model

- **NET-27** The `shell` tool's description and the skill's instructions say
  what the chat's network setting is and what it means: loopback only and no name
  resolution in both restricted modes, the allowlisted hosts reached through
  `http_proxy` and `https_proxy` in allowlist mode, that a chat starts
  allowlisted (NET-1), that the hosts a chat reaches are the entries it names of
  its own and its project's (NET-28, NET-36), and that a command which cannot
  reach a host is expected rather than broken (SHELL-8, SHELL-9, ISOL-21).
- **NET-35** The `network` skill's instructions tell the model when to ask: a
  command that cannot reach a host is a reason to ask for that host (NET-30)
  rather than to give up, to reach for a chat with no limit, or to look for
  another way out (ISOL-21). They say what the card offers the user — the host
  for this chat or for its project (NET-32) — and that a host this chat's work
  alone needs is not one to put in the project's list.

## Stored data

Backward compatible, with two read-time rules and no rewrite. A chat file's
`network` key holds the mode and, in allowlist mode, the entries the chat names
of its own — `%{mode: :unrestricted}`, `%{mode: :allowlist}` with no `hosts` entry
when it names none, or `%{mode: :none}` — and is written for every mode, so a
chat that chooses the whole network has it again after a restart (STORE-53,
NET-36). A file that names no mode reads as the default of NET-1 (STORE-54)
where it read as unrestricted before: the chats the UI saves empty as they are
started (STORE-22), and every chat file written before this change, are limited
from then on, and one that wants the whole network again chooses it once (NET-1).
Where no limit can be built there is no change at all, and such a chat still
reads unrestricted (NET-20, NET-25). A file that holds hosts of its own — written
before the entries moved to the project, or since — reads them as the entries the
chat names of its own, which is what they are (NET-36), so it still reaches them
and no file is rewritten: there is nothing to migrate (NET-29 is retired).

A stored project gains one optional field, `allowlist` — a list of entries
(PROJ-49) — in the registry file (PROJ-2). A file written before this change has
none, and a project read without one has an empty list, which reaches nothing
(NET-10), so nothing is rewritten and the file's version stays 1. Elia's own
project, which the registry never holds (PROJ-3), keeps its list in the settings
database under a key of its own (PROJ-49): a database written before this change
has none, which reads as the empty list.

## Out of scope

- Packet-level filtering, IP or CIDR entries and rules per connection beyond an
  entry's own port (NET-9): with no route out there is nothing to filter, and a
  redirect of a transparent client is what the namespace deliberately prevents.
- TLS interception: the proxy forwards bytes and holds no certificate, so it
  knows a host name and not a request.
- A client that does not speak to a proxy — ssh, a database client, `ping`, a
  script's own sockets — reaching the network. It has no route out, which is
  what none mode shows.
- Name resolution inside a restricted namespace (NET-15).
- The server's own outbound requests — the model provider, `Req` in a skill of
  the harness's own — which are not a command's and are untouched.
- A record of what a chat's proxy refused, and a page to read it.
- A queue of host requests outside the chat that is waiting on one (NET-31).
- The deploy's own network use, which is not a chat's (NET-19).

## Implementation

`Elia.Net.Allowlist` (parsing an entry and deciding a host and port against a
list), `Elia.Net.Proxy` (the per-command and per-session proxy: a Unix-socket
listener, the decision, the byte forwarding), `Elia.Net.Relay` (the in-jail
script, bound into the jail read-only, that listens on the namespace's loopback
and carries it to the proxy's socket), `Elia.Shell` (the namespace and the relay
in the argv, the proxy's environment, and where the limit cannot be built),
`Elia.Terminal.Session` (a session's proxy and namespace), `Elia.Agent.Session`
(the setting, its event, its save), `Elia.Store` (`save/3`'s `network:`,
`load_network/1`), `Elia.Skills.Shell`, `Elia.Skills.Folder` and `Elia.Harness`
(pass the chat's setting from the tool context), `Elia.Skills.Tasks` (the
child's copy), `Elia.Projects` (a project's allowlist and where it is stored),
`Elia.Net` (a setting that carries the chat's
own entries, and the lists an effective setting holds), `Elia.Skills.Network`
(the tool, and which list an answer fills), `EliaWeb.ChatSettingsLive` (the
section, its field for the chat's own entries and the project's shown beside
them), `EliaWeb.ProjectsLive` (a project's field), `EliaWeb.ChatLive` (the
request card's decisions).

## Tests

- `test/elia/network_access_test.exs` (the mode's request refused and allowed,
  the namespace a command gets, the loopback it reaches itself, the proxy's
  environment, the
  caller with no chat, and what is left behind after a command — NET-1 to
  NET-3, NET-13 to NET-21; the namespace and loopback skipped where the host
  can't build a limit at all (NET-20)).
- `test/elia/net_allowlist_test.exs` (an entry's forms, the case, the suffix and
  the port rules, the empty list — NET-7 to NET-10).
- `test/elia/net_test.exs` (the modes, the default, what is stored, and the
  effective setting a chat's commands are limited by, its own entries and its
  project's together — NET-1, NET-6, NET-28, NET-36).
- `test/elia/net_proxy_test.exs` (a forwarded request, a refused one, the
  proxy resolving the host and reading the project's entries at the moment it
  decides — NET-6, NET-13, NET-14).
- `test/elia/store_test.exs` (the setting saved and loaded in every mode, a chat
  whose file names no mode, one written before this change, and a chat that has
  never been saved — STORE-53, STORE-54).
- `test/elia/agent_test.exs` and `test/elia/tasks_test.exs` (the setting, its
  event, the child's copy of the mode and of its parent's own entries, and the
  request that waits for an answer with the answer reaching the tool — NET-3,
  NET-4, NET-31, NET-37).
- `test/elia/projects_test.exs` (a project's allowlist read, saved and cleaned,
  and Elia's own project's list — NET-28, PROJ-49).
- `test/elia/skills/network_test.exs` (the tool's shape, the answer that allows
  for the chat and the one that allows for the project, the one that doesn't, an
  entry that is not one of NET-7's forms, a chat whose mode is not allowlist, an
  answer that names no list, and the skill's instructions — NET-30, NET-33 to
  NET-35, NET-39).
- `test/elia/shell_test.exs` (the argv of each mode — NET-12 to NET-16,
  NET-20).
- `test/elia/skills/shell_test.exs` (the tool's description and the skill's
  instructions, both naming the request tool — NET-27, NET-35).
- `test/elia_web/live/network_test.exs` (the section, its controls and its
  message, the mode applied on click, the chat's own entries in a field with its
  Save and the message for a bad entry, the project's entries shown beside it,
  the disabled control, the request card and its three buttons, and no network
  notice in the composer — NET-11, NET-22 to NET-25, NET-32, NET-38).
- `test/elia_web/live/chat_live_test.exs` (a chat the New chat button starts
  comes up allowlisted — NET-1, STORE-22).
- `test/elia_web/live/projects_live_test.exs` (a project's allowlist field, its
  Save, and the message for a list holding an entry that is not one of NET-7's
  forms — PROJ-50).
- No test: NET-5 and NET-18 — that a change reaches only later commands, and
  that a terminal keeps its namespace for its life, are read from where the
  setting is read when a process starts (NET-18's callers) rather than
  asserted by a run.
