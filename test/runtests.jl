addprocs(2)

@everywhere using SharedDataStructures
@everywhere using Semaphores
using Base.Test

include("test_shared_circdq.jl")
include("test_shm_dict.jl")

test_shared_circdq()
test_shm_dict()
