"""
    OutputDemux()

Splits the raw stdout/stderr stream of a session process into segments attributed to the
request that produced them. The session process wraps output produced while a request is
running in `OUTPUT_BEGIN_MARKER <request id> "` … `OUTPUT_END_MARKER`; anything outside
those markers belongs to the session itself, e.g. a background task the user started.

Kept separate from the IO task so it can be tested without spawning a process.
"""
mutable struct OutputDemux
    buffer::String
    current_request_id::Union{Nothing,String}
end

OutputDemux() = OutputDemux("", nothing)

"""
Does `marker` occur at byte offset `i` of `s`? Returns `:full`, `:none`, or `:partial`
when `s` ends mid-marker and more input is needed to decide.
"""
function match_marker(s::AbstractString, i::Int, marker::AbstractString)
    n = ncodeunits(s)
    m = ncodeunits(marker)
    k = 0
    while k < m
        i + k > n && return :partial
        codeunit(s, i + k) == codeunit(marker, k + 1) || return :none
        k += 1
    end
    return :full
end

"""
    demux!(d, chunk)

Feed raw process output into `d` and return the segments it completed, as
`request_id => text` pairs where a `nothing` id means session-level output. Bytes that
might be the start of a marker are retained until the next call.
"""
function demux!(d::OutputDemux, chunk::AbstractString)
    segments = Pair{Union{Nothing,String},String}[]

    buf = d.buffer * chunk
    n = ncodeunits(buf)
    i = 1

    pending = IOBuffer()
    pending_id = d.current_request_id

    flush_pending!() = let text = String(take!(pending))
        isempty(text) || push!(segments, pending_id => text)
    end

    while i <= n
        begin_match = match_marker(buf, i, OUTPUT_BEGIN_MARKER)
        end_match = match_marker(buf, i, OUTPUT_END_MARKER)

        # A truncated marker is indistinguishable from ordinary text until more arrives.
        (begin_match === :partial || end_match === :partial) && break

        if begin_match === :full
            id_start = i + ncodeunits(OUTPUT_BEGIN_MARKER)
            terminator = id_start > n ? nothing : findnext(isequal('"'), buf, id_start)
            terminator === nothing && break
            flush_pending!()
            d.current_request_id = String(SubString(buf, id_start, prevind(buf, terminator)))
            pending_id = d.current_request_id
            i = nextind(buf, terminator)
            continue
        end

        if end_match === :full
            # Also swallowed when no request is open: an interrupt can land between a
            # request starting and its begin marker being written.
            flush_pending!()
            d.current_request_id = nothing
            pending_id = nothing
            i += ncodeunits(OUTPUT_END_MARKER)
            continue
        end

        nxt = nextind(buf, i)
        write(pending, SubString(buf, i, prevind(buf, nxt)))
        i = nxt
    end

    flush_pending!()
    d.buffer = i > n ? "" : String(SubString(buf, i, n))

    return segments
end

# ═══════════════════════════════════════════════════════════════════════════════
# Launching
# ═══════════════════════════════════════════════════════════════════════════════

struct SessionProcessCrashException <: Exception
    session_id::String
    exitcode::Union{Nothing,Int}
    term_signal::Union{Nothing,Int}
    captured_output::String
end

function Base.showerror(io::IO, e::SessionProcessCrashException)
    print(io, "Session process '", e.session_id, "' exited before it could connect")
    e.exitcode === nothing || print(io, " (exit code ", e.exitcode, ")")
    println(io, ".")
    isempty(e.captured_output) || print(io, "\nOutput:\n", e.captured_output)
end

JSONRPC.@message_dispatcher dispatch_session_msg begin
    JuliaSessionServerProtocol.ready_notification_type => (params, ctx) -> begin
        reactor_channel, ss = ctx
        put!(reactor_channel, SessionReadyMsg(ss.id, params.juliaVersion))
    end
    JuliaSessionServerProtocol.debugger_ready_notification_type => (params, ctx) -> begin
        reactor_channel, ss = ctx
        put!(reactor_channel, AttachDebuggerMsg(ss.id, params.debugPipeName))
    end
end

"""
Build the environment for a session process, applying the caller's overrides on top of the
current one. A `nothing` value removes the variable entirely.
"""
function build_process_env(env::SessionEnvironment)
    jl_env = copy(ENV)

    # During precompilation Julia restricts JULIA_LOAD_PATH to dependency paths only (no
    # "@" entry), which would stop the child from resolving its own active project.
    if ccall(:jl_generating_output, Cint, ()) == 1
        delete!(jl_env, "JULIA_LOAD_PATH")
    end

    for (k, v) in pairs(env.julia_env)
        if v !== nothing
            jl_env[k] = v
        elseif haskey(jl_env, k)
            delete!(jl_env, k)
        end
    end

    nthreads = env.julia_num_threads
    if nthreads !== nothing && nthreads != "auto" && nthreads != ""
        jl_env["JULIA_NUM_THREADS"] = nthreads
    end

    return jl_env
end

"""
Command line arguments for a session process.

Note the deliberate divergence from TestItemControllers: user code is evaluated with
ordinary semantics, so neither `--check-bounds=yes` nor `--code-coverage` is passed.
"""
function build_process_args(env::SessionEnvironment)
    args = copy(env.julia_args)
    if env.julia_num_threads == "auto"
        push!(args, "--threads=auto")
    end
    return args
end

