@info "Julia session process precompiling"

# Julia versions before 1.10 do not precompile the vendored packages reliably on first use,
# so the controller runs this script once per environment to warm them up.
let
    version_specific_env_path = joinpath(@__DIR__, "../environments", "v$(VERSION.major).$(VERSION.minor)")
    env_path = isdir(version_specific_env_path) ? version_specific_env_path : joinpath(@__DIR__, "../environments", "fallback")
    if isdefined(Base, :ACTIVE_PROJECT)
        Base.ACTIVE_PROJECT[] = env_path
    else
        import Pkg
        Pkg.activate(env_path)
    end
end

let
    has_error_handler = false

    try
        if length(ARGS) > 0
            include(ARGS[1])
            has_error_handler = true
        end

        Base.require(Main, :JuliaSessionServer)
    catch err
        bt = catch_backtrace()
        if has_error_handler
            Base.invokelatest(global_err_handler, err, bt, Base.ARGS[2], "Julia Session")
        else
            rethrow(err)
        end
    end
end
