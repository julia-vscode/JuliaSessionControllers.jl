# BenchmarkTools is loaded from the session process's own private environment, into which
# `scripts/update_app_environments.jl` develops the vendored copy for the Julia versions it
# supports. Unlike the other vendored packages it cannot simply be `include`d, because it
# has no `packagedef.jl` and resolves its own dependencies with `using`.

const BENCHMARKTOOLS_UUID = Base.UUID("6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf")
const BENCHMARKTOOLS = Ref{Union{Nothing,Module}}(nothing)

function load_benchmarktools()
    BENCHMARKTOOLS[] === nothing || return BENCHMARKTOOLS[]
    try
        BENCHMARKTOOLS[] = Base.require(Base.PkgId(BENCHMARKTOOLS_UUID, "BenchmarkTools"))
    catch err
        @debug "BenchmarkTools is not available in this session" exception = (err,)
        return nothing
    end
    return BENCHMARKTOOLS[]
end

unsupported_benchmark() = Protocol.BenchmarkResult(
    status=Protocol.STATUS_UNSUPPORTED,
    error="BenchmarkTools is not available on Julia $(VERSION).",
    minTime=missing, medianTime=missing, meanTime=missing, maxTime=missing,
    allocs=missing, memory=missing, nsamples=missing, evalsPerSample=missing,
    summary=missing,
)

function benchmark_request(params::Protocol.BenchmarkParams, state::SessionServerState, token)
    BT = load_benchmarktools()
    BT === nothing && return unsupported_benchmark()

    mod = module_from_string(params.mod)
    filename = isempty(params.filename) ? "session" : params.filename

    outcome = run_on_backend(request_id=params.requestId) do
        expr = parse_toplevel(params.code, filename)
        params.line > 1 && offset_line_numbers!(expr, params.line - 1)

        # Build the `@benchmarkable` call by hand rather than through `@benchmark`, so that
        # the tuning parameters can be passed as ordinary values.
        body = toplevel_to_block(expr)
        benchmarkable = Core.eval(mod, Expr(:macrocall, GlobalRef(BT, Symbol("@benchmarkable")), nothing, body))

        tune_params = benchmarkable.params
        params.seconds === missing || (tune_params.seconds = params.seconds)
        params.samples === missing || (tune_params.samples = params.samples)
        if params.evals === missing
            BT.tune!(benchmarkable)
        else
            tune_params.evals = params.evals
        end

        trial = BT.run(benchmarkable)

        # BenchmarkTools is loaded with `Base.require` at runtime, so its methods must be
        # reduced to plain data here, inside the world age that can see them.
        summary = try
            sprint(io -> show(IOContext(io, :color => false), MIME("text/plain"), trial))
        catch
            missing
        end

        return (
            minTime=BT.time(minimum(trial)),
            medianTime=BT.time(Statistics.median(trial)),
            meanTime=BT.time(Statistics.mean(trial)),
            maxTime=BT.time(maximum(trial)),
            allocs=Int(BT.allocs(trial)),
            memory=Int(BT.memory(trial)),
            nsamples=length(trial.times),
            evalsPerSample=Int(trial.params.evals),
            summary=summary,
        )
    end

    if outcome isa BackendError
        return Protocol.BenchmarkResult(
            status=Protocol.STATUS_ERROR,
            error=format_error_message(outcome.err),
            minTime=missing, medianTime=missing, meanTime=missing, maxTime=missing,
            allocs=missing, memory=missing, nsamples=missing, evalsPerSample=missing,
            summary=missing,
        )
    end

    stats = outcome.content
    return Protocol.BenchmarkResult(
        status=Protocol.STATUS_SUCCESS,
        error=missing,
        minTime=stats.minTime,
        medianTime=stats.medianTime,
        meanTime=stats.meanTime,
        maxTime=stats.maxTime,
        allocs=stats.allocs,
        memory=stats.memory,
        nsamples=stats.nsamples,
        evalsPerSample=stats.evalsPerSample,
        summary=stats.summary,
    )
end
