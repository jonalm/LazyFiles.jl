using Test
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

const BUCKET = get(ENV, "LAZYFILES_TEST_BUCKET",
                   "lazyfiles-testbucket-319898207248-eu-north-1-an")
const CACHE = mktempdir()
const CFG = config_from_env(; local_cache_dir = CACHE)
const RID = string(getpid(), "-", time_ns())

# Test-side helper: delete a remote object via the package internals.
delete_remote(b) = LazyFiles._with_rclone(CFG) do mk
    LazyFiles._run(mk(`deletefile $(LazyFiles.RCLONE_REMOTE):$(b.bucket)/$(b.name)`))
end

# Test-side helper: presigned HTTP URL for an S3 object (drives LazyArtifact
# tests with content we control, rather than a flaky third-party URL).
presign(b) = String(strip(LazyFiles._with_rclone(CFG) do mk
    LazyFiles._run(mk(`link $(LazyFiles.RCLONE_REMOTE):$(b.bucket)/$(b.name)`))
end.out))

# Best-effort teardown so re-runs stay idempotent and the bucket stays clean.
function cleanup(blobs...)
    for b in blobs
        try; delete_remote(b); catch; end
        try; clear_from_cache(b; config = CFG); catch; end
    end
end

@testset "LazyFiles" begin

    @testset "config validation (offline)" begin
        @test LazyFiles.is_valid_s3_config(Config()) == false
        @test_throws ErrorException LazyFiles.validate_s3_config(Config())
        @test_throws ErrorException LazyFiles.validate_s3_config(Config(local_cache_dir = "/tmp"))
        @test LazyFiles.validate_s3_config(
            Config(local_cache_dir = "/tmp", s3_access_key_id = "a",
                   s3_secret_access_key = "b", s3_region = "r")) == true
    end

    @testset "operations enforce config (offline)" begin
        nocreds = Config(local_cache_dir = mktempdir())   # cache set, but no S3 creds
        f = tempname(); write(f, "x")
        @test_throws ErrorException s3_upload(f, "bucket"; config = nocreds)
        @test_throws ErrorException s3_search("bucket"; config = nocreds)
        @test_throws ErrorException LazyS3Blob(bucket = "b", name = "n")(; config = nocreds)

        # a blob name must not escape the cache directory
        okcreds = Config(local_cache_dir = mktempdir(), s3_access_key_id = "a",
                         s3_secret_access_key = "b", s3_region = "r")
        @test_throws ErrorException LazyS3Blob(bucket = "b", name = "../../escape")(; config = okcreds)

        # LazyArtifact needs a cache dir but no S3 credentials
        @test_throws ErrorException LazyArtifact(url = "http://x", name = "n")(; config = Config())
        @test LazyArtifact(url = "http://127.0.0.1:1/nope", name = "x.bin")(; config = nocreds) === nothing
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

                @testset "failed download returns nothing" begin
                    a = LazyArtifact(url = "http://127.0.0.1:1/nope", name = "artfail-$RID.bin")
                    @test a(; config = CFG) === nothing
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
