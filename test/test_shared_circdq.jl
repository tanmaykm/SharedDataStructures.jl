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

function splicewithlock(circdq)
    withlock(circdq.lck) do
        push!(circdq, 1)
        push!(circdq, 2)
        push!(circdq, 3)
        push!(circdq, 4)
        push!(circdq, 5)

        @test typeof(circdq[1:4]) == Vector{Int}
        @test length(circdq[1:end]) == length(circdq)

        @test splice!(circdq, 3) == 3
        @test splice!(circdq, 3) == 4
        @test splice!(circdq, 1) == 1
        @test splice!(circdq, 1) == 2
        @test splice!(circdq, 1) == 5
        @test length(circdq) == 0
    end
end

function test_shared_circdq()
    path = pwd()
    println("testing circular deque")
    master_circdq = SharedCircularDeque{Int}(path, 10; create=true)
    println("    closing and...")
    close(master_circdq)
    println("    deleting and...")
    delete!(master_circdq)
    println("    ...creating new")
    master_circdq = SharedCircularDeque{Int}(path, 10; create=true)

    try
        W = workers()
        println("    workers: ", W)
        for w in W
            remotecall_wait(()->(global circdq=SharedCircularDeque{Int}(path, 10); nothing), w)
        end
        println("    created on workers")

        @test length(master_circdq) == 0
        splicewithlock(master_circdq)

        remotecall_wait(()->(pushwithlock!(circdq, 2); nothing), W[1])
        @test remotecall_fetch(()->length(circdq), W[1]) == 1
        @test length(master_circdq) == 1
        @test 2 in master_circdq
        @test !(3 in master_circdq)
        remotecall_wait(()->(pushwithlock!(circdq, 3); nothing), W[2])
        @test remotecall_fetch(()->length(circdq), W[2]) == 2
        @test length(master_circdq) == 2
        @test 3 in master_circdq
        @test !(4 in master_circdq)
        remotecall_wait(()->(shiftwithlock!(circdq); nothing), W[1])
        @test remotecall_fetch(()->length(circdq), W[1]) == 1
        @test length(master_circdq) == 1
        @test !(2 in master_circdq)
        remotecall_wait(()->(popwithlock!(circdq); nothing), W[2])
        @test remotecall_fetch(()->length(circdq), W[2]) == 0
        @test length(master_circdq) == 0
        @test !(3 in master_circdq)

        splicewithlock(master_circdq)

        println("    test done")
        println("    closing...")
        close(master_circdq)
        remotecall_wait(()->close(circdq), W[1])
        remotecall_wait(()->close(circdq), W[2])
    finally
        println("    deleting...")
        delete!(master_circdq)
        println("    done.")
    end
end
