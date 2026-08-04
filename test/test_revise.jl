@testitem "revise picks up an edit made on disk" setup=[SessionHelpers] begin
    using .SessionHelpers
    using JuliaSessionControllers: filepath2uri

    pkg = SessionHelpers.copy_testdata("BasicPkg")
    source = joinpath(pkg, "src", "BasicPkg.jl")
    env = SessionEnvironment(project_uri=filepath2uri(pkg), package_name="BasicPkg")

    SessionHelpers.with_session(env) do ctrl, sid
        @test evaluate(ctrl, sid, "using BasicPkg; BasicPkg.greeting()").inline == "\"hello\""

        write(source, replace(read(source, String), "\"hello\"" => "\"goodbye\""))
        @test revise!(ctrl, sid)

        @test SessionHelpers.timed_wait(20) do
            evaluate(ctrl, sid, "BasicPkg.greeting()").inline == "\"goodbye\""
        end
    end
end

@testitem "revise on a session with nothing to revise succeeds" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        @test revise!(ctrl, sid)
    end
end

@testitem "a live session can switch environments" setup=[SessionHelpers] begin
    using .SessionHelpers
    using JuliaSessionControllers: filepath2uri

    pkg = joinpath(SessionHelpers.TESTDATA_DIR, "BasicPkg")

    SessionHelpers.with_session() do ctrl, sid
        active = activate_env(ctrl, sid; project_uri=filepath2uri(pkg), package_name="BasicPkg")

        @test occursin("BasicPkg", active)
        @test evaluate(ctrl, sid, "using BasicPkg; BasicPkg.add_one(1)").inline == "2"
        # Switching the environment does not discard the session's own state.
        @test only(list_sessions(ctrl)).alive
    end
end

@testitem "activating a broken environment throws and leaves the session alive" setup=[SessionHelpers] begin
    using .SessionHelpers
    using JuliaSessionControllers: filepath2uri

    broken = joinpath(SessionHelpers.TESTDATA_DIR, "BrokenPkg")

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "survivor = :still_here")

        @test_throws SessionStartupFailedException activate_env(ctrl, sid;
            project_uri=filepath2uri(broken), package_name="BrokenPkg")

        @test evaluate(ctrl, sid, "survivor").inline == ":still_here"
    end
end
