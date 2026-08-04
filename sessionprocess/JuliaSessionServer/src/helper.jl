const SERVER_DIR = @__DIR__
const JULIA_BASE_DIR = normpath(joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base"))
const JULIA_STDLIB_DIR = Sys.STDLIB

"""Is this frame part of the session server itself, or of Base/stdlib?"""
function is_infrastructure_frame(file::AbstractString)
    return startswith(file, SERVER_DIR) ||
           startswith(file, JULIA_BASE_DIR) ||
           startswith(file, JULIA_STDLIB_DIR)
end

function format_error_message(err)
    try
        actual = err isa LoadError ? err.error : err
        return Base.invokelatest(sprint, showerror, actual)
    catch
        return "Error while trying to format an error message"
    end
end

function resolve_source_file(file::AbstractString)
    isabspath(file) && return String(file)
    resolved = Base.find_source_file(String(file))
    return resolved === nothing ? String(file) : resolved
end

"""
Convert a backtrace into protocol stack frames, dropping the trailing frames that belong to
the server rather than to the user's code.
"""
function backtrace_to_stackframes(bt)
    frames = try
        stacktrace(bt)
    catch
        return missing
    end

    result = Protocol.StackFrame[]
    files = String[]

    for frame in frames
        frame.from_c && continue
        file = resolve_source_file(string(frame.file))
        uri = isabspath(file) ? filepath2uri(file) : missing

        push!(result, Protocol.StackFrame(label=string(frame.func), uri=uri, line=frame.line))
        push!(files, file)
    end

    last_user_frame = findlast(f -> !is_infrastructure_frame(f), files)
    last_user_frame === nothing && return missing
    resize!(result, last_user_frame)

    return isempty(result) ? missing : result
end

"""Resolve a dotted module path such as `"Main.Foo"`, falling back to `Main`."""
function module_from_string(name::AbstractString)
    isempty(name) && return Main
    mod = Main
    for part in split(name, '.')
        part == "Main" && continue
        sym = Symbol(part)
        if isdefined(mod, sym)
            candidate = getfield(mod, sym)
            candidate isa Module || return Main
            mod = candidate
        else
            return Main
        end
    end
    return mod
end

const INLINE_RESULT_LENGTH = 200
const MAX_RESULT_LENGTH = 20_000

function truncate_to(s::AbstractString, limit::Int)
    ncodeunits(s) <= limit && return String(s)
    i = limit
    while i > 0 && !isvalid(s, i)
        i -= 1
    end
    return String(SubString(s, 1, i)) * "…"
end

"""Render a value the way a REPL would, both as a one-line summary and in full."""
function render_value(value)
    value === nothing && return ("", "")

    full = try
        sprint(io -> Base.invokelatest(show, IOContext(io, :limit => true, :color => false), MIME("text/plain"), value))
    catch err
        "Error showing value: " * format_error_message(err)
    end

    inline = truncate_to(replace(full, r"\s*\n\s*" => " "), INLINE_RESULT_LENGTH)

    return (inline, truncate_to(full, MAX_RESULT_LENGTH))
end
