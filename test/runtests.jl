using Appose
using SharedArrays
using Test

@testset "Appose.jl Shared Arrays" begin
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

@testset "TaskStatus enum" begin
    @test is_finished(COMPLETE)
    @test is_finished(FAILED)
    @test !is_finished(RUNNING)
    @test is_error(FAILED)
    @test !is_error(COMPLETE)
end


@testset "Appose.jl Concurrent tasks on same worker" begin
    in, out = Appose.launch_python_apposed()
    t1 = Threads.@spawn Appose.create_python_shared_memory(in, out, Int32, (4,))
    t2 = Threads.@spawn Appose.create_python_shared_memory(in, out, Int32, (4,))
    a = fetch(t1)
    b = fetch(t2)
    @test first(a) == 123
    @test first(b) == 123
end
