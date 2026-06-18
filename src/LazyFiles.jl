module LazyFiles

using Dates
using Downloads
using JSON
using Rclone_jll

public S3Config, NoConfig, LazyS3Blob, LazyArtifact, S3Entry,
    cache_dir, cache_dir!,
    s3_upload, s3_list, s3_list_with_stats,
    clear_from_cache, validate_s3_config, default_config!, default_config, config_from_env,
    # Extension interface for custom lazy blobs (see the README "Extending" section).
    AbstractLazyBlob, resolve, fetch!, cache_subpath, config_type, validate_config, local_path

# ---------------------------------------------------------------------------
# Cache root
#
# The cache directory is the one thing *every* blob needs, independent of how it
# is fetched, so it is framework state — a process-wide setting — rather than a
# field of any per-backend config. Set it once with `cache_dir!`, or via the
# `LAZYFILES_CACHE_DIR` environment variable, or override per call with the
# `cache_dir` keyword; with none of those set it defaults to `DEFAULT_CACHE_DIR`.
# ---------------------------------------------------------------------------

const CACHE_DIR = Ref{String}("")

# Fallback cache root when neither `cache_dir!` nor `LAZYFILES_CACHE_DIR` is set.
const DEFAULT_CACHE_DIR = joinpath(homedir(), ".LazyFiles.jl_cache")

"""
    cache_dir() -> String

The process-wide cache root every blob resolves under, in precedence order: the
path set with [`cache_dir!`](@ref), else the `LAZYFILES_CACHE_DIR` environment
variable, else the default `~/.LazyFiles.jl_cache`. Never empty; the directory is
created on first use.
"""
function cache_dir()
    isempty(CACHE_DIR[]) || return CACHE_DIR[]
    env = get(ENV, "LAZYFILES_CACHE_DIR", "")
    return isempty(env) ? DEFAULT_CACHE_DIR : env
end

"""
    cache_dir!(path)

Set the process-wide cache root (see [`cache_dir`](@ref)), taking precedence over
both the `LAZYFILES_CACHE_DIR` environment variable and the default.
"""
cache_dir!(path::AbstractString) = (CACHE_DIR[] = String(path))

# Maximum seconds a single artifact download may take (rclone has its own timeouts).
const ARTIFACT_TIMEOUT = 300

# ---------------------------------------------------------------------------
# Fetch configs
#
# A "config" carries only what a particular backend needs to *fetch* — never the
# cache dir. Most blobs need nothing (`NoConfig`); the S3 backend needs
# credentials (`S3Config`). A blob declares its config type via `config_type`.
# ---------------------------------------------------------------------------

"""
    NoConfig()

The fetch config for blobs that need none (e.g. [`LazyArtifact`](@ref)). The
default [`config_type`](@ref) of every blob.
"""
struct NoConfig end

"""
    S3Config(; access_key_id, secret_access_key, region)

Credentials for the S3 backend ([`LazyS3Blob`](@ref) and the `s3_*` operations).
Carries no cache dir — that is framework state, see [`cache_dir!`](@ref).
"""
Base.@kwdef struct S3Config
    access_key_id::String = ""
    secret_access_key::String = ""
    region::String = ""
end

is_valid_s3_config(c::S3Config) =
    !isempty(c.access_key_id) && !isempty(c.secret_access_key) && !isempty(c.region)

validate_s3_config(c::S3Config) = is_valid_s3_config(c) || error("S3 config is not properly set")

# Process-wide default per config type; a config type's owner adds a method.
const DEFAULT_S3_CONFIG = Ref{S3Config}(S3Config())

"""
    default_config(::Type{C}) -> C

The process-wide default config of type `C`, used when a blob is resolved without
an explicit `config` (see [`config_type`](@ref)). `NoConfig` needs no setup;
`S3Config` returns the one set by [`default_config!`](@ref); a package introducing
its own config type adds a method here.
"""
default_config(::Type{NoConfig}) = NoConfig()
default_config(::Type{S3Config}) = DEFAULT_S3_CONFIG[]

"""
    default_config!(c::S3Config)

Set the process-wide default `S3Config` used by the `s3_*` operations and by
`LazyS3Blob` resolution when no `config` is passed.
"""
default_config!(c::S3Config) = (DEFAULT_S3_CONFIG[] = c)

