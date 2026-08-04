"""
    SessionEnvironment(; kwargs...)

Everything that determines how a session's Julia process is launched and what environment
it activates. Two sessions with equal `SessionEnvironment`s are still entirely separate
processes — this type is a description, not a pool key.

# Keyword arguments
- `julia_cmd` — path to the Julia executable (default: the running one).
- `julia_args` — extra command line arguments.
- `julia_num_threads` — `"auto"`, a number as a string, or `nothing`.
- `julia_env` — environment variable overrides. A `nothing` value removes the variable.
- `project_uri` — the project to activate, as a `file://` URI.
- `package_uri` / `package_name` — the package being developed, when there is one.
- `use_test_env` — activate the package's test environment via TestEnv.
"""
struct SessionEnvironment
    julia_cmd::String
    julia_args::Vector{String}
    julia_num_threads::Union{Nothing,String}
    julia_env::Dict{String,Union{String,Nothing}}
    project_uri::Union{Nothing,String}
    package_uri::Union{Nothing,String}
    package_name::Union{Nothing,String}
    use_test_env::Bool
end

function SessionEnvironment(;
    julia_cmd::AbstractString=joinpath(Sys.BINDIR, "julia"),
    julia_args::AbstractVector{<:AbstractString}=String[],
    julia_num_threads::Union{Nothing,AbstractString}=nothing,
    julia_env::AbstractDict=Dict{String,Union{String,Nothing}}(),
    project_uri::Union{Nothing,AbstractString}=nothing,
    package_uri::Union{Nothing,AbstractString}=nothing,
    package_name::Union{Nothing,AbstractString}=nothing,
    use_test_env::Bool=false,
)
    return SessionEnvironment(
        String(julia_cmd),
        String[String(a) for a in julia_args],
        julia_num_threads === nothing ? nothing : String(julia_num_threads),
        Dict{String,Union{String,Nothing}}(String(k) => (v === nothing ? nothing : String(v)) for (k, v) in julia_env),
        project_uri === nothing ? nothing : String(project_uri),
        package_uri === nothing ? nothing : String(package_uri),
        package_name === nothing ? nothing : String(package_name),
        use_test_env,
    )
end

const _SESSION_ENV_FIELDS = fieldnames(SessionEnvironment)

Base.hash(x::SessionEnvironment, h::UInt) =
    foldr((f, acc) -> hash(getfield(x, f), acc), _SESSION_ENV_FIELDS; init=hash(:SessionEnvironment, h))
Base.:(==)(a::SessionEnvironment, b::SessionEnvironment) =
    all(f -> getfield(a, f) == getfield(b, f), _SESSION_ENV_FIELDS)
Base.isequal(a::SessionEnvironment, b::SessionEnvironment) =
    all(f -> isequal(getfield(a, f), getfield(b, f)), _SESSION_ENV_FIELDS)

# ── Results ───────────────────────────────────────────────────────────────────

"""One frame of a backtrace reported by a session."""
struct StackFrame
    label::String
    uri::Union{Nothing,String}
    line::Union{Nothing,Int}
end

"""
    EvalResult

Outcome of [`evaluate`](@ref). `status` is `:success` or `:error`; on error, `all` holds
the full error message and `stack_frames` the backtrace with infrastructure frames removed.
"""
struct EvalResult
    status::Symbol
    inline::String
    all::String
    result_type::Union{Nothing,String}
    stack_frames::Union{Nothing,Vector{StackFrame}}
    elapsed::Float64
end

iserror(r::EvalResult) = r.status === :error

"""
    BenchmarkResult

Outcome of [`benchmark`](@ref). `status` is `:success`, `:error`, or `:unsupported` when
the session's Julia version is too old for the vendored BenchmarkTools. Times are in
nanoseconds, `memory` in bytes.
"""
struct BenchmarkResult
    status::Symbol
    error::Union{Nothing,String}
    min_time::Union{Nothing,Float64}
    median_time::Union{Nothing,Float64}
    mean_time::Union{Nothing,Float64}
    max_time::Union{Nothing,Float64}
    allocs::Union{Nothing,Int}
    memory::Union{Nothing,Int}
    nsamples::Union{Nothing,Int}
    evals_per_sample::Union{Nothing,Int}
    summary::Union{Nothing,String}
