@testitem "vendored packages do not leak into the session" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        loaded = get_modules(ctrl, sid)

        # The vendored copies are submodules of JuliaSessionServer, so none of them may
        # appear as a top-level loaded module where they would shadow the real package.
        for vendored in ("Revise", "JSONRPC", "JuliaInterpreter", "LoweredCodeUtils",
            "CodeTracking", "CancellationTokens", "URIParser", "TestEnv",
            "OrderedCollections", "Preferences", "JSON", "DebugAdapter")
            @test !(vendored in loaded)
        end
    end
end

@testitem "the session server leaves no bindings in Main" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        # Checked before anything is evaluated, because evaluating sets `ans`.
        @test isempty([v.name for v in get_variables(ctrl, sid)])

        for leaked in ("JuliaSessionServer", "Revise", "JSONRPC", "server", "env_path",
            "version_specific", "has_error_handler", "previous_project")
            @test evaluate(ctrl, sid, "isdefined(Main, :$leaked)").inline == "false"
        end
    end
end

@testitem "a session lands in a usable environment by default" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        # The server loads from a private environment; leaving the process there would
        # strand user code somewhere it cannot even load a stdlib.
        @test evaluate(ctrl, sid, "import Pkg; Pkg isa Module").inline == "true"
        @test evaluate(ctrl, sid, "import Dates; Dates isa Module").inline == "true"

        active = evaluate(ctrl, sid, "something(Base.active_project(), \"\")").inline
        @test !occursin("sessionprocess", active)
    end
end

@testitem "a session does not inherit the controller's environment" setup=[SessionHelpers] begin
    using .SessionHelpers
    using JuliaSessionsControllers: build_process_env

    withenv("JULIA_PROJECT" => "/somewhere/of/the/hosts/own",
        "JULIA_LOAD_PATH" => "/only/this") do
        built = build_process_env(SessionEnvironment())

        @test !haskey(built, "JULIA_PROJECT")
        @test !haskey(built, "JULIA_LOAD_PATH")

        # ...but an explicit override still wins.
        overridden = build_process_env(SessionEnvironment(julia_env=Dict("JULIA_PROJECT" => "/asked/for")))
        @test overridden["JULIA_PROJECT"] == "/asked/for"
    end
end

@testitem "user code sees its own project, not the server's" setup=[SessionHelpers] begin
    using .SessionHelpers
    using JuliaSessionsControllers: filepath2uri

    pkg = joinpath(SessionHelpers.TESTDATA_DIR, "BasicPkg")
    env = SessionEnvironment(project_uri=filepath2uri(pkg), package_name="BasicPkg")

    SessionHelpers.with_session(env) do ctrl, sid
        active = evaluate(ctrl, sid, "Base.active_project()")

        @test occursin("BasicPkg", active.inline)
        # The private environment the server loads from must not be the active one.
        @test !occursin("environments", active.inline)
    end
end
