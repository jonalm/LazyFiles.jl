using Test
import Downloads
using Sockets
import LazyFiles
using LazyFiles: Config, LazyS3Blob, LazyArtifact, s3_upload, s3_search, clear_from_cache, config_from_env

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
const CFG = config_from_env(; local_cache_dir = CACHE)
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
            clear_from_cache(b; config = CFG)
        catch
        end
    end
    return
end

@testset "LazyFiles" begin

    @testset "config validation (offline)" begin
        @test LazyFiles.is_valid_s3_config(Config()) == false
        @test_throws ErrorException LazyFiles.validate_s3_config(Config())
        @test_throws ErrorException LazyFiles.validate_s3_config(Config(local_cache_dir = "/tmp"))
        @test LazyFiles.validate_s3_config(
            Config(
                local_cache_dir = "/tmp", s3_access_key_id = "a",
                s3_secret_access_key = "b", s3_region = "r"
            )
        ) == true

        # validate_minimal_config: only local_cache_dir matters (no S3 creds needed)
        @test_throws ErrorException LazyFiles.validate_minimal_config(Config())
        @test LazyFiles.validate_minimal_config(Config(local_cache_dir = "/tmp")) == true
    end

    @testset "operations enforce config (offline)" begin
        nocreds = Config(local_cache_dir = mktempdir())   # cache set, but no S3 creds
        f = tempname(); write(f, "x")
        @test_throws ErrorException s3_upload(f, "bucket"; config = nocreds)
        @test_throws ErrorException s3_search("bucket"; config = nocreds)
        @test_throws ErrorException LazyS3Blob(bucket = "b", name = "n")(; config = nocreds)

        # a blob name must not escape the cache directory
        okcreds = Config(
            local_cache_dir = mktempdir(), s3_access_key_id = "a",
            s3_secret_access_key = "b", s3_region = "r"
        )
        @test_throws ErrorException LazyS3Blob(bucket = "b", name = "../../escape")(; config = okcreds)
        # an absolute-path name must not escape the cache directory either
        @test_throws ErrorException LazyS3Blob(bucket = "b", name = "/etc/passwd")(; config = okcreds)

        # LazyArtifact needs a cache dir but no S3 credentials
        @test_throws ErrorException LazyArtifact(url = "http://x", name = "n")(; config = Config())

        # an artifact resolves to `nothing` only on a genuine 404 ...
        p404 = serve_once("404 Not Found")
        @test LazyArtifact(url = "http://127.0.0.1:$p404/x", name = "a404.bin")(; config = nocreds) === nothing
        # ... any other failure surfaces rather than masquerading as "not found"
        @test_throws Downloads.RequestError LazyArtifact(url = "http://127.0.0.1:1/nope", name = "aconn.bin")(; config = nocreds)
        p500 = serve_once("500 Internal Server Error")
        @test_throws Downloads.RequestError LazyArtifact(url = "http://127.0.0.1:$p500/y", name = "a500.bin")(; config = nocreds)

        # clear_from_cache reports an unset cache dir clearly (not as a path-escape)
        @test_throws ErrorException clear_from_cache(LazyS3Blob(bucket = "b", name = "n"); config = Config())
    end

    @testset "non-portable keys are refused (offline)" begin
        cfg = Config(
            local_cache_dir = mktempdir(), s3_access_key_id = "a",
            s3_secret_access_key = "b", s3_region = "r",
        )
        resolve(name) = LazyS3Blob(bucket = "b", name = name)(; config = cfg)
        # backslash, Windows-illegal chars, reserved device names, leading/trailing
        # space, trailing dot: rejected before any network is touched
        for bad in ("a\\b.bin", "a:b.bin", "logs/*.txt", "q?.txt", "a<b", "a|b",
                "data/NUL", "CON.txt", "name.", "name ", " name", "a\tb")
            @test_throws ErrorException resolve(bad)
        end
        # a bucket name carrying a backslash is refused too
        @test_throws ErrorException LazyS3Blob(bucket = "a\\b", name = "k")(; config = cfg)
        # ordinary nested keys, dotfiles and multi-dot names are NOT false positives
        @test LazyFiles._check_portable_name("bucket", "dir/sub/file.bin") === nothing
        @test LazyFiles._check_portable_name("bucket", ".gitignore") === nothing
        @test LazyFiles._check_portable_name("bucket", "report.final.txt") === nothing

        # s3_upload applies the same gate up front, so it can't strand an object
        # under a key the handle it returns could never resolve (checked before
        # any network: these throw despite cfg's creds being usable-looking).
        f = tempname(); write(f, "x")
        @test_throws ErrorException s3_upload(f, "b", "CON.txt"; config = cfg)
        @test_throws ErrorException s3_upload(f, "b", "trailing "; config = cfg)
        @test_throws ErrorException s3_upload(f, "a\\b", "k"; config = cfg)
    end

    @testset "lsf parsing keeps significant whitespace (offline)" begin
        # CRLF terminators dropped and the trailing empty line ignored, but spaces
        # that are part of a key are preserved — trimming would resolve a *different*
        # object. (Leading/trailing-space keys are non-portable and refused at
        # resolve; preserving them here means that refusal is honest, not a key the
        # listing silently rewrote.)
        out = "a.txt\r\nb/c.bin\r\n leading.txt\r\ntrailing .txt\r\n"
        @test LazyFiles._parse_lsf(out) == ["a.txt", "b/c.bin", " leading.txt", "trailing .txt"]
        @test LazyFiles._parse_lsf("") == String[]
        @test LazyFiles._parse_lsf("only\n") == ["only"]
        @test LazyFiles._parse_lsf("no-terminator") == ["no-terminator"]
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
                @test clear_from_cache(blob; config = CFG) == true
                @test !isfile(lp)
                @test clear_from_cache(blob; config = CFG) == false  # nothing left
                @test delete_remote(blob).ok
                @test blob(; config = CFG) === nothing               # truly cleared
            finally
                cleanup(blob)
            end
        end

        @testset "resolving a missing blob returns nothing" begin
            blob = LazyS3Blob(bucket = BUCKET, name = "missing-$RID.bin")
            @test blob(; config = CFG) === nothing
        end

        @testset "s3_search lists blobs and filters by regex" begin
            pre = "search-$RID"
            n1 = "$pre/alpha.txt"; n2 = "$pre/beta.log"
            f1 = tempname(); write(f1, "A"); f2 = tempname(); write(f2, "B")
            b1 = s3_upload(f1, BUCKET, n1; config = CFG)
            b2 = s3_upload(f2, BUCKET, n2; config = CFG)
            try
                found = s3_search(BUCKET; config = CFG)
                @test found isa Vector{LazyS3Blob}
                names = Set(b.name for b in found)
                @test n1 in names
                @test n2 in names
                txt = s3_search(BUCKET, Regex(pre * raw".*\.txt"); config = CFG)
                @test Set(b.name for b in txt) == Set([n1])
            finally
                cleanup(b1, b2)
            end
        end

        @testset "s3_search narrows by server-side prefix" begin
            pre = "prefix-$RID"
            n1 = "$pre/x/one.txt"; n2 = "$pre/x/two.txt"; n3 = "$pre/y/three.txt"
            f = tempname(); write(f, "p")
            b1 = s3_upload(f, BUCKET, n1; config = CFG)
            b2 = s3_upload(f, BUCKET, n2; config = CFG)
            b3 = s3_upload(f, BUCKET, n3; config = CFG)
            try
                under_x = s3_search(BUCKET; prefix = "$pre/x", config = CFG)
                # full keys are reconstructed (not relative to the prefix); y/ excluded
                @test Set(b.name for b in under_x) == Set([n1, n2])
                # a reconstructed blob actually resolves, proving the key is the full key
                @test read(first(under_x)(; config = CFG), String) == "p"
                # a prefix matching nothing is an empty vector, not an error
                @test isempty(s3_search(BUCKET; prefix = "$pre/zzz", config = CFG))
                # prefix and regex compose; the regex matches against the full key
                one = s3_search(BUCKET, Regex("one\\.txt"); prefix = "$pre/x", config = CFG)
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

        @testset "s3_search with a non-matching regex returns an empty vector" begin
            res = s3_search(BUCKET, Regex("no-such-key-zzz-$RID"); config = CFG)
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
                @test clear_from_cache(blob; config = CFG)     # drop stale cache
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
                        lp = a(; config = CFG)
                        @test lp !== nothing
                        @test isfile(lp)
                        @test occursin(joinpath("_artifacts_", a.name), lp)
                        @test read(lp, String) == content
                    finally
                        clear_from_cache(a; config = CFG)
                    end
                end

                @testset "serves from cache, keyed by name" begin
                    nm = "artcache-$RID.bin"
                    a1 = LazyArtifact(url = url, name = nm)
                    try
                        lp1 = a1(; config = CFG)
                        # same name, broken url: a cache hit must ignore the url
                        a2 = LazyArtifact(url = "http://127.0.0.1:1/nope", name = nm)
                        lp2 = a2(; config = CFG)
                        @test lp2 == lp1
                        @test read(lp2, String) == content
                    finally
                        clear_from_cache(a1; config = CFG)
                    end
                end

                @testset "a transport failure raises (not silently nothing)" begin
                    a = LazyArtifact(url = "http://127.0.0.1:1/nope", name = "artfail-$RID.bin")
                    @test_throws Downloads.RequestError a(; config = CFG)
                end

                @testset "clear_from_cache works on artifacts" begin
                    a = LazyArtifact(url = url, name = "artclear-$RID.bin")
                    lp = a(; config = CFG)
                    @test isfile(lp)
                    @test clear_from_cache(a; config = CFG) == true
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
