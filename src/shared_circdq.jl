"""
SharedCircularDeque{T}(n)

Create a double-ended queue of maximum capacity `n`, implemented as a circular buffer. The element type is `T`.
The data buffers are shared memory segments, accessible across processes on the same physical node.

Instances can be serialized and deserialized or created afresh using identical path and capacity.

Methods on the datastructure itself are not locked 
    - to avoid deadlock due to internal recursive calls
    - to enable efficient batched calls
However they can be locked by the caller using the `withlock(q.lck) do ... end` syntax.
"""
struct SharedCircularDeque{T}
    path::String
    buffer::SysVSharedArray{T,1}
    state::SysVSharedArray{Int,1} # capacity, n, first, last
    lck::NamedSemaphore # lock operations between processes
end

const CAP = 1
const LEN = 2
const FST = 3
const LST = 4

function SharedCircularDeque{T}(path::String, capacity::Int; create::Bool=false) where {T}
    buffer = SysVSharedVector((path,1), capacity, T)
    state = SysVSharedVector((path,2), 4, Int)
    if create
        S = state.A
        S[CAP] = capacity # capacity
        S[LEN] = 0        # n
        S[FST] = 1        # first
        S[LST] = capacity # last
    end
    lck = NamedSemaphore("/$(hash(path))")
    SharedCircularDeque{T}(path, buffer, state, lck)
end

function Base.hash(D::SharedCircularDeque, h::UInt)
    h += 0xe4fbea67fe10ce78 % UInt
    h = hash(D.path, h)
end

Base.length(D::SharedCircularDeque) = D.state.A[LEN]
Base.eltype(::Type{SharedCircularDeque{T}}) where {T} = T
capacity(D::SharedCircularDeque) = D.state.A[CAP]

function Base.empty!(D::SharedCircularDeque)
    S = D.state.A
    S[LEN] = 0
    S[FST] = 1
    S[LST] = S[CAP]
    D
end

function Base.delete!(D::SharedCircularDeque)
    delete!(D.state)
    delete!(D.buffer)
    delete!(D.lck)
    nothing
end

function Base.close(D::SharedCircularDeque)
    close(D.state)
    close(D.buffer)
    close(D.lck)
    nothing
end

Base.isempty(D::SharedCircularDeque) = D.state.A[LEN] == 0

@inline function front(D::SharedCircularDeque)
    S = D.state.A
    @boundscheck S[LEN] > 0 || throw(BoundsError())
    D.buffer.A[S[FST]]
end

@inline function back(D::SharedCircularDeque)
    S = D.state.A
    @boundscheck S[LEN] > 0 || throw(BoundsError())
    D.buffer.A[S[LST]]
end

@inline function Base.push!(D::SharedCircularDeque, v)
    S = D.state.A
    @boundscheck S[LEN] < S[CAP] || throw(BoundsError()) # prevent overflow
    S[LEN] += 1
    tmp = S[LST]+1
    S[LST] = ifelse(tmp > S[CAP], 1, tmp)  # wraparound
    @inbounds D.buffer.A[S[LST]] = v
    D
end

@inline function Base.pop!(D::SharedCircularDeque)
    S = D.state.A
    v = back(D)
    S[LEN] -= 1
    tmp = S[LST] - 1
    S[LST] = ifelse(tmp < 1, S[CAP], tmp)
    v
end

@inline function Base.unshift!(D::SharedCircularDeque, v)
    S = D.state.A
    @boundscheck S[LEN] < S[CAP] || throw(BoundsError())
    S[LEN] += 1
    tmp = S[FST] - 1
    S[FST] = ifelse(tmp < 1, S[CAP], tmp)
    @inbounds D.buffer.A[S[FST]] = v
    D
end

@inline function Base.shift!(D::SharedCircularDeque)
    S = D.state.A
    v = front(D)
    S[LEN] -= 1
    tmp = S[FST] + 1
    S[FST] = ifelse(tmp > S[CAP], 1, tmp)
    v
end

@inline function Base.splice!(D::SharedCircularDeque, idx)
    S = D.state.A
    C = S[CAP]
    j = S[FST] + idx - 1
    if j > C
        j -= C
    end
    A = D.buffer.A
    @inbounds ret = A[j]

    L = S[LST]
    S[LST] = L - 1
    S[LEN] -= 1

    if L < j
        while j < C
            @inbounds A[j] = A[j+1]
            j += 1
        end
        @inbounds A[j] = A[1]
        j = 1
    end

    while j < L
        @inbounds A[j] = A[j+1]
        j += 1
    end

    return ret
end

# getindex sans bounds checking
@inline function _unsafe_getindex(D::SharedCircularDeque, i::Integer)
    S = D.state.A
    j = S[FST] + i - 1
    if j > S[CAP]
        j -= S[CAP]
    end
    @inbounds ret = D.buffer.A[j]
    return ret
end

@inline function Base.getindex(D::SharedCircularDeque, i::Integer)
    @boundscheck 1 <= i <= D.state.A[LEN] || throw(BoundsError())
    return _unsafe_getindex(D, i)
end

# Iteration via getindex
@inline Base.start(d::SharedCircularDeque) = 1
@inline Base.next(d::SharedCircularDeque, i) = (_unsafe_getindex(d, i), i+1)
@inline Base.done(d::SharedCircularDeque, i) = i == d.state.A[LEN] + 1

function Base.show(io::IO, D::SharedCircularDeque{T}) where T
    print(io, "SharedCircularDeque{$T}([")
    for i = 1:length(D)
        print(io, D[i])
        i < length(D) && print(io, ',')
    end
    print(io, "])")
end
