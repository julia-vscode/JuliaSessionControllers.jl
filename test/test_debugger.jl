@testitem "starting a debugger exposes a pipe a DAP client can connect to" setup=[SessionHelpers] tags=[:debugger] begin
    using .SessionHelpers
    using Sockets

    announced = String[]

    SessionHelpers.with_session(; on_attach_debugger=(sid, pipe) -> push!(announced, pipe)) do ctrl, sid
        pipe_name = start_debug_session(ctrl, sid)

        @test !isempty(pipe_name)
        @test SessionHelpers.timed_wait(() -> pipe_name in announced, 10)

        client = Sockets.connect(pipe_name)
        try
            @test isopen(client)
        finally
            close(client)
        end

        # Starting the debugger must not take the session out of service.
        @test evaluate(ctrl, sid, "1 + 1").inline == "2"
    end
end

@testitem "the debug adapter answers an initialize request" setup=[SessionHelpers] tags=[:debugger] begin
    using .SessionHelpers
    using Sockets
    using JuliaSessionsControllers: JSON

    SessionHelpers.with_session() do ctrl, sid
        pipe_name = start_debug_session(ctrl, sid)
        client = Sockets.connect(pipe_name)

        try
            body = JSON.json(Dict(
                "seq" => 1,
                "type" => "request",
                "command" => "initialize",
                "arguments" => Dict("adapterID" => "julia"),
            ))
            write(client, "Content-Length: $(ncodeunits(body))\r\n\r\n", body)
            flush(client)

            # Read one Content-Length framed message back.
            response = Channel{Any}(1)
            @async try
                length = 0
                while true
                    line = readline(client)
                    isempty(strip(line)) && break
                    startswith(line, "Content-Length:") &&
                        (length = parse(Int, strip(split(line, ':')[2])))
                end
                put!(response, JSON.parse(String(read(client, length))))
            catch err
                put!(response, err)
            end

            @test SessionHelpers.timed_wait(() -> isready(response), 30)
            message = take!(response)

            @test message isa Dict
            @test message["type"] == "response"
            @test message["command"] == "initialize"
        finally
            close(client)
        end
    end
end
