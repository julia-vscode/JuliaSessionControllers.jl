# Public per-session requests. Each builds a `PendingRequest`, hands it to the reactor, and
# blocks until the session has run it. Requests against one session never overlap.

_from_wire(f::Protocol.StackFrame) = StackFrame(f.label, coalesce(f.uri, nothing), coalesce(f.line, nothing))

_from_wire_frames(frames) = frames === missing ? nothing : StackFrame[_from_wire(f) for f in frames]

function _from_wire(w::Protocol.EvalResult)
    return EvalResult(
        Symbol(w.status),
        w.inline,
        w.all,
        coalesce(w.resultType, nothing),
        _from_wire_frames(w.stackFrames),
        w.elapsed,
    )
end

function _from_wire(w::Protocol.BenchmarkResult)
    return BenchmarkResult(
        Symbol(w.status),
        coalesce(w.error, nothing),
        coalesce(w.minTime, nothing),
        coalesce(w.medianTime, nothing),
        coalesce(w.meanTime, nothing),
        coalesce(w.maxTime, nothing),
        coalesce(w.allocs, nothing),
        coalesce(w.memory, nothing),
        coalesce(w.nsamples, nothing),
        coalesce(w.evalsPerSample, nothing),
        coalesce(w.summary, nothing),
    )
end

function _from_wire(f::Protocol.ProfileFrame)
    return ProfileFrame(
        f.func,
        f.file,
        f.path,
        f.line,
        f.count,
        coalesce(f.countLabel, nothing),
        f.flags,
        coalesce(f.taskId, nothing),
        ProfileFrame[_from_wire(child) for child in f.children],
    )
end

function _from_wire(w::Protocol.ProfileResult)
    threads = w.threads === missing ? nothing :
              Dict{String,ProfileFrame}(t.name => _from_wire(t.root) for t in w.threads)
    return ProfileResult(Symbol(w.status), coalesce(w.error, nothing), threads, coalesce(w.totalSamples, nothing))
end

function _from_wire(w::Protocol.WorkspaceItem)
    return WorkspaceVariable(
        w.head, w.id, w.haschildren, w.lazy, w.icon, w.value, w.canshow, w.type,
        coalesce(w.uri, nothing), coalesce(w.line, nothing),
    )
end

_from_wire(w::Protocol.CompletionItem) = CompletionItem(w.label, w.kind, coalesce(w.documentation, nothing))

_from_wire_vector(::Type{T}, items) where {T} = T[_from_wire(i) for i in items]

"""
    evaluate(controller, session_id, code; kwargs...) -> EvalResult

Evaluate `code` in a session and block until it finishes. State persists between calls, so
a binding defined by one `evaluate` is visible to the next.

An error in the evaluated code is *not* thrown: it comes back as an `EvalResult` with
`status === :error`, carrying the message and backtrace. Exceptions are reserved for
problems with the session itself.

# Keyword arguments
- `filename`, `line`, `column` — source position `code` should appear to come from.
- `mod` — module to evaluate in (default `"Main"`).
- `softscope` — use REPL scoping rules rather than hard scope (default `true`).
- `timeout` — seconds before the session is interrupted and the call fails with
  [`RequestTimeoutException`](@ref).
- `token` — cancellation token; cancelling interrupts the session.
"""
function evaluate(
    c::JuliaSessionsController,
    session_id::AbstractString,
    code::AbstractString;
    filename::AbstractString="",
    line::Integer=1,
    column::Integer=1,
    mod::AbstractString="Main",
    softscope::Bool=true,
    timeout::Union{Nothing,Real}=nothing,
    token::Union{Nothing,CancellationTokens.CancellationToken}=nothing,
)
    request_id = string(UUIDs.uuid4())
    params = Protocol.EvalParams(
        requestId=request_id,
        code=String(code),
        filename=String(filename),
        line=Int(line),
        column=Int(column),
        mod=String(mod),
        softscope=softscope,
    )

    req = PendingRequest(
        :eval,
        SessionEvaluating,
        endpoint -> JSONRPC.send(endpoint, Protocol.eval_request_type, params);
        convert_result=_from_wire,
        timeout=timeout,
        token=token,
        id=request_id,
    )
    return _submit(c, session_id, req)::EvalResult
end

"""
    revise!(controller, session_id)

Run `Revise.revise()` in the session so that edits made on disk take effect. Returns `true`
when the revision succeeded; a failed revision returns `false` and usually means the
session should be replaced.
"""
function revise!(c::JuliaSessionsController, session_id::AbstractString;
    timeout::Union{Nothing,Real}=nothing,
    token::Union{Nothing,CancellationTokens.CancellationToken}=nothing,
)
    req = PendingRequest(
        :revise,
        SessionRevising,
        endpoint -> JSONRPC.send(endpoint, Protocol.revise_request_type, nothing);
        convert_result=r -> r.status == Protocol.STATUS_SUCCESS,
        timeout=timeout,
        token=token,
    )
    return _submit(c, session_id, req)::Bool
