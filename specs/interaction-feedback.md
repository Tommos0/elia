# Interaction feedback

Status: Draft

Every control in Elia is a LiveView event: a tap goes over the websocket and the
page changes when the reply comes back. The controls said almost nothing about
that. Most buttons had no pressed state at all, and no control showed that an
event was in flight, so a tap that registered and is being worked on looked
exactly like a tap that missed the button — the user waits, wonders whether to
tap again, and taps again.

This spec is about the feedback a control gives *before* the page changes:
something on the press itself, so the tap is known to have landed, and something
while the server has not answered yet, so waiting reads as waiting rather than
as nothing happening.

The wait signal is LiveView's own, so nothing has to be tracked in Elixir:
LiveView puts `phx-click-loading` on the element whose `phx-click` it pushed, and
`phx-submit-loading` on a submitted form and on its controls
(`Phoenix.LiveView` JavaScript, `pushEvent`/`disableForm`), for exactly as long
as the reply is outstanding. A `phx-click` that only runs client-side commands —
the theme toggle's `JS.dispatch`, for instance — compiles to commands with no
push and so never gets the class: a control only reads as busy when the server
really is being waited on. A navigation is the case that already had feedback:
the top bar (`phx:page-loading-*` in `assets/js/app.js`).

## Requirements

- **FEED-1** Every control that acts shows a pressed state while it is held
  down (the `:active` state, from the pointer or the keyboard): a `button`, a
  `.btn`, an element with `role="button"` or `role="switch"`, and a navigation
  link — the header's nav, the sidebar's "New chat" and its chat rows, which
  LiveView renders as `a[data-phx-link]`. It comes from one rule in
  `assets/css/app.css`, not from a class each template adds, so a control has it
  without styling of its own and a control added later has it too. It is
  immediate, on the press itself, before any server reply. A button shrinks
  slightly; a navigation link, as wide as the list it sits in, tints instead.
  Taps are not delayed by the browser's double-tap-to-zoom wait
  (`touch-action: manipulation`).
- **FEED-2** A quick tap is still seen: the pressed state does not snap back
  the instant the pointer lifts, so a click that lasted 30ms is visible and not
  a flicker. A button's scale comes back up about 90ms later; a link's tint
  fades out over about 150ms.
- **FEED-3** A control whose event the server has not answered yet — the
  `.phx-click-loading` element itself, and a control carrying
  `.phx-submit-loading` as part of a submitted form — reads as *working*, not as
  disabled: it is dimmed and shows the progress cursor, and without a
  reduced-motion preference it pulses gently in place. It does not move, resize
  or change the layout, and it stops the moment the reply lands.
- **FEED-4** The wait state takes a moment to appear (about 150ms of not being
  answered), so a reply that comes straight back — the common case — never
  flashes a busy control at all.
- **FEED-5** The wait state belongs to the control the user acted on. The rest
  of a submitted form — its text input, its other elements, the `form` element
  itself, which LiveView marks as well — is not dimmed.
- **FEED-6** A control that is disabled and not waiting shows no pressed and no
  hover state, keeps the disabled look it has, and says so with its cursor. A
  control that is disabled *because* its round trip is in flight (LiveView
  disables the buttons of a submitted form) still shows the wait state of
  FEED-3.
- **FEED-7** Keyboard focus is visible: a control focused with the keyboard —
  but not one just clicked with the pointer — shows an outline, so a keyboard
  user can see which control Enter or Space will act on.
- **FEED-8** With `prefers-reduced-motion: reduce` neither state moves: the
  press is a change of colour rather than of size, nothing pulses, and nothing
  eases. Both states stay as visible as they are for everyone else.
- **FEED-9** This is every page's feedback, not the chat page's: the header and
  its theme toggle, the sidebar (a chat row tapped to go to that chat dims until
  the chat is there), the composer and the buttons in an approval card, the
  chat settings page, the projects, settings, files and logs pages.

## Out of scope

- A spinner drawn inside a control, or swapping a button's label for its
  progress ("Saving…"): FEED-3 says the control is busy as a whole, and a label
  of its own is up to the button that needs it (`phx-disable-with`).
- Tracking the round trip in Elixir, or a timeout that reports a slow server:
  FEED-3 is LiveView's own loading class, which ends the way the request does.
- Ignoring a second tap while an event is in flight: LiveView already ignores a
  second click on an element that has one pending.
- The transcript's own streaming, tool and task status display (UI-11, UI-16,
  UI-44): those report server-side work that outlives a click.
- The sidebar drag handle (UI-35), a drag rather than a tap.

## Implementation

- `assets/css/app.css` — the shared pressed, waiting, focus and disabled states
  for every page (FEED-1 - FEED-9), keyed on the `phx-click-loading` and
  `phx-submit-loading` variants the file already declares.
- The templates' own `active:scale-*` classes come out as the shared rule
  replaces them (`lib/elia_web/live/chat_live.ex`,
  `lib/elia_web/live/chat_settings_live.ex`,
  `lib/elia_web/live/settings_live.ex`, `lib/elia_web/live/projects_live.ex`).

## Tests

- `test/elia_web/browser/interaction_feedback_test.exs` (FEED-1 - FEED-7,
  FEED-9): a real headless Chromium (`specs/browser-tests.md`) is the only layer
  that can answer this — the states are computed styles and a live class, which
  `Phoenix.LiveViewTest` never sees. A held pointer, a click with the socket
  slowed down (`liveSocket.enableLatencySim/1`) and a keyboard tab are the
  inputs; `ELIA_BROWSER_TESTS=1 mix test --only real_browser` runs them, after
  `mix assets.build`.
- FEED-8 is checked by hand, with the operating system's "reduce motion"
  setting: the wrapper this project drives Chromium through has no way to
  emulate the media feature.
