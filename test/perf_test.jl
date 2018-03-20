using SharedDataStructures
using Semaphores
using Base.Test
using BenchmarkTools

function deletewithlock!(D, key)
    withlock(D.lck) do
        SharedDataStructures.delete!(D, key)
    end
end

function setindexwithlock!(D, val, key)
    withlock(D.lck) do
        SharedDataStructures.setindex!(D, val, key)
    end
end

function getindexwithlock(D, key)
    withlock(D.lck) do
        SharedDataStructures.getindex(D, key)
    end
end

function test_shm_dict(keepkeys::Bool)
    path = pwd()
    master_shmdict = ShmDict(path, 10^3, 64; create=true, keepkeys=keepkeys)
    close(master_shmdict)
    delete!(master_shmdict)
    master_shmdict = ShmDict(path, 10^3, 64; create=true)

    try
        for N in 1:10^3
            for idx in 1:10^3
                str = string(idx)
                setindexwithlock!(master_shmdict, str, str)
                @test haskey(master_shmdict, str)
                @test getindexwithlock(master_shmdict, str) == convert(Vector{UInt8}, str)
            end
        end
        close(master_shmdict)
    finally
        delete!(master_shmdict)
    end
end

println("with no key stored:")
@btime test_shm_dict(false)
println("with key stored:")
@btime test_shm_dict(true)
