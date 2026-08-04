@testitem "session FSM allows the normal lifecycle" begin
    using JuliaSessionsControllers: session_fsm, transition!, state,
        SessionCreated, SessionStarting, SessionActivatingEnv, SessionIdle,
        SessionEvaluating, SessionInterrupting, SessionDead

    fsm = session_fsm("s")
    @test state(fsm) === SessionCreated

    transition!(fsm, SessionStarting)
    transition!(fsm, SessionActivatingEnv)
    transition!(fsm, SessionIdle)
    transition!(fsm, SessionEvaluating)
    transition!(fsm, SessionIdle)
    @test state(fsm) === SessionIdle
end

@testitem "a session can be interrupted out of any busy state" begin
    using JuliaSessionsControllers: session_fsm, transition!, state,
        SessionStarting, SessionIdle, SessionInterrupting, BUSY_PHASES

    for phase in BUSY_PHASES
        fsm = session_fsm("s")
        transition!(fsm, SessionStarting)
        transition!(fsm, SessionIdle)
        transition!(fsm, phase)
        transition!(fsm, SessionInterrupting)
        transition!(fsm, SessionIdle)
        @test state(fsm) === SessionIdle
    end
end

@testitem "SessionDead is reachable from anywhere and is terminal" begin
    using JuliaSessionsControllers: session_fsm, transition!, state, SessionPhase,
        SessionDead, SessionIdle

    for phase in instances(SessionPhase)
        phase === SessionDead && continue
        fsm = session_fsm("s")
        fsm.current = phase
        transition!(fsm, SessionDead)
        @test state(fsm) === SessionDead
        # Sessions are never restarted, so there is no way back out.
        @test_throws ErrorException transition!(fsm, SessionIdle)
    end
end

@testitem "invalid session transitions are rejected" begin
    using JuliaSessionsControllers: session_fsm, transition!, SessionEvaluating, SessionActivatingEnv

    fsm = session_fsm("s")
    @test_throws ErrorException transition!(fsm, SessionEvaluating)
    @test_throws ErrorException transition!(fsm, SessionActivatingEnv)
end

@testitem "controller FSM runs down to stopped" begin
    using JuliaSessionsControllers: controller_fsm, transition!, state,
        ControllerRunning, ControllerShuttingDown, ControllerStopped

    fsm = controller_fsm("c")
    @test state(fsm) === ControllerRunning
    transition!(fsm, ControllerShuttingDown)
    transition!(fsm, ControllerStopped)
    @test state(fsm) === ControllerStopped
    @test_throws ErrorException transition!(fsm, ControllerRunning)
end

@testitem "every session phase has a status label" begin
    using JuliaSessionsControllers: status_label, SessionPhase

    labels = [status_label(p) for p in instances(SessionPhase)]
    @test all(!isempty, labels)
    @test length(unique(labels)) == length(labels)
end
