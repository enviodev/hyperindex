// Runs before every test file. Files share a worker's module cache, so the
// runtime's process-global state goes back to what a fresh process starts with.
EnvioGlobal.reset()
