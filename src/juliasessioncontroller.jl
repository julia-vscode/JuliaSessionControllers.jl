"""Grace period before a shutdown request is escalated to killing the process."""
const SHUTDOWN_GRACE_SECONDS = 5.0

"""Grace periods for the interrupt escalation ladder: notification → SIGINT → kill."""
const INTERRUPT_SIGINT_GRACE_SECONDS = 2.0
const INTERRUPT_KILL_GRACE_SECONDS = 5.0

"""
How long to wait for a process exit to be observed after a request's connection drops,
before giving up and failing the request without exit details.
"""
const TRANSPORT_ERROR_GRACE_SECONDS = 10.0

"""
    JuliaSessionController(callbacks; kwargs...)

Manages Julia child processes in which arbitrary code can be evaluated.

After construction, start the reactor with `run(controller)` (normally on its own task),
then create sessions and submit requests against them.

# Keyword arguments
- `error_handler_file` — optional Julia file loaded in session processes to install a
  global error handler.
- `crash_reporting_pipename` — optional named pipe for crash diagnostics.
- `log_level::Symbol` — minimum log level (default `:Info`).

# Lifecycle

1. `ctrl = JuliaSessionController(callbacks)`
2. `t = @async run(ctrl)`
3. `sid = create_session(ctrl, SessionEnvironment(; project_uri=...))`
4. `evaluate(ctrl, sid, "1 + 1")`
5. `shutdown(ctrl); wait_for_shutdown(ctrl, t)`

Sessions are never restarted. If a session dies, create a new one with the same
[`SessionEnvironment`](@ref).
"""
mutable struct JuliaSessionController{CB<:ControllerCallbacks}
    callbacks::CB
    reactor_channel::Channel{ReactorMessage}
    sessions::Dict{String,SessionState}
    error_handler_file::Union{Nothing,String}
    crash_reporting_pipename::Union{Nothing,String}
    log_level::Symbol
    controller_fsm::FSM{ControllerPhase}

    function JuliaSessionController(
        callbacks::CB;
        error_handler_file=nothing,
        crash_reporting_pipename=nothing,
        log_level::Symbol=:Info,
    ) where {CB<:ControllerCallbacks}
        return new{CB}(
            callbacks,
            Channel{ReactorMessage}(Inf),
            Dict{String,SessionState}(),
            error_handler_file,
            crash_reporting_pipename,
            log_level,
            controller_fsm("controller"),
        )
    end
end

JuliaSessionController(; kwargs...) = JuliaSessionController(ControllerCallbacks(); kwargs...)

# ═══════════════════════════════════════════════════════════════════════════════
# Reactor event loop
# ═══════════════════════════════════════════════════════════════════════════════

function Base.run(controller::JuliaSessionController)
    while true
        msg = take!(controller.reactor_channel)
        @debug "Reactor msg" msg_type = typeof(msg).name.name

        should_stop = try
            handle!(controller, msg)
        catch err
            @error "Error handling reactor message" msg_type = typeof(msg).name.name exception = (err, catch_backtrace())
            false
        end
        should_stop === true && break
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════════════

function _lookup(c::JuliaSessionController, session_id::String)
    return get(c.sessions, session_id, nothing)
end

function _transition!(c::JuliaSessionController, ss::SessionState, phase::SessionPhase; reason=nothing)
    state(ss.fsm) === phase && return
    transition!(ss.fsm, phase; reason=reason)
    put!(c.reactor_channel, SessionStatusChangedMsg(ss.id, status_label(phase)))
    return nothing
end

"""
Fail every queued and in-flight request of `ss` with `exception`, leaving the queue empty.
"""
function _fail_all_requests!(ss::SessionState, exception)
    cur = ss.current_request
    if cur !== nothing
        complete_request!(cur, exception)
        ss.current_request = nothing
    end
    for req in ss.request_queue
        complete_request!(req, exception)
    end
    empty!(ss.request_queue)
    return nothing
end

function _disarm_timers!(ss::SessionState)
    for field in (:interrupt_timer, :kill_timer)
        timer = getfield(ss, field)
        if timer !== nothing
            try close(timer) catch end
            setfield!(ss, field, nothing)
        end
    end
    return nothing
