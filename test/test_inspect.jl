@testitem "get_variables reports bindings defined in the session" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "answer = 42")
        evaluate(ctrl, sid, "greeting = \"hi\"")

        vars = get_variables(ctrl, sid)
        by_name = Dict(v.name => v for v in vars)

        @test haskey(by_name, "answer")
        @test by_name["answer"].type == "$Int"
        @test by_name["answer"].value == "42"
        @test haskey(by_name, "greeting")
        # Modules are excluded unless asked for.
        @test !any(v -> v.type == "Module", vars)
    end
end

@testitem "get_variables can include modules" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "module Scratch end")

        without = get_variables(ctrl, sid)
        with = get_variables(ctrl, sid; include_modules=true)

        @test !any(v -> v.name == "Scratch", without)
        @test any(v -> v.name == "Scratch", with)
    end
end

@testitem "structured values expand lazily" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "struct Point; x::Int; y::Int; end")
        evaluate(ctrl, sid, "p = Point(3, 4)")

        var = only(filter(v -> v.name == "p", get_variables(ctrl, sid)))
        @test var.has_children
        @test var.lazy

        children = get_lazy(ctrl, sid, var.id)
        by_name = Dict(c.name => c for c in children)
        @test by_name["x"].value == "3"
        @test by_name["y"].value == "4"
    end
end

@testitem "arrays expand to their elements" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        evaluate(ctrl, sid, "xs = [10, 20, 30]")

        var = only(filter(v -> v.name == "xs", get_variables(ctrl, sid)))
        children = get_lazy(ctrl, sid, var.id)

        @test [c.name for c in children] == ["1", "2", "3"]
        @test [c.value for c in children] == ["10", "20", "30"]
    end
end

@testitem "expanding an unknown id returns nothing rather than failing" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        @test isempty(get_lazy(ctrl, sid, 999_999))
    end
end

@testitem "completions come from the session's own state" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        @test "sqrt" in [c.label for c in get_completions(ctrl, sid, "sqr")]

        evaluate(ctrl, sid, "my_very_distinctive_name = 1")
        @test "my_very_distinctive_name" in [c.label for c in get_completions(ctrl, sid, "my_very_dist")]
    end
end

@testitem "get_modules lists loaded modules" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        mods = get_modules(ctrl, sid)

        @test !isempty(mods)
        @test mods == sort(unique(mods))
        @test "Base" in mods || any(m -> occursin("Base", m), mods)
    end
end

@testitem "inspection is queued behind running code" setup=[SessionHelpers] begin
    using .SessionHelpers

    SessionHelpers.with_session() do ctrl, sid
        running = @async evaluate(ctrl, sid, "sleep(2); late_binding = :done")
        sleep(0.3)
        vars = @async get_variables(ctrl, sid)

        fetch(running)
        # Because requests never overlap, the inspection sees the completed assignment.
        @test any(v -> v.name == "late_binding", fetch(vars))
    end
end
