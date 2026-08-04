module JuliaSessionControllers

import Sockets, UUIDs, Dates

include("../packages/URIParser/src/URIParser.jl")
include("../packages/JSON/src/JSON.jl")
include("../packages/CancellationTokens/src/CancellationTokens.jl")

module JSONRPC
    import ..CancellationTokens
    import ..JSON
    import UUIDs
    import Sockets
    include("../packages/JSONRPC/src/packagedef.jl")
end

export JuliaSessionController
export SessionEnvironment, ControllerCallbacks
export SessionInfo, EvalResult, ProfileResult, ProfileFrame
export WorkspaceVariable, CompletionItem, StackFrame
export SessionNotFoundException, SessionDiedException, SessionStartupFailedException
export RequestTimeoutException, RequestInterruptedException
export create_session, terminate_session, interrupt_session, list_sessions
export evaluate, revise!, activate_env, profile
export get_variables, get_lazy, get_completions, get_modules, start_debug_session
export shutdown, wait_for_shutdown

include("../shared/sessionserver_protocol.jl")
include("../shared/urihelper.jl")

const Protocol = JuliaSessionServerProtocol
using .JuliaSessionServerProtocol: OUTPUT_BEGIN_MARKER, OUTPUT_END_MARKER

include("datatypes.jl")
include("fsm.jl")
include("state.jl")
include("messages.jl")
include("callbacks.jl")
include("sessionprocess.jl")
include("juliasessioncontroller.jl")
include("requests.jl")

end # module JuliaSessionControllers