"""
    config_from_env() -> S3Config

Build an `S3Config` from `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and
`AWS_REGION`. The cache root is separate framework state — set it with
[`cache_dir!`](@ref) or the `LAZYFILES_CACHE_DIR` environment variable.
"""
config_from_env() = S3Config(
    access_key_id = get(ENV, "AWS_ACCESS_KEY_ID", ""),
    secret_access_key = get(ENV, "AWS_SECRET_ACCESS_KEY", ""),
    region = get(ENV, "AWS_REGION", ""),
)

# DOS device names reserved by Windows; illegal as a path component (with or
# without an extension) even though they are valid S3 keys / POSIX filenames.
const _WIN_RESERVED_NAMES = Set([
    "CON", "PRN", "AUX", "NUL",
    ("COM$i" for i in 1:9)...,
    ("LPT$i" for i in 1:9)...,
])

# Reject bucket names / object keys that resolve to a valid path on POSIX but
# behave differently — or are outright illegal — on Windows, so a handle that
# caches on one OS caches on every OS instead of silently diverging or failing
# only on Windows. `/` is allowed: it is the portable key delimiter and maps to
# nested cache dirs everywhere.
function _check_portable_name(parts...)
    for part in parts
        for seg in split(part, '/'; keepempty = false)
            # `\` is a literal char on POSIX but a path separator on Windows.
            occursin('\\', seg) &&
                error("name not portable to Windows (contains a backslash): \"$seg\"")
            # Control chars and the characters Windows forbids in a path component.
            i = findfirst(c -> c < ' ' || c in ('<', '>', ':', '"', '|', '?', '*'), seg)
            isnothing(i) ||
                error("name not portable to Windows (illegal character $(repr(seg[i]))): \"$seg\"")
            # Windows trims a leading space (Explorer) and a trailing dot or
            # space (the path API) from a component, so such a name would cache
            # under a different filename there — reject rather than diverge.
            (startswith(seg, ' ') || endswith(seg, '.') || endswith(seg, ' ')) &&
                error("name not portable to Windows (leading/trailing space or trailing dot): \"$seg\"")
            # Reserved device name, with or without an extension (CON, CON.txt).
            uppercase(first(split(seg, '.'))) in _WIN_RESERVED_NAMES &&
                error("name not portable to Windows (reserved device name): \"$seg\"")
        end
    end
    return nothing
end

# Resolve a cache path, refusing names that escape the cache directory (e.g. a
# blob name containing `..` or an absolute path) or that aren't portable across
# operating systems.
function _checked_path(base::AbstractString, parts...)
    _check_portable_name(parts...)
    full = normpath(joinpath(base, parts...))
    root = normpath(base)
    sep = Base.Filesystem.path_separator
    prefix = endswith(root, sep) ? root : root * sep
    (full == root || startswith(full, prefix)) ||
        error("path escapes the cache directory: $(joinpath(parts...))")
    return full
end

# ---------------------------------------------------------------------------
# Lazy blobs
#
# A lazy blob is a handle that resolves to a local path, downloading into the
# cache on a miss and serving from cache thereafter. The resolve algorithm
# (check cache -> fetch to a temp -> atomically rename in) is identical for every
# blob type; a concrete type supplies only the two things that differ:
#
#   cache_subpath(b)                 -> the path components under the cache dir
#   fetch!(b, dest; config, verbose) -> write `dest`, or leave it absent if the
#                                       resource genuinely does not exist
#
# and, optionally, `config_type(b)` (the fetch config it needs; default none) and
# `validate_config(config, b)`. Implement those and `b()`, `resolve(b)`,
# `local_path(b)` and `clear_from_cache(b)` all work — see the "Extending"
# section of the README.
# ---------------------------------------------------------------------------

abstract type AbstractLazyBlob end

"""
    config_type(b::AbstractLazyBlob) -> Type

The fetch-config type `b` resolves with. Defaults to [`NoConfig`](@ref); a blob
backed by credentials or other parameters overrides it (e.g. [`LazyS3Blob`](@ref)
uses [`S3Config`](@ref)), and `b()` then defaults `config` to that type's
[`default_config`](@ref). The cache dir is *not* part of this — it is framework
state (see [`cache_dir`](@ref)).
"""
config_type(::AbstractLazyBlob) = NoConfig

