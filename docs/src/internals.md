# Internals

This section documents the internal architecture. It is intended for contributors.

## Architecture overview

The controller is a **message-driven reactor**. A single-threaded event loop takes
messages off an unbounded channel and mutates controller state in response. All async I/O
— process spawning, JSONRPC communication, timeout and interrupt timers — runs on separate
tasks that post messages back to the reactor rather than touching shared state. This
removes data races while keeping the programming model straightforward.

```
┌──────────────┐   ReactorMessage   ┌─────────────────────┐
│  IO tasks    │ ─────────────────► │                     │
│  (per        │                    │   Reactor loop      │
│   session)   │                    │   handle!(ctrl,msg) │
├──────────────┤                    │                     │
│ evaluate()   │ ─────────────────► ├─────────────────────┘
│ and friends  │  SubmitRequestMsg  │       │
├──────────────┤                    │       ▼
│ interrupt /  │ ─────────────────► │  State mutation
│ shutdown     │                    │  (FSMs, queues)
└──────────────┘                    │       │
                                    │       ▼
                                    │  Callbacks
```

The loop lives in `Base.run(controller)` and exits when `handle!` returns `true`, which
only happens once a shutdown has completed and every session is dead.

## Finite state machines

Two enum-based FSMs track lifecycle phases. Each is an `FSM{S}` storing the current state
and an allowed-transition table, validated on every `transition!`.

### ControllerPhase

```
ControllerRunning → ControllerShuttingDown → ControllerStopped
```

### SessionPhase

```
SessionCreated → SessionStarting → SessionActivatingEnv → SessionIdle
                                        │
                     ┌──────────────────┴──────────────────┐
                     ▼                                     │
   SessionEvaluating / SessionRevising / SessionProfiling   │
   SessionInspecting / SessionDebugging                     │
                     │                                     │
                     ├──────────► SessionIdle ─────────────┘
                     ▼
             SessionInterrupting ──► SessionIdle

SessionDead  (reachable from ANY state, terminal)
```

`SessionDead` has no outgoing transitions at all. Sessions are never restarted, so the
FSM enforces at the type level what the API promises.

## The request queue

Each session owns a `Vector{PendingRequest}` plus a `current_request`. A `PendingRequest`
carries the JSONRPC call as a closure, a result converter, its own completion channel, and
optional timeout and cancellation token.

`_pump_queue!` is the only place a request is handed to a session process. It refuses to
start anything unless the session is `SessionIdle` and nothing is in flight, which is what
guarantees requests never overlap.

The public functions ([`evaluate`](@ref) and friends) build a request, post a
`SubmitRequestMsg`, and block on the request's completion channel. `complete_request!`
delivers exactly once, so a timeout and a late reply can race harmlessly.

### Cancellation

Cancellation tokens are registered when a request is **submitted**, not when it starts, so
a request that is still queued can be cancelled and never reach the session at all. A
queued request completes with `OperationCanceledException`; a running one is interrupted.

### Death

When a session process exits, `SessionTerminatedMsg` fails every queued and in-flight
request with [`SessionDiedException`](@ref).

A dropped connection is handled specially. Rather than surfacing the raw
`JSONRPC.TransportError`, the current request is held open until the exit is observed, so
it can be failed with the real exit code and captured output. A fallback timer bounds the
wait.

## Process management

### Launch

Each session process is started with `--startup-file=no --history-file=no --depwarn=no`
plus the caller's own arguments. Note what is deliberately *absent* compared with
TestItemControllers: neither `--check-bounds=yes` nor `--code-coverage` is passed, because
user code must run with ordinary semantics.

The child loads `sessionprocess/app/sessionserver_main.jl`, which activates the
version-specific private environment and starts `JuliaSessionServer`.

Startup is guarded: the named pipe is listened on *before* the process is spawned, and a
watcher cancels the `accept` if the child exits first, so a crash during precompilation
surfaces as a startup failure instead of hanging.

### Output demultiplexing

A session's stdout and stderr are merged into one stream carrying both request output and
anything background tasks print. The session process brackets output produced while a
request runs with sentinel markers containing the request id, and `OutputDemux` splits the
stream back apart.

The demultiplexer is a separate type rather than inline in the IO task specifically so it
can be tested without spawning a process. It holds back bytes that might be the start of a
marker, and swallows an unmatched end marker — which can happen when an interrupt lands
between a request starting and its begin marker being written.

## The session process

`JuliaSessionServer` runs a JSONRPC message loop that **never executes user code**.
Everything that might block is handed to a single long-lived backend task fed by an
unbuffered channel, with `Base.sigatomic_begin`/`end` protecting the handshake around it.

This is what makes interrupting possible: because the message loop is always responsive, a
`session/interrupt` notification can be handled immediately and throw an
`InterruptException` into the backend task. It also serialises user code inside the process,
independently of the controller's own queueing.

## Vendored packages

Dependencies are vendored under `packages/` as git subtrees and loaded by direct `include`,
so a session process never resolves or downloads anything, and nothing leaks into the
user's own environment. `packages-old/v1.5` and `packages-old/v1.9` hold the last releases
supporting those Julia versions;
`sessionprocess/JuliaSessionServer/src/pkg_imports.jl` selects between the tiers.

Two dependencies do not fit that pattern:

- **Compiler**, needed by LoweredCodeUtils on Julia 1.10+, is a 21-line re-export shim.
  Upstream only tags releases that vendor the whole compiler pinned to a single Julia
  version, so the shim is carried as first-party source in `compiler_shim.jl`.
- Packages without a `packagedef.jl` that resolve their own dependencies with `using`
  cannot be `include`d into an ad-hoc module at all. Adding one means either patching it or
  developing it into the version-specific environments as a real package.

## Version-specific environments

`sessionprocess/environments/vX.Y` holds a resolved environment per supported Julia
version, plus a `fallback` for versions newer than any of them. They are committed so a
session never has to resolve anything at launch. Regenerate them with
`scripts/update_app_environments.jl`, which needs every version installed via
`scripts/install_julia_versions.jl`.
