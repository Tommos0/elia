# Network access

Status: Draft

A chat's commands reach whatever the machine reaches: the jail keeps the secrets
out of their hand (ISOL-5) and leaves the wire alone (ISOL-11), and an approval
prompt says nothing about where a command may connect. This spec gives every
chat a network setting beside its jail setting (ISOL-16) — unrestricted, as
every chat is today; an allowlist of hosts, reached only through a proxy the
harness serves; or no network at all.

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
  allowlist and none — plus, for allowlist, the chat's list of hosts; a chat
  whose saved file carries no value is unrestricted (STORE-53).
- **NET-2** The setting is saved with the chat (STORE-53) and loaded with it
  (STORE-54), so it survives a restart.
- **NET-3** A change to it is carried by the chat's `{:settings, settings}`
  event like its other settings (SESS-41, CSET-3), so every view of the chat
  follows it.
- **NET-4** A sub-task starts with a copy of its parent's setting and its own
  from then on (SUBTASK-30, ISOL-18), so changing either chat afterwards never
  affects the other.
- **NET-5** A change of mode applies to the commands and terminals that start
  after it: one already running keeps the network it started with (ISOL-19).
- **NET-6** A change to the allowlist applies to the next request a running
  command makes, because the proxy reads the chat's list when it decides
  (NET-14).

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
- **NET-11** The settings page saves a host list only when every entry is one of
  NET-7's forms: a list holding an entry that is not one changes nothing and the
  page shows the message for it (CSET-7, CSET-11).

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
  switch rather than the page's one Save (CSET-4, CSET-7), and applying one
  keeps the host list as it stands in the field (NET-24).
- **NET-24** In allowlist mode the section shows a host list field
  (`#network-hosts`) holding the chat's entries one per line, saved by the
  page's own Save (CSET-7, CSET-11).
- **NET-25** Where the limit cannot be built (NET-20) the section says so and
  its control is disabled (`#network-unavailable`), rather than showing a chat
  as limited where it is not (UI-68).
- **NET-26** The chat page says when the chat's network is limited, beside its
  jail warning in the composer toolbar (`#network-warning`, CSET-9), naming the
  mode in words (UI-100).

### Telling the model

- **NET-27** The `shell` tool's description and the skill's instructions say
  what the chat's network setting is and what it means: loopback only and no name
  resolution in both restricted modes, the allowlisted hosts reached through
  `http_proxy` and `https_proxy` in allowlist mode, and that a command which
  cannot reach a host is expected rather than broken (SHELL-8, SHELL-9, ISOL-21).

## Stored data

A chat file gains one optional key, `network`, holding the mode and, in
allowlist, the list: `%{mode: :allowlist, hosts: ["api.example.com"]}` or
`%{mode: :none}`. It is written only when the chat's mode is not unrestricted
(STORE-53), and is backward compatible in both directions: a file written before
this change has no key and reads as unrestricted (NET-1), and code that knows
nothing of the key ignores it, as `jail` was ignored while it did not exist. No
migration is needed.

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
child's copy), `EliaWeb.ChatSettingsLive` (the section), `EliaWeb.ChatLive` (the
toolbar warning).

## Tests

- `test/elia/network_access_test.exs` (the mode's request refused and allowed,
  the namespace a command gets, the loopback it reaches itself, the proxy's
  environment, the
  caller with no chat, and what is left behind after a command — NET-1 to
  NET-3, NET-13 to NET-21; the namespace and loopback skipped where the host
  can't build a limit at all (NET-20)).
- `test/elia/net_allowlist_test.exs` (an entry's forms, the case, the suffix and
  the port rules, the empty list — NET-7 to NET-10).
- `test/elia/net_proxy_test.exs` (a forwarded request, a refused one, the
  proxy resolving the host and reading the chat's list at the moment it decides
  — NET-6, NET-11, NET-13, NET-14).
- `test/elia/store_test.exs` (the setting saved and loaded — STORE-53,
  STORE-54).
- `test/elia/agent_test.exs` and `test/elia/tasks_test.exs` (the setting, its
  event, and the child's copy — NET-3, NET-4).
- `test/elia/shell_test.exs` (the argv of each mode — NET-12 to NET-16,
  NET-20).
- `test/elia/skills/shell_test.exs` (the tool's description and the skill's
  instructions — NET-27).
- `test/elia_web/live/network_test.exs` (the section, its controls and its
  message, the mode applied on click, the list saved by the page's Save, the
  disabled control, the chat page's warning — NET-11, NET-22 to NET-26).
- No test: NET-5 and NET-18 — that a change reaches only later commands, and
  that a terminal keeps its namespace for its life, are read from where the
  setting is read when a process starts (NET-18's callers) rather than
  asserted by a run.