"""
    cache_subpath(b::AbstractLazyBlob) -> Tuple of path components

The blob's location under the cache dir, as `/`-free path components that
[`local_path`](@ref) joins onto the cache root and portability-checks. A concrete
blob type defines this (or overrides `local_path` for full control of the layout).
"""
function cache_subpath end

"""
    fetch!(b::AbstractLazyBlob, dest::AbstractString; config, verbose=false)

Download `b` to the path `dest`. Leave `dest` nonexistent (write nothing) **iff**
the resource genuinely does not exist — [`resolve`](@ref) reads a missing `dest`
as "not found" and returns `nothing`. Raise on any real failure (auth, network,
timeout, 5xx): a failure must not masquerade as "not found". A concrete blob type
defines this; `config` is of the blob's [`config_type`](@ref). (`resolve` removes
a partial `dest` if `fetch!` throws.)
"""
function fetch! end

# The cache root is mandatory for every blob; check it before touching the network.
_require_cache_dir(dir) =
    isempty(dir) && error("cache dir is not set — call cache_dir!(path) or pass cache_dir=")

"""
    validate_config(config, b::AbstractLazyBlob)

Check `config` carries what *fetching* `b` needs, raising if not. Defaults to a
no-op (most blobs need no fetch config); a blob type that needs credentials
overrides it (e.g. [`LazyS3Blob`](@ref)). The cache dir is validated separately.
"""
validate_config(::Any, ::AbstractLazyBlob) = nothing

"""
    local_path(b::AbstractLazyBlob; cache_dir=cache_dir()) -> String

The absolute cache path `b` resolves to: `cache_subpath(b)` joined onto the cache
root, with the cross-OS portability / no-escape checks applied to every blob
type. Override directly to take full control of the layout.
"""
local_path(b::AbstractLazyBlob; cache_dir = cache_dir()) =
    _checked_path(cache_dir, cache_subpath(b)...)

"""
    resolve(b::AbstractLazyBlob; cache_dir=cache_dir(), config=default_config(config_type(b)), verbose=false) -> String | Nothing

Resolve `b` to a local path: return the cached copy on a hit, otherwise
[`fetch!`](@ref) it into the cache and return the new path. Returns `nothing`
only when `fetch!` reports the resource absent. `cache_dir` defaults to the
process-wide [`cache_dir`](@ref); `config` to the default for the blob's
[`config_type`](@ref). Calling a blob — `b()` — forwards here.
"""
function resolve(
        b::AbstractLazyBlob;
        cache_dir = cache_dir(), config = default_config(config_type(b)), verbose::Bool = false
    )
    _require_cache_dir(cache_dir)
    validate_config(config, b)
    lp = local_path(b; cache_dir)
    isfile(lp) && return lp
    mkpath(dirname(lp))
    # Fetch into a unique temp in the same dir, then rename: an interrupted run
    # never caches a partial, and concurrent resolves of the same blob don't
    # clobber each other. `cleanup=false`: we manage its lifecycle.
    tmp = tempname(dirname(lp); cleanup = false)
    try
        fetch!(b, tmp; config, verbose)
    catch
        # `fetch!` may have written a partial before failing; never cache it.
        isfile(tmp) && rm(tmp; force = true)
        rethrow()
    end
    # A surviving `tmp` is the fetched object; its absence means `fetch!`
    # reported the resource genuinely missing.
    isfile(tmp) || return nothing
    mv(tmp, lp; force = true)
    return lp
end

(b::AbstractLazyBlob)(;
    cache_dir = cache_dir(), config = default_config(config_type(b)), verbose::Bool = false) =
    resolve(b; cache_dir, config, verbose)

"""
    s = LazyS3Blob(; bucket, name)
    s()  -> resolves to a local path, downloading on a cache miss; `nothing` if absent

A handle to an object in an S3 bucket. Calling it returns the path to a local
copy (under the cache root), downloading the object on first use. Resolves with
an [`S3Config`](@ref). Returns `nothing` only when the object does not exist; a
genuine failure (auth, missing bucket, network) raises.
"""
Base.@kwdef struct LazyS3Blob <: AbstractLazyBlob
    bucket::String
    name::String
end

