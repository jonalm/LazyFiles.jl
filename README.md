# LazyFiles

[![CI](https://github.com/jonalm/LazyFiles.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/jonalm/LazyFiles.jl/actions/workflows/CI.yml)

Lazy, cached handles to remote files. A `LazyS3Blob` (object in an S3 bucket) or
`LazyArtifact` (file at an HTTP URL) resolves to a local path on demand,
downloading into a local cache on first use and serving from cache thereafter.
Define a handle for any other source by implementing a two-method interface — see
[Extending](#extending-custom-lazy-blobs).

## Configuration

The **cache root** — where every blob caches — is process-wide state. It defaults
to `~/.LazyFiles.jl_cache` (created on first use); override it, in precedence
order, with `cache_dir!(path)`, the `LAZYFILES_CACHE_DIR` environment variable, or
a per-call `cache_dir=` keyword (`cache_dir!` beats the env var, and a per-call
keyword beats both):

```julia
using LazyFiles
using LazyFiles: cache_dir!, S3Config, LazyS3Blob, LazyArtifact,
    s3_upload, s3_list, s3_list_with_stats, clear_from_cache

cache_dir!(expanduser("~/.cache/lazyfiles"))   # optional; defaults to ~/.LazyFiles.jl_cache
```

**Fetch credentials are separate** — only the backends that need them carry them,
and the cache dir is never one of their fields. The S3 backend uses an `S3Config`:

```julia
cfg = S3Config(
    access_key_id     = ENV["AWS_ACCESS_KEY_ID"],
    secret_access_key = ENV["AWS_SECRET_ACCESS_KEY"],
    region            = "eu-north-1",
)

# Or read them from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION:
cfg = LazyFiles.config_from_env()

# Avoid passing `config` to every S3 call by setting a process-wide default:
LazyFiles.default_config!(cfg)
```

HTTP artifacts need no config at all — only the cache root.

The public names are exported via `public` (Julia ≥ 1.11), so reach them as
`LazyFiles.s3_upload` or `using LazyFiles: s3_upload`.

## S3 objects

```julia
blob = s3_upload("report.csv", "my-bucket"; config = cfg)   # -> LazyS3Blob; name defaults to basename
path = blob(; config = cfg)                                 # downloads on first call, returns local path
path = blob(; config = cfg)                                 # cache hit: returns immediately, no network

blobs = s3_list("my-bucket"; config = cfg)                  # Vector{LazyS3Blob}, every object (recursive)
csvs  = s3_list(r"\.csv$", "my-bucket"; config = cfg)       # Regex shorthand: filter on the key
big   = s3_list(e -> e.size > 1024^2, "my-bucket"; config = cfg)  # predicate on the S3Entry record
logs  = s3_list("my-bucket"; prefix = "logs/2024", config = cfg)  # server-side: only keys under logs/2024/

# Same listing, with each object's size (bytes) and last-modified time:
stats = s3_list_with_stats("my-bucket"; prefix = "logs/2024", config = cfg)
# -> Vector{S3Entry}, i.e. @NamedTuple{blob::LazyS3Blob, size::Int, modified::DateTime}
latest = argmax(e -> e.modified, stats).blob                # e.g. pick the newest object

clear_from_cache(blob)                                      # drop the local copy (cache root only)
```

A handle resolves to `nothing` if the object does not exist; a genuine failure
(bad credentials, missing bucket, network error) raises rather than silently
returning `nothing`. (Set a default with `default_config!` and you can drop the
`config = cfg` from these calls entirely.)

## HTTP artifacts

`LazyArtifact` needs no credentials — only the cache root. It is keyed by `name`,
so a cache hit ignores the URL.

```julia
a = LazyArtifact(url = "https://example.com/data.bin", name = "data.bin")
path = a()                      # downloads to <cache>/_artifacts_/data.bin

# bound each download (seconds); defaults to 300
slow = LazyArtifact(url = "https://example.com/big.bin", name = "big.bin", timeout = 600)
```

Like a blob, an artifact resolves to `nothing` only when the URL responds
`404 Not Found`; a genuine failure (network error, timeout, 5xx) raises rather
than silently returning `nothing`.

## Extending: custom lazy blobs

Every handle resolves the same way — check the cache, download to a temp file,
atomically rename it in — so a new source only has to say *where* it caches and
*how* it fetches. Subtype `AbstractLazyBlob` and implement two methods. Here is a
handle to a file in a public GitHub repo, pinned to a branch, tag or commit — and
keyed by that identity rather than an opaque URL:

```julia
using LazyFiles
using LazyFiles: AbstractLazyBlob, NoConfig
import Downloads

struct LazyGitHubFile <: AbstractLazyBlob
    repo::String   # "owner/name"
    ref::String    # branch, tag or commit SHA
    path::String   # path to the file within the repo
end

# where it caches: path components under the cache root (portability-checked;
# the `/` in `repo` and `path` just maps to nested cache directories)
LazyFiles.cache_subpath(f::LazyGitHubFile) = ("github", f.repo, f.ref, f.path)

# how it fetches: write `dest`, or leave it absent if the file doesn't exist
# (404); raise on any real failure so it never masquerades as "not found"
function LazyFiles.fetch!(f::LazyGitHubFile, dest; config::NoConfig = NoConfig(), verbose = false)
    url = "https://raw.githubusercontent.com/$(f.repo)/$(f.ref)/$(f.path)"
    try
        Downloads.download(url, dest)
    catch e
        e isa Downloads.RequestError && e.response.status == 404 && return nothing
        rethrow()
    end
    return nothing
end
```

That blob needs no credentials, so it is done — calling it, `resolve`,
`local_path` and `clear_from_cache` all work, caching under the process-wide
`cache_dir`:

```julia
cache_dir!(expanduser("~/.cache/lazyfiles"))
path = LazyGitHubFile("JuliaLang/Example.jl", "master", "README.md")()  # cached after first call
```

### Custom fetch config

The public handle above needs no auth. To also reach *private* repos, give it a
config type carrying a token and declare it with `config_type` — defaulting, if
you don't, to `NoConfig`. The cache root is *not* part of it:

```julia
struct GitHubToken
    token::String
end
const _GH = Ref(GitHubToken(""))
LazyFiles.default_config(::Type{GitHubToken}) = _GH[]       # optional process-wide default

LazyFiles.config_type(::LazyGitHubFile) = GitHubToken
LazyFiles.validate_config(c::GitHubToken, ::LazyGitHubFile) =   # optional
    isempty(c.token) && error("GitHub token not set")
function LazyFiles.fetch!(f::LazyGitHubFile, dest; config::GitHubToken, verbose = false)
    # ... download with an `Authorization: Bearer $(config.token)` header
end

_GH[] = GitHubToken(ENV["GITHUB_TOKEN"])
LazyGitHubFile("me/private", "main", "data.bin")()                                  # uses the default token
LazyGitHubFile("me/private", "main", "data.bin")(; config = GitHubToken("ghp_…"))   # or pass one explicitly
```

`fetch!`'s contract is the one subtlety: leave `dest` nonexistent **iff** the
resource genuinely doesn't exist — that is what makes the handle return
`nothing` — and raise on any real error. For full control of the cache layout,
override `local_path(b; cache_dir)` directly instead of `cache_subpath`.

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
