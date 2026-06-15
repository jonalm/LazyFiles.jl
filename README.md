# LazyFiles

[![CI](https://github.com/jonalm/LazyFiles.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/jonalm/LazyFiles.jl/actions/workflows/CI.yml)

Lazy, cached handles to remote files. A `LazyS3Blob` (object in an S3 bucket) or
`LazyArtifact` (file at an HTTP URL) resolves to a local path on demand,
downloading into a local cache on first use and serving from cache thereafter.

## Configuration

All operations take a `Config` (or use a process-wide default):

```julia
using LazyFiles
using LazyFiles: Config, LazyS3Blob, LazyArtifact, s3_upload, s3_list, s3_list_with_stats, clear_from_cache

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

blobs = s3_list("my-bucket"; config = cfg)                  # Vector{LazyS3Blob}, every object (recursive)
csvs  = s3_list("my-bucket", r"\.csv$"; config = cfg)       # filtered by a regex on the key
logs  = s3_list("my-bucket"; prefix = "logs/2024", config = cfg)  # server-side: only keys under logs/2024/

# Same listing, with each object's size (bytes) and last-modified time:
stats = s3_list_with_stats("my-bucket"; prefix = "logs/2024", config = cfg)
# -> Vector{@NamedTuple{blob::LazyS3Blob, size::Int, modified::DateTime}}
latest = argmax(e -> e.modified, stats).blob                # e.g. pick the newest object

clear_from_cache(blob; config = cfg)                        # drop the local copy
```

A handle resolves to `nothing` if the object does not exist; a genuine failure
(bad credentials, missing bucket, network error) raises rather than silently
returning `nothing`.

## HTTP artifacts

`LazyArtifact` needs only `local_cache_dir` — no S3 credentials. It is keyed by
`name`, so a cache hit ignores the URL.

```julia
a = LazyArtifact(url = "https://example.com/data.bin", name = "data.bin")
path = a(; config = cfg)        # downloads to <cache>/_artifacts_/data.bin
```

Like a blob, an artifact resolves to `nothing` only when the URL responds
`404 Not Found`; a genuine failure (network error, timeout, 5xx) raises rather
than silently returning `nothing`.

## Notes

- Downloads are written to a unique temporary file in the cache and renamed on
  success, so an interrupted run never leaves a truncated file in the cache and
  concurrent resolves of the same handle don't clobber each other.
- The rclone S3 backend is provided by `Rclone_jll` — no system install needed.
- Bucket names and object keys must be portable across operating systems: `/`
  delimits nested cache directories, but a name containing a backslash, a
  character Windows forbids in a path (`<>:"|?*` or a control char), a reserved
  device name (`CON`, `NUL`, …), or a leading/trailing space or trailing dot is
  rejected — so a blob that caches on one OS caches on all of them. The same
  check runs at upload time, so `s3_upload` can't strand an object under a key
  the handle it returns could never resolve.

## Tests

`Pkg.test("LazyFiles")` runs offline checks unconditionally. The live S3 tests
run only when usable credentials are present (see `test/runtests.jl`); otherwise
they are skipped.

Credentials are read from `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
`AWS_REGION` in the environment. To run the live tests without keeping keys in a
file, store them in your OS keychain with
[`aws-vault`](https://github.com/99designs/aws-vault) and inject them for a
single run:

```sh
aws-vault exec lazyfiles-test --no-session -- \
    julia --project -e 'using Pkg; Pkg.test()'
```

`--no-session` is required: the S3 backend authenticates with a static access
key and does not read `AWS_SESSION_TOKEN`, so temporary/STS credentials —
aws-vault's default, AWS SSO, and MFA-gated sessions — won't work.
