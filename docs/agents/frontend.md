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
- Keep the UI usable and consistent with the existing pages. Use transitions and hover states where they help (buttons, lists), and give loading and empty states.

## JS

- Only the `app.js` and `app.css` bundles are supported.
- You can't reference an external `src` or `href` in the layouts. Import vendor dependencies into `app.js` or `app.css`.
- **Never** write inline `<script>` tags in templates. Use a colocated hook (see `docs/agents/phoenix-liveview.md`).

## Components and icons

- Wrap LiveView templates in `<Layouts.app flash={@flash}>`. (`Layouts` is aliased in `lib/elia_web.ex`.) There's no auth, so no `current_scope` is passed.
- **Never** call `<.flash_group>` outside `layouts.ex`.
- Use `<.icon name="hero-x-mark" class="w-5 h-5"/>` for icons. Never use `Heroicons` modules.
- Use `<.input>` from `core_components.ex` for form inputs. If you pass your own `class`, no default classes are inherited, so your classes must style the input fully.
