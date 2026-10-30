# Phoenix and LiveView

Read this before touching LiveViews, HEEx templates, the router, or forms. Styling and components are in `docs/agents/frontend.md`.

Reference code: `lib/elia_web/live/chat_live.ex` (chat, streams, hooks, `to_form` from params), `lib/elia_web/router.ex`.

## Router

- A `scope` alias is prefixed onto every route inside it. Don't add your own `alias` for routes. In the default `:browser` scope, `live "/weather", WeatherLive` points to `EliaWeb.WeatherLive`.
- LiveViews are named with a `Live` suffix (`EliaWeb.SystemLive`).
- `Phoenix.View` is gone. Don't use it.

## HEEx

- Use `~H` or `.html.heex`. **Never** use `~E`.
- Put a unique DOM `id` on key elements (forms, buttons, containers). Tests rely on them.
- Interpolate with `{...}` in attributes and tag bodies. Use `<%= ... %>` only for block constructs (`if`, `cond`, `case`, `for`) in tag bodies. Never write `id="<%= @x %>"`.
- Use `<%= for item <- @items do %>` (or `:for`) to generate content. **Never** use `Enum.each`.
- There's no `else if`. Use `cond`:

      <%= cond do %>
        <% a -> %> ...
        <% b -> %> ...
        <% true -> %> ...
      <% end %>

- Class lists use list syntax, and `if`s inside `{...}` need parentheses:

      <a class={["px-2", @flag && "py-5", if(@x, do: "a", else: "b")]}>

- Comments are `<%!-- comment --%>`.
- To show literal `{` or `}` in `<pre>`/`<code>`, put `phx-no-curly-interpolation` on the parent tag.

## LiveView

- Use `<.link navigate={...}>` / `<.link patch={...}>` and `push_navigate` / `push_patch`. **Never** use `live_redirect` or `live_patch`.
- Avoid LiveComponents unless you have a specific need.

### Streams

- Use streams for collections: `stream/3`, `stream_insert/3`, `stream_delete/3`.
- The parent element needs `phx-update="stream"` and a DOM id. Each child uses the stream id:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>{msg.text}</div>
      </div>

- Streams aren't enumerable. To filter or refresh, refetch and `stream(socket, :name, items, reset: true)`.
- Streams have no count or empty state. Track a count in a separate assign. For an empty state, use a sibling `<div class="hidden only:block">`.
- If an assign changes content inside a streamed item, re-stream that item with `stream_insert`.
- **Never** use `phx-update="append"` or `"prepend"`.

### Hooks and JS interop

- `phx-hook` always needs a unique `id`. If the hook manages its own DOM, also set `phx-update="ignore"`.
- Inline scripts: **always** use a colocated hook (`<script :type={Phoenix.LiveView.ColocatedHook} name=".Name">`). The name must start with `.`. Never write raw `<script>` tags.
- External hooks go in `assets/js/` and are passed to the `LiveSocket` constructor in `app.js` (`assets/js/highlight.js` is an example).
- Push to the client with `push_event/3`, and always return or rebind the socket. Handle it in the hook with `this.handleEvent`. Clients push with `this.pushEvent` and the server replies with `{:reply, map, socket}`.

## Forms

- Build forms with `to_form/2` in the LiveView, then `<.form for={@form} id="...">` and `<.input field={@form[:field]} />`.
- From params: `to_form(params)`, or `to_form(params, as: :user)` to nest. The map needs string keys.
- **Never** pass a changeset to the template, use `<.form let={f}>`, or use `Phoenix.HTML.form_for`. This project has no Ecto, so forms are normally built from params.