cache_subpath(b::LazyS3Blob) = (b.bucket, b.name)
config_type(::LazyS3Blob) = S3Config
validate_config(c::S3Config, ::LazyS3Blob) = validate_s3_config(c)

function fetch!(b::LazyS3Blob, dest::AbstractString; config::S3Config, verbose::Bool = false)
    r = _with_rclone(config) do make_cmd
        _run(make_cmd(`copyto $RCLONE_REMOTE:$(b.bucket)/$(b.name) $dest`); verbose)
    end
    # rclone `copyto` exits 0 and writes nothing when the object is absent (so
    # `resolve` sees the missing `dest` as "not found"); a nonzero exit is a real
    # failure (auth, missing bucket, network) and must surface, not masquerade as
    # "not found".
    r.ok || error("download failed (rclone exit $(r.code)): $(strip(r.err))")
    return nothing
end

"""
    a = LazyArtifact(; url, name, timeout=$ARTIFACT_TIMEOUT)
    a()  -> resolves to a local path, downloading on a cache miss; `nothing` if absent

A handle to a file at an HTTP(S) `url`. Calling it returns the path to a local
copy (cached under `<cache>/_artifacts_/<name>`), downloading on first use, with
at most `timeout` seconds per download. Needs no fetch config ([`NoConfig`](@ref))
— only the cache root. Returns `nothing` only when the URL responds
`404 Not Found`; a genuine failure (network, timeout, 5xx, …) raises rather than
masquerading as "not found".
"""
Base.@kwdef struct LazyArtifact <: AbstractLazyBlob
    url::String
    name::String
    timeout::Int = ARTIFACT_TIMEOUT
end

cache_subpath(a::LazyArtifact) = ("_artifacts_", a.name)

function fetch!(a::LazyArtifact, dest::AbstractString; config::NoConfig = NoConfig(), verbose::Bool = false)
    try
        Downloads.download(a.url, dest; timeout = a.timeout)
    catch e
        # A 404 means the artifact genuinely isn't there: drop any partial and
        # leave `dest` absent so `resolve` returns `nothing`. Any other failure
        # (network, timeout, 5xx) is real and must surface, not look like "not
        # found".
        if e isa Downloads.RequestError && e.response.status == 404
            isfile(dest) && rm(dest; force = true)
            verbose && @warn "artifact not found (404)" url = a.url
            return nothing
        end
        verbose && @warn "artifact download failed" url = a.url exception = e
        rethrow()
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Public operations
# ---------------------------------------------------------------------------

# Remove now-empty cache directories left behind by a removed blob, walking up
# toward (but never past or including) the cache root.
function _prune_empty_dirs(dir::AbstractString, root::AbstractString)
    isempty(root) && return nothing
    root = normpath(root)
    sep = Base.Filesystem.path_separator
    prefix = endswith(root, sep) ? root : root * sep
    dir = normpath(dir)
    while dir != root && startswith(dir, prefix) && isdir(dir) && isempty(readdir(dir))
        try
            rm(dir)
        catch
            # Racing a concurrent resolve that repopulated this dir (ENOTEMPTY) or
            # another pruner that already removed it (ENOENT): pruning empty dirs
            # is a tidy-up, not required for correctness, so stop rather than fail
            # the cache-clear over a directory we don't strictly need to delete.
            break
        end
        dir = dirname(dir)
    end
    return nothing
end

"""
    clear_from_cache(b; cache_dir=cache_dir()) -> Bool

Remove the local cached copy of `b`, if present. Returns `true` if a file was
removed, `false` if there was nothing cached. Needs only the cache root, not any
fetch config.
"""
function clear_from_cache(b::AbstractLazyBlob; cache_dir = cache_dir())
    _require_cache_dir(cache_dir)
    lp = local_path(b; cache_dir)
    isfile(lp) || return false
    rm(lp; force = true)
    _prune_empty_dirs(dirname(lp), cache_dir)
    return true
end

