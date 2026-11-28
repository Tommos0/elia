# Project secrets

Status: Implemented

A project keeps its secrets in a `.env` file in its own folder. Elia reads it,
hands the values to the commands of chats in that project — so the project's own
app can use a key without the key ever being written into a chat — and names the
variables in the system prompt, so the agent can write code that reads them
without being told a value. Every occurrence of a value in what a chat sends to
a model is redacted: an `env`, a `cat .env`, a failing test that prints a key
leaves the real value in the transcript for the user to read, and
`[redacted:NAME]` in the request the model receives. Redaction is best effort —
a value is matched as it stands, so an encoding of it is not covered. Elia only
reads the file: nothing here writes it and no stored shape changes. Elia's own
tree ignores `/.env`, so a deploy's stash (DEPLOY-37) never puts the live
tree's own file aside.

## Requirements

### The file

- **SECRET-1** A project's secrets are the variables of a `.env` file in the
  project's folder (PROJ-1): every line that is not blank and whose first
  non-blank character is not `#` is an assignment — an optional `export `
  before the name, the name up to the first `=`, and the rest of the line the
  value — with the name and the value trimmed and the value read without the
  matching single or double quotes around it. A line with no `=`, and one whose
  name is not a variable name (`[A-Za-z_][A-Za-z0-9_]*`), are ignored, and a
  repeated name takes the value of its last line.
- **SECRET-2** A project with no `.env`, with one that cannot be read, and with
  one that holds no assignment, has no secrets, and none of those is an error.
- **SECRET-3** A chat's secrets are its project's (SECRET-1), read from that
  project's folder however the chat works: a chat in Elia's own project reads
  the live tree's file (PROJ-3, DEPLOY-1) while it works in a worktree of its
  own (DEPLOY-28).
- **SECRET-4** The file is read when a request is built and when a command is
  run, so an edit to it applies from the next one without a restart.

### The commands get the values

- **SECRET-5** A command a chat runs — a `shell` call, and a terminal session
  (TERM-7) — has that chat's secrets in its environment beside the ones ISOL-8
  allows, jailed (ISOL-16) and unjailed (ISOL-31) alike; a caller that sets the
  same name itself wins (ISOL-8), and a command run for no chat (DEPLOY-18) is
  given none of them.

### The request is redacted

- **SECRET-6** Every exact occurrence of a secret's value in what a model
  request carries is replaced by `[redacted:<name>]` before the request leaves
  the harness, `<name>` being the name of the entry the value came from
  (SECRET-1) — the name of the provider's key for one of those (SECRET-7).
- **SECRET-7** What counts as a secret to redact is every non-empty value of the
  chat's secrets that is at least `@min_length` characters long, every non-empty
  value of an entry whose name holds one of `@name_words` (case-insensitively)
  however short it is, and every API key Elia holds for its providers
  (`Elia.LLM.api_key/1`, CONF-5), whatever its length.
- **SECRET-8** Redaction covers the whole request: the system prompt — the
  project instructions and each skill's instructions included (SKILL-5,
  PROJ-15) — the tool definitions, and every message's user text, assistant text
  and reasoning, tool call inputs and tool results (LOOP-3), and the request a
  compaction summary is made with (COMPACT-29).
- **SECRET-9** Where one secret's value is part of another's, the longer is
  redacted first, so a longer value is never left partly redacted.
- **SECRET-10** Redaction changes the request and nothing else: the transcript
  keeps what a message or a tool result actually held, so the user reads the
  real value in the chat and the next turn's request is redacted again from that
  same text.
- **SECRET-11** A value is matched as it stands, so an encoding of it (base64,
  URL-encoded, hex) and one split across lines are not redacted.

### The model is told the names

- **SECRET-12** The system prompt of a chat in project P carries a section
  naming P's secrets — their names, never their values (SECRET-6) — and no such
  section when P has none (SKILL-5, PROJ-15).

## Configuration

- `@min_length` is 8 characters: a shorter value is redacted only through
  `@name_words` (SECRET-7), so an entry like `PORT=4000` does not turn every
  `4000` in a transcript into a redaction.
- `@name_words` is `api`, `auth`, `cert`, `credential`, `key`, `pass`,
  `private`, `salt`, `secret`, `signature`, `token`, matched against a name
  case-insensitively.

## Out of scope

- Elia reads the file and never writes it: the interface has no editor for a
  project's `.env`, a project created from a name (PROJ-34) is given none, and
  making the file is the user's own step — a command they run, or the agent
  writing a file whose value they gave it.
- Only the values SECRET-7 describes are redacted: an encoding of one
  (SECRET-11), a secret that reaches a message before it is in the file, and a
  server-side secret that is neither a provider key Elia holds nor a project
  secret — the push keys and `SECRET_KEY_BASE` in the settings database and the
  server's environment — are not.
- Redaction covers what the model is sent, not the wire: a command can still
  send a secret wherever its network setting reaches (NET-1, NET-13), and the
  approval prompt (SHELL-1) is what stands in front of that.
- A project's `.env` is not read for anything else: it is not a place for a
  project's settings, and no other part of the harness reads it.

## Stored data

Nothing is stored: Elia only reads the project's `.env` (SECRET-1, SECRET-4), and
reading it adds or changes no key of a saved chat and none of the settings
database, so no stored shape moves and no migration is needed. The file itself
is the user's, and one an older version read is read the same way.

## Implementation

`Elia.Secrets` (reading the file, what is a secret and redaction),
`Elia.Agent.Loop` and `Elia.Agent.Session` (the redacted request, the named
secrets in the estimate), `Elia.LLM.Compaction` (the summariser's own request),
`Elia.LLM.Context`, `Elia.Skills`, `Elia.Skills.Shell`, `Elia.Skills.Terminal`,
`Elia.Terminal.Session`, `EliaWeb.ChatLive`.

## Tests

- `test/elia/secrets_test.exs` (the file it reads and how it is parsed, a
  project with none, the project a chat's secrets come from, an edit read again
  at once, the values it redacts and those it does not, the placeholder, the
  longest-first rule and an encoding left alone — SECRET-1 to SECRET-4,
  SECRET-7, SECRET-9, SECRET-11).
- `test/elia/agent_test.exs` (the request a turn sends is redacted — in the
  system prompt and in a tool result — while the transcript keeps the real text
  — SECRET-6, SECRET-8, SECRET-10).
- `test/elia/llm/compaction_test.exs` (the default summarizer's own request —
  SECRET-8).
- `test/elia/skills/shell_test.exs` (a command's environment, jailed and
  unjailed, and a command that belongs to no chat — SECRET-3, SECRET-5).
- `test/elia/skills/terminal_test.exs` (a terminal session's environment —
  SECRET-5).
- `test/elia/skills_test.exs` (the section naming a project's secrets —
  SECRET-12).
- `test/elia/llm/context_test.exs` (the system bucket's "Project secrets" child —
  SECRET-12).
