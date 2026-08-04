@testitem "SessionEnvironment compares and hashes by value" begin
    a = SessionEnvironment(julia_cmd="julia", julia_args=["-O2"], project_uri="file:///a")
    b = SessionEnvironment(julia_cmd="julia", julia_args=["-O2"], project_uri="file:///a")
    c = SessionEnvironment(julia_cmd="julia", julia_args=["-O0"], project_uri="file:///a")

    @test a == b
    @test isequal(a, b)
    @test hash(a) == hash(b)
    @test a != c
    @test hash(a) != hash(c)
end

@testitem "SessionEnvironment defaults are usable as-is" begin
    env = SessionEnvironment()

    @test isfile(env.julia_cmd) || !isempty(env.julia_cmd)
    @test env.julia_args == String[]
    @test env.julia_num_threads === nothing
    @test env.project_uri === nothing
    @test env.use_test_env == false
end

@testitem "environment overrides accept a removal marker" begin
    env = SessionEnvironment(julia_env=Dict("JULIA_LOAD_PATH" => nothing, "FOO" => "bar"))

    @test env.julia_env["JULIA_LOAD_PATH"] === nothing
    @test env.julia_env["FOO"] == "bar"
end

@testitem "build_process_env applies overrides and removals" begin
    using JuliaSessionsControllers: build_process_env

    withenv("JSC_TEST_REMOVE_ME" => "present", "JSC_TEST_KEEP" => "kept") do
        env = SessionEnvironment(julia_env=Dict(
            "JSC_TEST_REMOVE_ME" => nothing,
            "JSC_TEST_ADDED" => "new",
        ))
        result = build_process_env(env)

        @test !haskey(result, "JSC_TEST_REMOVE_ME")
        @test result["JSC_TEST_KEEP"] == "kept"
        @test result["JSC_TEST_ADDED"] == "new"
    end
end

@testitem "an explicit thread count is passed through the environment" begin
    using JuliaSessionsControllers: build_process_env, build_process_args

    numeric = SessionEnvironment(julia_num_threads="4")
    @test build_process_env(numeric)["JULIA_NUM_THREADS"] == "4"
    @test build_process_args(numeric) == String[]

    # "auto" is a command line flag rather than an environment variable.
    auto = SessionEnvironment(julia_num_threads="auto")
    @test !haskey(build_process_env(auto), "JULIA_NUM_THREADS")
    @test "--threads=auto" in build_process_args(auto)
end

@testitem "session processes do not inherit test-runner semantics" begin
    using JuliaSessionsControllers: build_process_args

    # User code must run with ordinary semantics, unlike TestItemControllers' processes.
    args = build_process_args(SessionEnvironment(julia_args=["-O2"]))
    @test args == ["-O2"]
    @test !any(a -> occursin("check-bounds", a) || occursin("code-coverage", a), args)
end

@testitem "exception messages point at creating a new session" begin
    e = SessionDiedException("abc", 1, nothing, "boom")
    message = sprint(showerror, e)

    @test occursin("abc", message)
    @test occursin("exit code 1", message)
    @test occursin("Create a new session", message)
    @test occursin("boom", message)
end

@testitem "request completion delivers exactly once" begin
    using JuliaSessionsControllers: PendingRequest, complete_request!, SessionEvaluating

    req = PendingRequest(:eval, SessionEvaluating, _ -> nothing)

    @test complete_request!(req, 42)
    # A timeout and a late reply can race; only the first result may be delivered.
    @test !complete_request!(req, 43)
    @test take!(req.completion) == 42
end
