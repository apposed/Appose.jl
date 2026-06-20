using Appose
using SharedArrays
using Test

@testset "Appose.jl Python Service" begin
    svc = start_python_service()
    t = Appose.Task("task.outputs['answer'] = 6*7")
    execute!(svc,t)
    wait_for(t) # Test actually fails if you don't wait
    @test t.outputs["answer"] == 42

    # Test concurrent wait_for() on a single task.
    t = Appose.Task("task.outputs['nohang'] = 1")
    Appose.execute!(svc, t)
    done = Threads.Atomic{Bool}(false)
    waiter = Threads.@spawn begin
        Appose.wait_for(t)
        done[] = true
    end
    for _ in 1:10
        done[] && break
        sleep(0.01)
    end
    @test done[]  # False means it hung
    
    # 50 concurrent tasks on same service, confirm uuid dispatch
    tasks = [ Appose.Task(
        "import time, random; time.sleep(0.05*random.random()); task.outputs['v']=$i*2")
              for i in 1:50 ]
    for t in tasks
        execute!(svc,t)
    end
    for t in tasks
        wait_for(t)
    end
    wait_for(tasks[1]) # Shouldn't hang.
    for i in 1:length(tasks)
        @test tasks[i].outputs["v"] == i*2
    end

    # Test mix of success and failure
    tasks = [ Appose.Task(
        "import time, random; time.sleep(0.05*random.random()); task.outputs['sf']= 'even' if $i % 2 == 0 else odd") #Deliberate NameError
              for i in 1:50 ]
    for t in tasks
        execute!(svc,t)
    end
    for t in tasks
        wait_for(t)
    end
    wait_for(tasks[1]) # Shouldn't hang.
    for i in 1:length(tasks)
        if i % 2 == 0
            @test tasks[i].outputs["sf"] == "even"
        else
            @test occursin("NameError", tasks[1].error)
        end
        
    end

    
    
    # This tests closing the service. Run it last.
    # Not yet implemented.
    # closedtask = Appose.Task("import time; time.sleep(1); task.outputs['oops'] = 'finished'")
    #execute!(closedtask)
    #close!(svc)
    #wait_for(closedtask)
    
end


@testset "Many tasks complete" begin
    tasks = [Appose.Task("noop") for _ in 1:50]
    @async begin
        for t in shuffle(tasks)
            Appose.set_status!(t, Appose.COMPLETE)
        end
    end
    for t in tasks
        Appose.wait_for(t)
        @test t.status == Appose.COMPLETE
    end
end

@testset "Legacy concurrent tasks on same worker" begin
    in, out = Appose.launch_python_apposed()

    t1 = Threads.@spawn Appose.create_python_shared_memory(in, out, Int32, (4,))
    t2 = Threads.@spawn Appose.create_python_shared_memory(in, out, Int32, (4,))
    a = fetch(t1)
    b = fetch(t2)
    @test first(a) == 123
    @test first(b) == 123
end


@testset "Legacy Appose.jl" begin
    @testset "Shared Arrays" begin
        in, out = Appose.launch_python_apposed()
        for T in (Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64, Float32, Float64),#, Bool),
            _size in ((2,), (2,3), (2,3,4), (2,3,4,5))
            shared_arr = Appose.create_python_shared_memory(in, out, T, _size)
            @test size(shared_arr) == _size
            @test eltype(shared_arr) == T
            @test typeof(shared_arr) == SharedArray{T, length(_size)}
            @test first(shared_arr) == 123
        end
    end
end



@testset "TaskStatus enum" begin
    @test is_finished(COMPLETE)
    @test is_finished(FAILED)
    @test !is_finished(RUNNING)
    @test is_error(FAILED)
    @test !is_error(COMPLETE)
end

@testset "Task struct and wait_for" begin
    
    
    # Task with completion
    t = Appose.Task("#This task completes")
    @test t.status == Appose.INITIAL
    @test t.uuid != ""
    @test isempty(t.inputs)
    @test isempty(t.outputs)

    @async begin
        sleep(0.1)
        Appose.set_status!(t, Appose.COMPLETE)
    end

    Appose.wait_for(t)
    @test t.status == Appose.COMPLETE

    # Task with failure
    t = Appose.Task("#This task fails")
    @async begin
        sleep(0.05)
        t.error = "Task forced to fail."
        Appose.set_status!(t, Appose.FAILED)
    end
    Appose.wait_for(t)
    @test t.status == Appose.FAILED
    @test t.error == "Task forced to fail."
end

