module LazyFiles

using Downloads
using Rclone_jll

public Config, LazyS3Blob, LazyArtifact, s3_upload, s3_search, clear_from_cache,
       validate_s3_config, default_config!, config_from_env

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

# Resolve a cache path, refusing names that escape the cache directory (e.g. a
# blob name containing `..` or an absolute path).
function _checked_path(base::AbstractString, parts...)
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
    tmp = lp * ".partial"          # download out-of-place so an interrupted run never caches a partial
    r = _with_rclone(config) do make_cmd
        _run(make_cmd(`copyto $RCLONE_REMOTE:$(b.bucket)/$(b.name) $tmp`); verbose)
    end
    if !(r.ok && isfile(tmp))
        isfile(tmp) && rm(tmp; force = true)
        return nothing
    end
    mv(tmp, lp; force = true)
    return lp
end

"""
    a = LazyArtifact(; url, name)
    a()  -> resolves to a local path, downloading on a cache miss; `nothing` on failure

A handle to a file at an HTTP(S) `url`. Calling it returns the path to a local
copy (cached under `<cache>/_artifacts_/<name>`), downloading on first use.
Only `local_cache_dir` is required in the config — no S3 credentials.
"""
Base.@kwdef struct LazyArtifact <: AbstractLazyBlob
    url::String
    name::String
end

local_path(config::Config, a::LazyArtifact) = _checked_path(local_cache_dir(config), "_artifacts_", a.name)

function (a::LazyArtifact)(; config::Config = DEFAULT_CONFIG[], verbose::Bool = false, timeout::Real = ARTIFACT_TIMEOUT)
    is_valid_minimal_config(config) || error("local_cache_dir is not set")
    lp = local_path(config, a)
    isfile(lp) && return lp
    mkpath(dirname(lp))
    tmp = lp * ".partial"          # download out-of-place so an interrupted run never caches a partial
    try
        Downloads.download(a.url, tmp; timeout)
    catch e
        verbose && @warn "artifact download failed" url = a.url exception = e
        isfile(tmp) && rm(tmp; force = true)
        return nothing
    end
    isfile(tmp) || return nothing
    mv(tmp, lp; force = true)
    return lp
end

# ---------------------------------------------------------------------------
# Public operations
# ---------------------------------------------------------------------------

"""
    clear_from_cache(b; config=DEFAULT_CONFIG[]) -> Bool

Remove the local cached copy of `b`, if present. Returns `true` if a file was
removed, `false` if there was nothing cached.
"""
function clear_from_cache(b::AbstractLazyBlob; config::Config = DEFAULT_CONFIG[])
    lp = local_path(config, b)
    isfile(lp) || return false
    rm(lp; force = true)
    return true
end

function s3_upload(local_file, bucket, name = nothing; config::Config = DEFAULT_CONFIG[], verbose::Bool = false)
    validate_s3_config(config)
    isfile(local_file) || error("not a file: $local_file")
    name = isnothing(name) ? basename(local_file) : name
    r = _with_rclone(config) do make_cmd
        _run(make_cmd(`copyto $local_file $RCLONE_REMOTE:$bucket/$name --s3-no-check-bucket`); verbose)
    end
    r.ok || error("upload failed (rclone exit $(r.code)): $(strip(r.err))")
    return LazyS3Blob(; bucket, name)
end

"""
    s3_search(bucket, regex=nothing; config=DEFAULT_CONFIG[]) -> Vector{LazyS3Blob}

List objects in `bucket` (recursively) as `LazyS3Blob` handles. If `regex` is
given, only objects whose key matches are returned.
"""
function s3_search(bucket::String, regex::Union{Regex,Nothing} = nothing; config::Config = DEFAULT_CONFIG[], verbose::Bool = false)
    validate_s3_config(config)
    r = _with_rclone(config) do make_cmd
        _run(make_cmd(`lsf $RCLONE_REMOTE:$bucket --files-only -R`); verbose)
    end
    r.ok || error("search failed (rclone exit $(r.code)): $(strip(r.err))")
    names = [String(strip(l)) for l in split(r.out, '\n') if !isempty(strip(l))]
    isnothing(regex) || filter!(n -> occursin(regex, n), names)
    return [LazyS3Blob(; bucket, name) for name in names]
end

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
    proc = run(pipeline(cmd; stdout = out, stderr = err); wait = false)
    wait(proc)
    serr = String(take!(err))
    verbose && !isempty(serr) && @info "rclone stderr" serr
    return (; ok = success(proc), code = proc.exitcode, out = String(take!(out)), err = serr)
end

function _write_rclone_config(io::IO, c::Config)
    write(io, """
    [$RCLONE_REMOTE]
    type = s3
    provider = AWS
    access_key_id = $(c.s3_access_key_id)
    secret_access_key = $(c.s3_secret_access_key)
    region = $(c.s3_region)
    location_constraint = $(c.s3_region)
    """)
end

"""
    _with_rclone(f, config) -> f(make_cmd)

Write a temporary rclone config for `config` and call `f` with a closure
`make_cmd(args::Cmd) -> Cmd` that prepends the rclone binary and appends the
`--config` flag. The temp config is removed when `f` returns.
"""
function _with_rclone(f, config::Config)
    mktemp() do path, io
        _write_rclone_config(io, config)
        close(io)
        make_cmd(args::Cmd) = `$(rclone()) $args --config $path`
        f(make_cmd)
    end
end

end # module LazyFiles
