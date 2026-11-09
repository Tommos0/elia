# Hot reload

Status: Implemented

Hot reload is the soft deploy mode (DEPLOY-6): after DEPLOY-5 has run the full
test suite and brought the trunk `master` to `live`, it recompiles the live tree
and loads the result into the running server, keeping running state. Its
control is the "Hot reload" button on the Settings page (CONF-19); the other
deploy mode is a restart (DEPLOY-7). There is no `hot_reload` tool: an agent's
own step is to merge its branch into the trunk (DEPLOY-13), and deploying is the
user's.

## Requirements

- ~~**HOT-1** `hot_reload` needs approval.~~ *Retired: `hot_reload` is no longer
  a tool. The Settings page's deploy controls are the user's own click
  (DEPLOY-6).*
- **HOT-2** Hot reload is available only when Mix is loaded and the endpoint's
  code reloader is on (`code_reloader`, HOT-7). Otherwise it returns an error
  saying so, and nothing is merged or loaded.
- **HOT-3** It always runs the full test suite first (DEPLOY-5), even if the
  agent's own turn already ran it.
- **HOT-4** If the tests fail, nothing is loaded: `live` is rolled back to
  where it was (DEPLOY-5), so the running app is unaffected, and the error
  includes the test output.
- **HOT-5** If the tests pass, the live tree (with the trunk already merged into
  `live`, DEPLOY-5) is recompiled and the changed modules are loaded. This is
  the only way code changes reach the running app, other than a restart
  (DEPLOY-6, DEPLOY-8). Skills are reloaded.
- **HOT-6** A compile error is returned with the compiler output, truncated
  to 20,000 characters.
- **HOT-7** Reloading belongs to the deployment, not to the Mix environment:
  the endpoint's `code_reloader` and the `live_reload` wiring that points at the
  deploy's reloader (DEPLOY-8) are on in whatever environment the server runs
  in — not behind `config_env() == :dev` — and `phoenix_live_reload` is a normal
  dependency, not `only: :dev`. A browser reload (DEPLOY-12) and the in-VM code
  reloader (HOT-2, HOT-5) are therefore part of the normal deploy, as the tree's
  undigested assets are, rather than scaffolding of `config/dev.exs`. What stays
  there is that file's developer scaffolding: `debug_errors`, `dev_routes`, the
  stacktrace depth, the HEEx annotations and the expensive runtime checks, its
  `secret_key_base`, and the esbuild/tailwind watchers. A test run is not an
  operating mode, so the suite may keep its own value.
- **HOT-8** A reload reaches a page that is already open as **markup**: the
  LiveView's next render comes from the newly loaded modules and the client
  patches it in (HOT-5), while the page keeps the stylesheet it loaded — a
  browser fetches a new one only on a full page load, and a cache in front of
  the app (a proxy, a PWA's own store) can hold an old one longer. A change
  therefore must not rely on new CSS arriving with new markup: anything that
  hides, disables or "turns off" an element through a *new* rule would leave an
  open page with a control it cannot see or get rid of — a full-screen overlay
  blocking every tap, say. What keeps such a piece safe belongs in its own
  markup (IMG-7 in `specs/image-viewer.md`). A `priv/static` change is also
  what makes the browser's own live reload fire (DEPLOY-12), so a page whose
  assets did not change is not reloaded at all.
- **HOT-9** The live reload a deploy's own asset change triggers (HOT-8,
  DEPLOY-12) does not abort it: the browser page may reload and re-mount while
  the tests, the merge or the load run (DEPLOY-15), and the page that comes back
  reads the deploy's state from the runner rather than from its own assigns
  (DEPLOY-16, CONF-20).
- **HOT-10** A reload loads modules; it cannot add a supervised process to a
  tree that was built when the server started (DEPLOY-6). So it says when that
  is what happened: after the load it compares the children the running
  `Elia.Supervisor` has with the ones the loaded code asks for
  (`Elia.Application.children/0`), and the deploy's message names each child
  that is not running, and each one that runs and is no longer asked for, with
  the note that only a restart starts or stops it (DEPLOY-7). A reload whose
  tests failed, or one that changed no child, says nothing extra. The list of
  children is one function, so what the server starts and what the reload
  compares can never drift apart.

## Implementation

`Elia.Deploy.hot_reload/1` (the tests → merge → reload deploy, DEPLOY-6),
`Elia.Deploy.Runner` (the deploy's own process, DEPLOY-15, DEPLOY-16),
`Elia.Deploy.hot_reload_available?/0`, `Elia.Deploy`, `config/config.exs` and
`config/runtime.exs` (HOT-7), `mix.exs` (the dependency). HOT-8 is a rule for
each UI change rather than for a module: its first instance is the image
viewer's markup (`specs/image-viewer.md`, IMG-7). HOT-10 is
`Elia.Application.children/0` (the one child list), `Elia.Deploy.load/2`'s
comparison of it with the running supervisor (`Elia.Deploy.changed_children/1`)
and the notice it adds (`Elia.Deploy.restart_notice/1`).

## Tests

`test/elia/deployment_test.exs`, `test/elia_web/live/settings_live_test.exs`;
HOT-8 is what the image viewer's browser test holds to
(`test/elia_web/browser/chat_browser_test.exs`, IMG-7). HOT-9 is the deploy
runner's own test: the page may go away, the deploy goes on
(`test/elia_web/live/settings_live_test.exs`, DEPLOY-15). HOT-10 is what
`test/elia/deployment_test.exs` holds to: no child changed is no notice, a child
the running server lacks is named as missing, one it runs that the code no
longer asks for is named too, and a reload that failed says nothing extra.
