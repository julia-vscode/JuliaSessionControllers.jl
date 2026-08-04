"""Messages processed by the reactor event loop."""
abstract type ReactorMessage end

# ═══════════════════════════════════════════════════════════════════════════════
# Controller-level messages
# ═══════════════════════════════════════════════════════════════════════════════

struct ShutdownMsg <: ReactorMessage end

struct CreateSessionMsg <: ReactorMessage
    session_id::String
    env::SessionEnvironment
    completion::Channel{Any}
    token::Union{Nothing,CancellationTokens.CancellationToken}
end

struct TerminateSessionMsg <: ReactorMessage
    session_id::String
end

struct ListSessionsMsg <: ReactorMessage
    completion::Channel{Any}
end

# ═══════════════════════════════════════════════════════════════════════════════
# Request messages
# ═══════════════════════════════════════════════════════════════════════════════

struct SubmitRequestMsg <: ReactorMessage
    session_id::String
    request::PendingRequest
end

# Posted from the task running `PendingRequest.send`. `result` is either the wire value or
# an exception; either way it ends the request.
struct RequestCompletedMsg <: ReactorMessage
    session_id::String
    request_id::String
    result::Any
    is_error::Bool
end

struct RequestTimeoutMsg <: ReactorMessage
    session_id::String
    request_id::String
end

struct CancelRequestMsg <: ReactorMessage
    session_id::String
    request_id::String
end

struct InterruptSessionMsg <: ReactorMessage
    session_id::String
end

# Drives the interrupt escalation ladder: step 1 sends SIGINT, step 2 kills the process.
struct InterruptEscalationMsg <: ReactorMessage
    session_id::String
    step::Int
end

# ═══════════════════════════════════════════════════════════════════════════════
# Process-lifecycle messages (from IO tasks → reactor)
# ═══════════════════════════════════════════════════════════════════════════════

struct SessionLaunchedMsg <: ReactorMessage
    session_id::String
    jl_process::Base.Process
    endpoint::JSONRPC.JSONRPCEndpoint
end

struct SessionReadyMsg <: ReactorMessage
    session_id::String
    julia_version::String
end

struct SessionActivatedMsg <: ReactorMessage
    session_id::String
    active_project::Union{Nothing,String}
end

struct ActivationFailedMsg <: ReactorMessage
    session_id::String
    error_message::String
end

struct SessionTerminatedMsg <: ReactorMessage
    session_id::String
    exit_code::Union{Nothing,Int}
    term_signal::Union{Nothing,Int}
end

struct SessionStartupFailedMsg <: ReactorMessage
    session_id::String
    error_message::String
end

struct SessionStatusChangedMsg <: ReactorMessage
    session_id::String
    status::String
end

# Output produced outside any request, e.g. by a background task the user started.
struct SessionOutputMsg <: ReactorMessage
    session_id::String
    output::String
end

# Output the session process attributed to a specific in-flight request.
struct RequestOutputMsg <: ReactorMessage
    session_id::String
    request_id::String
    output::String
end

struct AttachDebuggerMsg <: ReactorMessage
    session_id::String
    debug_pipe_name::String
end
