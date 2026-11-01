# Hot reload

Status: Implemented

`hot_reload` is the soft deploy mode (DEPLOY-6): after the whole test suite
passes, it recompiles the live tree and loads a chat's tested code into the
running dev server. The other deploy mode is a restart (DEPLOY-7).

## Requirements

- **HOT-1** `hot_reload` needs approval.
- **HOT-2** It is available only when Mix is loaded and the endpoint's code
  reloader is on (the dev server). Otherwise it returns an error saying so.
- **HOT-3** It always runs the full test suite first, even if verification
  would skip it.
- **HOT-4** If the tests fail, nothing is reloaded. The workspace is rolled
  back to the turn's checkpoint, if there is one, and skills are reloaded. The
  error says whether a rollback happened and includes the test output.
- **HOT-5** If the tests pass, the live tree is recompiled and the changed
  modules are loaded. This is the only way code changes reach the running app,
  other than a restart (DEPLOY-6, DEPLOY-8). Skills are reloaded.
- **HOT-6** A compile error is returned with the compiler output, truncated
  to 20,000 characters.

## Implementation

`Elia.Harness.hot_reload/2` (the tests → merge → reload deploy, DEPLOY-6),
`Elia.Deploy`, `Elia.Skills.Harness`.

## Tests

`test/elia/deployment_test.exs`.
