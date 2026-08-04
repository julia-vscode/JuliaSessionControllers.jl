@testitem "concurrently submitted requests run one at a time, in order" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "order = Int[]")

        results = Vector{Any}(undef, 5)
        @sync for i in 1:5
            @async results[i] = evaluate(ctrl, sid, "push!(order, $i); length(order)")
        end

        # Each request observes every earlier one, which is only possible if they never
        # overlapped and ran in submission order.
        @test [parse(Int, r.inline) for r in results] == 1:5
        @test evaluate(ctrl, sid, "order").inline == "5-element Vector{$Int}: 1 2 3 4 5"
    end
end

@testitem "a slow request does not block the ones behind it from being queued" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        slow = @async evaluate(ctrl, sid, "sleep(2); :slow")
        # Give the first request time to actually start.
        @test SessionHelpers.timed_wait(() -> !isempty(list_sessions(ctrl)), 10)
        quick = @async evaluate(ctrl, sid, ":quick")

        @test fetch(slow).inline == ":slow"
        @test fetch(quick).inline == ":quick"
    end
end

@testitem "list_sessions reports queue depth" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        running = @async evaluate(ctrl, sid, "sleep(3)")
        queued = [@async evaluate(ctrl, sid, "$i") for i in 1:3]

        @test SessionHelpers.timed_wait(10) do
            info = only(list_sessions(ctrl))
            info.current_request !== nothing && info.queued_requests > 0
        end

        fetch(running)
        foreach(fetch, queued)

        @test only(list_sessions(ctrl)).queued_requests == 0
    end
end

@testitem "a per-request timeout fails only that request" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        @test_throws RequestTimeoutException evaluate(ctrl, sid, "sleep(60)"; timeout=1)

        # The session is interrupted back to idle and remains usable.
        @test SessionHelpers.timed_wait(() -> only(list_sessions(ctrl)).status == "Idle", 20)
        @test evaluate(ctrl, sid, "1 + 1").inline == "2"
    end
end

@testitem "cancelling a queued request never reaches the session" setup=[SessionHelpers] begin
    using .SessionHelpers
    using JuliaSessionControllers: CancellationTokens

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "reached = String[]")

        blocker = @async evaluate(ctrl, sid, "sleep(3)")

        source = CancellationTokens.CancellationTokenSource()
        cancelled = @async evaluate(ctrl, sid, "push!(reached, \"cancelled\")";
            token=CancellationTokens.get_token(source))

        sleep(0.5)
        CancellationTokens.cancel(source)

        err = SessionHelpers.captured_exception(cancelled)
        @test err isa CancellationTokens.OperationCanceledException

        fetch(blocker)
        @test evaluate(ctrl, sid, "reached").inline == "String[]"
    end
end

@testitem "requests against an unknown session fail fast" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_controller() do ctrl
        @test_throws SessionNotFoundException evaluate(ctrl, "no-such-session", "1 + 1")
    end
end
