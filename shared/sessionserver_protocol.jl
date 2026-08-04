module JuliaSessionServerProtocol

import ..JSONRPC
import ..JSONRPC.JSON

using ..JSONRPC: @dict_readable, RequestType, NotificationType, Outbound

# Result `status` values shared by every request that can degrade rather than fail:
# a session process running on an old Julia reports `STATUS_UNSUPPORTED` instead of
# erroring, so the controller can surface a useful message.
const STATUS_SUCCESS = "success"
const STATUS_ERROR = "error"
const STATUS_UNSUPPORTED = "unsupported"

# Sentinel markers the session process wraps around output produced while a request is
# running, so the controller can attribute each chunk to that request. The begin marker is
# followed by the request id and a closing `"`. Both start with a unit separator, which
# user code is vanishingly unlikely to emit.
const OUTPUT_BEGIN_MARKER = "\x1f0a3c7e19b54d2fa8c6e0b4d7f9a1c3e5"
const OUTPUT_END_MARKER = "\x1f6b2d8f04a71e5c39d0f8a2b6c4e7d9f1"

@dict_readable struct Position <: Outbound
    line::Int
    column::Int
end

@dict_readable struct StackFrame <: Outbound
    label::String
    uri::Union{Missing,String}
    line::Union{Missing,Int}
end

# ── Environment activation ────────────────────────────────────────────────────

@dict_readable struct ActivateEnvParams <: Outbound
    projectUri::Union{Missing,String}
    packageUri::Union{Missing,String}
    packageName::Union{Missing,String}
    useTestEnv::Bool
end

@dict_readable struct ActivateEnvResult <: Outbound
    status::String
    error::Union{Missing,String}
    activeProject::Union{Missing,String}
end

# ── Eval ──────────────────────────────────────────────────────────────────────

@dict_readable struct EvalParams <: Outbound
    requestId::String
    code::String
    filename::String
    line::Int
    column::Int
    mod::String
    softscope::Bool
end

@dict_readable struct EvalResult <: Outbound
    requestId::String
    status::String
    # Single-line summary of the value, suitable for an inline annotation.
    inline::String
    # Full `show`n value, or the full error message when `status == STATUS_ERROR`.
    all::String
    resultType::Union{Missing,String}
    stackFrames::Union{Missing,Vector{StackFrame}}
    elapsed::Float64
end

# ── Revise ────────────────────────────────────────────────────────────────────

@dict_readable struct ReviseResult <: Outbound
    status::String
    error::Union{Missing,String}
end

# ── Benchmark ─────────────────────────────────────────────────────────────────

@dict_readable struct BenchmarkParams <: Outbound
    requestId::String
    code::String
    filename::String
    line::Int
    mod::String
    seconds::Union{Missing,Float64}
    samples::Union{Missing,Int}
    evals::Union{Missing,Int}
end

@dict_readable struct BenchmarkResult <: Outbound
    status::String
    error::Union{Missing,String}
    # Times in nanoseconds, memory in bytes.
    minTime::Union{Missing,Float64}
    medianTime::Union{Missing,Float64}
    meanTime::Union{Missing,Float64}
    maxTime::Union{Missing,Float64}
    allocs::Union{Missing,Int}
    memory::Union{Missing,Int}
    nsamples::Union{Missing,Int}
    evalsPerSample::Union{Missing,Int}
    # Pre-rendered `show` output of the trial, which reads better than the raw numbers.
    summary::Union{Missing,String}
end

# ── Profiling ─────────────────────────────────────────────────────────────────

# Bit flags matching FlameGraphs/VSCodeServer so the tree can be rendered the same way.
const PROFILE_FLAG_RUNTIME_DISPATCH = UInt8(2^0)
const PROFILE_FLAG_GC_EVENT = UInt8(2^1)
const PROFILE_FLAG_REPL = UInt8(2^2)
const PROFILE_FLAG_COMPILATION = UInt8(2^3)
const PROFILE_FLAG_TASK_EVENT = UInt8(2^4)

@dict_readable struct ProfileFrame <: Outbound
    func::String
    file::String
    path::String
    line::Int
    count::Int
    countLabel::Union{Missing,String}
    flags::Int
    taskId::Union{Missing,Int}
    children::Vector{ProfileFrame}
end

@dict_readable struct ProfileThread <: Outbound
    name::String
    root::ProfileFrame
end

@dict_readable struct ProfileParams <: Outbound
    requestId::String
    code::String
    filename::String
    line::Int
    mod::String
    # "cpu" or "alloc"
    kind::String
    # CPU sampling interval in seconds; allocation sample rate for "alloc".
    delay::Union{Missing,Float64}
    sampleRate::Union{Missing,Float64}
end

@dict_readable struct ProfileResult <: Outbound
    status::String
    error::Union{Missing,String}
    # One entry per thread for "cpu", a single "all" entry for "alloc".
    threads::Union{Missing,Vector{ProfileThread}}
    totalSamples::Union{Missing,Int}
end

# ── Inspection ────────────────────────────────────────────────────────────────

@dict_readable struct WorkspaceItem <: Outbound
    head::String
    id::Int
    haschildren::Bool
    lazy::Bool
    icon::String
    value::String
    canshow::Bool
    type::String
    uri::Union{Missing,String}
    line::Union{Missing,Int}
end

@dict_readable struct GetVariablesParams <: Outbound
    mod::String
    includeModules::Bool
end

@dict_readable struct GetLazyParams <: Outbound
    id::Int
end

@dict_readable struct GetCompletionsParams <: Outbound
    line::String
    mod::String
end

@dict_readable struct CompletionItem <: Outbound
    label::String
    kind::String
    documentation::Union{Missing,String}
end

# ── Debugging ─────────────────────────────────────────────────────────────────

@dict_readable struct StartDebuggerParams <: Outbound
    debugPipeName::String
    stopOnEntry::Bool
end

# ── Message types ─────────────────────────────────────────────────────────────

# Controller → session process
const activate_env_request_type = RequestType("session/activateEnv", ActivateEnvParams, ActivateEnvResult)
const revise_request_type = RequestType("session/revise", Nothing, ReviseResult)
const eval_request_type = RequestType("session/eval", EvalParams, EvalResult)
const benchmark_request_type = RequestType("session/benchmark", BenchmarkParams, BenchmarkResult)
const profile_request_type = RequestType("session/profile", ProfileParams, ProfileResult)
const get_variables_request_type = RequestType("session/getVariables", GetVariablesParams, Vector{WorkspaceItem})
const get_lazy_request_type = RequestType("session/getLazy", GetLazyParams, Vector{WorkspaceItem})
const get_completions_request_type = RequestType("session/getCompletions", GetCompletionsParams, Vector{CompletionItem})
const get_modules_request_type = RequestType("session/getModules", Nothing, Vector{String})
const start_debugger_request_type = RequestType("session/startDebugger", StartDebuggerParams, Nothing)
const shutdown_request_type = RequestType("session/shutdown", Nothing, Nothing)

# The interrupt is a notification rather than a request so that it can be handled while a
# request is still in flight — the session process reads it on its message loop task and
# throws into the separate task running user code.
const interrupt_notification_type = NotificationType("session/interrupt", Nothing)

# Session process → controller.
# Spelled out rather than written with `@NamedTuple`, which only exists on Julia 1.5+.
const ready_notification_type = NotificationType("session/ready", NamedTuple{(:juliaVersion,),Tuple{String}})
const debugger_ready_notification_type = NotificationType("session/debuggerReady", NamedTuple{(:debugPipeName,),Tuple{String}})

end
