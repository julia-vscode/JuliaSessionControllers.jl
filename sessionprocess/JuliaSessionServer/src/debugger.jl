# Debug Adapter Protocol support. The controller asks for a debugger, we listen on the pipe
# name it supplied, and a DAP client connects to it directly — debug traffic never goes
# through the controller.

function start_debugger_request(params::Protocol.StartDebuggerParams, state::SessionServerState, token)
    ready = Channel{Bool}(1)

    @async try
        server = Sockets.listen(params.debugPipeName)
        put!(ready, true)

        JSONRPC.send(state.endpoint, Protocol.debugger_ready_notification_type,
            (debugPipeName=params.debugPipeName,))

        while true
            conn = Sockets.accept(server)
            session = DebugAdapter.DebugSession(conn)
            state.debug_session = session
            try
                run(session, state.error_handler)
            finally
                state.debug_session = nothing
            end
        end
    catch err
        bt = catch_backtrace()
        state.error_handler === nothing || Base.invokelatest(state.error_handler, err, bt)
        @error "The session debug task failed." exception = (err, bt)
    end

    take!(ready)
    return nothing
end
