@everywhere function pushwithlock!(circdq, what)
    withlock(circdq.lck) do
        push!(circdq, what)
    end
end

@everywhere function shiftwithlock!(circdq)
    withlock(circdq.lck) do
        shift!(circdq)
    end
end

@everywhere function popwithlock!(circdq)
    withlock(circdq.lck) do
        pop!(circdq)
    end
end

function test_shared_circdq()
    println("testing circular deque")
    circdq = SharedCircularDeque{Int}("testq", 10)
    println("    resetting and...")
    delete!(circdq)
    println("    ...creating new")
    circdq = SharedCircularDeque{Int}("testq", 10)

    try
        W = workers()
        println("    workers: ", W)
        for w in W
           remotecall_fetch(()->circdq=SharedCircularDeque{Int}("testq", 10), w)
        end
        println("    created on workers")

        @test length(circdq) == 0

        remotecall_fetch(()->pushwithlock!(circdq, 2), W[1])
        @test length(circdq) == 1
        remotecall_fetch(()->pushwithlock!(circdq, 3), W[2])
        @test length(circdq) == 2

        remotecall_fetch(()->shiftwithlock!(circdq), W[1])
        @test length(circdq) == 1
        remotecall_fetch(()->popwithlock!(circdq), W[2])
        @test length(circdq) == 0
        println("    test done")
    finally
        println("    deleting...")
        delete!(circdq)
        println("    done.")
    end
end
