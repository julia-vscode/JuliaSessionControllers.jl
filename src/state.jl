"""
    PendingRequest

One unit of work queued against a session. Requests never run concurrently: the reactor
starts the head of the queue only when the session is idle, and starts the next one when
the current request completes.

`send` performs the actual JSONRPC call and runs on its own task so the reactor never
blocks; `convert_result` maps the wire type to the value handed back to the caller.
"""
mutable struct PendingRequest
    id::String
    kind::Symbol
    busy_phase::SessionPhase
    send::Function
    convert_result::Function
    completion::Channel{Any}
    timeout::Union{Nothing,Float64}
    token::Union{Nothing,CancellationTokens.CancellationToken}
    started_at::Union{Nothing,Float64}
    token_registration::Any
    timeout_timer::Union{Nothing,Timer}
    finished::Bool
end

function PendingRequest(
    kind::Symbol,
    busy_phase::SessionPhase,
    send::Function;
    convert_result::Function=identity,
    timeout::Union{Nothing,Real}=nothing,
    token::Union{Nothing,CancellationTokens.CancellationToken}=nothing,
    id::String=string(UUIDs.uuid4()),
)
    return PendingRequest(
        id,
        kind,
        busy_phase,
        send,
        convert_result,
        Channel{Any}(1),
        timeout === nothing ? nothing : Float64(timeout),
        token,
        nothing,
        nothing,
        nothing,
        false,
    )
end

"""
Hand `value` back to the caller blocked on this request. Safe to call more than once; only
the first call wins, which lets a timeout and a late reply race harmlessly.
"""
function complete_request!(req::PendingRequest, value)
    req.finished && return false
    req.finished = true

    if req.timeout_timer !== nothing
        try close(req.timeout_timer) catch end
        req.timeout_timer = nothing
    end
    if req.token_registration !== nothing
        try close(req.token_registration) catch end
        req.token_registration = nothing
    end

    try
        put!(req.completion, value)
    catch err
        @debug "Could not deliver request result" request_id = req.id exception = (err,)
    end
    return true
end

"""
    SessionState

Mutable state for a single session managed by the reactor. Only the reactor task mutates
this; IO tasks communicate by posting `ReactorMessage`s.
"""
mutable struct SessionState
    id::String
    fsm::FSM{SessionPhase}
    env::SessionEnvironment
    jl_process::Union{Nothing,Base.Process}
    endpoint::Union{Nothing,JSONRPC.JSONRPCEndpoint}
    active_project::Union{Nothing,String}
    julia_version::Union{Nothing,String}

    request_queue::Vector{PendingRequest}
    current_request::Union{Nothing,PendingRequest}

    # `create_session` blocks on this until the session reaches Idle or fails to start.
    startup_completion::Union{Nothing,Channel{Any}}

    cs::CancellationTokens.CancellationTokenSource
    process_tasks::Vector{Task}

    # Drives the notification → SIGINT → kill escalation of `interrupt_session`.
    interrupt_timer::Union{Nothing,Timer}
    interrupt_step::Int

    # Hard-kills the process if it does not exit on its own after a shutdown request.
    kill_timer::Union{Nothing,Timer}

    # Bounded tail of raw process output, reported when the session dies unexpectedly.
    recent_output::Vector{String}

    exit_code::Union{Nothing,Int}
    term_signal::Union{Nothing,Int}
    terminate_requested::Bool
end

function SessionState(id::String, env::SessionEnvironment)
    return SessionState(
        id,
        session_fsm(id),
        env,
        nothing,
        nothing,
        nothing,
        nothing,
        PendingRequest[],
        nothing,
        nothing,
        CancellationTokens.CancellationTokenSource(),
        Task[],
        nothing,
        0,
        nothing,
        String[],
        nothing,
        nothing,
        false,
    )
end

"""Maximum number of output chunks retained for crash diagnostics."""
const RECENT_OUTPUT_LIMIT = 64

function record_output!(ss::SessionState, chunk::AbstractString)
    push!(ss.recent_output, String(chunk))
    length(ss.recent_output) > RECENT_OUTPUT_LIMIT && popfirst!(ss.recent_output)
    return nothing
end

is_alive(ss::SessionState) = state(ss.fsm) !== SessionDead

died_exception(ss::SessionState) =
    SessionDiedException(ss.id, ss.exit_code, ss.term_signal, join(ss.recent_output, ""))

function SessionInfo(ss::SessionState)
    return SessionInfo(
        ss.id,
        ss.env,
        status_label(state(ss.fsm)),
        is_alive(ss),
        ss.active_project,
        length(ss.request_queue),
        ss.current_request === nothing ? nothing : String(ss.current_request.kind),
        ss.exit_code,
        ss.term_signal,
    )
end
