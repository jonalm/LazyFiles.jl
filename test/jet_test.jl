# ---------------------------------------------------------------------------
# Type-stability regression checks (JET).
#
# `@test_opt` *statically analyses* each call for optimization failures (runtime
# dispatch / type instability); it never executes the call, so the paths,
# credentials and URLs below need not be real and no network or rclone is hit.
#
# Analysis is scoped to the `LazyFiles` module via `target_modules`, so inference
# limitations in Base / stdlib / JLL accessors don't masquerade as our own bugs.
# A failure here means LazyFiles code introduced a type instability — fix the
# source (e.g. assert a concrete type) rather than relaxing the test.
#
# Run as part of the suite (`Pkg.test()`), or standalone against the test env.
# ---------------------------------------------------------------------------

using Test
using JET
import LazyFiles
using LazyFiles: Config, LazyS3Blob, LazyArtifact, s3_upload, s3_search,
    clear_from_cache, config_from_env, validate_s3_config, default_config!

# Restrict reports to instabilities originating in LazyFiles itself.
const TM = (LazyFiles,)

# Representative, fully-concrete arguments (analysed, never run).
const JCFG  = Config(
    local_cache_dir = "/tmp/lazyfiles-jet",
    s3_access_key_id = "a", s3_secret_access_key = "b", s3_region = "r",
)
const JBLOB = LazyS3Blob(bucket = "bucket", name = "dir/object.bin")
const JART  = LazyArtifact(url = "http://example.invalid/x.bin", name = "x.bin")

@testset "JET type stability (target: LazyFiles)" begin
    @testset "config" begin
        @test_opt target_modules = TM config_from_env()
        @test_opt target_modules = TM validate_s3_config(JCFG)
        @test_opt target_modules = TM LazyFiles.is_valid_s3_config(JCFG)
        @test_opt target_modules = TM default_config!(JCFG)
    end

    @testset "path resolution" begin
        @test_opt target_modules = TM LazyFiles.local_path(JCFG, JBLOB)
        @test_opt target_modules = TM LazyFiles.local_path(JCFG, JART)
        @test_opt target_modules = TM LazyFiles._checked_path("/base", "a", "b")
        @test_opt target_modules = TM LazyFiles._prune_empty_dirs("/base/a", "/base")
    end

    @testset "blob resolution (functors)" begin
        @test_opt target_modules = TM JBLOB(config = JCFG)
        @test_opt target_modules = TM JART(config = JCFG)
    end

    @testset "public operations" begin
        @test_opt target_modules = TM s3_upload("/tmp/f", "bucket", "name")
        @test_opt target_modules = TM s3_upload("/tmp/f", "bucket")          # name defaulted
        @test_opt target_modules = TM s3_search("bucket")                    # no regex
        @test_opt target_modules = TM s3_search("bucket", r"\.txt$")         # with regex
        @test_opt target_modules = TM clear_from_cache(JBLOB; config = JCFG)
        @test_opt target_modules = TM clear_from_cache(JART; config = JCFG)
    end

    @testset "rclone backend internals" begin
        @test_opt target_modules = TM LazyFiles._run(`true`)
        @test_opt target_modules = TM LazyFiles._write_rclone_config(IOBuffer(), JCFG)
    end
end
