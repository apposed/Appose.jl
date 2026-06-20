module Appose
export TaskStatus, INITIAL, QUEUED, RUNNING, COMPLETE, CANCELED, FAILED, CRASHED, is_error, is_finished, wait_for, set_status!, Service, start_python_service, register_task!, lookup_task, execute!, dispatch_loop!, handle_response!, close!

# We don't export Task, because that collides with Base.Task. Reference Appose.Task instead.

using JSON3
using UUIDs
using SharedArrays
# TODO: Make into an extension package
using CondaPkg

@enum TaskStatus begin
    # Order / Int value is used for status priority sorting.
    INITIAL
    QUEUED
    RUNNING
    COMPLETE
    CANCELED
    FAILED
    CRASHED
end

is_error(s::TaskStatus)::Bool = s in (CANCELED, FAILED, CRASHED)
is_finished(s::TaskStatus)::Bool = s == COMPLETE || is_error(s)
status_priority(s::TaskStatus)::Int = is_error(s) ? 4 : Int(s)


mutable struct Task
    ## An Appose *task* is an asynchronous operation performed by its
    ## associated Appose *service*. It is analogous to an asyncio.Future.
    ## This struct mirrors the python task in service.py.
    # service
    uuid::String
    script::String
    # queue
    inputs::Dict{String, Any}
    outputs::Dict{String, Any}
    status::TaskStatus
    error::Union{String, Nothing}
    listeners::Vector{Function}
    cv::Threads.Condition
end

function Task(script::String;
              inputs::Dict{String, Any} = Dict{String, Any}(),
              uuid::String = string(uuid4()))
    Task(uuid, script, inputs, Dict{String, Any}(), INITIAL,
         nothing, Function[], Threads.Condition())
end

## The Appose Service allows us to dispatch on the UUIDs of tasks,
## and run tasks asychronously. This is important because the
## worker can be multithreaded.
mutable struct Service
    ## An Appose *service* provides access to a linked Appose *worker* running
    ## in a different process. Using the service, programs create Appose *tasks*
    ## that run asynchronously in the worker process, which notifies the
    ## service of updates via communication over pipes (stdin and stdout).
    process::Base.Process
    input::Channel
    output::Channel
    tasks::Dict{String, Task}
    tasks_lock::ReentrantLock
    listener_task::Union{Base.Task, Nothing}
end

function Service(process::Base.Process, input::Channel, output::Channel)
    Service(process, input, output, Dict{String, Task}(), ReentrantLock(), nothing)
end

function set_status!(t::Task, s::TaskStatus)
    lock(t.cv) do
        t.status = s
        if is_finished(s)
            notify(t.cv; all=true)
        end
    end
end

function wait_for(t::Task)::Task
    ## Waits for this task to complete.
    ## Returns this task for method chaining.
    ## [TODO] Raises error if task fails, is canceled, or crashes.
    lock(t.cv) do
        while !is_finished(t.status)
            wait(t.cv)
        end
        if t.status != COMPLETE && is_error(t.status)
            #raise_error
        end
    end
    return t
end

function listen!(t::Task, listener::Function)
    # Registers a callback to be notified when task updates status.
    lock(t.cv) do
        if t.status != INITIAL
            error("In Appose.listen!: Attempting to add listener while Appose Task is not in INITIAL state")
        else
            push!(t.listeners, listener)
        end
    end
end

function start_python_service()::Service
    python_command = "import appose.python_worker; appose.python_worker.main()"
    to_python = Pipe()
    from_python = Pipe()
    err_python = Pipe()
    p = CondaPkg.withenv() do
        pl = pipeline(
            `python -c $python_command`,
            stdin=to_python,
            stdout=from_python,
            stderr=err_python
        )
        p = run(pl, wait=false)
    end
    
    # python stderr to Julia stderr
    errormonitor(
        Threads.@spawn while !eof(err_python)
        println(stderr, readline(err_python))
        end
    )
    
    output = Channel()  # __Claude recommended Channel{Any}(32), but I don't understand why.
    errormonitor(
        Threads.@spawn while !eof(from_python)
            l = readline(from_python)
            isempty(strip(l)) && continue
            local parsed
            try
               parsed = JSON3.read(l)
            catch e
               println(stderr, "$e: Invalid read from python: $l")
               # TODO: python collects invalid lines for diagnostics
               continue
            end
            push!(output, parsed)
        end
    )
    
    input = Channel()
    errormonitor(
        Threads.@spawn while true
        command = take!(input)
        println(to_python, JSON3.write(command))
        end
    )
    
    svc = Service(p, input, output)
    lt = errormonitor(
        Threads.@spawn dispatch_loop!(svc)
    )
    svc.listener_task = lt 
    return svc
