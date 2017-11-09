"""
SharedCircularDeque{T}(n)

Create a double-ended queue of maximum capacity `n`, implemented as a circular buffer. The element type is `T`.
The data buffers are shared memory segments, accessible across processes on the same physical node.

Instances can be serialized and deserialized or created afresh using identical name and capacity.

Methods on the datastructure itself are not locked 
    - to avoid deadlock due to internal recursive calls
    - to enable efficient batched calls
However they can be locked by the caller using the `withlock(q.lck) do ... end` syntax.
"""
struct SharedCircularDeque{T}
    name::String
    buffer::SharedVector{T}
    state::SharedVector{Int} # capacity, n, first, last
    lck::NamedSemaphore # lock operations between processes
end

const CAP = 1
const LEN = 2
const FST = 3
const LST = 4

function SharedCircularDeque{T}(name::String, n::Int) where {T}
    buffer = shm_mmap_array(T, (n,), name*"buffer", JL_O_CREAT | JL_O_RDWR)
    state = shm_mmap_array(T, (4,), name*"state", JL_O_CREAT | JL_O_RDWR)
    state[CAP] = n # capacity
    state[LEN] = 0 # n
    state[FST] = 1 # first
    state[LST] = n # last
    lck = NamedSemaphore(name*"lock")
    SharedCircularDeque{T}(name, buffer, state, lck)
end

function Base.hash(D::SharedCircularDeque, h::UInt)
    h += 0xe4fbea67fe10ce78 % UInt
    h = hash(D.name, h)
end

Base.length(D::SharedCircularDeque) = D.state[LEN]
Base.eltype(::Type{SharedCircularDeque{T}}) where {T} = T
capacity(D::SharedCircularDeque) = D.state[CAP]

function Base.empty!(D::SharedCircularDeque)
    D.state[LEN] = 0
    D.state[FST] = 1
    D.state[LST] = D.state[CAP]
    D
end

function Base.delete!(D::SharedCircularDeque)
    shm_unlink(D.name*"buffer")
    shm_unlink(D.name*"state")
    delete!(D.lck)
    nothing
end

Base.isempty(D::SharedCircularDeque) = D.state[LEN] == 0

@inline function front(D::SharedCircularDeque)
    @boundscheck D.state[LEN] > 0 || throw(BoundsError())
    D.buffer[D.state[FST]]
end

@inline function back(D::SharedCircularDeque)
    @boundscheck D.state[LEN] > 0 || throw(BoundsError())
    D.buffer[D.state[LST]]
end

@inline function Base.push!(D::SharedCircularDeque, v)
    @boundscheck D.state[LEN] < D.state[CAP] || throw(BoundsError()) # prevent overflow
    D.state[LEN] += 1
    tmp = D.state[LST]+1
    D.state[LST] = ifelse(tmp > D.state[CAP], 1, tmp)  # wraparound
    @inbounds D.buffer[D.state[LST]] = v
    D
end

@inline function Base.pop!(D::SharedCircularDeque)
    v = back(D)
    D.state[LEN] -= 1
    tmp = D.state[LST] - 1
    D.state[LST] = ifelse(tmp < 1, D.state[CAP], tmp)
    v
end

@inline function Base.unshift!(D::SharedCircularDeque, v)
    @boundscheck D.state[LEN] < D.state[CAP] || throw(BoundsError())
    D.state[LEN] += 1
    tmp = D.state[FST] - 1
    D.state[FST] = ifelse(tmp < 1, D.state[CAP], tmp)
    @inbounds D.buffer[D.state[FST]] = v
    D
end

@inline function Base.shift!(D::SharedCircularDeque)
    v = front(D)
    D.state[LEN] -= 1
    tmp = D.state[FST] + 1
    D.state[FST] = ifelse(tmp > D.state[CAP], 1, tmp)
    v
end

# getindex sans bounds checking
@inline function _unsafe_getindex(D::SharedCircularDeque, i::Integer)
    j = D.state[FST] + i - 1
    if j > D.state[CAP]
        j -= D.state[CAP]
    end
    @inbounds ret = D.buffer[j]
    return ret
end

@inline function Base.getindex(D::SharedCircularDeque, i::Integer)
    @boundscheck 1 <= i <= D.state[LEN] || throw(BoundsError())
    return _unsafe_getindex(D, i)
end

# Iteration via getindex
@inline Base.start(d::SharedCircularDeque) = 1
@inline Base.next(d::SharedCircularDeque, i) = (_unsafe_getindex(d, i), i+1)
@inline Base.done(d::SharedCircularDeque, i) = i == d.state[LEN] + 1

function Base.show(io::IO, D::SharedCircularDeque{T}) where T
    print(io, "SharedCircularDeque{$T}([")
    for i = 1:length(D)
        print(io, D[i])
        i < length(D) && print(io, ',')
    end
    print(io, "])")
end
