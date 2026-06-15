# LazyFiles

Lazy, cached handles to remote files. A `LazyS3Blob` (object in an S3 bucket) or
`LazyArtifact` (file at an HTTP URL) resolves to a local path on demand,
downloading into a local cache on first use and serving from cache thereafter.

## Configuration

All operations take a `Config` (or use a process-wide default):

```julia
using LazyFiles
using LazyFiles: Config, LazyS3Blob, LazyArtifact, s3_upload, s3_search, clear_from_cache

cfg = Config(
    local_cache_dir      = expanduser("~/.cache/lazyfiles"),
    s3_access_key_id     = ENV["AWS_ACCESS_KEY_ID"],
    s3_secret_access_key = ENV["AWS_SECRET_ACCESS_KEY"],
    s3_region            = "eu-north-1",
)

# Or read S3 credentials from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION:
cfg = LazyFiles.config_from_env(; local_cache_dir = expanduser("~/.cache/lazyfiles"))

# Avoid passing `config` to every call by setting a default:
LazyFiles.default_config!(cfg)
```

The public names are exported via `public` (Julia ≥ 1.11), so reach them as
`LazyFiles.s3_upload` or `using LazyFiles: s3_upload`.

## S3 objects

```julia
blob = s3_upload("report.csv", "my-bucket"; config = cfg)   # -> LazyS3Blob; name defaults to basename
path = blob(; config = cfg)                                 # downloads on first call, returns local path
path = blob(; config = cfg)                                 # cache hit: returns immediately, no network

blobs = s3_search("my-bucket"; config = cfg)                # Vector{LazyS3Blob}, every object (recursive)
csvs  = s3_search("my-bucket", r"\.csv$"; config = cfg)     # filtered by a regex on the key

clear_from_cache(blob; config = cfg)                        # drop the local copy
```

A handle resolves to `nothing` if the object does not exist.

## HTTP artifacts

`LazyArtifact` needs only `local_cache_dir` — no S3 credentials. It is keyed by
`name`, so a cache hit ignores the URL.

```julia
a = LazyArtifact(url = "https://example.com/data.bin", name = "data.bin")
path = a(; config = cfg)        # downloads to <cache>/_artifacts_/data.bin, or nothing on failure
```

## Notes

- Downloads are written to a `.partial` file and renamed on success, so an
  interrupted run never leaves a truncated file in the cache.
- The rclone S3 backend is provided by `Rclone_jll` — no system install needed.

## Tests

`Pkg.test("LazyFiles")` runs offline checks unconditionally. The live S3 tests
run only when usable credentials are present (see `test/runtests.jl`); otherwise
they are skipped.
