"""Cap on how many children a single lazy expansion reports."""
const MAX_LAZY_CHILDREN = 200

function has_children(value)
    value isa Module && return true
    value isa AbstractArray && return !isempty(value)
    value isa AbstractDict && return !isempty(value)
    value isa Tuple && return !isempty(value)
    return try
        fieldcount(typeof(value)) > 0
    catch
        false
    end
end

function icon_for(value)
    value isa Module && return "symbol-namespace"
    value isa Function && return "symbol-method"
    value isa Type && return "symbol-structure"
    value isa AbstractArray && return "symbol-array"
    value isa AbstractDict && return "symbol-object"
    value isa Number && return "symbol-numeric"
    value isa AbstractString && return "symbol-string"
    return "symbol-variable"
end

"""Where a function or type was defined, when that can be determined cheaply."""
function definition_location(value)
    try
        ms = methods(value)
        isempty(ms) && return (missing, missing)
        m = first(ms)
        file = resolve_source_file(string(m.file))
        isabspath(file) || return (missing, missing)
        return (filepath2uri(file), Int(m.line))
    catch
        return (missing, missing)
    end
end

function register_lazy!(state::SessionServerState, value)
    id = state.next_lazy_id
    state.next_lazy_id += 1
    state.lazy_values[id] = value
    return id
end

function workspace_item(state::SessionServerState, name::AbstractString, value)
    children = has_children(value)
    inline, _ = render_value(value)
    uri, line = definition_location(value)

    return Protocol.WorkspaceItem(
        head=String(name),
        id=children ? register_lazy!(state, value) : 0,
        haschildren=children,
        lazy=children,
        icon=icon_for(value),
        value=inline,
        canshow=true,
        type=string(typeof(value)),
        uri=uri,
        line=line,
    )
end

function collect_variables(state::SessionServerState, mod::Module, include_modules::Bool)
    items = Protocol.WorkspaceItem[]

    for name in sort!(names(mod; all=true, imported=false))
        text = string(name)
        # Compiler-generated bindings are noise, and `include`/`eval` are on every module.
        (startswith(text, "#") || name === :include || name === :eval) && continue
        isdefined(mod, name) || continue

        value = try
            getfield(mod, name)
        catch
            continue
        end
        value isa Module && !include_modules && continue
        value === mod && continue

        push!(items, workspace_item(state, text, value))
    end

    return items
end

function get_variables_request(params::Protocol.GetVariablesParams, state::SessionServerState, token)
    outcome = run_on_backend() do
        collect_variables(state, module_from_string(params.mod), params.includeModules)
    end
    outcome isa BackendError && return Protocol.WorkspaceItem[]
    return outcome.content
end

function collect_children(state::SessionServerState, value)
    items = Protocol.WorkspaceItem[]

    if value isa Module
        return collect_variables(state, value, false)
    elseif value isa AbstractDict
        for (i, (k, v)) in enumerate(value)
            i > MAX_LAZY_CHILDREN && break
            push!(items, workspace_item(state, first(render_value(k)), v))
        end
    elseif value isa AbstractArray || value isa Tuple
        for (i, v) in enumerate(value)
            i > MAX_LAZY_CHILDREN && break
            push!(items, workspace_item(state, string(i), v))
        end
    else
        T = typeof(value)
        for name in fieldnames(T)
            isdefined(value, name) || continue
            push!(items, workspace_item(state, string(name), getfield(value, name)))
        end
    end

    return items
end

function get_lazy_request(params::Protocol.GetLazyParams, state::SessionServerState, token)
    haskey(state.lazy_values, params.id) || return Protocol.WorkspaceItem[]
    value = state.lazy_values[params.id]

    outcome = run_on_backend() do
        collect_children(state, value)
    end
    outcome isa BackendError && return Protocol.WorkspaceItem[]
    return outcome.content
end

function get_completions_request(params::Protocol.GetCompletionsParams, state::SessionServerState, token)
    outcome = run_on_backend() do
        mod = module_from_string(params.mod)
        completions, _, _ = REPL.completions(params.line, lastindex(params.line), mod)

        items = Protocol.CompletionItem[]
        for c in completions
            length(items) >= MAX_LAZY_CHILDREN && break
            push!(items, Protocol.CompletionItem(
                label=REPL.completion_text(c),
                kind=string(nameof(typeof(c))),
                documentation=missing,
            ))
        end
        return items
    end

    outcome isa BackendError && return Protocol.CompletionItem[]
    return outcome.content
end

function get_modules_request(::Nothing, state::SessionServerState, token)
    names = String[]
    for m in values(Base.loaded_modules)
        push!(names, string(m))
    end
    return sort!(unique!(names))
end
