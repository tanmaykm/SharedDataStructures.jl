
@everywhere function deletewithlock!(D, key)
    withlock(D.lck) do
        SharedDataStructures.delete!(D, key)
    end
end

@everywhere function setindexwithlock!(D, val, key)
    withlock(D.lck) do
        SharedDataStructures.setindex!(D, val, key)
    end
end

@everywhere function getindexwithlock!(D, key)
    withlock(D.lck) do
        SharedDataStructures.getindex(D, key)
    end
end

function test_shm_dict(keepkeys::Bool)
    path = pwd()
    println("testing shm dict with keepkeys=", keepkeys)
    master_shmdict = ShmDict(path, 10^3, 128; create=true, keepkeys=keepkeys)
    println("    closing and...")
    close(master_shmdict)
    println("    deleting and...")
    delete!(master_shmdict)
    println("    ...creating new")
    master_shmdict = ShmDict(path, 10^3, 128; create=true)

    try
        W = workers()
        println("    workers: ", W)
        for w in W
            remotecall_wait(()->(global shmdict=ShmDict(path, 10^3, 128); nothing), w)
        end
        println("    created on workers")

        remotecall_wait(()->(setindexwithlock!(shmdict, "abc", "123"); nothing), W[1])
        remotecall_wait(()->(setindexwithlock!(shmdict, "def", "456"); nothing), W[2])
        @test haskey(master_shmdict, "123")
        @test haskey(master_shmdict, "456")
        @test String(copy(master_shmdict["123"])) == "abc"
        @test String(copy(master_shmdict["456"])) == "def"

        remotecall_wait(()->(setindexwithlock!(shmdict, "abc", "456"); nothing), W[1])
        remotecall_wait(()->(setindexwithlock!(shmdict, "def", "123"); nothing), W[2])
        @test haskey(master_shmdict, "123")
        @test haskey(master_shmdict, "456")
        @test String(copy(master_shmdict["456"])) == "abc"
        @test String(copy(master_shmdict["123"])) == "def"

        @test String(copy(remotecall_fetch(()->getindexwithlock!(shmdict, "456"), W[1]))) == "abc"
        @test String(copy(remotecall_fetch(()->getindexwithlock!(shmdict, "123"), W[2]))) == "def"

        remotecall_wait(()->(deletewithlock!(shmdict, "123"); nothing), W[1])
        @test !haskey(master_shmdict, "123")
        @test haskey(master_shmdict, "456")
        remotecall_wait(()->(deletewithlock!(shmdict, "456"); nothing), W[1])
        @test !haskey(master_shmdict, "456")

        @test_throws ErrorException master_shmdict["123"] = zeros(UInt8, 1024)
        if keepkeys
            @test_throws ErrorException master_shmdict[randstring(128)] = zeros(UInt8, 1024)
        end

        println("    test done")
        println("    closing...")
        close(master_shmdict)
        remotecall_wait(()->close(shmdict), W[1])
        remotecall_wait(()->close(shmdict), W[2])
    finally
        println("    deleting...")
        delete!(master_shmdict)
        println("    done.")
    end
end
