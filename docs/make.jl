using Documenter, JuliaSessionControllers

makedocs(
    sitename = "JuliaSessionControllers.jl",
    modules = [JuliaSessionControllers],
    # Stated explicitly so the build does not depend on a configured git remote.
    repo = Documenter.Remotes.GitHub("julia-testitems", "JuliaSessionControllers.jl"),
    pages = [
        "Home" => "index.md",
        "API" => "api.md",
        "Internals" => "internals.md",
    ],
    checkdocs = :exports,
    # The vendored dependencies carry their own docstrings, which are not ours to publish.
    checkdocs_ignored_modules = [
        JuliaSessionControllers.CancellationTokens,
        JuliaSessionControllers.JSON,
        JuliaSessionControllers.JSONRPC,
        JuliaSessionControllers.URIParser,
        JuliaSessionControllers.JuliaSessionServerProtocol,
    ],
)

deploydocs(repo = "github.com/julia-testitems/JuliaSessionControllers.jl.git")
