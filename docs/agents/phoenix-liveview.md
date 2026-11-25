# Phoenix and LiveView

Read this before touching LiveViews, HEEx templates, the router, or forms. Styling and components are in `docs/agents/frontend.md`.

Reference code: `lib/elia_web/live/chat_live.ex` (chat, streams, hooks, `to_form` from params), `lib/elia_web/router.ex`.

## Router

- A `scope` alias is prefixed onto every route inside it. Don't add your own `alias` for routes. In the default `:browser` scope, `live "/weather", WeatherLive` points to `EliaWeb.WeatherLive`.
- LiveViews are named with a `Live` suffix (`EliaWeb.SystemLive`).
- `Phoenix.View` is gone. Don't use it.
- A plug that answers — `send_resp`, `send_file`, `halt` — must **also halt**,
  and the halt has to cover every answer it gives (`halt(conn)` after the
  `case`, not inside one branch). A plug in the endpoint's own plug list that
  answers without halting lets the next plug answer a connection that is
  already sent, and the symptom is a `Plug.Conn.AlreadySentError` raised from
  `lib/elia_web/endpoint.ex:1`, which says nothing about which plug it was.
  `EliaWeb.PreviewHost` is the one that sits at the top of the endpoint
  (`specs/preview-host.md`).
- A plug that must be reached *before everything* — ahead of the static files,
  the session and the router — goes in `EliaWeb.Endpoint`'s plug list, not the
  router: a router plug runs only after the static files have had their turn.

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
- A function component sees **only the attributes passed to it**, not the caller's assigns: `assigns[:x]` inside `Layouts.app` is `nil` for an assign the page holds and did not hand over. So a new piece of the header's state is a new attr on `Layouts.app` **and** an edit at all ten `<Layouts.app ...>` call sites (the new-project modal, PROJ-55). `required: true` on the attr makes a page that misses it a compile error rather than a header quietly missing a control, which is what `active_chats` does. The failure the other way round is a shape with no error at all: the modal simply never rendered in the test.
- The heavy state that hangs off every page (`EliaWeb.ChatList`, `EliaWeb.ActiveChats`, `EliaWeb.NewProject`) is one module per control, registered in the router's `on_mount` and attached as a `:handle_event` hook, so a page wires nothing; a hook that does not know an event returns `{:cont, socket}` and the next one sees it. `EliaWeb.NewProject` needs two functions of the chat list's own state, so they are public on `EliaWeb.ChatList` (`refresh_projects/1`, `close_menu/1`) rather than a second copy of `projects_open` two modules disagree about.

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
- A colocated hook's name is resolved against the module its markup is compiled in (`ColocatedHook` builds `"<module>.<Name>"`), so markup that moves to another module takes its hooks with it and the compiler then reports the *caller* as undefined — `<.Foo.bar>` is a **local** component call (a leading dot means local), a remote one has no dot at all (`<Foo.bar>`). Both traps were hit moving a chat row's menu into `EliaWeb.ChatRowMenu` (ACTIVE-8). So a hook a second module draws is compiled where the markup lives, and `phx-hook=".Name"` in the caller just names it.
- External hooks go in `assets/js/` and are passed to the `LiveSocket` constructor in `app.js` (`assets/js/highlight.js` is an example).
- Push to the client with `push_event/3`, and always return or rebind the socket. Handle it in the hook with `this.handleEvent`. Clients push with `this.pushEvent` and the server replies with `{:reply, map, socket}`.

## Showing a modal before it is deployed

`bin/preview` navigates and screenshots; it cannot click (PREVIEW, "scripted
interaction" is out of scope). So a preview of anything the user opens — a
modal, a menu — is taken by temporarily forcing that state open in the
worktree's own code (a `closed()` returning `open: true`, a `projects_open:
true`), running `bin/preview`, and reverting the edit before the commit: say in
the reply that the picture was taken that way. Two states worth showing means
two runs — a preview overwrites its own file names (PREVIEW-4) — and a picture
worth keeping can be copied aside under a name of its own in `tmp/preview/`,
which the same route serves.

## Forms

- Build forms with `to_form/2` in the LiveView, then `<.form for={@form} id="...">` and `<.input field={@form[:field]} />`.
- From params: `to_form(params)`, or `to_form(params, as: :user)` to nest. The map needs string keys.
- **Never** pass a changeset to the template, use `<.form let={f}>`, or use `Phoenix.HTML.form_for`. This project has no Ecto, so forms are normally built from params.
- A `<.form>` **inside** another one is the trap to avoid: an inner form makes the outer one's own controls unreachable — `view |> form("#outer", ...)` then fails to find an input inside it, and the failure reads as an HTML problem rather than a nested form. The settings page hit this when the Network section got a Save of its own: the section had to move *out* of `#settings-form` (CSET-7, NET-38), so a new form in a section means checking whether that section is inside another one.

## The transcript's Markdown

Assistant text is rendered by `EliaWeb.Markdown.to_html/2`
(`lib/elia_web/markdown.ex`): it parses the text once with MDEx and runs three
passes over the AST before rendering — `EliaWeb.FunctionLinks` (an Elixir
function mention becomes the Files page at its definition's line, FUNC),
`EliaWeb.FileLinks` (a path mention, FLINK) and `EliaWeb.SpecRefs` (a cited
requirement's tooltip, CITE). Each takes a `%MDEx.Document{}` and returns one,
and each resolves its mentions in a chat's context, `%{chat_id, root}` (a
`EliaWeb.FileLinks.t()`); with no context a pass does nothing.

- A new kind of mention is another such pass, added to the chain in `to_html/2`.
  Order matters: the file pass replaces an inline code span with a link, and the
  later passes leave a `%MDEx.Link{}` alone.
- Splice real nodes (`%MDEx.Link{}`, `%MDEx.Text{}`, `%MDEx.Code{}`), not an
  `%MDEx.Raw{}` holding HTML: a later pass walks nodes and never looks inside a
  raw string, so markup spliced as raw is not visited again. Raw is for text
  *inside* a code span, where there are no nodes to have.
- The renderer escapes a `%MDEx.Text{}` literal itself, so a label may hold `<`
  or `&`; it encodes nothing, so build a URL with `URI.encode_query/1`. A file's
  page at a line is `EliaWeb.FileLinks.line_url/3`
  (`/files?chat=<id>&path=<path>&line=<n>`, EXPL-27).
