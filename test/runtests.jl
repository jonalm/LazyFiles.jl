using Test
import Downloads
using Sockets
using Dates: DateTime
import LazyFiles
using LazyFiles: S3Config, NoConfig, LazyS3Blob, LazyArtifact, s3_upload, s3_list,
    s3_list_with_stats, clear_from_cache, config_from_env, cache_dir, cache_dir!

# ---------------------------------------------------------------------------
# Test setup
#
# Live S3 tests run against a real bucket using credentials taken from the
# environment. The repo `env` file is gitignored and local-only; when present
# its values take precedence (a fresh checkout has the right creds without
# fighting any unrelated AWS vars in the shell). In CI the file is absent, so
# credentials injected into the environment are used instead. If no usable S3
# config is found, the live tests are skipped (only offline validation runs).
# ---------------------------------------------------------------------------

const ENVFILE = joinpath(@__DIR__, "..", "env")
if isfile(ENVFILE)
    for line in eachline(ENVFILE)
        s = strip(line)
        (isempty(s) || startswith(s, "#")) && continue
        k, v = split(s, "=", limit = 2)
        ENV[strip(k)] = strip(v)
    end
end
get!(ENV, "AWS_REGION", "eu-north-1")

const BUCKET = get(
    ENV, "LAZYFILES_TEST_BUCKET",
    "lazyfiles-testbucket-319898207248-eu-north-1-an"
)
const CACHE = mktempdir()
cache_dir!(CACHE)                 # the framework cache root for the whole suite
const CFG = config_from_env()     # S3 credentials only (cache dir is separate)
const RID = string(getpid(), "-", time_ns())

# Test-side helper: delete a remote object via the package internals.
delete_remote(b) = LazyFiles._with_rclone(CFG) do mk
    LazyFiles._run(mk(`deletefile $(LazyFiles.RCLONE_REMOTE):$(b.bucket)/$(b.name)`))
end

# Test-side helper: presigned HTTP URL for an S3 object (drives LazyArtifact
# tests with content we control, rather than a flaky third-party URL).
presign(b) = String(
    strip(
        LazyFiles._with_rclone(CFG) do mk
            LazyFiles._run(mk(`link $(LazyFiles.RCLONE_REMOTE):$(b.bucket)/$(b.name)`))
        end.out
    )
)

