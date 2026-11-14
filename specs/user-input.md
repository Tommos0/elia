# Structured user input

Status: Implemented

Sometimes only the user can settle something: a decision between two ways of
doing a job, a value the model cannot look up, a choice that is theirs to make.
Today the model's only way to ask is a sentence in its reply, and the turn ends
there — the user types prose into the composer, and the model has to read the
answer back out of a chat message. When the model can name the choices, one
click should be enough: the question is a card in the transcript with a button
per option, and the user's answer comes back to the model as the result of the
call that asked.

The turn does not end while a question is open. The loop waits for the answer
the way it waits for a tool approval (LOOP-21), so the answer arrives as the
`ask_user` call's result and the model carries on in the same turn with it in
hand. Nothing new is saved: the question is a tool call and the answer is its
result, so a chat reopened later shows both (STORE-1).

## Requirements

- **ASK-1** The built-in `user-input` skill (SKILL-7) carries one tool,
  `ask_user`, whose input is `question` (a string, required) and `options`
  (optional): an array of at most six short strings, each a choice the user can
  pick. The tool never needs approval (APPR-7).
- **ASK-2** A call to `ask_user` does not run when the model makes it: the turn
  puts the question to the user and waits for the answer, and the answer is the
  call's result (LOOP-21). The turn goes on in the same step sequence, so the
  model gets the answer in hand rather than at the start of a new turn.
- **ASK-3** While a question is unanswered the session's status is
  `:awaiting_input` (SESS-4, SESS-34) and the call's status is
  `:awaiting_input`; once the user answers it the call's status is `:answered`,
  and the call runs as usual after that (LOOP-11).
- **ASK-4** The user answers by picking an option or by writing an answer of
  their own; an answer that is blank once trimmed is not accepted and changes
  nothing (SESS-34). The card offers both (UI-75).
- **ASK-5** The result the model is given is `The user answered: "<answer>"`,
  with the answer verbatim.
- **ASK-6** Every call awaiting an answer in a step must be answered before any
  of that step's tools run, exactly as with approvals (APPR-5): several
  questions in one step are all put to the user at once (APPR-3), each is
  answered separately (APPR-4), and the session returns to `:running` when the
  last one is answered. `Elia.Agent.answer/3` answers one call and returns
  `{:error, :not_pending}` for a call that isn't awaiting an answer, as
  `decide` does (APPR-4).
- **ASK-7** A question never traps the chat: stopping the turn (SESS-8) closes
  the call with an error result ("Cancelled by the user.") like any other
  unanswered call, and ending the turn clears the session's pending questions
  (SESS-34). An answer that arrives after that returns `{:error, :not_pending}`.
- **ASK-8** Time spent waiting for an answer does not count against the turn's
  wall-clock budget, as with approvals and a pause (LOOP-20).
- **ASK-9** A question asked in a sub-task chat is answered in that chat, and
  the parent's task card (UI-44) and the sidebar (UI-47) say the child is
  waiting for an answer, so a child's question is not missed from the parent.
- **ASK-10** A chat that is waiting for an answer is never shown as idle or
  working: the sidebar says so (UI-59), and the compact view's one-line summary
  names it and offers the way back to the card (UI-62). A question card is shown
  in the compact view too, since it is addressed to the user rather than a
  detail of the agent's work (UI-61).
- **ASK-11** The `user-input` skill's instructions tell the model when to ask:
  when the answer changes what it does and it cannot settle it itself (read the
  file, run the test, check the docs); to name the choices it can see as
  `options`, short and at most six, so the user can answer with one click; that
  the user can always answer in their own words instead; and not to ask about
  things it can find out or decide itself, nor for permission to carry on.
- **ASK-12** A call whose input doesn't match the tool's schema never reaches
  the user: it gets an error result and no question is put (LOOP-8, which checks
  an array's item type and `maxItems` as well).

## Out of scope

- Picking several options at once, and a question with no free-text answer.
- Folder skills asking: `tools.json` tools cannot declare that they ask the user
  (a built-in tool can, `Elia.Tool.asks_user`).
- Keeping a question open across a restart: a restart closes it as an unanswered
  call (SESS-21), as with any other tool call that was running.
- The sub-task brief, which still tells a child to prefer noting a question in
  its `questions` result (SUBTASK-1) over waiting for the user.

## Implementation

`Elia.Skills.UserInput` (the skill and the `ask_user` tool), `Elia.Tool`
(`asks_user`), `Elia.Agent.Loop` (the await, LOOP-21), `Elia.Agent.Session`
(the pending question, `:awaiting_input`), `Elia.Agent` (`answer/3`,
`awaiting_input/0`), `EliaWeb.ChatLive` (the question card and the indicators).

## Tests

`test/elia/user_input_test.exs` (the tool: its schema, the result text, and a
call whose input doesn't match the schema — ASK-1, ASK-5, ASK-11, ASK-12), `test/elia/agent_test.exs` (the turn waits and carries
on, the statuses, `answer/3`, several questions, stop, the budget, ASK-2 to
ASK-9), `test/elia_web/live/user_input_test.exs` (the card, the buttons, the
text answer, the indicators, ASK-10, UI-75, UI-76).
