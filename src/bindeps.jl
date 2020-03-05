# discovering binary CUDA dependencies

using Pkg, Pkg.Artifacts
using Libdl


## global state

const __dirs = Ref{Vector{String}}()
const __version = Ref{VersionNumber}()

# paths
const __nvdisasm = Ref{String}()
const __libcupti = Ref{String}()
const __libnvtx = Ref{String}()
const __libdevice = Ref{String}()
const __libcudadevrt = Ref{String}()

# device compatibility
const __target_support = Ref{Vector{VersionNumber}}()
const __ptx_support = Ref{Vector{VersionNumber}}()


## discovery

# NOTE: we don't use autogenerated JLLs, because we have multiple artifacts and need to
#       decide at run time (i.e. not via package dependencies) which one to use.
const cuda_artifacts = Dict(
    v"10.2" => ()->artifact"CUDA10.2",
    v"10.1" => ()->artifact"CUDA10.1",
    v"10.0" => ()->artifact"CUDA10.0",
    v"9.2"  => ()->artifact"CUDA9.2",
    v"9.0"  => ()->artifact"CUDA9.0",
)

# try use CUDA from an artifact
function use_artifact_cuda()
    @debug "Trying to use artifacts..."

    # select compatible artifacts
    if haskey(ENV, "JULIA_CUDA_VERSION")
        wanted_version = VersionNumber(ENV["JULIA_CUDA_VERSION"])
        filter!(((version,artifact),) -> version == wanted_version, cuda_artifacts)
    else
        driver_version = CUDAdrv.release()
        filter!(((version,artifact),) -> version <= driver_version, cuda_artifacts)
    end

    # download and install
    artifact = nothing
    for release in sort(collect(keys(cuda_artifacts)); rev=true)
        try
            artifact = (release=release, dir=cuda_artifacts[release]())
            break
        catch
        end
    end
    if artifact == nothing
        @debug "Could not find a compatible artifact."
        return false
    end
    __dirs[] = [artifact.dir]

    # utilities to look up stuff in the artifact (at known locations, so not using CUDAapi)
    get_binary(name) = joinpath(artifact.dir, "bin", Sys.iswindows() ? "$name.exe" : name)
    function get_library(name)
        filename = if Sys.iswindows()
            "$name.dll"
        elseif Sys.isapple()
            "lib$name.dylib"
        else
            "lib$name.so"
        end
        joinpath(artifact.dir, Sys.iswindows() ? "bin" : "lib", filename)
    end
    get_static_library(name) = joinpath(artifact.dir, "lib", Sys.iswindows() ? "$name.lib" : "lib$name.a")
    get_file(path) = joinpath(artifact.dir, path)

    __nvdisasm[] = get_binary("nvdisasm")
    @assert isfile(__nvdisasm[])
    __version[] = parse_toolkit_version(__nvdisasm[])

    # Windows libraries are tagged with the CUDA release
    long = "$(artifact.release.major)$(artifact.release.minor)"
    short = artifact.release >= v"10.1" ? string(artifact.release.major) : long

    __libcupti[] = get_library(Sys.iswindows() ? "cupti64_$long" : "cupti")
    __libnvtx[] = get_library(Sys.iswindows() ? "nvToolsExt64_1" : "nvToolsExt")

    __libcudadevrt[] = get_static_library("cudadevrt")
    @assert isfile(__libcudadevrt[])
    __libdevice[] = get_file(joinpath("share", "libdevice", "libdevice.10.bc"))
    @assert isfile(__libdevice[])

    @debug "Using CUDA $(__version[]) from an artifact at $(artifact.dir)"
    return true
end