end

"""
    activate_env(controller, session_id; kwargs...) -> String

Activate a different environment in a live session. Returns the path of the newly active
project. Throws if activation fails, leaving the session on its previous environment.
"""
function activate_env(
    c::JuliaSessionsController,
    session_id::AbstractString;
    project_uri::Union{Nothing,AbstractString}=nothing,
    package_uri::Union{Nothing,AbstractString}=nothing,
    package_name::Union{Nothing,AbstractString}=nothing,
    use_test_env::Bool=false,
    timeout::Union{Nothing,Real}=nothing,
    token::Union{Nothing,CancellationTokens.CancellationToken}=nothing,
)
    params = Protocol.ActivateEnvParams(
        projectUri=project_uri === nothing ? missing : String(project_uri),
        packageUri=package_uri === nothing ? missing : String(package_uri),
        packageName=package_name === nothing ? missing : String(package_name),
        useTestEnv=use_test_env,
    )

    function convert(result)
        result.status == Protocol.STATUS_SUCCESS ||
            throw(SessionStartupFailedException(String(session_id), coalesce(result.error, "Environment activation failed")))
        return coalesce(result.activeProject, "")
    end

    req = PendingRequest(
        :activate_env,
        SessionEvaluating,
        endpoint -> JSONRPC.send(endpoint, Protocol.activate_env_request_type, params);
        convert_result=convert,
        timeout=timeout,
        token=token,
    )
    return _submit(c, session_id, req)::String
end

"""
    benchmark(controller, session_id, code; kwargs...) -> BenchmarkResult

Benchmark `code` with BenchmarkTools. On a Julia version older than the vendored
BenchmarkTools supports, the result comes back with `status === :unsupported` rather than
failing.

# Keyword arguments
- `seconds`, `samples`, `evals` — passed through to `BenchmarkTools`.
- `mod`, `filename`, `line` — evaluation context, as for [`evaluate`](@ref).
"""
function benchmark(
    c::JuliaSessionsController,
    session_id::AbstractString,
    code::AbstractString;
    seconds::Union{Nothing,Real}=nothing,
    samples::Union{Nothing,Integer}=nothing,
    evals::Union{Nothing,Integer}=nothing,
    mod::AbstractString="Main",
    filename::AbstractString="",
    line::Integer=1,
    timeout::Union{Nothing,Real}=nothing,
    token::Union{Nothing,CancellationTokens.CancellationToken}=nothing,
)
    request_id = string(UUIDs.uuid4())
    params = Protocol.BenchmarkParams(
        requestId=request_id,
        code=String(code),
        filename=String(filename),
        line=Int(line),
        mod=String(mod),
        seconds=seconds === nothing ? missing : Float64(seconds),
        samples=samples === nothing ? missing : Int(samples),
        evals=evals === nothing ? missing : Int(evals),
    )

    req = PendingRequest(
        :benchmark,
        SessionBenchmarking,
        endpoint -> JSONRPC.send(endpoint, Protocol.benchmark_request_type, params);
        convert_result=_from_wire,
        timeout=timeout,
        token=token,
        id=request_id,
    )
    return _submit(c, session_id, req)::BenchmarkResult
end

"""
    profile(controller, session_id, code; kind=:cpu, kwargs...) -> ProfileResult

Profile `code` and return the resulting call tree. `kind` is `:cpu` for a sampling profile
or `:alloc` for an allocation profile.

Allocation profiling requires Julia 1.8 or newer; on older versions the result comes back
with `status === :unsupported`.
"""
function profile(
    c::JuliaSessionsController,
    session_id::AbstractString,
    code::AbstractString;
    kind::Symbol=:cpu,
    delay::Union{Nothing,Real}=nothing,
    sample_rate::Union{Nothing,Real}=nothing,
    mod::AbstractString="Main",
    filename::AbstractString="",
    line::Integer=1,
    timeout::Union{Nothing,Real}=nothing,
    token::Union{Nothing,CancellationTokens.CancellationToken}=nothing,
)
    kind in (:cpu, :alloc) || throw(ArgumentError("profile `kind` must be :cpu or :alloc, got :$kind"))

    request_id = string(UUIDs.uuid4())
    params = Protocol.ProfileParams(
        requestId=request_id,
        code=String(code),
        filename=String(filename),
        line=Int(line),
        mod=String(mod),
        kind=String(kind),
        delay=delay === nothing ? missing : Float64(delay),
        sampleRate=sample_rate === nothing ? missing : Float64(sample_rate),
    )

    req = PendingRequest(
        :profile,
        SessionProfiling,
        endpoint -> JSONRPC.send(endpoint, Protocol.profile_request_type, params);
        convert_result=_from_wire,
        timeout=timeout,
        token=token,
        id=request_id,
    )
    return _submit(c, session_id, req)::ProfileResult
