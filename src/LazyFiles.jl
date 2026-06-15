module LazyFiles

using Dates
using Downloads
using JSON
using Rclone_jll

public Config, LazyS3Blob, LazyArtifact, S3Entry, s3_upload, s3_list, s3_list_with_stats,
    clear_from_cache, validate_s3_config, validate_minimal_config, default_config!,
    config_from_env

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

Base.@kwdef struct Config
    local_cache_dir::String = ""

    # S3 only
    s3_access_key_id::String = ""
    s3_secret_access_key::String = ""
    s3_region::String = ""
end

local_cache_dir(c::Config) = c.local_cache_dir

# Maximum seconds a single artifact download may take (rclone has its own timeouts).
const ARTIFACT_TIMEOUT = 300

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

is_valid_minimal_config(c::Config) = !isempty(c.local_cache_dir)
is_valid_s3_config(c::Config) = is_valid_minimal_config(c) &&
    !isempty(c.s3_access_key_id) && !isempty(c.s3_secret_access_key) && !isempty(c.s3_region)

validate_s3_config(c::Config) = is_valid_s3_config(c) || error("S3 config is not properly set")
validate_minimal_config(c::Config) = is_valid_minimal_config(c) || error("local_cache_dir is not set")


const DEFAULT_CONFIG = Ref{Config}(Config())
default_config!(c::Config) = (DEFAULT_CONFIG[] = c)

"""
    config_from_env(; local_cache_dir) -> Config

Build a `Config` from `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and
`AWS_REGION` environment variables.
"""
config_from_env(; local_cache_dir::String = get(ENV, "LAZYFILES_CACHE_DIR", "")) = Config(;
    local_cache_dir,
    s3_access_key_id = get(ENV, "AWS_ACCESS_KEY_ID", ""),
    s3_secret_access_key = get(ENV, "AWS_SECRET_ACCESS_KEY", ""),
    s3_region = get(ENV, "AWS_REGION", ""),
)

# ---------------------------------------------------------------------------
# Lazy blobs
# ---------------------------------------------------------------------------

abstract type AbstractLazyBlob end

"""
    s = LazyS3Blob(; bucket, name)
    s()  -> resolves to a local path, downloading on a cache miss; `nothing` if absent

A handle to an object in an S3 bucket. Calling it returns the path to a local
copy (under the config's cache dir), downloading the object on first use.
Returns `nothing` only when the object does not exist; a genuine failure
(auth, missing bucket, network) raises.
"""
Base.@kwdef struct LazyS3Blob <: AbstractLazyBlob
    bucket::String
    name::String
end

local_path(config::Config, b::LazyS3Blob) = _checked_path(local_cache_dir(config), b.bucket, b.name)

function (b::LazyS3Blob)(; config::Config = DEFAULT_CONFIG[], verbose::Bool = false)
    validate_s3_config(config)
    lp = local_path(config, b)
    isfile(lp) && return lp
    mkpath(dirname(lp))
    # Download to a unique temp in the same dir, then rename: an interrupted run
    # never caches a partial, and concurrent resolves of the same blob don't
    # clobber each other's download. `cleanup=false`: we manage its lifecycle.
    tmp = tempname(dirname(lp); cleanup = false)
    r = _with_rclone(config) do make_cmd
        _run(make_cmd(`copyto $RCLONE_REMOTE:$(b.bucket)/$(b.name) $tmp`); verbose)
    end
    # rclone `copyto` exits 0 and writes nothing when the object is absent; a
    # nonzero exit is a real failure (auth, missing bucket, network) and must
    # be surfaced rather than masquerading as "not found".
    if !r.ok
        isfile(tmp) && rm(tmp; force = true)
        error("download failed (rclone exit $(r.code)): $(strip(r.err))")
    end
    isfile(tmp) || return nothing
    mv(tmp, lp; force = true)
    return lp
end

"""
    a = LazyArtifact(; url, name)
    a()  -> resolves to a local path, downloading on a cache miss; `nothing` if absent

A handle to a file at an HTTP(S) `url`. Calling it returns the path to a local
copy (cached under `<cache>/_artifacts_/<name>`), downloading on first use.
Only `local_cache_dir` is required in the config — no S3 credentials.
Returns `nothing` only when the URL responds `404 Not Found`; a genuine failure
(network, timeout, 5xx, …) raises rather than masquerading as "not found".
"""
Base.@kwdef struct LazyArtifact <: AbstractLazyBlob
    url::String
    name::String
end

local_path(config::Config, a::LazyArtifact) = _checked_path(local_cache_dir(config), "_artifacts_", a.name)

function (a::LazyArtifact)(; config::Config = DEFAULT_CONFIG[], verbose::Bool = false, timeout::Real = ARTIFACT_TIMEOUT)
    validate_minimal_config(config)
    lp = local_path(config, a)
    isfile(lp) && return lp
    mkpath(dirname(lp))
    # Unique temp in the same dir, renamed on success: an interrupted run never
    # caches a partial, and concurrent resolves don't clobber each other.
    tmp = tempname(dirname(lp); cleanup = false)
    try
        Downloads.download(a.url, tmp; timeout)
    catch e
        isfile(tmp) && rm(tmp; force = true)
        # A 404 means the artifact genuinely isn't there: return `nothing`,
        # mirroring the S3 path. Any other failure (network, timeout, 5xx, a
        # bad cache path) is real and must surface, not look like "not found".
        if e isa Downloads.RequestError && e.response.status == 404
            verbose && @warn "artifact not found (404)" url = a.url
            return nothing
        end
        verbose && @warn "artifact download failed" url = a.url exception = e
        rethrow()
    end
    isfile(tmp) || return nothing
    mv(tmp, lp; force = true)
    return lp
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
    clear_from_cache(b; config=DEFAULT_CONFIG[]) -> Bool

Remove the local cached copy of `b`, if present. Returns `true` if a file was
removed, `false` if there was nothing cached.
"""
function clear_from_cache(b::AbstractLazyBlob; config::Config = DEFAULT_CONFIG[])
    validate_minimal_config(config)
    lp = local_path(config, b)
    isfile(lp) || return false
    rm(lp; force = true)
    _prune_empty_dirs(dirname(lp), local_cache_dir(config))
    return true
end

function s3_upload(
        local_file::AbstractString, bucket::AbstractString, name::Union{AbstractString, Nothing} = nothing;
        config::Config = DEFAULT_CONFIG[], verbose::Bool = false
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
    s3_list_with_stats([pred,] bucket; prefix="", config=DEFAULT_CONFIG[]) -> Vector{S3Entry}

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
        prefix::AbstractString = "", config::Config = DEFAULT_CONFIG[], verbose::Bool = false
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
    s3_list([pred,] bucket; prefix="", config=DEFAULT_CONFIG[]) -> Vector{LazyS3Blob}

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

function _write_rclone_config(io::IO, c::Config)
    return write(
        io, """
        [$RCLONE_REMOTE]
        type = s3
        provider = AWS
        access_key_id = $(c.s3_access_key_id)
        secret_access_key = $(c.s3_secret_access_key)
        region = $(c.s3_region)
        location_constraint = $(c.s3_region)
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
function _with_rclone(f, config::Config)
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
