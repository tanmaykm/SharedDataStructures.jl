__precompile__(true)

module SharedDataStructures

using Semaphores
using Base: shm_mmap_array, shm_unlink, JL_O_CREAT, JL_O_RDWR
import Base: hash, length, eltype, empty!, delete!, isempty, push!, pop!, unshift!, shift!, getindex, start, next, done, show, close, endof, getindex, setindex!, haskey

include("sysv_shm.jl")
include("shared_circdq.jl")
include("shm_dict.jl")

export SharedCircularDeque, ShmDict
export hash, length, eltype, empty!, delete!, isempty, push!, pop!, unshift!, shift!, getindex, start, next, done, show, capacity, close

end # module
