# Manual tests

Some tests are best run manually - such as checking that logs still look good after an update.

## Running the tests

Run the following to test the output:

```bash
# default setup (same as `console-pretty`):
node test/manual/LogTesting.res.mjs # LOG_STRATEGY=console-pretty
# ecs-file
LOG_STRATEGY="ecs-file" node test/manual/LogTesting.res.mjs
# ecs-console
LOG_STRATEGY="ecs-console" node test/manual/LogTesting.res.mjs
# file-only
LOG_STRATEGY="file-only" node test/manual/LogTesting.res.mjs
# console-raw
LOG_STRATEGY="console-raw" node test/manual/LogTesting.res.mjs
# both-prettyconsole
LOG_STRATEGY="both-prettyconsole" node test/manual/LogTesting.res.mjs
```
