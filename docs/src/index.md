# JuliaSessionsControllers.jl

Manages long-lived Julia child processes ("sessions") in which arbitrary code can be
evaluated, and exposes them through an in-process Julia API.

This package is to interactive Julia sessions what
[TestItemControllers.jl](https://github.com/julia-testitems/TestItemControllers.jl) is to
test items: it launches child processes, talks to them over JSONRPC on a named pipe,
demultiplexes their output, and handles the process lifecycle.

## Getting started

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

## Core ideas

### Explicit sessions

A session is created from a [`SessionEnvironment`](@ref) describing the project, Julia
command, arguments, thread count and environment variables. [`create_session`](@ref)
returns an id used for every subsequent call. There is no implicit pooling and no reuse
across environments — two sessions created from equal environments are still entirely
separate processes.

### One request at a time

Every request against a session is queued and executed first-in-first-out. Requests never
interleave, so a session behaves exactly like a REPL: whatever the previous call did is
visible to the next one, and nothing else can slip in between.

This holds even when requests are submitted concurrently:

```julia
@sync for i in 1:3
    @async evaluate(controller, session, "push!(log, $i)")
end
```

### No restart

A session whose process exits stays dead. [`terminate_session`](@ref) forgets it, and a
fresh one is obtained with another [`create_session`](@ref) call using the same
environment. This keeps the state model honest: a session id always refers to one process
with one continuous history.

Requests that were queued or running when the process died fail with
[`SessionDiedException`](@ref), which carries the exit code and the tail of the process
output.

### Errors versus exceptions

An error in evaluated code is *not* thrown. It comes back as an [`EvalResult`](@ref) with
`status === :error`, carrying the message and a backtrace with infrastructure frames
removed. Exceptions are reserved for problems with the session itself — an unknown id, a
dead process, a timeout.

## Interrupting

[`interrupt_session`](@ref) cancels whatever is running and drops everything queued behind
it, the way Ctrl-C abandons pending input in a REPL. Queued requests fail with
[`RequestInterruptedException`](@ref).

Interrupting escalates: first a notification that throws an `InterruptException` into the
task running user code, then `SIGINT`, then killing the process.

!!! warning
    Code that never yields — a bare `while true; end` — can only be interrupted by the
    `SIGINT` step, which is unavailable on Windows. There such a session has to be killed,
    and killing a session is fatal to it.

## Julia version support

Session processes run on Julia 1.0 and newer, independently of the Julia running the
controller. Allocation profiling requires Julia 1.8 or newer; below that the request
reports `status === :unsupported` rather than failing.
