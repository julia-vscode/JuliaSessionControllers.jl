@testitem "a session that exits is reported as dead, not restarted" setup=[SessionHelpers] begin
    using .SessionHelpers

    deaths = Any[]
    SessionHelpers.with_session(; on_session_died=(sid, ex) -> push!(deaths, (sid, ex))) do ctrl, sid
        # `exit` kills the process out from under the in-flight request.
        died = @async evaluate(ctrl, sid, "exit(3)")
        @test SessionHelpers.captured_exception(died) isa SessionDiedException

        @test SessionHelpers.timed_wait(() -> !isempty(deaths), 30)
        @test first(deaths)[1] == sid

        # The record survives so the death can be reported, but the session stays dead.
        info = only(list_sessions(ctrl))
        @test !info.alive
        @test info.status == "Dead"
        @test_throws SessionDiedException evaluate(ctrl, sid, "1 + 1")
    end
end

@testitem "queued requests fail when the session dies" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        dying = @async evaluate(ctrl, sid, "sleep(1); exit(1)")
        sleep(0.3)
        queued = [@async evaluate(ctrl, sid, "$i") for i in 1:3]

        @test SessionHelpers.captured_exception(dying) isa SessionDiedException
        for task in queued
            @test SessionHelpers.captured_exception(task) isa SessionDiedException
        end
    end
end

@testitem "a dead session can be replaced by a new one with the same environment" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_controller() do ctrl
        env = SessionEnvironment()
        first = create_session(ctrl, env)

        evaluate(ctrl, first, "marker = :original")
        try
            evaluate(ctrl, first, "exit(1)")
        catch err
            @test err isa SessionDiedException
        end

        terminate_session(ctrl, first)
        @test SessionHelpers.timed_wait(() -> isempty(list_sessions(ctrl)), 30)

        # This is the supported alternative to restarting: a fresh process, fresh state.
        second = create_session(ctrl, env)
        @test second != first
        @test evaluate(ctrl, second, "marker").status === :error
        @test evaluate(ctrl, second, "1 + 1").inline == "2"
    end
end

@testitem "the death exception carries diagnostics" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        died = @async evaluate(ctrl, sid, "println(\"about to die\"); flush(stdout); exit(7)")
        err = SessionHelpers.captured_exception(died)

        @test err isa SessionDiedException
        @test err.session_id == sid
        @test occursin("about to die", err.output)
    end
end

@testitem "terminating an already dead session drops the record" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_controller() do ctrl
        sid = create_session(ctrl, SessionEnvironment())
        try
            evaluate(ctrl, sid, "exit(1)")
        catch
        end

        @test SessionHelpers.timed_wait(() -> !only(list_sessions(ctrl)).alive, 30)

        terminate_session(ctrl, sid)
        @test SessionHelpers.timed_wait(() -> isempty(list_sessions(ctrl)), 30)
    end
end