end

function _launch_session!(c::JuliaSessionController, ss::SessionState)
    _transition!(c, ss, SessionStarting; reason="launching")
    token = CancellationTokens.get_token(ss.cs)

    t = @async try
        start(c.reactor_channel, ss, c.error_handler_file, c.crash_reporting_pipename, token)
    catch err
        @error "Error in session process IO task" session_id = ss.id exception = (err, catch_backtrace())
        try
            put!(c.reactor_channel, SessionTerminatedMsg(ss.id, nothing, nothing))
        catch
        end
    end
    push!(ss.process_tasks, t)
    return nothing
end

"""
Ask the session process to exit, and arm a timer that kills it if it does not.
"""
function _terminate_session!(c::JuliaSessionController, ss::SessionState)
    ss.terminate_requested && return
    ss.terminate_requested = true

    endpoint = ss.endpoint
    if endpoint !== nothing && isopen(endpoint)
        @async try
            JSONRPC.send(endpoint, Protocol.shutdown_request_type, nothing)
        catch err
            @debug "Shutdown request failed, will kill instead" session_id = ss.id exception = (err,)
        end
    else
        CancellationTokens.cancel(ss.cs)
        return nothing
    end

    ss.kill_timer = Timer(SHUTDOWN_GRACE_SECONDS) do _
        @debug "Session did not exit in time, killing" session_id = ss.id
        try CancellationTokens.cancel(ss.cs) catch end
    end
    return nothing
end

"""
Start the next queued request if the session is idle. Requests never overlap: this is the
only place a request is handed to the session process.
"""
function _pump_queue!(c::JuliaSessionController, ss::SessionState)
    ss.current_request === nothing || return
    state(ss.fsm) === SessionIdle || return
    isempty(ss.request_queue) && return

    req = popfirst!(ss.request_queue)
    if req.finished
        return _pump_queue!(c, ss)
    end

    endpoint = ss.endpoint
    if endpoint === nothing || !isopen(endpoint)
        complete_request!(req, died_exception(ss))
        return _pump_queue!(c, ss)
    end

    ss.current_request = req
    req.started_at = time()
    _transition!(c, ss, req.busy_phase; reason="request $(req.kind)")
    safe_callback(c.callbacks.on_request_started, ss.id, req.id, req.kind)

    if req.timeout !== nothing
        req.timeout_timer = Timer(req.timeout) do _
            try put!(c.reactor_channel, RequestTimeoutMsg(ss.id, req.id)) catch end
        end
    end

    @async try
        result = req.send(endpoint)
        put!(c.reactor_channel, RequestCompletedMsg(ss.id, req.id, result, false))
    catch err
        @debug "Request failed" session_id = ss.id request_id = req.id exception = (err,)
        try
            put!(c.reactor_channel, RequestCompletedMsg(ss.id, req.id, err, true))
        catch
        end
    end

    return nothing
end

function _finish_current_request!(c::JuliaSessionController, ss::SessionState, value)
    req = ss.current_request
    req === nothing && return

    ss.current_request = nothing
    _disarm_timers!(ss)
    ss.interrupt_step = 0

    complete_request!(req, value)
    safe_callback(c.callbacks.on_request_completed, ss.id, req.id, req.kind, value)

    if state(ss.fsm) !== SessionDead
        _transition!(c, ss, SessionIdle; reason="request finished")
    end
    return nothing
end

function _arm_interrupt_timer!(c::JuliaSessionController, ss::SessionState, step::Int, delay::Float64)
    ss.interrupt_step = step
    ss.interrupt_timer = Timer(delay) do _
        try put!(c.reactor_channel, InterruptEscalationMsg(ss.id, step)) catch end
    end
    return nothing
end

# ═══════════════════════════════════════════════════════════════════════════════
# Handlers
# ═══════════════════════════════════════════════════════════════════════════════

