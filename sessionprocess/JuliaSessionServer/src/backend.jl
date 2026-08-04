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
                result = try
                    BackendValue(Base.invokelatest(f))
                catch err
                    BackendError(err, catch_backtrace())
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
Throw an `InterruptException` into the backend task, if it is currently running user code.
Called from the message loop task, never from the backend itself.
"""
function interrupt_backend()
    task = EVAL_BACKEND_TASK[]
    (task === nothing || istaskdone(task) || !IS_BACKEND_WORKING[]) && return false
    try
        schedule(task, InterruptException(); error=true)
    catch err
        @debug "Could not interrupt the backend task" exception = (err,)
        return false
    end
    return true
end