function s3_upload(
        local_file::AbstractString, bucket::AbstractString, name::Union{AbstractString, Nothing} = nothing;
        config::S3Config = default_config(S3Config), verbose::Bool = false
    )
    validate_s3_config(config)
    isfile(local_file) || error("not a file: $local_file")
    name = isnothing(name) ? basename(local_file) : name
    # Refuse a bucket/key the returned handle could never resolve (resolve applies
    # the same check). Fail here, before the upload, instead of stranding an object
    # in S3 that this package can't read back.
    _check_portable_name(bucket, name)
    # `--` stops rclone flag parsing so a local_file beginning with `-` is
    # treated as a path, not a flag.
    r = _with_rclone(config) do make_cmd
        _run(make_cmd(`copyto --s3-no-check-bucket -- $local_file $RCLONE_REMOTE:$bucket/$name`); verbose)
    end
    r.ok || error("upload failed (rclone exit $(r.code)): $(strip(r.err))")
    return LazyS3Blob(; bucket, name)
end

"""
    S3Entry

One object in a bucket listing: a `blob::LazyS3Blob` handle paired with the
object's `size` (bytes) and `modified` time (the S3 last-modified timestamp, UTC,
second resolution). The element type returned by [`s3_list_with_stats`](@ref), and
the value passed to a listing predicate.
"""
const S3Entry = @NamedTuple{blob::LazyS3Blob, size::Int, modified::DateTime}

# The rclone `lsjson` fields we use. JSON's typed parse fills these by name and
# ignores the rest (Name, IsDir, …); field names match rclone's JSON keys, which
# is why they're capitalized rather than Julia-style.
struct _LsObject
    Path::String
    Size::Int
    ModTime::String
end

# rclone `lsjson` emits an RFC3339 ModTime (e.g. "2024-01-02T12:00:00.123456789Z").
# Its first 19 characters are always `yyyy-mm-ddTHH:MM:SS`, so truncate to whole
# seconds and read as a naive `DateTime`. We pass `--use-server-modtime`, so the
# value is the S3 last-modified time (UTC); the sub-second part and zone suffix
# are dropped — second resolution is enough to order and poll listings.
_parse_modtime(s::AbstractString) = DateTime(first(s, 19), dateformat"yyyy-mm-ddTHH:MM:SS")

# Turn an `lsjson` listing into `S3Entry` records. Factored out of
# `s3_list_with_stats` so it is unit-testable without rclone. `lsjson -R` reports
# keys relative to the listed dir, so re-prepend `pfx` to rebuild the full key
# each LazyS3Blob needs (the full key is what a listing predicate later sees).
function _parse_lsjson(out::AbstractString, bucket::AbstractString, pfx::AbstractString)
    recs = S3Entry[]
    isempty(strip(out)) && return recs
    for o in JSON.parse(out, Vector{_LsObject})::Vector{_LsObject}
        name = isempty(pfx) ? o.Path : string(pfx, '/', o.Path)
        push!(
            recs, (;
                blob = LazyS3Blob(; bucket, name),
                size = o.Size,
                modified = _parse_modtime(o.ModTime),
            )
        )
    end
    return recs
end

"""
    s3_list_with_stats([pred,] bucket; prefix="", config=default_config(S3Config)) -> Vector{S3Entry}

List objects in `bucket` (recursively) as [`S3Entry`](@ref) records, each pairing a
`LazyS3Blob` handle with the object's `size` (bytes) and `modified` time (the S3
last-modified timestamp, UTC, second resolution).

`prefix` narrows the listing *on the server* to keys under that `/`-delimited key
prefix (e.g. `"logs/2024"`), so only that subtree is fetched instead of the whole
bucket — the one filter S3 itself can apply. A prefix matching nothing yields an
empty vector.

`pred` filters the records *client-side*, after the listing returns:
`pred(::S3Entry)::Bool` keeps the entries for which it returns `true`, so it can
select on name, size and time together. As a shorthand, a `Regex` given in `pred`'s
place matches against each full key, i.e. `s3_list_with_stats(r, bucket)` ==
`s3_list_with_stats(e -> occursin(r, e.blob.name), bucket)`.

    # .csv objects over 1 MiB, modified this year
    s3_list_with_stats(bucket) do e
        endswith(e.blob.name, ".csv") && e.size > 1024^2 && e.modified > DateTime(2024)
    end

[`s3_list`](@ref) is this call projected down to just the `blob` handles.
"""
function s3_list_with_stats(
        bucket::AbstractString;
        prefix::AbstractString = "", config::S3Config = default_config(S3Config), verbose::Bool = false
    )
    validate_s3_config(config)
    # rclone lists the "directory" `bucket/pfx`; the keys come back relative to it.
    pfx = strip(prefix, '/')
    remote = isempty(pfx) ? "$RCLONE_REMOTE:$bucket" : "$RCLONE_REMOTE:$bucket/$pfx"
    r = _with_rclone(config) do make_cmd
        _run(make_cmd(`lsjson $remote --files-only -R --use-server-modtime`); verbose)
    end
    r.ok || error("list failed (rclone exit $(r.code)): $(strip(r.err))")
    return _parse_lsjson(r.out, bucket, pfx)