function handle!(c::JuliaSessionController, ::ShutdownMsg)
    state(c.controller_fsm) === ControllerRunning || return false

    @info "Shutting down controller" session_count = length(c.sessions)
    transition!(c.controller_fsm, ControllerShuttingDown; reason="shutdown requested")

    for ss in values(c.sessions)
        _fail_all_requests!(ss, died_exception(ss))
        state(ss.fsm) === SessionDead || _terminate_session!(c, ss)
    end

    if all(ss -> state(ss.fsm) === SessionDead, values(c.sessions))
        transition!(c.controller_fsm, ControllerStopped; reason="no live sessions")
        return true
    end
    return false
end

function handle!(c::JuliaSessionController, msg::CreateSessionMsg)
    if state(c.controller_fsm) !== ControllerRunning
        try put!(msg.completion, SessionStartupFailedException(msg.session_id, "Controller is shutting down.")) catch end
        return false
    end

    ss = SessionState(msg.session_id, msg.env)
    ss.startup_completion = msg.completion
    c.sessions[msg.session_id] = ss

    safe_callback(c.callbacks.on_session_created, ss.id, ss.env)

    if msg.token !== nothing
        CancellationTokens.register(msg.token) do
            try put!(c.reactor_channel, TerminateSessionMsg(ss.id)) catch end
        end
    end

    _launch_session!(c, ss)
    return false
end

function handle!(c::JuliaSessionController, msg::SessionLaunchedMsg)
    ss = _lookup(c, msg.session_id)
    ss === nothing && return false

    ss.jl_process = msg.jl_process
    ss.endpoint = msg.endpoint
    return false
end

function handle!(c::JuliaSessionController, msg::SessionReadyMsg)
    ss = _lookup(c, msg.session_id)
    ss === nothing && return false

    ss.julia_version = msg.julia_version

    # Only activate an environment when there is one to activate; otherwise the session is
    # immediately usable in whatever project the process started with.
    if ss.env.project_uri === nothing && ss.env.package_uri === nothing
        _transition!(c, ss, SessionIdle; reason="ready")
        _finish_startup!(c, ss, ss.id)
        _pump_queue!(c, ss)
        return false
    end

    _transition!(c, ss, SessionActivatingEnv; reason="activating environment")
    endpoint = ss.endpoint
    @async try
        result = JSONRPC.send(endpoint, Protocol.activate_env_request_type, Protocol.ActivateEnvParams(
            projectUri=something(ss.env.project_uri, missing),
            packageUri=something(ss.env.package_uri, missing),
            packageName=something(ss.env.package_name, missing),
            useTestEnv=ss.env.use_test_env,
        ))
        if result.status == Protocol.STATUS_SUCCESS
            put!(c.reactor_channel, SessionActivatedMsg(msg.session_id, coalesce(result.activeProject, nothing)))
        else
            put!(c.reactor_channel, ActivationFailedMsg(msg.session_id, coalesce(result.error, "Environment activation failed")))
        end
    catch err
        @debug "Environment activation failed" session_id = msg.session_id exception = (err,)
        try
            put!(c.reactor_channel, ActivationFailedMsg(msg.session_id, sprint(showerror, err)))
        catch
        end
    end
    return false
end

function handle!(c::JuliaSessionController, msg::SessionActivatedMsg)
    ss = _lookup(c, msg.session_id)
    ss === nothing && return false

    ss.active_project = msg.active_project
    _transition!(c, ss, SessionIdle; reason="environment activated")
    _finish_startup!(c, ss, ss.id)
    _pump_queue!(c, ss)
    return false
end

function handle!(c::JuliaSessionController, msg::ActivationFailedMsg)
    ss = _lookup(c, msg.session_id)
    ss === nothing && return false

    @warn "Session environment activation failed" session_id = ss.id error = msg.error_message
    _finish_startup!(c, ss, SessionStartupFailedException(ss.id, msg.error_message))
    _terminate_session!(c, ss)
    return false
end

function handle!(c::JuliaSessionController, msg::SessionStartupFailedMsg)
    ss = _lookup(c, msg.session_id)
    ss === nothing && return false

    _finish_startup!(c, ss, SessionStartupFailedException(ss.id, msg.error_message))
    return false
