# Hot reload

Status: Implemented

`hot_reload` loads the agent's code changes into the running dev server, but
only after the whole test suite passes.

## Requirements

- **HOT-1** `hot_reload` needs approval.
- **HOT-2** It is available only when Mix is loaded and the endpoint's code
  reloader is on (the dev server). Otherwise it returns an error saying so.
- **HOT-3** It always runs the full test suite first, even if verification
  would skip it.
- **HOT-4** If the tests fail, nothing is reloaded. The workspace is rolled
  back to the turn's checkpoint, if there is one, and skills are reloaded. The
  error says whether a rollback happened and includes the test output.
- **HOT-5** If the tests pass, the project is recompiled and the changed
  modules are loaded. This is the only way code changes reach the running app
  (GUARD-8). The code files' current contents are recorded as loaded
  (GUARD-10), and skills are reloaded.
- **HOT-6** A compile error is returned with the compiler output, truncated
  to 20,000 characters.

## Implementation

`Elia.Harness.hot_reload/1`, `Elia.Skills.Harness`.

## Tests

None yet.
