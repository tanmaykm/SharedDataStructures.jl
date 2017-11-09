module SharedDataStructures

using Semaphores
using Base: shm_mmap_array, shm_unlink, JL_O_CREAT, JL_O_RDWR
import Base: hash, length, eltype, empty!, delete!, isempty, push!, pop!, unshift!, shift!, getindex, start, next, done, show

include("shared_circdq.jl")

export SharedCircularDeque
export hash, length, eltype, empty!, delete!, isempty, push!, pop!, unshift!, shift!, getindex, start, next, done, show

end # module
