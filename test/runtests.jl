addprocs(2)

@everywhere using SharedDataStructures
@everywhere using Semaphores
using Base.Test

include("test_shared_circdq.jl")

test_shared_circdq()
