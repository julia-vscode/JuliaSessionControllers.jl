@testitem "benchmarking reports timings, or says it is unsupported" setup=[SessionHelpers] tags=[:benchmark] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        result = benchmark(ctrl, sid, "sum(1:1000)"; seconds=1)

        if result.status === :unsupported
            # BenchmarkTools is only developed into environments whose Julia it supports.
            @test result.error !== nothing
            @test occursin("BenchmarkTools", result.error)
        else
            @test result.status === :success
            @test result.min_time > 0
            @test result.median_time >= result.min_time
            @test result.max_time >= result.median_time
            @test result.nsamples > 0
            @test result.evals_per_sample >= 1
            @test result.summary !== nothing
        end
    end
end

@testitem "benchmarking can see session state" setup=[SessionHelpers] tags=[:benchmark] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "data = collect(1:1000)")
        result = benchmark(ctrl, sid, "sum(data)"; seconds=1)

        result.status === :unsupported && return
        @test result.status === :success
        @test result.min_time > 0
    end
end

@testitem "a failing benchmark target reports the error" setup=[SessionHelpers] tags=[:benchmark] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        result = benchmark(ctrl, sid, "error(\"nope\")"; seconds=1)

        result.status === :unsupported && return
        @test result.status === :error
        @test result.error !== nothing
        @test evaluate(ctrl, sid, "1 + 1").status === :success
    end
end