end

"""
    get_variables(controller, session_id; mod="Main", include_modules=false)

List the bindings of a module in the session. Values that are expensive to render are
reported with `lazy = true`; expand them with [`get_lazy`](@ref).
"""
function get_variables(
    c::JuliaSessionsController,
    session_id::AbstractString;
    mod::AbstractString="Main",
    include_modules::Bool=false,
    timeout::Union{Nothing,Real}=nothing,
    token::Union{Nothing,CancellationTokens.CancellationToken}=nothing,
)
    params = Protocol.GetVariablesParams(mod=String(mod), includeModules=include_modules)
    req = PendingRequest(
        :get_variables,
        SessionInspecting,
        endpoint -> JSONRPC.send(endpoint, Protocol.get_variables_request_type, params);
        convert_result=items -> _from_wire_vector(WorkspaceVariable, items),
        timeout=timeout,
        token=token,
    )
    return _submit(c, session_id, req)::Vector{WorkspaceVariable}
end

"""
    get_lazy(controller, session_id, id)

Expand the children of a lazily reported [`WorkspaceVariable`](@ref).
"""
function get_lazy(
    c::JuliaSessionsController,
    session_id::AbstractString,
    id::Integer;
    timeout::Union{Nothing,Real}=nothing,
    token::Union{Nothing,CancellationTokens.CancellationToken}=nothing,
)
    params = Protocol.GetLazyParams(id=Int(id))
    req = PendingRequest(
        :get_lazy,
        SessionInspecting,
        endpoint -> JSONRPC.send(endpoint, Protocol.get_lazy_request_type, params);
        convert_result=items -> _from_wire_vector(WorkspaceVariable, items),
        timeout=timeout,
        token=token,
    )
    return _submit(c, session_id, req)::Vector{WorkspaceVariable}
end

"""
    get_completions(controller, session_id, line; mod="Main")

Completion candidates for the partial expression `line`, as the session's REPL would offer
them.
"""
function get_completions(
    c::JuliaSessionsController,
    session_id::AbstractString,
    line::AbstractString;
    mod::AbstractString="Main",
    timeout::Union{Nothing,Real}=nothing,
    token::Union{Nothing,CancellationTokens.CancellationToken}=nothing,
)
    params = Protocol.GetCompletionsParams(line=String(line), mod=String(mod))
    req = PendingRequest(
        :get_completions,
        SessionInspecting,
        endpoint -> JSONRPC.send(endpoint, Protocol.get_completions_request_type, params);
        convert_result=items -> _from_wire_vector(CompletionItem, items),
        timeout=timeout,
        token=token,
    )
    return _submit(c, session_id, req)::Vector{CompletionItem}
end

"""
    get_modules(controller, session_id) -> Vector{String}

Names of the modules currently loaded in the session.
"""
function get_modules(
    c::JuliaSessionsController,
    session_id::AbstractString;
    timeout::Union{Nothing,Real}=nothing,
    token::Union{Nothing,CancellationTokens.CancellationToken}=nothing,
)
    req = PendingRequest(
        :get_modules,
        SessionInspecting,
        endpoint -> JSONRPC.send(endpoint, Protocol.get_modules_request_type, nothing);
        convert_result=names -> String[String(n) for n in names],
        timeout=timeout,
        token=token,
    )
    return _submit(c, session_id, req)::Vector{String}
end

"""
    start_debug_session(controller, session_id; stop_on_entry=false) -> String

Start a Debug Adapter Protocol server inside the session and return the name of the pipe a
DAP client should connect to. The session stays in the debugging state until the client
disconnects.
"""
function start_debug_session(
    c::JuliaSessionsController,
    session_id::AbstractString;
    stop_on_entry::Bool=false,
    timeout::Union{Nothing,Real}=nothing,
    token::Union{Nothing,CancellationTokens.CancellationToken}=nothing,
)
    debug_pipe_name = JSONRPC.generate_pipe_name()
    params = Protocol.StartDebuggerParams(debugPipeName=debug_pipe_name, stopOnEntry=stop_on_entry)

    req = PendingRequest(
        :start_debugger,
        SessionDebugging,
        endpoint -> JSONRPC.send(endpoint, Protocol.start_debugger_request_type, params);
        convert_result=_ -> debug_pipe_name,
        timeout=timeout,
        token=token,
    )
    return _submit(c, session_id, req)::String
end