# try to use CUDA from a local installation
function use_local_cuda()
    @debug "Trying to use local installation..."

    cuda_dirs = find_toolkit()
    __dirs[] = cuda_dirs

    __nvdisasm[] = find_cuda_binary("nvdisasm")
    if __nvdisasm[] === nothing
        @debug "Could not find nvdisasm"
        return false
    end
    cuda_version = parse_toolkit_version(__nvdisasm[])
    __version[] = cuda_version

    cupti_dirs = map(dir->joinpath(dir, "extras", "CUPTI"), cuda_dirs) |> x->filter(isdir,x)
    __libcupti[] = find_cuda_library("cupti", [cuda_dirs; cupti_dirs], [cuda_version])
    __libnvtx[] = find_cuda_library("nvtx", cuda_dirs, [v"1"])

    __libcudadevrt[] = find_libcudadevrt(cuda_dirs)
    if __libcudadevrt[] === nothing
        @debug "Could not find libcudadevrt"
        return false
    end
    __libdevice[] = find_libdevice(cuda_dirs)
    if __libdevice[] === nothing
        @debug "Could not find libdevice"
        return false
    end

    @debug "Found local CUDA $(cuda_version) at $(join(cuda_dirs, ", "))"
    return true
end


## initialization

const __initialized__ = Ref{Union{Nothing,Bool}}(nothing)

"""
    functional(show_reason=false)

Check if the package has been initialized successfully and is ready to use.

This call is intended for packages that support conditionally using an available GPU. If you
fail to check whether CUDA is functional, actual use of functionality might warn and error.
"""
function functional(show_reason::Bool=false)
    if __initialized__[] === nothing
        __runtime_init__(show_reason)
    end
    __initialized__[]
end

function __runtime_init__(show_reason::Bool)
    __initialized__[] = false

    # if any dependent GPU package failed, expect it to have logged an error and bail out
    if !CUDAdrv.functional(show_reason)
        show_reason && @warn "CUDAnative.jl did not initialize because CUDAdrv.jl failed to"
        return
    end

    if Base.libllvm_version != LLVM.version()
        show_reason && @error("LLVM $(LLVM.version()) incompatible with Julia's LLVM $(Base.libllvm_version)")
        return
    end


    # CUDA toolkit

    if parse(Bool, get(ENV, "JULIA_CUDA_USE_BINARYBUILDER", "true"))
        __initialized__[] = use_artifact_cuda()
    end

    if !__initialized__[]
        __initialized__[] = use_local_cuda()
    end

    if !__initialized__[]
        show_reason && @error "Could not find a suitable CUDA installation"
        return
    end

    if release() < v"9"
        @warn "CUDAnative.jl only supports CUDA 9.0 or higher (your toolkit provides CUDA $(release()))"
    elseif release() > CUDAdrv.release()
         @warn """You are using CUDA toolkit $(release()) with a driver that only supports up to $(CUDAdrv.release()).
                  It is recommended to upgrade your driver, or switch to automatic installation of CUDA."""
    end


    # device compatibility

    llvm_support = llvm_compat()
    cuda_support = cuda_compat()

    __target_support[] = sort(collect(llvm_support.cap ∩ cuda_support.cap))
    isempty(__target_support[]) && error("Your toolchain does not support any device capability")

    __ptx_support[] = sort(collect(llvm_support.ptx ∩ cuda_support.ptx))
    isempty(__ptx_support[]) && error("Your toolchain does not support any PTX ISA")

    @debug("Toolchain with LLVM $(LLVM.version()), CUDA driver $(CUDAdrv.version()) and toolkit $(CUDAnative.version()) supports devices $(verlist(__target_support[])); PTX $(verlist(__ptx_support[]))")
end


## getters

macro initialized(ex)
    quote
        @assert functional(true) "CUDAnative.jl is not functional"
        $(esc(ex))
    end
end

"""
    prefix()

Returns the installation prefix directories of the CUDA toolkit in use.
"""
prefix() = @initialized(__dirs[])

"""
    version()

Returns the version of the CUDA toolkit in use.
"""
version() = @initialized(__version[])

"""
    release()

Returns the CUDA release part of the version as returned by [`version`](@ref).
"""
release() = @initialized(VersionNumber(__version[].major, __version[].minor))

nvdisasm() = @initialized(__nvdisasm[])
libcupti() = @initialized(__libcupti[])
libnvtx() = @initialized(__libnvtx[])
libdevice() = @initialized(__libdevice[])
libcudadevrt() = @initialized(__libcudadevrt[])

target_support() = @initialized(__target_support[])
ptx_support() = @initialized(__ptx_support[])