@testitem "demux splits session output from request output" begin
    using JuliaSessionsControllers: OutputDemux, demux!, OUTPUT_BEGIN_MARKER, OUTPUT_END_MARKER

    d = OutputDemux()
    segments = demux!(d, "before" * OUTPUT_BEGIN_MARKER * "req-1\"inside" * OUTPUT_END_MARKER * "after")

    @test segments == [nothing => "before", "req-1" => "inside", nothing => "after"]
    @test d.buffer == ""
    @test d.current_request_id === nothing
end

@testitem "demux carries state across chunk boundaries" begin
    using JuliaSessionsControllers: OutputDemux, demux!, OUTPUT_BEGIN_MARKER, OUTPUT_END_MARKER

    full = "a" * OUTPUT_BEGIN_MARKER * "req-7\"body" * OUTPUT_END_MARKER * "z"

    # Feeding one byte at a time must produce the same attribution as feeding it whole.
    d = OutputDemux()
    collected = Pair{Union{Nothing,String},String}[]
    for i in 1:ncodeunits(full)
        append!(collected, demux!(d, string(full[i])))
    end

    merged = Pair{Union{Nothing,String},String}[]
    for (id, text) in collected
        if !isempty(merged) && merged[end].first == id
            merged[end] = id => (merged[end].second * text)
        else
            push!(merged, id => text)
        end
    end

    @test merged == [nothing => "a", "req-7" => "body", nothing => "z"]
end

@testitem "demux holds back a partial marker instead of emitting it" begin
    using JuliaSessionsControllers: OutputDemux, demux!, OUTPUT_BEGIN_MARKER

    d = OutputDemux()
    half = SubString(OUTPUT_BEGIN_MARKER, 1, 8)

    @test demux!(d, "text" * half) == [nothing => "text"]
    @test d.buffer == half

    rest = SubString(OUTPUT_BEGIN_MARKER, 9, ncodeunits(OUTPUT_BEGIN_MARKER))
    @test demux!(d, rest * "id\"tail") == ["id" => "tail"]
end

@testitem "demux waits for the request id terminator" begin
    using JuliaSessionsControllers: OutputDemux, demux!, OUTPUT_BEGIN_MARKER

    d = OutputDemux()
    # The marker is complete but the id has not been terminated by `"` yet.
    @test demux!(d, OUTPUT_BEGIN_MARKER * "partial-i") == []
    @test demux!(d, "d\"now") == ["partial-id" => "now"]
end

@testitem "demux swallows a stray end marker" begin
    using JuliaSessionsControllers: OutputDemux, demux!, OUTPUT_END_MARKER

    # An interrupt can land between starting a request and writing its begin marker, which
    # leaves an unmatched end marker. It must not reach the caller as literal text.
    d = OutputDemux()
    @test demux!(d, "a" * OUTPUT_END_MARKER * "b") == [nothing => "a", nothing => "b"]
end

@testitem "demux preserves multi-byte characters" begin
    using JuliaSessionsControllers: OutputDemux, demux!, OUTPUT_BEGIN_MARKER, OUTPUT_END_MARKER

    d = OutputDemux()
    text = "αβγ ∑ 🎉"
    segments = demux!(d, OUTPUT_BEGIN_MARKER * "r\"" * text * OUTPUT_END_MARKER)
    @test segments == ["r" => text]
end

@testitem "match_marker distinguishes full, partial and absent matches" begin
    using JuliaSessionsControllers: match_marker

    @test match_marker("abcdef", 1, "abc") === :full
    @test match_marker("abcdef", 4, "def") === :full
    @test match_marker("abcdef", 1, "abd") === :none
    @test match_marker("ab", 1, "abc") === :partial
    @test match_marker("abc", 4, "x") === :partial
end
