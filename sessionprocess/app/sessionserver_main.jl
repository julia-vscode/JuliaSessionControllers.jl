@info "Julia session process launching"

let
    has_error_handler = false

    try
        if length(ARGS) > 1
            include(ARGS[2])
            has_error_handler = true
        end

        version_specific = joinpath(@__DIR__, "../environments", "v$(VERSION.major).$(VERSION.minor)")
        env_path = isdir(version_specific) ? version_specific : joinpath(@__DIR__, "../environments", "fallback")

        set_project = path -> @static if VERSION < v"1.8.0"
            Base.ACTIVE_PROJECT[] = path
        else
            Base.set_active_project(path)
        end

        # The server loads from its own private environment, but the process is put back on
        # the environment it started with afterwards — otherwise the user's code would be
        # stuck in ours, where it cannot even load a stdlib the server did not declare.
        previous_project = Base.ACTIVE_PROJECT[]
        server = try
            set_project(env_path)
            # `Base.require` rather than `using`, so no binding is left behind in `Main`.
            Base.require(Main, :JuliaSessionServer)
        finally
            set_project(previous_project)
        end

        server.serve(
            ARGS[1],
            has_error_handler ? (err, bt) -> Base.invokelatest(global_err_handler, err, bt, Base.ARGS[3], "Julia Session") : nothing)
    catch err
        if has_error_handler
            Base.invokelatest(global_err_handler, err, catch_backtrace(), Base.ARGS[3], "Julia Session")
        end

        rethrow()
    end
end
