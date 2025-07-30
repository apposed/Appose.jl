module Appose

using JSON3
using UUIDs
using SharedArrays
# TODO: Make into an extension package
using CondaPkg

function launch_python_apposed()
    python_command = "import appose.python_worker; appose.python_worker.main()"
    to_python = Pipe()
    from_python = Pipe()
    err_python = Pipe()
    CondaPkg.withenv() do
        pl = pipeline(
            `python -c $python_command`,
            stdin=to_python,
            stdout=from_python,
            stderr=err_python
        )
        p = run(pl, wait=false)
    end
    Threads.@spawn while true
        println(stderr, readline(err_python))
    end
    output = Channel()
    Threads.@spawn while true
        push!(output, JSON3.read(readline(from_python)))
    end
    input = Channel()
    Threads.@spawn while true
        command = take!(input)
        println(to_python, JSON3.write(command))
    end
    return (; input, output)
end

function appose_execute(script, input=Dict{String,Any}())
    return Dict{String, Any}(
        "task" => string(uuid4()),
        "requestType" => "EXECUTE",
        "script" => script,
        "inputs" => input
    )
end

"""
create_python_shared_memory(
    input::Channel,
    output::Channel,
    dtype::Type,
    size::Dims
)

Function to test creation of Python Shared Memory
"""
function create_python_shared_memory(
    input::Channel,
    output::Channel,
    dtype::Type,
    size::Dims
)
    # Transform data for Python script
    python_rsize = sizeof(dtype) * prod(size)
    # TODO: Map Julia types to Numpy types via PythonCall?
    python_dtype = lowercase(string(dtype))
    python_size = reverse(size)
    python_zeros = zero.(size)

    # Indentation matters here
    python_command = """
    import appose
    shm = appose.SharedMemory(create = True, rsize=$python_rsize)
    data = appose.NDArray("$python_dtype", $python_size, shm)
    data.ndarray()[$python_zeros] = 123 # testing
    task.outputs["result"] = data
    """
    put!(input, appose_execute(python_command))

    # Handle LAUNCH message
    launch = take!(output)::JSON3.Object
    if launch["responseType"] == "FAILURE"
        error("Appose Failure: " * launch["error"])
    elseif launch["responseType"] == "LAUNCH"
        @info "Launched" launch["task"]
    else
        error("Unknown Appose Response: " * string(launch))
    end

    # Handle COMPLETION message
    completion = take!(output)
    if completion["responseType"] == "FAILURE"
        error("Appose Failure: " * completion["error"])
    elseif completion["responseType"] == "COMPLETION"
        result = completion.outputs.result
    else
        error("Unknown Appose Response: " * string(launch))
    end

    # TODO: Generalize to Windows
    arr = SharedArray{dtype}(get_shared_memory_prefix() * result.shm.name, size)
    return arr
end

function get_shared_memory_prefix()
    if Sys.islinux()
        return "/dev/shm/"
    elseif Sys.iswindows()
        return ""
    elseif Sys.isunix()
        return "/"
    end
end

function create_python_shared_memory(dtype, size)
    in, out = launch_python_apposed()
    return create_python_shared_memory(in, out, dtype, size)
end

end # module Appose
