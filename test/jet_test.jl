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
using LazyFiles: S3Config, NoConfig, LazyS3Blob, LazyArtifact, s3_upload, s3_list,
    s3_list_with_stats, clear_from_cache, config_from_env, validate_s3_config,
    default_config!, cache_dir, cache_dir!

# Restrict reports to instabilities originating in LazyFiles itself.
const TM = (LazyFiles,)

# Representative, fully-concrete arguments (analysed, never run).
const JDIR  = "/tmp/lazyfiles-jet"
const JS3   = S3Config(access_key_id = "a", secret_access_key = "b", region = "r")
const JBLOB = LazyS3Blob(bucket = "bucket", name = "dir/object.bin")
const JART  = LazyArtifact(url = "http://example.invalid/x.bin", name = "x.bin")

# A custom blob with its OWN config type, defined exactly as an external package
# would, to check the config_type-dispatch extension path stays type-stable.
struct _JetConfig
    token::String
end
const _JET_DEFAULT = Ref(_JetConfig("t"))
LazyFiles.default_config(::Type{_JetConfig}) = _JET_DEFAULT[]

struct _JetBlob <: LazyFiles.AbstractLazyBlob
    name::String
end
LazyFiles.config_type(::_JetBlob) = _JetConfig
LazyFiles.cache_subpath(b::_JetBlob) = ("_jet_", b.name)
LazyFiles.fetch!(b::_JetBlob, dest::AbstractString; config::_JetConfig, verbose::Bool = false) =
    (write(dest, config.token); nothing)
const JCUSTOM = _JetBlob("custom.bin")

@testset "JET type stability (target: LazyFiles)" begin
    @testset "config" begin
        @test_opt target_modules = TM config_from_env()
        @test_opt target_modules = TM validate_s3_config(JS3)
        @test_opt target_modules = TM LazyFiles.is_valid_s3_config(JS3)
        @test_opt target_modules = TM default_config!(JS3)
        @test_opt target_modules = TM LazyFiles.default_config(S3Config)
        @test_opt target_modules = TM LazyFiles.default_config(NoConfig)
        @test_opt target_modules = TM cache_dir()
        @test_opt target_modules = TM cache_dir!("/tmp/x")
        # config_type trait (built-in + custom)
        @test_opt target_modules = TM LazyFiles.config_type(JBLOB)
        @test_opt target_modules = TM LazyFiles.config_type(JART)
        @test_opt target_modules = TM LazyFiles.config_type(JCUSTOM)
    end

    @testset "path resolution" begin
        @test_opt target_modules = TM LazyFiles.local_path(JBLOB; cache_dir = JDIR)
        @test_opt target_modules = TM LazyFiles.local_path(JART; cache_dir = JDIR)
        @test_opt target_modules = TM LazyFiles.local_path(JCUSTOM; cache_dir = JDIR)
        @test_opt target_modules = TM LazyFiles._checked_path("/base", "a", "b")
        @test_opt target_modules = TM LazyFiles._prune_empty_dirs("/base/a", "/base")
    end

    @testset "blob resolution (functors)" begin
        @test_opt target_modules = TM JBLOB(cache_dir = JDIR, config = JS3)
        @test_opt target_modules = TM JART(cache_dir = JDIR)
        @test_opt target_modules = TM LazyFiles.resolve(JBLOB; cache_dir = JDIR, config = JS3)
        @test_opt target_modules = TM LazyFiles.resolve(JART; cache_dir = JDIR)
        # full trait-default path (no explicit config) for built-in and custom blobs
        @test_opt target_modules = TM JART()
        @test_opt target_modules = TM JCUSTOM(cache_dir = JDIR)
        @test_opt target_modules = TM JCUSTOM()
    end

    @testset "public operations" begin
        @test_opt target_modules = TM s3_upload("/tmp/f", "bucket", "name")
        @test_opt target_modules = TM s3_upload("/tmp/f", "bucket")          # name defaulted
        @test_opt target_modules = TM s3_list("bucket")                      # no filter
        @test_opt target_modules = TM s3_list(r"\.txt$", "bucket")           # regex shorthand
        @test_opt target_modules = TM s3_list(e -> e.size > 0, "bucket")     # function predicate
        @test_opt target_modules = TM s3_list("bucket"; prefix = "a/b")      # server-side prefix
        @test_opt target_modules = TM s3_list(r"\.txt$", "bucket"; prefix = "a/b")
        @test_opt target_modules = TM s3_list_with_stats("bucket")
        @test_opt target_modules = TM s3_list_with_stats(e -> e.size > 0, "bucket")
        @test_opt target_modules = TM s3_list_with_stats(r"\.txt$", "bucket"; prefix = "a/b")
        @test_opt target_modules = TM clear_from_cache(JBLOB; cache_dir = JDIR)
        @test_opt target_modules = TM clear_from_cache(JART; cache_dir = JDIR)
        @test_opt target_modules = TM clear_from_cache(JCUSTOM; cache_dir = JDIR)
    end

    @testset "rclone backend internals" begin
        @test_opt target_modules = TM LazyFiles._run(`true`)
        @test_opt target_modules = TM LazyFiles._write_rclone_config(IOBuffer(), JS3)
        @test_opt target_modules = TM LazyFiles._parse_modtime("2024-01-02T12:00:00.0Z")
        @test_opt target_modules = TM LazyFiles._parse_lsjson("[]", "bucket", "")
    end
end