function truncate_for_log(s::AbstractString; max_bytes::Int=8192)
    ncodeunits(s) <= max_bytes && return s
    i = max_bytes
    while i > 0 && !Base.isvalid(s, i)
        i -= 1
    end
    return SubString(s, 1, i) * "... ($(ncodeunits(s) - i) bytes truncated)"
end

"""
    start(reactor_channel, ss, error_handler_file, crash_reporting_pipename, token)

Launch the session's Julia process, connect to it, and pump its JSONRPC messages until it
exits. Runs entirely on an IO task; all state changes are communicated by posting
`ReactorMessage`s. Always ends by posting a `SessionTerminatedMsg`, whatever went wrong.
"""
function start(reactor_channel, ss::SessionState, error_handler_file, crash_reporting_pipename, token)
    session_id = ss.id
    pipe_name = JSONRPC.generate_pipe_name()
    server = Sockets.listen(pipe_name)

    try
        server_script = joinpath(@__DIR__, "..", "sessionprocess", "app", "sessionserver_main.jl")
        pipe_out = Pipe()

        try
            jl_env = build_process_env(ss.env)
            jl_args = build_process_args(ss.env)

            extra_args = String[]
            error_handler_file === nothing || push!(extra_args, error_handler_file)
            crash_reporting_pipename === nothing || push!(extra_args, crash_reporting_pipename)

            cmd = `$(ss.env.julia_cmd) $jl_args --startup-file=no --history-file=no --depwarn=no $server_script $pipe_name $extra_args`

            @info "Launching Julia session process" session_id pipe_name
            @debug "Full launch command" session_id cmd = string(cmd)

            jl_process = open(pipeline(Cmd(cmd, detach=false, env=jl_env), stdout=pipe_out, stderr=pipe_out))

            proc_kill_registration = CancellationTokens.register(token) do
                @info "Killing session process due to cancellation" session_id
                try kill(jl_process) catch end
            end

            try
                raw_output_chunks = String[]
                raw_output_lock = ReentrantLock()

                @async try
                    demuxer = OutputDemux()
                    while !eof(pipe_out)
                        data = String(readavailable(pipe_out, token))

                        lock(raw_output_lock) do
                            push!(raw_output_chunks, data)
                        end

                        for (request_id, text) in demux!(demuxer, data)
                            isempty(text) && continue
                            @debug "Session output" session_id request_id = something(request_id, missing) output = truncate_for_log(text)
                            if request_id === nothing
                                put!(reactor_channel, SessionOutputMsg(session_id, text))
                            else
                                put!(reactor_channel, RequestOutputMsg(session_id, request_id, text))
                            end
                        end
                    end
                catch err
                    if err isa CancellationTokens.OperationCanceledException
                        @debug "Output reading cancelled by token" session_id
                    else
                        @error "Error reading session process output" session_id exception = (err, catch_backtrace())
                    end
                end

                abort_accept_source = CancellationTokens.CancellationTokenSource()
                abort_accept_token = CancellationTokens.get_token(abort_accept_source)

                # If the process dies during startup (e.g. a precompilation failure) nothing
                # will ever connect, so unblock the accept below rather than hanging.
                connection_established = Ref(false)
                @async try
                    wait(jl_process)
                    if !connection_established[] && !CancellationTokens.is_cancellation_requested(token)
                        CancellationTokens.cancel(abort_accept_source)
                    end
                catch err
                    @error "Error waiting for session process exit" session_id exception = (err, catch_backtrace())
                end

                accept_token = CancellationTokens.get_token(
                    CancellationTokens.CancellationTokenSource(token, abort_accept_token))

                @debug "Waiting for connection from session process" session_id pipe_name
                try
                    socket = Sockets.accept(server, accept_token)
                    try
                        connection_established[] = true
                        @info "Session process connected" session_id

                        endpoint = JSONRPC.JSONRPCEndpoint(socket, socket)
                        try
                            JSONRPC.start(endpoint)
                            put!(reactor_channel, SessionLaunchedMsg(session_id, jl_process, endpoint))

                            while true
                                msg = try
                                    JSONRPC.get_next_message(endpoint, token=token)
                                catch err
                                    if CancellationTokens.is_cancellation_requested(token) || err isa CancellationTokens.OperationCanceledException
                                        break
                                    end
                                    rethrow(err)
                                end
                                dispatch_session_msg(endpoint, msg, (reactor_channel, ss))
                            end
                        finally
                            close(endpoint)
                        end
                    finally
                        close(socket)
                    end
                catch err
                    if err isa CancellationTokens.OperationCanceledException && CancellationTokens.is_cancellation_requested(abort_accept_token)
                        captured = lock(raw_output_lock) do
                            join(raw_output_chunks)
                        end
                        put!(reactor_channel, SessionStartupFailedMsg(
                            session_id,
                            sprint(showerror, SessionProcessCrashException(
                                session_id, jl_process.exitcode, jl_process.termsignal, captured)),
                        ))
                    elseif err isa JSONRPC.TransportError
                        # Expected whenever the process exits: it closes the socket while we
                        # are still blocked reading from it.
                        @debug "Session process connection closed" session_id exception = (err,)
                    elseif !(err isa CancellationTokens.OperationCanceledException)
                        @error "Error in session process IO" session_id exception = (err, catch_backtrace())
                        try kill(jl_process) catch end
                    end
                end

                try wait(jl_process) catch end
                put!(reactor_channel, SessionTerminatedMsg(session_id, jl_process.exitcode, jl_process.termsignal))
            finally
                close(proc_kill_registration)
            end
        finally
            close(pipe_out)
        end
    finally
        close(server)
    end
end
