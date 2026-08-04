"""
    ControllerPhase

States for the controller-level FSM.
- `ControllerRunning`: normal operation, accepts new sessions and requests
- `ControllerShuttingDown`: rejects new work, terminates all sessions
- `ControllerStopped`: reactor loop breaks
"""
@enum ControllerPhase begin
    ControllerRunning
    ControllerShuttingDown
    ControllerStopped
end

"""
    SessionPhase

States for the per-session FSM. `SessionDead` is reachable from any other state and is
terminal — sessions are never restarted.
"""
@enum SessionPhase begin
    SessionCreated
    SessionStarting
    SessionActivatingEnv
    SessionIdle
    SessionEvaluating
    SessionRevising
    SessionProfiling
    SessionInspecting
    SessionDebugging
    SessionInterrupting
    SessionDead
end

"""The states in which a session is running a request on behalf of the caller."""
const BUSY_PHASES = (
    SessionEvaluating,
    SessionRevising,
    SessionProfiling,
    SessionInspecting,
    SessionDebugging,
)

"""
    FSM{S}

Simple finite state machine parameterized on state enum type `S`.
Validates transitions against an allowed-transition table and logs changes.
"""
mutable struct FSM{S}
    current::S
    transitions::Dict{S,Set{S}}
    id::String
end

"""Return the current state of the FSM."""
state(fsm::FSM) = fsm.current

"""
    transition!(fsm, new_state; reason=nothing)

Transition the FSM to `new_state`. Raises an error if the transition is not allowed.
"""
function transition!(fsm::FSM{S}, new_state::S; reason=nothing) where {S}
    allowed = get(fsm.transitions, fsm.current, Set{S}())
    if new_state ∉ allowed
        error("Invalid FSM transition for '$(fsm.id)': $(fsm.current) → $(new_state)" *
              (reason !== nothing ? " (reason: $reason)" : ""))
    end
    old_state = fsm.current
    fsm.current = new_state
    @debug "FSM transition" id = fsm.id from = old_state to = new_state reason
    return new_state
end

"""Create a controller-phase FSM starting in `ControllerRunning`."""
function controller_fsm(id::String)
    transitions = Dict{ControllerPhase,Set{ControllerPhase}}(
        ControllerRunning => Set([ControllerShuttingDown]),
        ControllerShuttingDown => Set([ControllerStopped]),
    )
    return FSM(ControllerRunning, transitions, id)
end

"""Create a session-phase FSM starting in `SessionCreated`."""
function session_fsm(id::String)
    transitions = Dict{SessionPhase,Set{SessionPhase}}()
    # ANY → Dead (except Dead itself)
    for phase in instances(SessionPhase)
        phase == SessionDead || (transitions[phase] = Set([SessionDead]))
    end

    union!(transitions[SessionCreated], Set([SessionStarting]))
    union!(transitions[SessionStarting], Set([SessionActivatingEnv, SessionIdle]))
    union!(transitions[SessionActivatingEnv], Set([SessionIdle]))
    union!(transitions[SessionIdle], Set(BUSY_PHASES))

    # A busy session either finishes its request or is interrupted out of it.
    for phase in BUSY_PHASES
        union!(transitions[phase], Set([SessionIdle, SessionInterrupting]))
    end
    union!(transitions[SessionInterrupting], Set([SessionIdle]))

    return FSM(SessionCreated, transitions, id)
end

"""Human-readable status label reported through `on_session_status_changed`."""
function status_label(phase::SessionPhase)
    phase === SessionCreated && return "Created"
    phase === SessionStarting && return "Starting"
    phase === SessionActivatingEnv && return "Activating"
    phase === SessionIdle && return "Idle"
    phase === SessionEvaluating && return "Evaluating"
    phase === SessionRevising && return "Revising"
    phase === SessionProfiling && return "Profiling"
    phase === SessionInspecting && return "Inspecting"
    phase === SessionDebugging && return "Debugging"
    phase === SessionInterrupting && return "Interrupting"
    return "Dead"
end
