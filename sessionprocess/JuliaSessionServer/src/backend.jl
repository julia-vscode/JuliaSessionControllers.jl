# All user code runs on a single long-lived backend task. Keeping it off the message loop is
# what makes `session/interrupt` possible: the loop stays responsive and can throw an
# `InterruptException` into this task. It also guarantees requests never overlap inside the
# session process, independently of the controller's own queueing.

"""Wraps a successful backend result so that it is never confused with a `BackendError`."""
struct BackendValue
    content::Any
end

struct BackendError
    err::Any
    bt::Any
end

const EVAL_CHANNEL_IN = Channel{Any}(0)
const EVAL_CHANNEL_OUT = Channel{Any}(0)
const EVAL_BACKEND_TASK = Ref{Union{Nothing,Task}}(nothing)
const IS_BACKEND_WORKING = Ref{Bool}(false)

# Requests that the message loop has accepted but that have not finished. A request spends
# this whole time on its own dispatch task, and on a cold session most of it is compilation,
# long before anything reaches the backend.
const IN_FLIGHT_REQUESTS = Ref{Int}(0)

# Set when an interrupt arrives while a request is in flight but the backend is not yet
# inside user code. Without it that interrupt is simply dropped, the request runs to
# completion, and the controller kills a perfectly healthy process once the grace period
# runs out.
const INTERRUPT_PENDING = Ref{Bool}(false)

function start_eval_backend()
    EVAL_BACKEND_TASK[] = @async begin
        # `sigatomic` protects the plumbing around user code, so an interrupt that arrives
        # between requests cannot corrupt the channel handshake.
        Base.sigatomic_begin()
        while true
            try
                f = take!(EVAL_CHANNEL_IN)
                Base.sigatomic_end()
                IS_BACKEND_WORKING[] = true
                result = if INTERRUPT_PENDING[]
                    # Interrupted before we got here, so the user's code never runs. The
                    # caller sees the same result it would have seen had the interrupt
                    # landed a moment later, mid-execution.
                    INTERRUPT_PENDING[] = false
                    BackendError(InterruptException(), backtrace())
                else
                    try
                        BackendValue(Base.invokelatest(f))
                    catch err
                        BackendError(err, catch_backtrace())
                    end
                end
                IS_BACKEND_WORKING[] = false
                Base.sigatomic_begin()
                put!(EVAL_CHANNEL_OUT, result)
            catch err
                try
                    put!(EVAL_CHANNEL_OUT, BackendError(err, catch_backtrace()))
                catch
                end
            finally
                IS_BACKEND_WORKING[] = false
            end
        end
        Base.sigatomic_end()
    end
    return nothing
end

"""
    run_on_backend(f; request_id=nothing)

Run `f` on the backend task and wait for it. Returns a [`BackendValue`](@ref) or a
`BackendError`; it never throws on account of the user's code.

When `request_id` is given, output produced while `f` runs is bracketed by the sentinel
markers the controller uses to attribute it to that request.
"""
function run_on_backend(f; request_id::Union{Nothing,AbstractString}=nothing)
    wrapped = request_id === nothing ? f : function ()
        try
            print(stderr, Protocol.OUTPUT_BEGIN_MARKER, request_id, "\"")
            flush(stderr)
            f()
        finally
            print(stderr, Protocol.OUTPUT_END_MARKER)
            flush(stderr)
        end
    end

    put!(EVAL_CHANNEL_IN, wrapped)
    return take!(EVAL_CHANNEL_OUT)
end

"""
    request_accepted!()
    request_finished!()

Bracket a request for as long as the message loop is responsible for it, so
[`interrupt_backend`](@ref) can tell "nothing is running" apart from "something is on its
way to the backend".
"""
request_accepted!() = (IN_FLIGHT_REQUESTS[] += 1; nothing)

function request_finished!()
    IN_FLIGHT_REQUESTS[] = max(0, IN_FLIGHT_REQUESTS[] - 1)
    # A held interrupt belongs to a request that is in flight. Once none are left it could
    # only ever hit an unrelated future one, so drop it.
    IN_FLIGHT_REQUESTS[] == 0 && (INTERRUPT_PENDING[] = false)
    return nothing
end

"""
Interrupt whatever the session is currently working on. Returns whether there was anything
to interrupt. Called from the message loop task, never from the backend itself.

Two cases, and the second is the one that used to be missed: user code is running, so an
`InterruptException` is thrown into the backend task; or a request is still on its way there
— being parsed, compiled, dispatched — in which case the interrupt is held and applied the
moment that request reaches the backend.
"""
function interrupt_backend()
    task = EVAL_BACKEND_TASK[]
    (task === nothing || istaskdone(task)) && return false

    if IS_BACKEND_WORKING[]
        try
            schedule(task, InterruptException(); error=true)
        catch err
            @debug "Could not interrupt the backend task" exception = (err,)
            return false
        end
        return true
    end

    if IN_FLIGHT_REQUESTS[] > 0
        INTERRUPT_PENDING[] = true
        return true
    end

    return false
end