end

function dispatch_loop!(svc::Service)
    # Pulls responses from the service and routes them to the appropirate tasks.
    # Runs in its own thread.
    while true
        local response, uuid
        try
            response = take!(svc.output) # output is JSON3.Object
            uuid = response[:task]
            if uuid === nothing
                continue
            end            
        catch e # Did channel close?
            e isa InvalidStateException ? break : rethrow()
        end
        task = lock(svc.tasks_lock) do
            get(svc.tasks, uuid, nothing)
        end
        if task === nothing
            continue
        end
        handle_response!(task, response)
    end
end

function register_task!(svc::Service, task::Task)
    ## Insert a task into the service's registry under its uuid.
    ## Do so safely by locking the service.
    lock(svc.tasks_lock) do
        svc.tasks[task.uuid] = task
    end
end

function lookup_task(svc::Service, uuid::AbstractString)::Union{Task, Nothing}
    ## Return task from service given its uuid.
    lock(svc.tasks_lock) do
        get(svc.tasks, String(uuid), nothing)
    end
end

function execute!(svc::Service, task::Task)
    ## Submit a new task to the service/worker
    ## Assumes the task has already been constructed with Task().
    ## We add the task to the service first to avoid dispatching a uuid that isn't in the table later.
    ## Todo: make a wrapper version which initializes the task given a script and inputs.
    register_task!(svc, task)
    set_status!(task, QUEUED)
    request = Dict(
        "task" => task.uuid,
        "requestType" => "EXECUTE",
        "script" => task.script,
        "inputs" => task.inputs,
    )
    put!(svc.input, request)
    return task
end

"""
   launch_python_apposed()::(; ::Channel, ::Channel)

Deprecating or rewriting this interface soon.
Please use Appose.Service for new code.
"""
function launch_python_apposed()
    python_command = "import appose.python_worker; appose.python_worker.main()"
    to_python = Pipe()
    from_python = Pipe()
    err_python = Pipe()
    p = CondaPkg.withenv() do
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


function appose_execute(script, inputs=Dict{String,Any}())::Dict #::Task
    # Included for backwards compatibility during refactor. Previously returned Dict().
    Task(script; inputs=inputs) # to do: remove Dict block below.
    return Dict{String, Any}(
        "task" => string(uuid4()),
        "requestType" => "EXECUTE",
        "script" => script,
        "inputs" => inputs
    )
end

function handle_response!(task::Task, response)
    ## Route a single response by its type,
    ## Updates the task
    rtype = get(response, :responseType, nothing)
    if rtype == nothing
        return
    end
    if rtype == "LAUNCH"
        set_status!(task, RUNNING)
    elseif rtype=="UPDATE"
        ## TODO: python runs listeners
    elseif rtype=="COMPLETION"
        d = get(response, :outputs, nothing)
        if !(d === nothing)
            lock(task.cv) do
                for (key, value) in d
                    task.outputs[String(key)] = value
                end
            end
        end
        # Order matters: set_status! calls notify(task.cv),
        # so set all task non-statuses first.
        set_status!(task, COMPLETE)
    elseif rtype == "FAILURE"
        lock(task.cv) do         
            task.error = String(get(response, :error, nothing))
        end
        # Order matters: set_status! calls notify(task.cv),
        # so set all task non-statuses first.
        set_status!(task, FAILED)
    elseif rtype == "CANCELATION"
        set_status!(task, CANCELED)
    end
    for listener in task.listeners
        listener(response)
    end
    if is_finished(task.status)
        lock(task.cv) do
            notify(task.cv)
        end
    end
end

"""
    close!(Appose.Service)

Closes the service without waiting for tasks to complete.
"""

function close!(svc::Service)
   ## TODO 
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
