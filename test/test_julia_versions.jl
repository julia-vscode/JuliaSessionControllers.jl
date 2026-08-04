@testitem "sessions work on every supported Julia version" setup=[SessionHelpers] tags=[:comprehensive_platform] begin
    using .SessionHelpers

    for version in SessionHelpers.installed_julia_versions()
        env = SessionEnvironment(julia_cmd="julia", julia_args=["+$version"])

        @testset "Julia $version" begin
            SessionHelpers.with_session(env) do ctrl, sid
                r = evaluate(ctrl, sid, "1 + 1")
                @test r.status === :success
                @test r.inline == "2"

                # State must persist here exactly as it does on a current Julia.
                evaluate(ctrl, sid, "x = 41")
                @test evaluate(ctrl, sid, "x + 1").inline == "42"

                err = evaluate(ctrl, sid, "sqrt(-1)")
                @test err.status === :error
                @test err.stack_frames !== nothing

                @test only(list_sessions(ctrl)).alive
            end
        end
    end
end

@testitem "output is attributed correctly on every Julia version" setup=[SessionHelpers] tags=[:comprehensive_platform] begin
    using .SessionHelpers

    for version in SessionHelpers.installed_julia_versions()
        env = SessionEnvironment(julia_cmd="julia", julia_args=["+$version"])

        @testset "Julia $version" begin
            captured = Dict{String,Vector{String}}()
            SessionHelpers.with_session(env;
                on_request_output=(sid, rid, out) -> push!(get!(captured, rid, String[]), out),
            ) do ctrl, sid
                evaluate(ctrl, sid, "println(\"from-$version\")")

                @test SessionHelpers.timed_wait(() -> !isempty(captured), 10)
                text = join(reduce(vcat, values(captured)))
                @test occursin("from-$version", text)
                # The sentinel markers must never survive into the reported output.
                @test !occursin('\x1f', text)
            end
        end
    end
end

@testitem "allocation profiling degrades rather than fails on old Julia" setup=[SessionHelpers] tags=[:comprehensive_platform] begin
    using .SessionHelpers

    for version in SessionHelpers.installed_julia_versions()
        env = SessionEnvironment(julia_cmd="julia", julia_args=["+$version"])

        @testset "Julia $version" begin
            SessionHelpers.with_session(env) do ctrl, sid
                result = profile(ctrl, sid, "[collect(1:100) for _ in 1:10]"; kind=:alloc)

                if VersionNumber(version) < v"1.8"
                    @test result.status === :unsupported
                else
                    @test result.status === :success
                end
            end
        end
    end
end

@testitem "interrupting works on every Julia version" setup=[SessionHelpers] tags=[:comprehensive_platform] begin
    using .SessionHelpers

    for version in SessionHelpers.installed_julia_versions()
        env = SessionEnvironment(julia_cmd="julia", julia_args=["+$version"])

        @testset "Julia $version" begin
            SessionHelpers.with_session(env) do ctrl, sid
                running = @async evaluate(ctrl, sid, "sleep(60)")
                sleep(1)
                interrupt_session(ctrl, sid)

                @test fetch(running).status === :error
                @test evaluate(ctrl, sid, "1 + 1").inline == "2"
            end
        end
    end
end
