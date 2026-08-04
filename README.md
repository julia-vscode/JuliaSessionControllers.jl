# JuliaSessionsControllers

Manages long-lived Julia client processes ("sessions") in which arbitrary code can be
evaluated, and exposes them through an in-process Julia API.

This package is to interactive Julia sessions what
[TestItemControllers.jl](https://github.com/julia-testitems/TestItemControllers.jl) is to
test items: it launches child Julia processes, talks to them over JSONRPC on a named pipe,
demultiplexes their output, and handles the messy parts of process lifecycle management.

## Design

- **Explicit sessions.** The caller creates a session from a `SessionEnvironment`
  (project, Julia command, arguments, thread count, environment variables) and gets back
  an id. There is no implicit pooling and no reuse across environments.
- **One request at a time.** Every request against a session is queued and executed FIFO.
  Requests never interleave, which keeps the semantics of a session identical to a REPL.
- **No restart.** A session that dies stays dead. To get a fresh one, terminate it and
  create a new session with the same `SessionEnvironment`.
- **Vendored dependencies.** Everything the child process needs (Revise, DebugAdapter,
  BenchmarkTools, JSONRPC, ...) is vendored under `packages/` and loaded into a private
  environment, so a session never perturbs the user's own project.

## Status

Under construction.

## License

MIT