end

"""Hand `value` to the `create_session` call still blocked on this session, if any."""
function _finish_startup!(c::JuliaSessionController, ss::SessionState, value)
    completion = ss.startup_completion
    completion === nothing && return
    ss.startup_completion = nothing
    try put!(completion, value) catch end
    return nothing
end

function handle!(c::JuliaSessionController, msg::SessionStatusChangedMsg)
    safe_callback(c.callbacks.on_session_status_changed, msg.session_id, msg.status)
    return false
end

function handle!(c::JuliaSessionController, msg::SessionOutputMsg)
    ss = _lookup(c, msg.session_id)
    ss === nothing || record_output!(ss, msg.output)
    safe_callback(c.callbacks.on_session_output, msg.session_id, msg.output)
    return false
end

function handle!(c::JuliaSessionController, msg::RequestOutputMsg)
    ss = _lookup(c, msg.session_id)
    ss === nothing || record_output!(ss, msg.output)
    safe_callback(c.callbacks.on_request_output, msg.session_id, msg.request_id, msg.output)
    return false
end

function handle!(c::JuliaSessionController, msg::AttachDebuggerMsg)
    safe_callback(c.callbacks.on_attach_debugger, msg.session_id, msg.debug_pipe_name)
    return false
end

function handle!(c::JuliaSessionController, msg::SubmitRequestMsg)
    ss = _lookup(c, msg.session_id)
    if ss === nothing
        complete_request!(msg.request, SessionNotFoundException(msg.session_id))
        return false
    end
    if state(ss.fsm) === SessionDead
        complete_request!(msg.request, died_exception(ss))
        return false
    end
    if state(c.controller_fsm) !== ControllerRunning || ss.terminate_requested
        complete_request!(msg.request, died_exception(ss))
        return false
    end

    push!(ss.request_queue, msg.request)

    # Registered on submission rather than on start, so that a request can be cancelled
    # while it is still queued and never reach the session at all.
    if msg.request.token !== nothing
        msg.request.token_registration = CancellationTokens.register(msg.request.token) do
            try put!(c.reactor_channel, CancelRequestMsg(ss.id, msg.request.id)) catch end
        end
    end

    _pump_queue!(c, ss)
    return false
end

function handle!(c::JuliaSessionController, msg::RequestCompletedMsg)
    ss = _lookup(c, msg.session_id)
    ss === nothing && return false

    cur = ss.current_request
    if cur === nothing || cur.id != msg.request_id
        @debug "Ignoring result for a request that is no longer current" session_id = msg.session_id request_id = msg.request_id
        return false
    end

    # A dropped connection means the process is on its way out. Hold the request open so it
    # can be failed with the real exit code and output once the exit is observed.
    if msg.is_error && msg.result isa JSONRPC.TransportError
        @debug "Request connection dropped, waiting for the session to exit" session_id = ss.id request_id = cur.id
        cur.timeout_timer = Timer(TRANSPORT_ERROR_GRACE_SECONDS) do _
            complete_request!(cur, died_exception(ss))
        end
        return false
    end

    value = if msg.is_error
        msg.result
    else
        try
            cur.convert_result(msg.result)
        catch err
            @error "Could not convert request result" session_id = ss.id request_id = cur.id exception = (err, catch_backtrace())
            err
        end
    end

    _finish_current_request!(c, ss, value)
    _pump_queue!(c, ss)
    return false
end

function handle!(c::JuliaSessionController, msg::RequestTimeoutMsg)
    ss = _lookup(c, msg.session_id)
    ss === nothing && return false

    cur = ss.current_request
    (cur === nothing || cur.id != msg.request_id) && return false

    @warn "Request timed out, interrupting session" session_id = ss.id request_id = cur.id timeout = cur.timeout
    complete_request!(cur, RequestTimeoutException(ss.id, cur.id, something(cur.timeout, 0.0)))
    _begin_interrupt!(c, ss)
    return false
end