end

"""A node of a profile tree. `flags` uses the `PROFILE_FLAG_*` constants."""
struct ProfileFrame
    func::String
    file::String
    path::String
    line::Int
    count::Int
    count_label::Union{Nothing,String}
    flags::Int
    task_id::Union{Nothing,Int}
    children::Vector{ProfileFrame}
end

"""
    ProfileResult

Outcome of [`profile`](@ref). `threads` maps a thread name to the root of its profile
tree; allocation profiles report a single `"all"` entry.
"""
struct ProfileResult
    status::Symbol
    error::Union{Nothing,String}
    threads::Union{Nothing,Dict{String,ProfileFrame}}
    total_samples::Union{Nothing,Int}
end

"""A binding reported by [`get_variables`](@ref)."""
struct WorkspaceVariable
    name::String
    id::Int
    has_children::Bool
    lazy::Bool
    icon::String
    value::String
    canshow::Bool
    type::String
    uri::Union{Nothing,String}
    line::Union{Nothing,Int}
end

"""A completion candidate reported by [`get_completions`](@ref)."""
struct CompletionItem
    label::String
    kind::String
    documentation::Union{Nothing,String}
end

"""Summary of a session, as reported by [`list_sessions`](@ref)."""
struct SessionInfo
    id::String
    env::SessionEnvironment
    status::String
    alive::Bool
    active_project::Union{Nothing,String}
    queued_requests::Int
    current_request::Union{Nothing,String}
    exit_code::Union{Nothing,Int}
    term_signal::Union{Nothing,Int}
end

# ── Exceptions ────────────────────────────────────────────────────────────────

"""Thrown when a session id is not known to the controller."""
struct SessionNotFoundException <: Exception
    session_id::String
end

Base.showerror(io::IO, e::SessionNotFoundException) =
    print(io, "No session with id '", e.session_id, "'.")

"""
Thrown when a request targets a session whose process has exited — either because it died
while the request was queued or running, or because it was already dead when the request
was submitted. Sessions are never restarted; create a new one instead.
"""
struct SessionDiedException <: Exception
    session_id::String
    exit_code::Union{Nothing,Int}
    term_signal::Union{Nothing,Int}
    output::String
end

function Base.showerror(io::IO, e::SessionDiedException)
    print(io, "Session '", e.session_id, "' has died")
    e.exit_code === nothing || print(io, " (exit code ", e.exit_code, ")")
    e.term_signal === nothing || print(io, " (signal ", e.term_signal, ")")
    print(io, ". Create a new session to continue.")
    isempty(e.output) || print(io, "\n\nLast output:\n", e.output)
end

"""Thrown by [`create_session`](@ref) when the process could not be brought up."""
struct SessionStartupFailedException <: Exception
    session_id::String
    message::String
end

Base.showerror(io::IO, e::SessionStartupFailedException) =
    print(io, "Session '", e.session_id, "' failed to start: ", e.message)

"""Thrown when a request exceeded its `timeout`."""
struct RequestTimeoutException <: Exception
    session_id::String
    request_id::String
    timeout::Float64
end

Base.showerror(io::IO, e::RequestTimeoutException) =
    print(io, "Request '", e.request_id, "' on session '", e.session_id,
        "' timed out after ", e.timeout, "s.")

"""
Thrown for requests that were still queued when the session was interrupted. Interrupting
drains the queue, matching what Ctrl-C does to a REPL.
"""
struct RequestInterruptedException <: Exception
    session_id::String
    request_id::String
end

Base.showerror(io::IO, e::RequestInterruptedException) =
    print(io, "Request '", e.request_id, "' on session '", e.session_id,
        "' was cancelled because the session was interrupted.")
