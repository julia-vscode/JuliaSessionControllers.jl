@testitem "interrupting stops the running request and leaves the session usable" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        running = @async evaluate(ctrl, sid, "sleep(60)")
        sleep(1)

        interrupt_session(ctrl, sid)
        r = fetch(running)

        @test r.status === :error
        @test occursin("InterruptException", r.all)

        @test SessionHelpers.timed_wait(() -> only(list_sessions(ctrl)).status == "Idle", 20)
        @test evaluate(ctrl, sid, "1 + 1").inline == "2"
    end
end

@testitem "interrupting drains the queue" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "reached = String[]")

        running = @async evaluate(ctrl, sid, "sleep(60)")
        sleep(1)
        queued = [@async evaluate(ctrl, sid, "push!(reached, \"q$i\")") for i in 1:3]
        sleep(0.5)

        interrupt_session(ctrl, sid)
        fetch(running)

        for task in queued
            @test SessionHelpers.captured_exception(task) isa RequestInterruptedException
        end

        # Interrupting abandons queued work the way Ctrl-C abandons pending REPL input.
        @test evaluate(ctrl, sid, "reached").inline == "String[]"
    end
end

@testitem "interrupting an idle session is a no-op" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        interrupt_session(ctrl, sid)
        sleep(0.5)

        @test only(list_sessions(ctrl)).alive
        @test evaluate(ctrl, sid, "1 + 1").inline == "2"
    end
end

@testitem "interrupting an unknown session does not throw" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_controller() do ctrl
        interrupt_session(ctrl, "no-such-session")
        sleep(0.2)
        @test isempty(list_sessions(ctrl))
    end
end

@testitem "interrupting a blocked read wakes the session up" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        running = @async evaluate(ctrl, sid, "take!(Channel{Int}(1))")
        sleep(1)

        interrupt_session(ctrl, sid)
        @test fetch(running).status === :error
        @test evaluate(ctrl, sid, ":alive").inline == ":alive"
    end
end