function handle!(c::JuliaSessionController, msg::CancelRequestMsg)
    ss = _lookup(c, msg.session_id)
    ss === nothing && return false

    idx = findfirst(r -> r.id == msg.request_id, ss.request_queue)
    if idx !== nothing
        req = ss.request_queue[idx]
        deleteat!(ss.request_queue, idx)
        complete_request!(req, CancellationTokens.OperationCanceledException(req.token))
        return false
    end

    cur = ss.current_request
    if cur !== nothing && cur.id == msg.request_id
        complete_request!(cur, CancellationTokens.OperationCanceledException(cur.token))
        _begin_interrupt!(c, ss)
    end
    return false
end

function handle!(c::JuliaSessionController, msg::InterruptSessionMsg)
    ss = _lookup(c, msg.session_id)
    ss === nothing && return false
    state(ss.fsm) === SessionDead && return false

    # Interrupting drains the queue, the way Ctrl-C abandons pending input in a REPL.
    for req in ss.request_queue
        complete_request!(req, RequestInterruptedException(ss.id, req.id))
    end
    empty!(ss.request_queue)

    _begin_interrupt!(c, ss)
    return false
end

"""
Start the interrupt escalation ladder against whatever the session is currently running.
The caller-facing result may already have been delivered (on timeout or cancellation); this
only concerns getting the session process back to a usable state.
"""
function _begin_interrupt!(c::JuliaSessionController, ss::SessionState)
    ss.current_request === nothing && return
    state(ss.fsm) === SessionInterrupting && return

    _transition!(c, ss, SessionInterrupting; reason="interrupt requested")

    endpoint = ss.endpoint
    if endpoint !== nothing && isopen(endpoint)
        @async try
            JSONRPC.send(endpoint, Protocol.interrupt_notification_type, nothing)
        catch err
            @debug "Interrupt notification failed" session_id = ss.id exception = (err,)
        end
    end

    _arm_interrupt_timer!(c, ss, 1, INTERRUPT_SIGINT_GRACE_SECONDS)
    return nothing
end

function handle!(c::JuliaSessionController, msg::InterruptEscalationMsg)
    ss = _lookup(c, msg.session_id)
    ss === nothing && return false
    state(ss.fsm) === SessionInterrupting || return false
    ss.interrupt_step == msg.step || return false

    if msg.step == 1
        # SIGINT is not available on Windows, so there the ladder goes straight to a kill.
        if !Sys.iswindows() && ss.jl_process !== nothing
            @debug "Escalating interrupt to SIGINT" session_id = ss.id
            try kill(ss.jl_process, Base.SIGINT) catch end
            _arm_interrupt_timer!(c, ss, 2, INTERRUPT_KILL_GRACE_SECONDS)
        else
            _arm_interrupt_timer!(c, ss, 2, INTERRUPT_KILL_GRACE_SECONDS)
        end
    else
        @warn "Session did not respond to interrupt, killing it" session_id = ss.id
        try CancellationTokens.cancel(ss.cs) catch end
    end
    return false
end

function handle!(c::JuliaSessionController, msg::TerminateSessionMsg)
    ss = _lookup(c, msg.session_id)
    ss === nothing && return false

    if state(ss.fsm) === SessionDead
        delete!(c.sessions, ss.id)
        return false
    end

    @info "Terminating session" session_id = ss.id
    _fail_all_requests!(ss, died_exception(ss))
    _terminate_session!(c, ss)
    return false
end

function handle!(c::JuliaSessionController, msg::SessionTerminatedMsg)
    ss = _lookup(c, msg.session_id)
    ss === nothing && return false

    ss.exit_code = msg.exit_code
    ss.term_signal = msg.term_signal
    _disarm_timers!(ss)

    was_requested = ss.terminate_requested || state(c.controller_fsm) !== ControllerRunning

    if state(ss.fsm) !== SessionDead
        transition!(ss.fsm, SessionDead; reason="process exited")
        put!(c.reactor_channel, SessionStatusChangedMsg(ss.id, status_label(SessionDead)))
    end

    exception = died_exception(ss)
    _finish_startup!(c, ss, SessionStartupFailedException(ss.id, sprint(showerror, exception)))
    _fail_all_requests!(ss, exception)

    if was_requested
        @info "Session terminated" session_id = ss.id
        safe_callback(c.callbacks.on_session_terminated, ss.id)
        delete!(c.sessions, ss.id)
    else
        @warn "Session died unexpectedly" session_id = ss.id exit_code = msg.exit_code term_signal = msg.term_signal
        safe_callback(c.callbacks.on_session_died, ss.id, exception)
        # The record stays so `list_sessions` can report the death; `terminate_session`
        # drops it.
    end

    if state(c.controller_fsm) === ControllerShuttingDown &&
       all(s -> state(s.fsm) === SessionDead, values(c.sessions))
        transition!(c.controller_fsm, ControllerStopped; reason="all sessions terminated")
        return true
    end
    return false
