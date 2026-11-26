# Flash messages

Status: Implemented

A notice the app shows over the page — "Chat deleted.", "Project deleted.",
"Projects root saved.", an error for something that did not work — is a flash:
the event handler that produced it puts it in the LiveView's flash
(`Phoenix.LiveView.put_flash/3`) and the layout draws it in the corner
(`EliaWeb.CoreComponents.flash/1`, under `EliaWeb.Layouts.flash_group/1`). The
notice's own × dismisses it. It used to stay there until that × was pressed, so a
message about something that had already happened sat over the page waiting to be
dismissed by hand.

This spec is how long such a notice stays: it goes away by itself about a second
after it appeared. Its × still hides it at once, for a notice the user has read,
and the two notices the connection itself draws are not on that timer — they are
shown while the page is disconnected and hidden when it reconnects (CONN).

## Requirements

- **FLASH-1** A notice drawn from the LiveView's flash — `#flash-info` and
  `#flash-error`, whichever handler put it there — goes away on its own about a
  second after it appeared, with nothing pressed and no reload: still on screen a
  few hundred milliseconds after the event that put it there, and gone by two
  seconds.
- **FLASH-2** A notice's × hides it at once, without waiting for that second, and
  clears it from the LiveView's flash, so nothing draws it again.
- **FLASH-3** A notice the connection draws — "We can't find the internet" and
  "Something went wrong!" (`#client-error`, `#server-error`) — is not on that
  timer: it stays for as long as the page is disconnected and goes when the
  connection is back, however long that takes (CONN-1, CONN-4).

## Out of scope

- Which handler puts which message, and what a message says: that belongs to the
  feature that puts it there (UI-65, PROJ-39).
- A notice raised while the page has no connection: it is drawn when the reply
  arrives, and is on the same timer from then.
- Several notices of a kind, stacked or waiting their turn: the page holds one
  notice per kind, which the flash's own shape decides.
- A notice that stays until the user acknowledges it.

## Implementation

- `EliaWeb.Layouts.flash_group/1`, with the colocated hook that times a notice
  out.
- `EliaWeb.CoreComponents.flash/1`, the notice, its × and the `lv:clear-flash`
  push that clears it.

## Tests

- `test/elia_web/browser/flash_test.exs` (FLASH-1 to FLASH-3) — a timer is the
  browser's, and so is the connection FLASH-3 is about, so these are read in a
  real headless Chromium (BROWSER-7) and never by `Phoenix.LiveViewTest`.
