# CPU and allocation profiling, producing the same flame-graph shaped tree the Julia VS Code
# extension renders. Ported from VSCodeServer's profiler.

function frame_status(sf::StackTraces.StackFrame)
    st = 0
    if sf.from_c && (sf.func === :jl_invoke || sf.func === :jl_apply_generic || sf.func === :ijl_apply_generic)
        st |= Protocol.PROFILE_FLAG_RUNTIME_DISPATCH
    end
    if sf.from_c && startswith(String(sf.func), "jl_gc_")
        st |= Protocol.PROFILE_FLAG_GC_EVENT
    end
    if !sf.from_c && sf.func === :eval_user_input && endswith(String(sf.file), "REPL.jl")
        st |= Protocol.PROFILE_FLAG_REPL
    end
    if !sf.from_c && occursin("./compiler/", String(sf.file))
        st |= Protocol.PROFILE_FLAG_COMPILATION
    end
    if !sf.from_c && occursin("task.jl", String(sf.file))
        st |= Protocol.PROFILE_FLAG_TASK_EVENT
    end
    return st
end

function node_status(node, include_c::Bool)
    st = frame_status(node.frame)
    include_c && return st
    # When C frames are hidden their flags still matter, so fold them into the parent.
    for child in values(node.down)
        child.frame.from_c || continue
        st |= node_status(child, include_c)
    end
    return st
end

function profile_frame(node, include_c::Bool)
    file = string(node.frame.file)
    func = String(node.frame.func)
    isempty(func) && (func = "unknown")

    return Protocol.ProfileFrame(
        func=func,
        file=basename(file),
        path=resolve_source_file(file),
        line=node.frame.line,
        count=node.count,
        countLabel=missing,
        flags=node_status(node, include_c),
        taskId=missing,
        children=Protocol.ProfileFrame[],
    )
end

function build_tree!(graph::Protocol.ProfileFrame, node; include_c::Bool=false)
    for child_node in sort!(collect(values(node.down)); rev=true, by=n -> n.count)
        if include_c || !child_node.frame.from_c
            child = profile_frame(child_node, include_c)
            push!(graph.children, child)
            build_tree!(child, child_node; include_c=include_c)
        else
            build_tree!(graph, child_node; include_c=include_c)
        end
    end
    return graph
end

empty_frame(name::AbstractString, count::Int=0) =
    Protocol.ProfileFrame(func=String(name), file="", path="", line=0, count=count,
        countLabel=missing, flags=0, taskId=missing, children=Protocol.ProfileFrame[])

function stack_frame_tree(data_u64, lidict; thread=nothing, recur=:off)
    root = Profile.StackFrameTree{StackTraces.StackFrame}()
    @static if VERSION >= v"1.8.0-DEV.460"
        root, _ = Profile.tree!(root, data_u64, lidict, true, recur, thread)
    else
        root = Profile.tree!(root, data_u64, lidict, true, recur)
    end
    isempty(root.down) || (root.count = sum(pr -> pr.second.count, root.down))
    return root
end

function collect_cpu_profile(include_c::Bool)
    data = Profile.fetch()
    isempty(data) && return (Protocol.ProfileThread[], 0)

    lidict = Profile.getdict(unique(data))
    data_u64 = convert(Vector{UInt64}, data)

    @static if VERSION >= v"1.8.0-DEV.460"
        all_tids = isdefined(Threads, :threadpooltids) ?
                   sort([Threads.threadpooltids(:interactive)..., Threads.threadpooltids(:default)...]) :
                   Int[1:Threads.nthreads()...]
        threads = Union{Nothing,Int}[nothing, all_tids...]
    else
        threads = Union{Nothing,Int}[nothing]
    end

    result = Protocol.ProfileThread[]
    for thread in threads
        graph = stack_frame_tree(data_u64, lidict; thread=thread)
        name = thread === nothing ? "all" : string(thread)
        root = empty_frame("root", graph.count)
        build_tree!(root, graph; include_c=include_c)
        push!(result, Protocol.ProfileThread(name=name, root=root))
    end

    return (result, length(data))
end

"""Mutable accumulator for allocation profiles; converted to wire frames at the end."""
mutable struct AllocNode
    func::String
    file::String
    path::String
    line::Int
    bytes::Int
    flags::Int
    children::Dict{Tuple{String,Int},AllocNode}
end

AllocNode(func, file, path, line, flags) =
    AllocNode(func, file, path, line, 0, flags, Dict{Tuple{String,Int},AllocNode}())

"""Add one allocation's stack trace to `root`, accumulating bytes along the way."""
function insert_alloc!(root::AllocNode, stacktrace, size::Int, include_c::Bool)
    node = root
    for sf in Iterators.reverse(stacktrace)
        (!include_c && sf.from_c) && continue
        file = string(sf.file)
        func = isempty(String(sf.func)) ? "unknown" : String(sf.func)

        node = get!(node.children, (func, sf.line)) do
            AllocNode(func, basename(file), resolve_source_file(file), sf.line, frame_status(sf))
        end
        node.bytes += size
    end
    return root
end

function to_profile_frame(node::AllocNode)
    return Protocol.ProfileFrame(
        func=node.func,
        file=node.file,
        path=node.path,
        line=node.line,
        count=node.bytes,
        countLabel="bytes",
        flags=node.flags,
        taskId=missing,
        children=Protocol.ProfileFrame[
            to_profile_frame(c) for c in sort!(collect(values(node.children)); rev=true, by=n -> n.bytes)
        ],
    )
end

function profile_request(params::Protocol.ProfileParams, state::SessionServerState, token)
    mod = module_from_string(params.mod)
    filename = isempty(params.filename) ? "session" : params.filename

    if params.kind == "alloc" && !isdefined(Profile, :Allocs)
        return Protocol.ProfileResult(
            status=Protocol.STATUS_UNSUPPORTED,
            error="Allocation profiling requires Julia 1.8 or newer; this session runs $(VERSION).",
            threads=missing,
            totalSamples=missing,
        )
    end

    outcome = run_on_backend(request_id=params.requestId) do
        expr = parse_toplevel(params.code, filename)
        params.line > 1 && offset_line_numbers!(expr, params.line - 1)

        if params.kind == "alloc"
            @static if isdefined(Profile, :Allocs)
                rate = coalesce(params.sampleRate, 0.0001)
                Profile.Allocs.clear()
                Profile.Allocs.@profile sample_rate = rate eval_toplevel(mod, expr, true)

                results = Profile.Allocs.fetch()
                root = AllocNode("root", "", "", 0, 0)
                for alloc in results.allocs
                    insert_alloc!(root, alloc.stacktrace, alloc.size, false)
                end
                return (Protocol.ProfileThread[Protocol.ProfileThread(name="all", root=to_profile_frame(root))], length(results.allocs))
            else
                return (Protocol.ProfileThread[], 0)
            end
        end

        Profile.clear()
        params.delay === missing || Profile.init(delay=params.delay)
        Profile.@profile eval_toplevel(mod, expr, true)
        return collect_cpu_profile(false)
    end

    if outcome isa BackendError
        return Protocol.ProfileResult(
            status=Protocol.STATUS_ERROR,
            error=format_error_message(outcome.err),
            threads=missing,
            totalSamples=missing,
        )
    end

    threads, total = outcome.content
    return Protocol.ProfileResult(
        status=Protocol.STATUS_SUCCESS,
        error=missing,
        threads=threads,
        totalSamples=total,
    )
end
