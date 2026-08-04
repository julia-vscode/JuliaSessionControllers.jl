@testitem "a session evaluates code and reports the value" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        r = evaluate(ctrl, sid, "1 + 1")

        @test r.status === :success
        @test r.inline == "2"
        @test r.result_type == "Int64"
        @test r.elapsed >= 0
        @test r.stack_frames === nothing
    end
end

@testitem "state persists across evaluations" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "counter = 0")
        evaluate(ctrl, sid, "counter += 41")

        @test evaluate(ctrl, sid, "counter + 1").inline == "42"
        # Functions defined in one call are callable from the next.
        evaluate(ctrl, sid, "double(x) = 2x")
        @test evaluate(ctrl, sid, "double(21)").inline == "42"
    end
end

@testitem "ans refers to the previous result" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "6 * 7")
        @test evaluate(ctrl, sid, "ans").inline == "42"
    end
end

@testitem "errors are results, not exceptions" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        r = evaluate(ctrl, sid, "sqrt(-1)")

        @test r.status === :error
        @test occursin("DomainError", r.all)
        @test r.result_type == "DomainError"
        @test r.stack_frames !== nothing && !isempty(r.stack_frames)

        # A failed evaluation must not poison the session.
        @test evaluate(ctrl, sid, "1 + 1").status === :success
    end
end

@testitem "stack frames drop the server's own frames" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "inner() = error(\"boom\")")
        evaluate(ctrl, sid, "outer() = inner()")
        r = evaluate(ctrl, sid, "outer()")

        @test r.status === :error
        labels = [f.label for f in r.stack_frames]
        @test "inner" in labels
        @test "outer" in labels
        # Nothing from the session server itself should be visible.
        @test !any(f -> f.uri !== nothing && occursin("JuliaSessionServer", f.uri), r.stack_frames)
    end
end

@testitem "syntax errors are reported as errors" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        r = evaluate(ctrl, sid, "1 +")
        @test r.status === :error
        @test evaluate(ctrl, sid, "1 + 1").status === :success
    end
end

@testitem "multiple top-level statements return the last value" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        r = evaluate(ctrl, sid, "a = 1\nb = 2\na + b")
        @test r.inline == "3"
    end
end

@testitem "soft scope lets a loop assign an outer binding" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "total = 0")
        r = evaluate(ctrl, sid, "for i in 1:3\n    total += i\nend\ntotal")
        @test r.status === :success
        @test r.inline == "6"
    end
end

@testitem "code can be evaluated in another module" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "module Scratch\nvalue = 99\nend")

        @test evaluate(ctrl, sid, "value"; mod="Main.Scratch").inline == "99"
        @test evaluate(ctrl, sid, "value").status === :error
    end
end

@testitem "output is attributed to the request that produced it" setup=[SessionHelpers] begin
    using .SessionHelpers

    request_output = Dict{String,Vector{String}}()
    session_output = String[]

    SessionHelpers.with_session(;
        on_request_output=(sid, rid, out) -> push!(get!(request_output, rid, String[]), out),
        on_session_output=(sid, out) -> push!(session_output, out),
    ) do ctrl, sid
        evaluate(ctrl, sid, "println(\"marker-one\")")
        evaluate(ctrl, sid, "println(\"marker-two\")")

        @test SessionHelpers.timed_wait(() -> length(request_output) >= 2, 10)

        texts = [join(v) for v in values(request_output)]
        @test any(t -> occursin("marker-one", t), texts)
        @test any(t -> occursin("marker-two", t), texts)
        # Each request's output goes to its own bucket, never merged.
        @test !any(t -> occursin("marker-one", t) && occursin("marker-two", t), texts)
        # The sentinel markers must never leak into the reported text.
        @test !any(t -> occursin('\x1f', t), texts)
    end
end

@testitem "a caller-supplied request id is used for output attribution" setup=[SessionHelpers] begin
    using .SessionHelpers

    request_output = Dict{String,Vector{String}}()

    SessionHelpers.with_session(;
        on_request_output=(sid, rid, out) -> push!(get!(request_output, rid, String[]), out),
    ) do ctrl, sid
        evaluate(ctrl, sid, "println(\"mine\")"; request_id="my-own-id")

        @test SessionHelpers.timed_wait(() -> haskey(request_output, "my-own-id"), 10)
        @test occursin("mine", join(request_output["my-own-id"]))
    end
end

@testitem "the line number reported for an error respects the offset" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        r = evaluate(ctrl, sid, "error(\"here\")"; filename="/tmp/example.jl", line=100)

        @test r.status === :error
        frame = findfirst(f -> f.uri !== nothing && occursin("example.jl", f.uri), r.stack_frames)
        frame === nothing || @test r.stack_frames[frame].line == 100
    end
end