end

function handle!(c::JuliaSessionController, msg::ListSessionsMsg)
    infos = SessionInfo[SessionInfo(ss) for ss in values(c.sessions)]
    sort!(infos, by=i -> i.id)
    try put!(msg.completion, infos) catch end
    return false
end

# ═══════════════════════════════════════════════════════════════════════════════
# Public API
# ═══════════════════════════════════════════════════════════════════════════════

"""
    create_session(controller, env; token=nothing) -> String

Launch a new session process for `env` and block until it is ready to accept requests.
Returns the new session's id.

Throws [`SessionStartupFailedException`](@ref) if the process could not be started or its
environment could not be activated.
"""
function create_session(
    c::JuliaSessionController,
    env::SessionEnvironment;
    token::Union{Nothing,CancellationTokens.CancellationToken}=nothing,
)
    session_id = string(UUIDs.uuid4())
    completion = Channel{Any}(1)
    put!(c.reactor_channel, CreateSessionMsg(session_id, env, completion, token))

    result = take!(completion)
    result isa Exception && throw(result)
    return result::String
end

"""
    terminate_session(controller, session_id)

Ask a session to shut down and forget it. Any queued or in-flight requests fail with
[`SessionDiedException`](@ref). Returns immediately.

There is no restart: to get a fresh session, call [`create_session`](@ref) again with the
same [`SessionEnvironment`](@ref).
"""
function terminate_session(c::JuliaSessionController, session_id::AbstractString)
    put!(c.reactor_channel, TerminateSessionMsg(String(session_id)))
    return nothing
end

"""
    interrupt_session(controller, session_id)

Interrupt whatever the session is currently running and drop everything queued behind it.
Returns immediately; the interrupted request fails on its own completion path.
"""
function interrupt_session(c::JuliaSessionController, session_id::AbstractString)
    put!(c.reactor_channel, InterruptSessionMsg(String(session_id)))
    return nothing
end

"""
    list_sessions(controller) -> Vector{SessionInfo}

Snapshot of every session the controller knows about, including ones that have died but
not yet been terminated.
"""
function list_sessions(c::JuliaSessionController)
    completion = Channel{Any}(1)
    put!(c.reactor_channel, ListSessionsMsg(completion))
    return take!(completion)::Vector{SessionInfo}
end

"""
    shutdown(controller)

Request an orderly shutdown: all sessions are terminated, pending requests fail, and the
reactor loop exits. Returns immediately; use [`wait_for_shutdown`](@ref) to block.
"""
function shutdown(c::JuliaSessionController)
    @info "Queueing controller shutdown"
    put!(c.reactor_channel, ShutdownMsg())
    return nothing
end

"""
    wait_for_shutdown(controller, reactor_task)

Block until the reactor loop has exited and every session's IO task has finished.
"""
function wait_for_shutdown(c::JuliaSessionController, reactor_task::Task)
    try wait(reactor_task) catch end
    for ss in values(c.sessions)
        for t in ss.process_tasks
            try wait(t) catch end
        end
    end
    return nothing
end

"""
Submit `request` to a session and block until it completes, rethrowing any failure.
"""
function _submit(c::JuliaSessionController, session_id::AbstractString, request::PendingRequest)
    put!(c.reactor_channel, SubmitRequestMsg(String(session_id), request))
    result = take!(request.completion)
    result isa Exception && throw(result)
    return result
end
