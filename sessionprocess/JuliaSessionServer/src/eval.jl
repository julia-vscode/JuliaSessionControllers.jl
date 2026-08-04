@static if isdefined(REPL, :softscope)
    apply_softscope(ex) = REPL.softscope(ex)
else
    apply_softscope(ex) = ex
end

# `Meta.parseall` only exists on Julia 1.6+; `Base.parse_input_line` is what the REPL has
# always used and returns the same `:toplevel` expression.
@static if isdefined(Meta, :parseall)
    parse_toplevel(code, filename) = Meta.parseall(code, filename=filename)
else
    parse_toplevel(code, filename) = Base.parse_input_line(code, filename=filename)
end

"""Shift every `LineNumberNode` in `x` so the code appears to start at its real line."""
function offset_line_numbers!(x, offset::Int)
    x isa Expr || return x
    for (i, a) in enumerate(x.args)
        if a isa LineNumberNode
            x.args[i] = LineNumberNode(a.line + offset, a.file)
        else
            offset_line_numbers!(a, offset)
        end
    end
    return x
end

function eval_one(mod::Module, ex, lnn, softscope::Bool)
    ex = softscope ? apply_softscope(ex) : ex
    # `:toplevel` rather than `:block`, because `module` and `using` are only legal at top
    # level — wrapping them in a block makes them fail.
    return Core.eval(mod, lnn === nothing ? ex : Expr(:toplevel, lnn, ex))
end

"""
Collapse a parsed `:toplevel` expression into a single `:block`, for the callers that need
an ordinary expression rather than a sequence of top-level statements.
"""
function toplevel_to_block(expr)
    (expr isa Expr && expr.head === :toplevel) || return expr
    return Expr(:block, expr.args...)
end

"""Evaluate every top-level statement in order and return the value of the last one."""
function eval_toplevel(mod::Module, expr, softscope::Bool)
    # `parse_input_line` returns `nothing` for input that holds no expressions at all.
    expr === nothing && return nothing

    if expr isa Expr && expr.head === :toplevel
        result = nothing
        lnn = nothing
        for a in expr.args
            if a isa LineNumberNode
                lnn = a
                continue
            end
            result = eval_one(mod, a, lnn, softscope)
        end
        return result
    end
    return eval_one(mod, expr, nothing, softscope)
end

function eval_request(params::Protocol.EvalParams, state::SessionServerState, token)
    mod = module_from_string(params.mod)
    filename = isempty(params.filename) ? "session" : params.filename
    started = time()

    outcome = run_on_backend(request_id=params.requestId) do
        expr = parse_toplevel(params.code, filename)
        params.line > 1 && offset_line_numbers!(expr, params.line - 1)
        value = eval_toplevel(mod, expr, params.softscope)
        # Mirror the REPL so follow-up code can refer to the previous result.
        value === nothing || Core.eval(Main, Expr(:(=), :ans, QuoteNode(value)))
        return value
    end

    elapsed = time() - started

    if outcome isa BackendError
        message = format_error_message(outcome.err)
        actual = outcome.err isa LoadError ? outcome.err.error : outcome.err
        return Protocol.EvalResult(
            requestId=params.requestId,
            status=Protocol.STATUS_ERROR,
            inline=truncate_to(first(split(message, '\n')), INLINE_RESULT_LENGTH),
            all=truncate_to(message, MAX_RESULT_LENGTH),
            resultType=string(typeof(actual)),
            stackFrames=backtrace_to_stackframes(outcome.bt),
            elapsed=elapsed,
        )
    end

    value = outcome.content
    inline, full = render_value(value)

    return Protocol.EvalResult(
        requestId=params.requestId,
        status=Protocol.STATUS_SUCCESS,
        inline=inline,
        all=full,
        resultType=string(typeof(value)),
        stackFrames=missing,
        elapsed=elapsed,
    )
end

function activate_env_request(params::Protocol.ActivateEnvParams, state::SessionServerState, token)
    outcome = run_on_backend() do
        if params.projectUri === missing
            if params.packageUri !== missing
                @static if VERSION >= v"1.5.0"
                    Pkg.activate(temp=true)
                else
                    Pkg.activate(mktempdir())
                end
                Pkg.develop(Pkg.PackageSpec(path=uri2filepath(params.packageUri)))
                params.packageName === missing || TestEnv.activate(params.packageName)
            end
        else
            Pkg.activate(uri2filepath(params.projectUri))
            if params.useTestEnv && params.packageName !== missing
                TestEnv.activate(params.packageName)
            end
        end
        return Base.active_project()
    end

    if outcome isa BackendError
        return Protocol.ActivateEnvResult(
            status=Protocol.STATUS_ERROR,
            error=format_error_message(outcome.err),
            activeProject=missing,
        )
    end

    return Protocol.ActivateEnvResult(
        status=Protocol.STATUS_SUCCESS,
        error=missing,
        activeProject=outcome.content === nothing ? missing : String(outcome.content),
    )
end

function revise_request(::Nothing, state::SessionServerState, token)
    outcome = run_on_backend() do
        Revise.revise(throw=true)
    end

    outcome isa BackendError && return Protocol.ReviseResult(
        status=Protocol.STATUS_ERROR,
        error=format_error_message(outcome.err),
    )

    return Protocol.ReviseResult(status=Protocol.STATUS_SUCCESS, error=missing)
end

function shutdown_request(::Nothing, state::SessionServerState, token)
    return nothing
end
