@testmodule SessionHelpers begin

using JuliaSessionsControllers
const JSC = JuliaSessionsControllers

const TESTDATA_DIR = normpath(joinpath(@__DIR__, "..", "testdata"))

"""
Run `f(controller)` against a live controller, shutting it down afterwards whatever
happens. Callback keyword arguments are forwarded to `ControllerCallbacks`.
"""
function with_controller(f; kwargs...)
    controller = JuliaSessionsController(ControllerCallbacks(; kwargs...))
    task = @async run(controller)
    try
        return f(controller)
    finally
        shutdown(controller)
        wait_for_shutdown(controller, task)
    end
end

"""
Run `f(controller, session_id)` against a freshly created session.
"""
function with_session(f, env::SessionEnvironment=SessionEnvironment(); kwargs...)
    with_controller(; kwargs...) do controller
        session_id = create_session(controller, env)
        return f(controller, session_id)
    end
end

"""Poll `pred` until it holds or `timeout` seconds elapse. Returns whether it held."""
function timed_wait(pred, timeout::Real; interval::Real=0.05)
    deadline = time() + timeout
    while time() < deadline
        pred() && return true
        sleep(interval)
    end
    return pred()
end

"""Copy a `testdata/` fixture into a temp directory so tests can mutate it freely."""
function copy_testdata(name::AbstractString)
    dest = mktempdir()
    target = joinpath(dest, name)
    cp(joinpath(TESTDATA_DIR, name), target)
    return target
end

"""Unwrap the exception a failed `@async` request task carries."""
function captured_exception(task::Task)
    try
        fetch(task)
        return nothing
    catch err
        return err isa TaskFailedException ? err.task.exception : err
    end
end

end
