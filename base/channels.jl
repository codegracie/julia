# This file is a part of Julia. License is MIT: http://julialang.org/license

abstract AbstractChannel

type Channel{T} <: AbstractChannel
    cond_take::Condition    # waiting for data to become available
    cond_put::Condition     # waiting for a writeable slot
    state::Symbol

    data::Array{T,1}
    sz_max::UInt            # maximum size of channel

    # Used when sz_max == 0, i.e., an unbuffered channel.
    takers::Array{Condition}

    function Channel(sz::Float64)
        if sz == Inf
            Channel{T}(typemax(UInt))
        else
            Channel{T}(convert(UInt, sz))
        end
    end
    function Channel(sz::Integer)
        if sz < 0
            throw(ArgumentError("Channel size must be either 0, a positive integer or Inf"))
        end
        new(Condition(), Condition(), :open, Array{T}(0), sz, Array{Condition}(0))
    end
end

Channel(sz) = Channel{Any}(sz)

closed_exception() = InvalidStateException("Channel is closed.", :closed)

const UNBUFFERED_CHANNEL = Type{Val{false}}
const BUFFERED_CHANNEL = Type{Val{true}}
isbuffered(c::Channel) = c.sz_max==0 ? Val{false} : Val{true}

"""
    close(c::Channel)

Closes a channel. An exception is thrown by:

* `put!` on a closed channel.
* `take!` and `fetch` on an empty, closed channel.
"""
function close(c::Channel)
    c.state = :closed
    notify_error(c::Channel, closed_exception())
    nothing
end
isopen(c::Channel) = (c.state == :open)

type InvalidStateException <: Exception
    msg::AbstractString
    state::Symbol
end

"""
    put!(c::Channel, v)

Appends an item `v` to the channel `c`. Blocks if the channel is full.

For unbuffered channels, blocks until a `take!` is performed by a different
task.
"""
function put!(c::Channel, v)
    !isopen(c) && throw(closed_exception())
    put!(c,v,isbuffered(c))
end

function put!(c::Channel, v, ::BUFFERED_CHANNEL)
    while length(c.data) == c.sz_max
        wait(c.cond_put)
    end
    push!(c.data, v)
    notify(c.cond_take, nothing, true, false)  # notify all, since some of the waiters may be on a "fetch" call.
    v
end

# 0-sized channel
function put!(c::Channel, v, ::UNBUFFERED_CHANNEL)
    while length(c.takers) == 0
        notify(c.cond_take, nothing, true, false)  # Required to handle wait() on 0-sized channels
        wait(c.cond_put)
    end
    cond_taker = shift!(c.takers)
    notify(cond_taker, v, false, false)
    v
end

push!(c::Channel, v) = put!(c, v)

"""
    fetch(c::Channel)

Waits for and gets the first available item from the channel. Does not
remove the item. `fetch` is unsupported on an unbuffered (0-size) channel.
"""
fetch(c::Channel) = fetch(c, isbuffered(c))
function fetch(c::Channel, ::BUFFERED_CHANNEL)
    wait(c)
    c.data[1]
end
fetch(c::Channel, ::UNBUFFERED_CHANNEL) = throw(ErrorException("`fetch` is not supported on an unbuffered Channel."))


"""
    take!(c::Channel)

Removes and returns a value from a `Channel`. Blocks till data is available.

For unbuffered channels, blocks until a `put!` is performed by a different
task.
"""
take!(c::Channel) = take!(c, isbuffered(c))
function take!(c::Channel, ::BUFFERED_CHANNEL)
    wait(c)
    v = shift!(c.data)
    notify(c.cond_put, nothing, false, false) # notify only one, since only one slot has become available for a put!.
    v
end

shift!(c::Channel) = take!(c)

# 0-size channel
function take!(c::Channel, ::UNBUFFERED_CHANNEL)
    !isopen(c) && throw(closed_exception())
    cond_taker = Condition()
    push!(c.takers, cond_taker)
    notify(c.cond_put, nothing, false, false)
    try
        return wait(cond_taker)
    catch e
        if isa(e, InterruptException)
            # remove self from the list of takers
            filter!(x -> x != cond_taker, c.takers)
        else
            rethrow(e)
        end
    end
end

"""
    isready(c::Channel)

Determine whether a `Channel` has a value stored to it. Returns
immediately, does not block.

For unbuffered channels returns `true` if there are tasks waiting
on a `put!`.
"""
isready(c::Channel) = n_avail(c, isbuffered(c)) > 0
n_avail(c::Channel, ::BUFFERED_CHANNEL) = length(c.data)
n_avail(c::Channel, ::UNBUFFERED_CHANNEL) = n_waiters(c.cond_put)

function wait(c::Channel)
    while !isready(c)
        !isopen(c) && throw(closed_exception())
        wait(c.cond_take)
    end
    nothing
end

function notify_error(c::Channel, err)
    notify_error(c.cond_take, err)
    notify_error(c.cond_put, err)
    foreach(x->notify_error(x, err), c.takers)
end

eltype{T}(::Type{Channel{T}}) = T

show(io::IO, c::Channel) = print(io, "$(typeof(c))(sz_max:$(c.sz_max),sz_curr:$(n_avail(c, isbuffered(c))))")

start{T}(c::Channel{T}) = Ref{Nullable{T}}()
function done(c::Channel, state::Ref)
    try
        # we are waiting either for more data or channel to be closed
        state[] = take!(c)
        return false
    catch e
        if isa(e, InvalidStateException) && e.state==:closed
            return true
        else
            rethrow(e)
        end
    end
end
next{T}(c::Channel{T}, state) = (v=get(state[]); state[]=nothing; (v, state))

iteratorsize{C<:Channel}(::Type{C}) = SizeUnknown()