# One-shot localhost HTTP server: accepts a single connection and replies with
# the given status line (and an empty body). Lets the offline tests exercise the
# 404-vs-real-error split in LazyArtifact without any network or live bucket.
function serve_once(status_line)
    server = listen(IPv4(0), 0)
    port = Int(getsockname(server)[2])
    @async try
        sock = accept(server)
        readuntil(sock, "\r\n\r\n")
        write(sock, "HTTP/1.1 $status_line\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        close(sock)
    finally
        close(server)
    end
    return port
end

# Best-effort teardown so re-runs stay idempotent and the bucket stays clean.
function cleanup(blobs...)
    for b in blobs
        try
            delete_remote(b)
        catch
        end
        try
            clear_from_cache(b)          # cache_dir defaults to the suite root
        catch
        end
    end
    return
end

# ---------------------------------------------------------------------------
# User-defined blobs (as an external package would write them), driving the
# extension interface end-to-end with no network.
# ---------------------------------------------------------------------------

# (1) A no-config blob: it fetches by copying from a local source path, so it
# needs no fetch config at all (the default NoConfig). `fail` forces a raise.
struct LocalBlob <: LazyFiles.AbstractLazyBlob
    src::String
    name::String
    fail::Bool
end
LocalBlob(src, name) = LocalBlob(src, name, false)
LazyFiles.cache_subpath(b::LocalBlob) = ("_local_", b.name)
function LazyFiles.fetch!(b::LocalBlob, dest::AbstractString; config::NoConfig = NoConfig(), verbose::Bool = false)
    b.fail && error("boom")
    isfile(b.src) && cp(b.src, dest; force = true)   # absent source => leave dest untouched
    return nothing
end

# (2) A blob that needs its OWN fetch config (a token), selected by config_type.
struct TokenConfig
    token::String
end
const DEFAULT_TOKEN = Ref(TokenConfig(""))
LazyFiles.default_config(::Type{TokenConfig}) = DEFAULT_TOKEN[]

struct TokenBlob <: LazyFiles.AbstractLazyBlob
    name::String
end
LazyFiles.config_type(::TokenBlob) = TokenConfig
LazyFiles.cache_subpath(b::TokenBlob) = ("_token_", b.name)
LazyFiles.validate_config(c::TokenConfig, ::TokenBlob) = isempty(c.token) && error("token is not set")
function LazyFiles.fetch!(b::TokenBlob, dest::AbstractString; config::TokenConfig, verbose::Bool = false)
    write(dest, "token=" * config.token)   # the extra config flows through to fetch!
    return nothing
end

@testset "LazyFiles" begin

    @testset "config validation (offline)" begin
        @test LazyFiles.is_valid_s3_config(S3Config()) == false
        @test_throws ErrorException LazyFiles.validate_s3_config(S3Config())
        @test_throws ErrorException LazyFiles.validate_s3_config(S3Config(access_key_id = "a"))
        @test LazyFiles.validate_s3_config(
            S3Config(access_key_id = "a", secret_access_key = "b", region = "r")
        ) == true
    end

    @testset "cache root (offline)" begin
        creds = S3Config(access_key_id = "a", secret_access_key = "b", region = "r")
        # every blob needs a cache root: an empty one raises before any network
        @test_throws ErrorException LazyS3Blob(bucket = "b", name = "n")(; cache_dir = "", config = creds)
        @test_throws ErrorException LazyArtifact(url = "http://x", name = "n")(; cache_dir = "")
        @test_throws ErrorException clear_from_cache(LazyS3Blob(bucket = "b", name = "n"); cache_dir = "")
        # the suite's root is in effect
        @test cache_dir() == CACHE
        # cache_dir() falls back to the LAZYFILES_CACHE_DIR env var when unset
        saved = LazyFiles.CACHE_DIR[]
        try
            LazyFiles.CACHE_DIR[] = ""
            withenv("LAZYFILES_CACHE_DIR" => "/tmp/lf-env") do
                @test cache_dir() == "/tmp/lf-env"
            end
            # with neither set, cache_dir() is the built-in default, never ""
            withenv("LAZYFILES_CACHE_DIR" => nothing) do
                @test cache_dir() == LazyFiles.DEFAULT_CACHE_DIR
                @test !isempty(cache_dir())
            end
        finally
            LazyFiles.CACHE_DIR[] = saved
        end
    end

    @testset "operations enforce config (offline)" begin
        nocreds = S3Config()                       # no S3 credentials
        f = tempname(); write(f, "x")
        @test_throws ErrorException s3_upload(f, "bucket"; config = nocreds)
        @test_throws ErrorException s3_list("bucket"; config = nocreds)
        @test_throws ErrorException s3_list_with_stats("bucket"; config = nocreds)
        @test_throws ErrorException LazyS3Blob(bucket = "b", name = "n")(; config = nocreds)

        creds = S3Config(access_key_id = "a", secret_access_key = "b", region = "r")
        # a blob name must not escape the cache directory
        @test_throws ErrorException LazyS3Blob(bucket = "b", name = "../../escape")(; config = creds)
        # an absolute-path name must not escape the cache directory either
        @test_throws ErrorException LazyS3Blob(bucket = "b", name = "/etc/passwd")(; config = creds)

        # an artifact resolves to `nothing` only on a genuine 404 (needs no config)...
        p404 = serve_once("404 Not Found")
        @test LazyArtifact(url = "http://127.0.0.1:$p404/x", name = "a404.bin")() === nothing
        # ... any other failure surfaces rather than masquerading as "not found"
        @test_throws Downloads.RequestError LazyArtifact(url = "http://127.0.0.1:1/nope", name = "aconn.bin")()
        p500 = serve_once("500 Internal Server Error")
        @test_throws Downloads.RequestError LazyArtifact(url = "http://127.0.0.1:$p500/y", name = "a500.bin")()
    end

    @testset "non-portable keys are refused (offline)" begin
        creds = S3Config(access_key_id = "a", secret_access_key = "b", region = "r")
        resolve(name) = LazyS3Blob(bucket = "b", name = name)(; config = creds)
        # backslash, Windows-illegal chars, reserved device names, leading/trailing
        # space, trailing dot: rejected before any network is touched
        for bad in ("a\\b.bin", "a:b.bin", "logs/*.txt", "q?.txt", "a<b", "a|b",
                "data/NUL", "CON.txt", "name.", "name ", " name", "a\tb")
            @test_throws ErrorException resolve(bad)
        end
        # a bucket name carrying a backslash is refused too
        @test_throws ErrorException LazyS3Blob(bucket = "a\\b", name = "k")(; config = creds)
        # ordinary nested keys, dotfiles and multi-dot names are NOT false positives
        @test LazyFiles._check_portable_name("bucket", "dir/sub/file.bin") === nothing
        @test LazyFiles._check_portable_name("bucket", ".gitignore") === nothing
        @test LazyFiles._check_portable_name("bucket", "report.final.txt") === nothing

        # s3_upload applies the same gate up front, so it can't strand an object
        # under a key the handle it returns could never resolve (checked before
        # any network: these throw despite creds being usable-looking).
        f = tempname(); write(f, "x")
        @test_throws ErrorException s3_upload(f, "b", "CON.txt"; config = creds)
        @test_throws ErrorException s3_upload(f, "b", "trailing "; config = creds)
        @test_throws ErrorException s3_upload(f, "a\\b", "k"; config = creds)
    end

    @testset "custom AbstractLazyBlob extension (offline)" begin
        cache = mktempdir()

        # (1) a no-config blob: functor -> resolve -> fetch!, cached under cache_subpath
        src = tempname(); write(src, "custom payload")
        b = LocalBlob(src, "data.bin")
        lp = b(; cache_dir = cache)
        @test lp !== nothing
        @test isfile(lp)
        @test occursin(joinpath("_local_", "data.bin"), lp)
        @test read(lp, String) == "custom payload"

        # cache hit: same path, served without re-reading the (now gone) source
        rm(src)
        @test b(; cache_dir = cache) == lp

        # clear_from_cache needs only the cache root, no config
        @test clear_from_cache(b; cache_dir = cache) == true
        @test !isfile(lp)

        # absent resource: fetch! leaves dest untouched => resolve returns nothing
        @test LocalBlob(tempname(), "missing.bin")(; cache_dir = cache) === nothing

        # a fetch! failure surfaces, and nothing partial is cached
        fb = LocalBlob("", "fail.bin", true)
        @test_throws ErrorException fb(; cache_dir = cache)
        @test !isfile(LazyFiles.local_path(fb; cache_dir = cache))

        # custom blobs inherit the path-escape / portability gate
        @test_throws ErrorException LocalBlob(src, "../escape")(; cache_dir = cache)

        # (2) a blob with its OWN config type: the extra field flows to fetch!
        lp2 = TokenBlob("t.bin")(; cache_dir = cache, config = TokenConfig("abc"))
        @test read(lp2, String) == "token=abc"
        # its validate_config runs: a blank token raises
        @test_throws ErrorException TokenBlob("u.bin")(; cache_dir = cache, config = TokenConfig(""))
        # process-wide default keyed on the config TYPE: no config= needed
        DEFAULT_TOKEN[] = TokenConfig("default-tok")
        @test read(TokenBlob("v.bin")(; cache_dir = cache), String) == "token=default-tok"
    end

    @testset "lsjson parsing (offline)" begin
        # rclone lsjson: keys relative to the listed dir, plus size and RFC3339
        # ModTime. JSON keeps spaces in keys intact (line-based parsing couldn't),
        # and ModTime is truncated to whole seconds.
        out = """
        [
        {"Path":"a.txt","Name":"a.txt","Size":3,"ModTime":"2024-01-02T12:00:00.000000000Z","IsDir":false},
        {"Path":"b/c d.bin","Name":"c d.bin","Size":10,"ModTime":"2024-03-04T05:06:07.123456789+00:00","IsDir":false}
        ]
        """
        recs = LazyFiles._parse_lsjson(out, "bucket", "")
        @test recs isa Vector{LazyFiles.S3Entry}
        @test [r.blob.name for r in recs] == ["a.txt", "b/c d.bin"]   # spaces preserved
        @test all(r -> r.blob.bucket == "bucket", recs)
        @test [r.size for r in recs] == [3, 10]
        @test recs[1].modified == DateTime(2024, 1, 2, 12, 0, 0)      # truncated to seconds
        @test recs[2].modified == DateTime(2024, 3, 4, 5, 6, 7)

        # a prefix is re-prepended to rebuild the full key
        pre = LazyFiles._parse_lsjson(out, "bucket", "logs/2024")
        @test [r.blob.name for r in pre] == ["logs/2024/a.txt", "logs/2024/b/c d.bin"]
        # a listing predicate sees the full `S3Entry`: a `Regex` selects on the full
        # key (`blob.name`), a function can select on size (or modified) as well
        @test [r.blob.name for r in filter(e -> occursin(r"\.txt$", e.blob.name), recs)] == ["a.txt"]
        @test [r.blob.name for r in filter(e -> e.size > 5, recs)] == ["b/c d.bin"]
        # an empty listing is an empty vector, not an error
        @test isempty(LazyFiles._parse_lsjson("[]", "bucket", ""))
        @test isempty(LazyFiles._parse_lsjson("", "bucket", ""))
    end

    if !LazyFiles.is_valid_s3_config(CFG)
        @warn "Skipping live S3 tests: no usable S3 config (set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION)."
    else
        @testset "round-trip: upload then resolve to a local copy" begin
            src = tempname(); write(src, "hello lazyfiles $RID")
            blob = s3_upload(src, BUCKET, "rt-$RID.txt"; config = CFG)
            try
                @test blob isa LazyS3Blob
                @test blob.bucket == BUCKET
                lp = blob(; config = CFG)
                @test lp !== nothing
                @test isfile(lp)
                @test read(lp, String) == read(src, String)
            finally
                cleanup(blob)
            end
        end

        @testset "upload without a name uses the file's basename" begin
            dir = mktempdir(); src = joinpath(dir, "named-$RID.dat"); write(src, "x")
            blob = s3_upload(src, BUCKET; config = CFG)
            try
                @test blob.name == basename(src)
                @test blob(; config = CFG) !== nothing
            finally
                cleanup(blob)
            end
        end

        @testset "cache serves the blob after the remote is deleted" begin
            src = tempname(); write(src, "cache me $RID")
            blob = s3_upload(src, BUCKET, "cache-$RID.txt"; config = CFG)
            try
                lp1 = blob(; config = CFG)          # downloads
                @test isfile(lp1)
                @test delete_remote(blob).ok        # remote gone
                lp2 = blob(; config = CFG)          # served from cache
                @test lp2 == lp1
                @test read(lp2, String) == read(src, String)
            finally
                cleanup(blob)
            end
        end

        @testset "clear_from_cache removes the cached copy" begin
            src = tempname(); write(src, "clear me $RID")
            blob = s3_upload(src, BUCKET, "clear-$RID.txt"; config = CFG)
            try
                lp = blob(; config = CFG)
                @test isfile(lp)
                @test clear_from_cache(blob) == true
                @test !isfile(lp)
                @test clear_from_cache(blob) == false  # nothing left
                @test delete_remote(blob).ok
                @test blob(; config = CFG) === nothing  # truly cleared
            finally
                cleanup(blob)
            end
        end

        @testset "resolving a missing blob returns nothing" begin
            blob = LazyS3Blob(bucket = BUCKET, name = "missing-$RID.bin")
            @test blob(; config = CFG) === nothing
        end

        @testset "s3_list lists blobs and filters by regex or predicate" begin
            pre = "search-$RID"
            n1 = "$pre/alpha.txt"; n2 = "$pre/beta.log"
            f1 = tempname(); write(f1, "A"); f2 = tempname(); write(f2, "B")
            b1 = s3_upload(f1, BUCKET, n1; config = CFG)
            b2 = s3_upload(f2, BUCKET, n2; config = CFG)
            try
                found = s3_list(BUCKET; config = CFG)
                @test found isa Vector{LazyS3Blob}
                names = Set(b.name for b in found)
                @test n1 in names
                @test n2 in names
                # Regex shorthand: matches the full key
                txt = s3_list(Regex(pre * raw".*\.txt"), BUCKET; config = CFG)
                @test Set(b.name for b in txt) == Set([n1])
                # function predicate: selects on the whole record (here, by name)
                alpha = s3_list(e -> endswith(e.blob.name, "alpha.txt"), BUCKET; config = CFG)
                @test Set(b.name for b in alpha) == Set([n1])
            finally
                cleanup(b1, b2)
            end
        end

        @testset "s3_list_with_stats returns size and modtime" begin
            pre = "stats-$RID"
            nm = "$pre/payload.txt"
            body = "0123456789"
            f = tempname(); write(f, body)
            b = s3_upload(f, BUCKET, nm; config = CFG)
            try
                recs = s3_list_with_stats(BUCKET; prefix = pre, config = CFG)
                @test recs isa Vector{@NamedTuple{blob::LazyS3Blob, size::Int, modified::DateTime}}
                @test length(recs) == 1
                r = only(recs)
                @test r.blob.name == nm
                @test r.size == sizeof(body)
                @test r.modified isa DateTime
                @test read(r.blob(; config = CFG), String) == body   # the handle resolves
                # a predicate filters on the record (here, by size)
                @test length(s3_list_with_stats(e -> e.size >= sizeof(body), BUCKET; prefix = pre, config = CFG)) == 1
                @test isempty(s3_list_with_stats(e -> e.size > sizeof(body), BUCKET; prefix = pre, config = CFG))
            finally
                cleanup(b)
            end
        end

        @testset "s3_list narrows by server-side prefix" begin
            pre = "prefix-$RID"
            n1 = "$pre/x/one.txt"; n2 = "$pre/x/two.txt"; n3 = "$pre/y/three.txt"
            f = tempname(); write(f, "p")
            b1 = s3_upload(f, BUCKET, n1; config = CFG)
            b2 = s3_upload(f, BUCKET, n2; config = CFG)
            b3 = s3_upload(f, BUCKET, n3; config = CFG)
            try
                under_x = s3_list(BUCKET; prefix = "$pre/x", config = CFG)
                # full keys are reconstructed (not relative to the prefix); y/ excluded
                @test Set(b.name for b in under_x) == Set([n1, n2])
                # a reconstructed blob actually resolves, proving the key is the full key
                @test read(first(under_x)(; config = CFG), String) == "p"
                # a prefix matching nothing is an empty vector, not an error
                @test isempty(s3_list(BUCKET; prefix = "$pre/zzz", config = CFG))
                # prefix and regex compose; the regex matches against the full key
                one = s3_list(Regex("one\\.txt"), BUCKET; prefix = "$pre/x", config = CFG)
                @test Set(b.name for b in one) == Set([n1])
            finally
                cleanup(b1, b2, b3)
            end
        end

        @testset "round-trips binary content losslessly" begin
            bytes = rand(UInt8, 4096)
            src = tempname(); write(src, bytes)
            blob = s3_upload(src, BUCKET, "bin-$RID.dat"; config = CFG)
            try
                lp = blob(; config = CFG)
                @test lp !== nothing
                @test read(lp) == bytes
            finally
                cleanup(blob)
            end
        end

        @testset "s3_list with a non-matching regex returns an empty vector" begin
            res = s3_list(Regex("no-such-key-zzz-$RID"), BUCKET; config = CFG)
            @test res isa Vector{LazyS3Blob}
            @test isempty(res)
        end

        @testset "re-uploading the same name replaces the object" begin
            name = "overwrite-$RID.txt"
            s1 = tempname(); write(s1, "first $RID")
            s2 = tempname(); write(s2, "second $RID")
            blob = s3_upload(s1, BUCKET, name; config = CFG)
            try
                @test read(blob(; config = CFG), String) == "first $RID"
                s3_upload(s2, BUCKET, name; config = CFG)      # overwrite remote
                @test clear_from_cache(blob)                   # drop stale cache
                @test read(blob(; config = CFG), String) == "second $RID"
            finally
                cleanup(blob)
            end
        end

        @testset "resolves a nested key into nested cache dirs" begin
            name = "nested/$RID/deep/file.bin"
            src = tempname(); write(src, "deep $RID")
            blob = s3_upload(src, BUCKET, name; config = CFG)
            try
                lp = blob(; config = CFG)
                @test lp !== nothing
                @test isfile(lp)
                @test occursin(joinpath("nested", RID, "deep", "file.bin"), lp)
                @test read(lp, String) == "deep $RID"
            finally
                cleanup(blob)
            end
        end

        @testset "LazyArtifact" begin
            # Upload a source object and presign it; its URL backs the tests.
            content = "artifact body $RID"
            src = tempname(); write(src, content)
            s3src = s3_upload(src, BUCKET, "artifact-src-$RID.bin"; config = CFG)
            url = presign(s3src)
            try
                @testset "downloads URL to cache and resolves" begin
                    a = LazyArtifact(url = url, name = "art-$RID.bin")
                    try
                        lp = a()
                        @test lp !== nothing
                        @test isfile(lp)
                        @test occursin(joinpath("_artifacts_", a.name), lp)
                        @test read(lp, String) == content
                    finally
                        clear_from_cache(a)
                    end
                end

                @testset "serves from cache, keyed by name" begin
                    nm = "artcache-$RID.bin"
                    a1 = LazyArtifact(url = url, name = nm)
                    try
                        lp1 = a1()
                        # same name, broken url: a cache hit must ignore the url
                        a2 = LazyArtifact(url = "http://127.0.0.1:1/nope", name = nm)
                        lp2 = a2()
                        @test lp2 == lp1
                        @test read(lp2, String) == content
                    finally
                        clear_from_cache(a1)
                    end
                end

                @testset "a transport failure raises (not silently nothing)" begin
                    a = LazyArtifact(url = "http://127.0.0.1:1/nope", name = "artfail-$RID.bin")
                    @test_throws Downloads.RequestError a()
                end

                @testset "clear_from_cache works on artifacts" begin
                    a = LazyArtifact(url = url, name = "artclear-$RID.bin")
                    lp = a()
                    @test isfile(lp)
                    @test clear_from_cache(a) == true
                    @test !isfile(lp)
                end
            finally
                cleanup(s3src)
            end
        end
    end
end

# Type-stability checks (offline, always run). Kept in a separate script.
include("jet_test.jl")
