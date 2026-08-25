module JuliaSessionServer

include("pkg_imports.jl")

import .CancellationTokens: CancellationToken
import Pkg, Sockets, REPL, Profile, Logging
const StackTraces = Base.StackTraces

include("../../../shared/sessionserver_protocol.jl")
include("../../../shared/urihelper.jl")

const Protocol = JuliaSessionServerProtocol

mutable struct SessionServerState
    endpoint::JSONRPC.JSONRPCEndpoint
    error_handler::Union{Nothing,Function}
    lazy_values::Dict{Int,Any}
    next_lazy_id::Int
    debug_session::Any

    SessionServerState(endpoint, error_handler) =
        new(endpoint, error_handler, Dict{Int,Any}(), 1, nothing)
end

include("helper.jl")
include("backend.jl")
include("eval.jl")
include("inspect.jl")
include("profiler.jl")
include("debugger.jl")

JSONRPC.@message_dispatcher dispatch_msg begin
    Protocol.activate_env_request_type => activate_env_request
    Protocol.revise_request_type => revise_request
    Protocol.eval_request_type => eval_request
    Protocol.profile_request_type => profile_request
    Protocol.get_variables_request_type => get_variables_request
    Protocol.get_lazy_request_type => get_lazy_request
    Protocol.get_completions_request_type => get_completions_request
    Protocol.get_modules_request_type => get_modules_request
    Protocol.start_debugger_request_type => start_debugger_request
    Protocol.shutdown_request_type => shutdown_request
end

"""
    serve(pipename, error_handler=nothing)

Connect to the controller and serve requests until it asks us to shut down.

The message loop itself never runs user code — everything that might block is handed to the
backend task — so `session/interrupt` can always be processed, even mid-evaluation.
"""
function serve(pipename, error_handler=nothing)
    conn = Sockets.connect(pipename)
    endpoint = JSONRPC.JSONRPCEndpoint(conn, conn)
    JSONRPC.start(endpoint)

    state = SessionServerState(endpoint, error_handler)

    start_eval_backend()

    try
        Revise.revise()
    catch err
        @debug "Initial Revise pass failed" exception = (err,)
    end

    JSONRPC.send(endpoint, Protocol.ready_notification_type, (juliaVersion=string(VERSION),))

    while true
        msg = JSONRPC.get_next_message(endpoint)

        if msg.method == "session/shutdown"
            dispatch_msg(endpoint, msg, state)
            break
        elseif msg.method == "session/interrupt"
            # Handled inline rather than on a task: this must not queue behind anything.
            println(stderr, "^C")
            interrupt_backend()
        else
            request_accepted!()
            @async try
                dispatch_msg(endpoint, msg, state)
            catch err
                bt = catch_backtrace()
                error_handler === nothing || Base.invokelatest(error_handler, err, bt)
                @error "The session server failed to dispatch a message." exception = (err, bt)
                exit(1)
            finally
                request_finished!()
            end
        end
    end
end

end # module JuliaSessionServer
