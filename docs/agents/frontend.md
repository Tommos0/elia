# Frontend: CSS, JS and components

Read this before touching `assets/`, `lib/elia_web/components/`, or templates' styling.

Files: styles in `assets/css/app.css`, JS in `assets/js/app.js`, shared components in `lib/elia_web/components/core_components.ex`, layouts in `lib/elia_web/components/layouts.ex`. `lib/elia_web/live/chat_live.ex` is the reference LiveView.

## Tailwind and CSS

- Tailwind v4 needs no `tailwind.config.js`. `app.css` uses this import syntax, which you must keep:

      @import "tailwindcss" source(none);
      @import "phoenix-colocated/elia/colocated.css";
      @source "../css";
      @source "../js";
      @source "../../lib/elia_web";

- daisyUI is loaded as a plugin in `app.css` and is available. Prefer Tailwind utilities for custom layout, and match the existing components and styles first.
- **Never** use `@apply` in raw CSS.
- The theme is the `data-theme` attribute on `<html>` (`light` or `dark`), set by
  the root layout's own script from the stored preference or the system's, and
  `app.css` defines the variant for it —
  `@custom-variant dark (&:where([data-theme=dark], [data-theme=dark] *))` — so a
  `dark:` utility is how a colour that differs by theme is written. The palette
  itself is the two daisyUI theme blocks in `app.css` (`--color-primary`,
  `--color-base-content`, …); the dark theme's primary is blue where its
  `base-content` is the off-white text colour, which is what a control that has
  to be tinted *and* off-white in dark mode wants (`text-primary
  dark:text-base-content`).
- A class is only in the stylesheet once the assets have been rebuilt
  (`mix assets.build`, or the dev watchers in `config/dev.exs`). A deploy
  rebuilds the live tree's front end itself — installing the trunk's Node
  packages and running the build (DEPLOY-19) — but that reaches a *page* only
  when the browser reloads, and a page that was already open keeps the
  stylesheet it loaded while a hot reload patches new markup into it (HOT-8). A *new* class therefore must never be what keeps the layout on screen — a height, a `min-height: 0` that lets a pane shrink — because the page gets the new markup and no rule for it: that belongs in the element's own markup (`style`), as `#app-shell`'s height is (UI-78). For the same reason, never hide or overlay something with a *new* rule, or keep it hidden by one (IMG-7).
- Keep the UI usable and consistent with the existing pages. Use transitions and hover states where they help (buttons, lists), and give loading and empty states.

## JS

- Only the `app.js` and `app.css` bundles are supported.
- You can't reference an external `src` or `href` in the layouts. Import vendor dependencies into `app.js` or `app.css`.
- **Never** write inline `<script>` tags in templates. Use a colocated hook (see `docs/agents/phoenix-liveview.md`). The one script written by hand is in the root layout's head (`components/layouts/root.html.heex`), which applies a preference while the page is parsed rather than after it: the theme, and the UI scale (CONF-30–CONF-35). A hook runs only once the bundle has loaded, so a preference applied there would be painted at the old value first and jump.

## Layers

Overlays have a fixed order (UI-94): the chat list's backdrop is `z-20`, the
drawer (`#chats-drawer`, and the chat page's `#sidebar`) `z-30`, and the menus
the header opens (`#project-menu`, `#active-chats-menu`) `z-40` — so a menu a
user is choosing from is above a drawer that is open at the same time, rather
than behind it (which is how they are stacked in the tree: same `z-index`,
later wins). The image viewer is the exception, `z-50` over the whole page
(IMG). A new panel that must sit over the drawer goes above `z-30`; one that
belongs under a header menu goes below `z-40`.

## Components and icons

- Wrap LiveView templates in `<Layouts.app flash={@flash}>`. (`Layouts` is aliased in `lib/elia_web.ex`.) There's no auth, so no `current_scope` is passed.
- **Never** call `<.flash_group>` outside `layouts.ex`.
- Use `<.icon name="hero-x-mark" class="w-5 h-5"/>` for icons. Never use `Heroicons` modules.
- Use `<.input>` from `core_components.ex` for form inputs. If you pass your own `class`, no default classes are inherited, so your classes must style the input fully.

## UI previews

- `bin/preview <path>…` screenshots a page whole, but a page that scrolls is
  only captured as far as the viewport: what is below it is not in the picture,
  however tall `full_page` claims to be. A long page — a project's own page with
  30 chats under its header — hides its lower sections unless the viewport is
  made tall enough: `ELIA_PREVIEW_HEIGHT=2600 bin/preview /p/harness`.
