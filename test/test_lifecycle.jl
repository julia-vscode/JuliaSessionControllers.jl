@testitem "a session reports itself through list_sessions" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        info = only(list_sessions(ctrl))

        @test info.id == sid
        @test info.alive
        @test info.status == "Idle"
        @test info.queued_requests == 0
        @test info.current_request === nothing
        @test info.exit_code === nothing
    end
end

@testitem "sessions are isolated from each other" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_controller() do ctrl
        first = create_session(ctrl, SessionEnvironment())
        second = create_session(ctrl, SessionEnvironment())

        @test first != second
        evaluate(ctrl, first, "shared_name = :from_first")

        @test evaluate(ctrl, first, "shared_name").inline == ":from_first"
        @test evaluate(ctrl, second, "shared_name").status === :error
        @test length(list_sessions(ctrl)) == 2
    end
end

@testitem "terminating a session forgets it" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_controller() do ctrl
        sid = create_session(ctrl, SessionEnvironment())
        @test evaluate(ctrl, sid, "1 + 1").status === :success

        terminate_session(ctrl, sid)

        @test SessionHelpers.timed_wait(() -> isempty(list_sessions(ctrl)), 30)
        @test_throws SessionNotFoundException evaluate(ctrl, sid, "1 + 1")
    end
end

@testitem "status callbacks describe the lifecycle" setup=[SessionHelpers] begin
    using .SessionHelpers

    statuses = String[]
    SessionHelpers.with_session(; on_session_status_changed=(sid, s) -> push!(statuses, s)) do ctrl, sid
        evaluate(ctrl, sid, "1 + 1")
        @test SessionHelpers.timed_wait(() -> "Idle" in statuses && "Evaluating" in statuses, 10)
    end

    @test statuses[1] == "Starting"
    @test "Idle" in statuses
    @test "Evaluating" in statuses
end

@testitem "a session created for a package activates its project" setup=[SessionHelpers] begin
    using .SessionHelpers
    using JuliaSessionsControllers: filepath2uri

    pkg = joinpath(SessionHelpers.TESTDATA_DIR, "BasicPkg")
    env = SessionEnvironment(project_uri=filepath2uri(pkg), package_name="BasicPkg")

    SessionHelpers.with_session(env) do ctrl, sid
        info = only(list_sessions(ctrl))
        @test info.active_project !== nothing
        @test occursin("BasicPkg", info.active_project)

        @test evaluate(ctrl, sid, "using BasicPkg; BasicPkg.add_one(41)").inline == "42"
    end
end

@testitem "a broken project fails session creation" setup=[SessionHelpers] begin
    using .SessionHelpers
    using JuliaSessionsControllers: filepath2uri

    broken = joinpath(SessionHelpers.TESTDATA_DIR, "BrokenPkg")
    env = SessionEnvironment(project_uri=filepath2uri(broken), package_name="BrokenPkg")

    SessionHelpers.with_controller() do ctrl
        @test_throws SessionStartupFailedException create_session(ctrl, env)
        # The failed session must not linger.
        @test SessionHelpers.timed_wait(() -> isempty(list_sessions(ctrl)), 30)
    end
end

@testitem "creating a session with a bad Julia command fails cleanly" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_controller() do ctrl
        env = SessionEnvironment(julia_cmd=joinpath(@__DIR__, "definitely-not-julia"))
        @test_throws Exception create_session(ctrl, env)
    end
end

@testitem "shutdown terminates every session" setup=[SessionHelpers] begin
    using .SessionHelpers

    terminated = String[]
    ctrl = JuliaSessionsController(ControllerCallbacks(
        on_session_terminated=sid -> push!(terminated, sid)))
    task = @async run(ctrl)

    first = create_session(ctrl, SessionEnvironment())
    second = create_session(ctrl, SessionEnvironment())

    shutdown(ctrl)
    wait_for_shutdown(ctrl, task)

    @test istaskdone(task)
    @test sort(terminated) == sort([first, second])
end

@testitem "shutting down an idle controller completes immediately" setup=[SessionHelpers] begin
    using .SessionHelpers

    ctrl = JuliaSessionsController()
    task = @async run(ctrl)

    shutdown(ctrl)
    wait_for_shutdown(ctrl, task)

    @test istaskdone(task)
    @test !istaskfailed(task)
end
