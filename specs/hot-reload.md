# Hot reload

Status: Implemented

Hot reload is the soft deploy mode (DEPLOY-6): after DEPLOY-5 has run the full
test suite and brought the trunk `master` to `live`, it recompiles the live tree
and loads the result into the running dev server, keeping running state. Its
control is the "Hot reload" button on the Settings page (CONF-19); the other
deploy mode is a restart (DEPLOY-7). There is no `hot_reload` tool: an agent's
own step is to merge its branch into the trunk (DEPLOY-13), and deploying is the
user's.

## Requirements

- ~~**HOT-1** `hot_reload` needs approval.~~ *Retired: `hot_reload` is no longer
  a tool. The Settings page's deploy controls are the user's own click
  (DEPLOY-6).*
- **HOT-2** Hot reload is available only when Mix is loaded and the endpoint's
  code reloader is on (the dev server). Otherwise it returns an error saying
  so, and nothing is merged or loaded.
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

## Implementation

`Elia.Deploy.hot_reload/1` (the tests → merge → reload deploy, DEPLOY-6),
`Elia.Deploy.hot_reload_available?/0`, `Elia.Deploy`.

## Tests

`test/elia/deployment_test.exs`, `test/elia_web/live/settings_live_test.exs`.
