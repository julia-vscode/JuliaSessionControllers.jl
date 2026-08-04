using Documenter, JuliaSessionsControllers

makedocs(
    sitename = "JuliaSessionsControllers.jl",
    modules = [JuliaSessionsControllers],
    pages = [
        "Home" => "index.md",
        "API" => "api.md",
        "Internals" => "internals.md",
    ],
    checkdocs = :exports,
)

deploydocs(repo = "github.com/julia-testitems/JuliaSessionsControllers.jl.git")
