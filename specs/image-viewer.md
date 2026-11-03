# Image viewer

Status: Draft

An image in an assistant message is usually a screenshot — a UI preview
(PREVIEW-8), a chart — and at the transcript's width it is often too small to
read. Clicking it opens a viewer *over* the chat, in the page itself: a new tab
or a navigation away loses the chat, and in an installed app (PWA) the Android
back button then has nothing to go back to and closes the whole app. So the
viewer lives in the page, it has a close button of its own, and it adds one
entry to the browser history, which is what lets the back button close it too.

## Requirements

- **IMG-1** Clicking an image in the transcript — an assistant message's or a
  streaming draft's (UI-25, UI-27) — opens a viewer over the page: never a new
  tab, never a navigation away, with the chat behind it left where it was (its
  scroll position included). An image inside a link (`[![…](…)](…)`) keeps its
  link behaviour instead.
- **IMG-2** The viewer is a full-screen overlay (`#image-lightbox`) over the
  whole page, the sidebar included, on a dark backdrop. It shows the image
  (`#image-lightbox-image`) scaled down to fit the viewport, its aspect ratio
  kept and never enlarged past its own size, carrying the alt text of the image
  in the transcript, and the image can still be pinch-zoomed.
- **IMG-3** The viewer has a visible close button of its own
  (`#image-lightbox-close`, a cross in the top corner) and closes on it, on a
  click or tap on the backdrop — never on the picture itself — and on Escape, so
  closing it never depends on the browser's or the phone's own back control. A
  LiveView navigation (a click on a chat or another page link) closes it too.
- **IMG-4** Opening the viewer adds one entry to the browser history with the
  URL unchanged, so the back button — Android's in an installed app (PWA)
  included — closes the viewer and returns to the chat instead of leaving the
  page or closing the app. Closing the viewer by any other way (IMG-3) goes back
  over that entry, so the back button afterwards does what it did before.
- **IMG-5** While the viewer is open, focus is on its close button and a touch
  drag over it does not scroll the chat behind it.
- **IMG-6** The viewer is an element the server renders hidden — outside the
  transcript's stream, so patching it never touches the viewer — with the
  `.ZoomImage` colocated hook on it (`EliaWeb.ChatLive`). The hook delegates
  clicks on images, so the transcript's own markup is untouched and an image in
  a streaming draft opens the viewer too; no inline script is added
  (`docs/agents/frontend.md`).

## Out of scope

- Zoom and pan controls, a gallery for several images, keyboard arrows between
  them, swipe to close.
- Opening the image file itself in a new tab or downloading it: the viewer is
  the whole answer to "too small to read", and saving the picture is the
  browser's own long-press or right-click.
- Images outside the transcript: the file explorer shows files as plain text
  (EXPL-14), and video is not an image.

## Implementation

- `EliaWeb.ChatLive` (the `#image-lightbox` markup and the `.ZoomImage` hook),
  the `.markdown img` styling and the viewer's hidden state in
  `assets/css/app.css` (PREVIEW-8).

## Tests

- `test/elia_web/browser/chat_browser_test.exs` (IMG-1 - IMG-5): the viewer,
  its closing ways and the history entry, in a real headless Chromium, since no
  other layer runs JavaScript. Run with `ELIA_BROWSER_TESTS=1 mix test --only
  real_browser` (BROWSER-5).
- `test/elia_web/live/chat_live_test.exs` (IMG-6): the viewer's markup and the
  hook on it.
