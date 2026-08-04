@testmodule SessionHelpers begin

using JuliaSessionControllers
const JSC = JuliaSessionControllers

const TESTDATA_DIR = normpath(joinpath(@__DIR__, "..", "testdata"))

"""
Run `f(controller)` against a live controller, shutting it down afterwards whatever
happens. Callback keyword arguments are forwarded to `ControllerCallbacks`.
"""
function with_controller(f; kwargs...)
    controller = JuliaSessionController(ControllerCallbacks(; kwargs...))
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

"""
The `X.Y` juliaup channels that have a matching session process environment, so that the
cross-version tests only cover versions this checkout can actually serve.
"""
function installed_julia_versions()
    environments = normpath(joinpath(@__DIR__, "..", "sessionprocess", "environments"))
    available = Set(
        chop(name, head=1, tail=0)
        for name in readdir(environments)
        if startswith(name, "v")
    )

    status = try
        read(`juliaup status`, String)
    catch err
        @warn "juliaup is not available; skipping cross-version coverage" exception = (err,)
        return String[]
    end

    channels = String[]
    for m in eachmatch(r"(?m)^\s*\*?\s*(\d+\.\d+)\s+\d", status)
        channel = m[1]
        channel in available && push!(channels, channel)
    end

    return sort!(unique!(channels), by=VersionNumber)
end

end
