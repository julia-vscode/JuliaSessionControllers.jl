@testitem "a CPU profile produces a call tree" setup=[SessionHelpers] tags=[:profile] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "workload() = sum(sin(i) for i in 1:2_000_000)")
        result = profile(ctrl, sid, "workload()")

        @test result.status === :success
        @test result.threads !== nothing
        @test haskey(result.threads, "all")
        @test result.total_samples !== nothing && result.total_samples > 0

        root = result.threads["all"]
        @test root.func == "root"
        @test !isempty(root.children)
        # Frames should carry a resolvable location, not just a bare name.
        @test any(c -> !isempty(c.path), root.children)
    end
end

@testitem "a failing profile target reports the error" setup=[SessionHelpers] tags=[:profile] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        result = profile(ctrl, sid, "error(\"nope\")")

        @test result.status === :error
        @test result.error !== nothing && occursin("nope", result.error)
        @test evaluate(ctrl, sid, "1 + 1").status === :success
    end
end

@testitem "allocation profiling reports bytes, or says it is unsupported" setup=[SessionHelpers] tags=[:profile] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "allocator() = [collect(1:1000) for _ in 1:100]")
        result = profile(ctrl, sid, "allocator()"; kind=:alloc)

        if result.status === :unsupported
            # Julia below 1.8 has no allocation profiler; that must be reported, not thrown.
            @test result.error !== nothing
        else
            @test result.status === :success
            root = result.threads["all"]
            @test any(c -> c.count > 0, root.children)
            @test all(c -> c.count_label == "bytes", root.children)
        end
    end
end

@testitem "profile rejects an unknown kind" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        @test_throws ArgumentError profile(ctrl, sid, "1 + 1"; kind=:memory)
    end
end