end

# Optional client-side filter over the full listing. A bare predicate sees the
# whole `S3Entry`; a `Regex` is sugar for matching it against the full key.
s3_list_with_stats(pred, bucket::AbstractString; kwargs...) =
    filter(pred, s3_list_with_stats(bucket; kwargs...))

s3_list_with_stats(re::Regex, bucket::AbstractString; kwargs...) =
    s3_list_with_stats(e -> occursin(re, e.blob.name), bucket; kwargs...)

"""
    s3_list([pred,] bucket; prefix="", config=default_config(S3Config)) -> Vector{LazyS3Blob}

List objects in `bucket` (recursively) as `LazyS3Blob` handles. `prefix`, the
optional `pred`, and the `Regex` shorthand all filter exactly as in
[`s3_list_with_stats`](@ref); this is that call projected to just the handles.

    s3_list(bucket)                           # every object
    s3_list(r"\\.txt\$", bucket)                # keys ending in .txt
    s3_list(e -> e.size > 1024^2, bucket)     # objects larger than 1 MiB

Use [`s3_list_with_stats`](@ref) when you also need each object's size and
last-modified time.
"""
s3_list(bucket::AbstractString; kwargs...) =
    [e.blob for e in s3_list_with_stats(bucket; kwargs...)]
s3_list(pred, bucket::AbstractString; kwargs...) =
    [e.blob for e in s3_list_with_stats(pred, bucket; kwargs...)]

# ---------------------------------------------------------------------------
# rclone backend
# ---------------------------------------------------------------------------

const RCLONE_REMOTE = "lazyfiles"

"""
    _run(cmd; verbose=false) -> (; ok, code, out, err)

Run an rclone `cmd`, capturing stdout/stderr instead of throwing on failure
(a thrown `ProcessFailedException` would dump the whole process environment).
"""
function _run(cmd::Cmd; verbose::Bool = false)
    verbose && @info "rclone" cmd
    out = IOBuffer()
    err = IOBuffer()
    # `run` infers as `Any` through `pipeline`'s kwargs even though a redirected
    # single command always yields a `Base.Process`; assert it so `proc.exitcode`
    # et al. stay concrete and don't leak runtime dispatch into callers.
    proc = run(pipeline(cmd; stdout = out, stderr = err); wait = false)::Base.Process
    wait(proc)
    serr = String(take!(err))
    verbose && !isempty(serr) && @info "rclone stderr" serr
    return (; ok = success(proc), code = proc.exitcode, out = String(take!(out)), err = serr)
end

function _write_rclone_config(io::IO, c::S3Config)
    return write(
        io, """
        [$RCLONE_REMOTE]
        type = s3
        provider = AWS
        access_key_id = $(c.access_key_id)
        secret_access_key = $(c.secret_access_key)
        region = $(c.region)
        location_constraint = $(c.region)
        """
    )
end

"""
    _with_rclone(f, config) -> f(make_cmd)

Write a temporary rclone config for `config` and call `f` with a closure
`make_cmd(args::Cmd) -> Cmd` that prepends the rclone binary and the global
`--config` flag. The flag goes before the subcommand so a `--` flag terminator
inside `args` doesn't swallow it. The temp config is removed when `f` returns.
"""
function _with_rclone(f, config::S3Config)
    return mktemp() do path, io
        _write_rclone_config(io, config)
        close(io)
        # `rclone()` (a JLL accessor) infers as `Any`; assert its `Cmd` so the
        # interpolated command builds without runtime dispatch in `cmd_gen`.
        make_cmd(args::Cmd) = `$(rclone()::Cmd) --config $path $args`
        f(make_cmd)
    end
end

end # module LazyFiles
