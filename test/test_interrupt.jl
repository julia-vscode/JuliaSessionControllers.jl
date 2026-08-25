@testitem "interrupting stops the running request and leaves the session usable" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        running = @async evaluate(ctrl, sid, "sleep(60)")
        sleep(1)

        interrupt_session(ctrl, sid)
        r = fetch(running)

        @test r.status === :error
        @test occursin("InterruptException", r.all)

        @test SessionHelpers.timed_wait(() -> only(list_sessions(ctrl)).status == "Idle", 20)
        @test evaluate(ctrl, sid, "1 + 1").inline == "2"
    end
end

@testitem "interrupting drains the queue" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "reached = String[]")

        running = @async evaluate(ctrl, sid, "sleep(60)")
        sleep(1)
        queued = [@async evaluate(ctrl, sid, "push!(reached, \"q$i\")") for i in 1:3]
        sleep(0.5)

        interrupt_session(ctrl, sid)
        fetch(running)

        for task in queued
            @test SessionHelpers.captured_exception(task) isa RequestInterruptedException
        end

        # Interrupting abandons queued work the way Ctrl-C abandons pending REPL input.
        @test evaluate(ctrl, sid, "reached").inline == "String[]"
    end
end

@testitem "interrupting an idle session is a no-op" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        interrupt_session(ctrl, sid)
        sleep(0.5)

        @test only(list_sessions(ctrl)).alive
        @test evaluate(ctrl, sid, "1 + 1").inline == "2"
    end
end

@testitem "interrupting an unknown session does not throw" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_controller() do ctrl
        interrupt_session(ctrl, "no-such-session")
        sleep(0.2)
        @test isempty(list_sessions(ctrl))
    end
end

@testitem "interrupting a blocked read wakes the session up" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        running = @async evaluate(ctrl, sid, "take!(Channel{Int}(1))")
        sleep(1)

        interrupt_session(ctrl, sid)
        @test fetch(running).status === :error
        @test evaluate(ctrl, sid, ":alive").inline == ":alive"
    end
end

@testitem "an interrupt that arrives before the backend starts is not dropped" begin
    # `backend.jl` runs inside the session process, and the window this covers — a request
    # accepted but not yet in user code — is milliseconds wide on a warm machine and seconds
    # wide on a cold CI runner. It cannot be hit reliably through the controller, so drive
    # the backend directly instead. Dropping the interrupt is what used to make the
    # controller kill a perfectly healthy session once the grace period ran out.
    backend_source = normpath(joinpath(
        @__DIR__, "..", "sessionprocess", "JuliaSessionServer", "src", "backend.jl"))

    Protocol = Module(:Protocol)
    Core.eval(Protocol, :(const OUTPUT_BEGIN_MARKER = "<out "))
    Core.eval(Protocol, :(const OUTPUT_END_MARKER = "<end out>"))

    Backend = Module(:BackendUnderTest)
    Core.eval(Backend, :(const Protocol = $Protocol))
    Base.include(Backend, backend_source)

    Backend.start_eval_backend()

    @test Backend.run_on_backend(() -> 6 * 7).content == 42

    # Nothing is in flight, so there is nothing to interrupt and nothing is held.
    @test !Backend.interrupt_backend()
    @test Backend.run_on_backend(() -> 1).content == 1

    # A request has been accepted, but the backend has not reached it yet.
    Backend.request_accepted!()
    @test Backend.interrupt_backend()

    ran = Ref(false)
    outcome = Backend.run_on_backend(() -> (ran[] = true; 99))
    @test !ran[]
    @test outcome isa Backend.BackendError
    @test outcome.err isa InterruptException

    # The hold is consumed by that one request, never carried into the next.
    @test Backend.run_on_backend(() -> 1 + 1).content == 2
    Backend.request_finished!()

    # A hold whose request never arrives is dropped when the last request finishes, so it
    # cannot fire at an unrelated one later.
    Backend.request_accepted!()
    @test Backend.interrupt_backend()
    Backend.request_finished!()
    @test Backend.run_on_backend(() -> :untouched).content === :untouched
end
