"""
    ControllerCallbacks(; kwargs...)

Callbacks invoked by the controller as sessions and requests progress. All are optional
and default to no-ops; they run on the reactor task, so they must not block.

- `on_session_created(session_id, env)`
- `on_session_status_changed(session_id, status)` — `status` is a [`status_label`](@ref).
- `on_session_output(session_id, output)` — output produced outside any request.
- `on_request_output(session_id, request_id, output)` — output of an in-flight request.
- `on_request_started(session_id, request_id, kind)`
- `on_request_completed(session_id, request_id, kind, result)` — `result` may be an exception.
- `on_session_terminated(session_id)` — terminated on request, cleanly.
- `on_session_died(session_id, exception)` — the process exited without being asked to.
- `on_attach_debugger(session_id, debug_pipe_name)`
"""
struct ControllerCallbacks{
    F1<:Function,F2<:Function,F3<:Function,F4<:Function,F5<:Function,
    F6<:Function,F7<:Function,F8<:Function,F9<:Function,
}
    on_session_created::F1
    on_session_status_changed::F2
    on_session_output::F3
    on_request_output::F4
    on_request_started::F5
    on_request_completed::F6
    on_session_terminated::F7
    on_session_died::F8
    on_attach_debugger::F9
end

function ControllerCallbacks(;
    on_session_created=(session_id, env) -> nothing,
    on_session_status_changed=(session_id, status) -> nothing,
    on_session_output=(session_id, output) -> nothing,
    on_request_output=(session_id, request_id, output) -> nothing,
    on_request_started=(session_id, request_id, kind) -> nothing,
    on_request_completed=(session_id, request_id, kind, result) -> nothing,
    on_session_terminated=(session_id) -> nothing,
    on_session_died=(session_id, exception) -> nothing,
    on_attach_debugger=(session_id, debug_pipe_name) -> nothing,
)
    return ControllerCallbacks(
        on_session_created,
        on_session_status_changed,
        on_session_output,
        on_request_output,
        on_request_started,
        on_request_completed,
        on_session_terminated,
        on_session_died,
        on_attach_debugger,
    )
end

"""
Invoke a callback, logging and swallowing any error. A misbehaving callback must never
take down the reactor loop mid-`handle!`, because that would strand queued requests.
"""
function safe_callback(f::Function, args...)
    try
        f(args...)
    catch err
        @error "Error in controller callback" exception = (err, catch_backtrace())
    end
    return nothing
end
