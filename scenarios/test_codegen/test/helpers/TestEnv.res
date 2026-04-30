let isClaudeCloud: bool = %raw(`process.env.CLAUDE_CODE_CONTAINER_ID != null`)
let itSkipInClaudeCloud = Vitest.Async.it_skipIf(isClaudeCloud)
