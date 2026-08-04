# API

## Controller

```@docs
JuliaSessionsController
ControllerCallbacks
shutdown
wait_for_shutdown
```

## Sessions

```@docs
SessionEnvironment
create_session
terminate_session
interrupt_session
list_sessions
```

## Requests

```@docs
evaluate
revise!
activate_env
benchmark
profile
get_variables
get_lazy
get_completions
get_modules
start_debug_session
```

## Results

```@docs
EvalResult
BenchmarkResult
ProfileResult
ProfileFrame
WorkspaceVariable
CompletionItem
StackFrame
SessionInfo
```

## Exceptions

```@docs
SessionNotFoundException
SessionDiedException
SessionStartupFailedException
RequestTimeoutException
RequestInterruptedException
```
