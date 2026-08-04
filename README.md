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

## Example

```julia
using JuliaSessionsControllers

controller = JuliaSessionsController()
reactor = @async run(controller)

session = create_session(controller, SessionEnvironment())

evaluate(controller, session, "x = 41")
evaluate(controller, session, "x + 1").inline    # "42"

shutdown(controller)
wait_for_shutdown(controller, reactor)
```

`evaluate` reports an error in the evaluated code as an `EvalResult` with
`status === :error`; exceptions are reserved for problems with the session itself.

Alongside `evaluate` there are `revise!`, `activate_env`, `benchmark`, `profile`,
`get_variables`, `get_lazy`, `get_completions`, `get_modules` and `start_debug_session`,
plus `interrupt_session`, `terminate_session` and `list_sessions`.

## Interrupting

`interrupt_session` cancels whatever is running and drops everything queued behind it, the
way Ctrl-C abandons pending input in a REPL. It escalates: first an interrupt notification
that throws into the task running user code, then `SIGINT`, then killing the process.

Code that never yields — a bare `while true; end` — can only be interrupted by the `SIGINT`
step, which is unavailable on Windows. There such a session has to be killed, and killing a
session is fatal to it.

## Julia version support

Session processes run on Julia 1.0 and newer. `packages/` holds the dependency versions
used on modern Julia and `packages-old/v1.5` and `packages-old/v1.9` the last releases that
support those older versions; `sessionprocess/JuliaSessionServer/src/pkg_imports.jl` picks
between them.

Benchmarking requires Julia 1.6 or newer and allocation profiling Julia 1.8 or newer. Below
those versions the corresponding request reports `status === :unsupported` rather than
failing.

## Repository scripts

| Script | Purpose |
|:-------|:--------|
| `scripts/bootstrap_vendored_packages.jl` | One-time `git subtree add` of every vendored tree. |
| `scripts/update_vendored_packages.jl` | Move `packages/` to the newest upstream releases. |
| `scripts/install_julia_versions.jl` | Install every supported Julia via juliaup. |
| `scripts/update_app_environments.jl` | Regenerate the per-version session process environments. |

## License

MIT
