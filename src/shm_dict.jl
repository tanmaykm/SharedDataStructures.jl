const primes = [53, 97, 193, 389, 769, 1543, 3079, 6151, 12289, 24593, 49157, 98317, 196613, 393241, 786433, 1572869, 3145739, 6291469, 12582917, 25165843, 50331653, 100663319, 201326611, 402653189, 805306457, 1610612741]

# Layout (for capacity C, value size V)
# -   C bytes for used hash bucket marker
# -   C bytes for used collition bucket marker
# - 16C bytes for 2C key hash values
# -  8C bytes for 2C next entry values
# -  8C bytes for 2C value sizes
# - 2VC bytes for 2C values, each of max V bytes
#
# Note:
# - actual dict capacity is greater than the requested capacity (actual capacity = 2 * next higher value from primes)
# - with this scheme, loadfactor is around 0.5
struct ShmDict
    capacity::UInt32            # requested capacity (actual capacity > 2 * requested capacity)
    maxvalsize::UInt32          # max bytes in value (or value + key if keeping keys)
    maxkeysize::UInt8           # max bytes in key
    keepkeys::Bool              # whether to keep keys along with values (used for exact comparison, take up space from value buffer)
    shmid::Cint                 # shm id
    shmptr::Ptr{Void}           # shm pointer
    lck::NamedSemaphore         # lock for dict operations
    used::Vector{Bool}          # bucket in use marker
    khash::Vector{UInt64}       # hash of key that occupies the bucket
    next::Vector{UInt32}        # the next collision entry for this bucket (0 if none)
    valsize::Vector{UInt32}     # size occupied in val
    val::Vector{UInt8}          # value bytes

    function ShmDict(path::Union{String,Tuple{String,Integer}}, capacity::Integer, maxvalsize::Integer; keepkeys::Bool=true, maxkeysize::Integer=32, create::Bool=false, create_exclusive::Bool=false, permission::Integer=0o660)
        if keepkeys
            maxvalsize = maxvalsize + maxkeysize + 1
        end
        capacity = primes[min(length(primes), searchsortedfirst(primes, capacity))]
        memsz, offsets = _shmsize(capacity, maxvalsize)
        id = 0
        if isa(path, Tuple)
            path,id = path
        end
        lck = NamedSemaphore("/$(hash(path))")
        tok = ftok(path, id)
        shmid = shmget(tok, memsz; create=create, create_exclusive=create_exclusive, permission=permission)
        shmptr = shmat(shmid)

        used = unsafe_wrap(Array, convert(Ptr{Bool}, shmptr), (2*capacity,))
        khash = unsafe_wrap(Array, convert(Ptr{UInt64}, shmptr+shift!(offsets)), (2*capacity,))
        next = unsafe_wrap(Array, convert(Ptr{UInt32}, shmptr+shift!(offsets)), (2*capacity,))
        valsize = unsafe_wrap(Array, convert(Ptr{UInt32}, shmptr+shift!(offsets)), (2*capacity,))
        val = unsafe_wrap(Array, convert(Ptr{UInt8}, shmptr+shift!(offsets)), (2*maxvalsize*capacity,))

        new(capacity, maxvalsize, maxkeysize, keepkeys, shmid, shmptr, lck, used, khash, next, valsize, val)
    end
end

function _shmsize(C, V)
    offsets = Vector{Int}()
    sz = 2*C
    sz = ceil(Int, sz/8) * 8
    push!(offsets, sz)
    sz += 16*C
    sz = ceil(Int, sz/8) * 8
    push!(offsets, sz)
    sz += 8*C
    sz = ceil(Int, sz/8) * 8
    push!(offsets, sz)
    sz += 8*C
    sz = ceil(Int, sz/8) * 8
    push!(offsets, sz)
    sz += 2*V*C
    sz, offsets
end

_byte_repr(val::Vector{UInt8}) = val
_byte_repr(val::String) = convert(Vector{UInt8}, val)
_byte_repr(val::Number) = reinterpret(UInt8, [val])
function _byte_repr(val)
    iob = IOBuffer()
    serialize(iob, val)
    take!(iob)
end

_from_byte_repr(::Type{Vector{UInt8}}, val::Vector{UInt8}) = val
_from_byte_repr(::Type{T}, val::Vector{UInt8}) where {T<:Number} = reinterpret(T, val)[1]
_from_byte_repr(::Type{String}, val::Vector{UInt8}) = String(val)
_from_byte_repr(::Type{T}, val::Vector{UInt8}) where {T} = deserialize(IOBuffer(val))

function _key_matches(D::ShmDict, key, bucket)
    if D.keepkeys
        keystart = Int((D.maxvalsize * (bucket-1)) + 1)
        keysz = D.val[keystart]
        keystart += 1
        keyend = Int(keystart + keysz - 1)
        key == SubArray(D.val, (keystart:keyend,))
    else
        true
    end
end

function _val_bytes(D::ShmDict, bucket)
    if D.keepkeys
        valstart = Int((D.maxvalsize * (bucket-1)) + 1)
        keysz = D.val[valstart]
        keyoffset = 1 + keysz
        valstart += keyoffset
        valend = Int(valstart + D.valsize[bucket] - keyoffset - 1)
    else
        valstart = Int((D.maxvalsize * (bucket-1)) + 1)
        valend = Int(valstart + D.valsize[bucket] - 1)
    end
    SubArray(D.val, (valstart:valend,))
end

haskey(D::ShmDict, key) = haskey(D, _byte_repr(key))
function haskey(D::ShmDict, key::Vector{UInt8})
    khash = hash(key)
    bucket = (khash % D.capacity) + 1
    if D.used[bucket]
        while bucket > 0
            (D.khash[bucket] === khash) && _key_matches(D, key, bucket) && (return true)
            bucket = D.next[bucket]
        end
    end
    return false
end

getindex(D::ShmDict, key) = getindex(D, _byte_repr(key))
function getindex(D::ShmDict, key::Vector{UInt8})
    khash = hash(key)
    bucket = (khash % D.capacity) + 1
    if D.used[bucket]
        while bucket > 0
            (D.khash[bucket] === khash) && _key_matches(D, key, bucket) && (return _val_bytes(D, bucket))
            bucket = D.next[bucket]
        end
    end
    error("key not found")
end

function _setbucket(D::ShmDict, bucket, khash::UInt64, key::Vector{UInt8}, val::Vector{UInt8}, next::UInt32)
    D.used[bucket] = true
    D.khash[bucket] = khash
    D.next[bucket] = next
    D.valsize[bucket] = length(val)
    valstart = (D.maxvalsize * (bucket-1)) + 1
    valend = valstart + D.valsize[bucket] - 1
    if D.keepkeys
        keysz = UInt8(length(key))
        D.valsize[bucket] += (1 + keysz)
        D.val[valstart] = keysz
        copy!(D.val, valstart+1, key, 1, keysz)
        valstart += (1 + keysz)
    end
    copy!(D.val, valstart, val, 1, length(val))
    nothing
end

function _setbucket(D::ShmDict, bucket, khash::UInt64, keyval::Vector{UInt8}, next::UInt32)
    D.used[bucket] = true
    D.khash[bucket] = khash
    D.next[bucket] = next
    D.valsize[bucket] = length(keyval)
    valstart = (D.maxvalsize * (bucket-1)) + 1
    valend = valstart + D.valsize[bucket] - 1
    copy!(D.keyval, valstart, keyval, 1, length(keyval))
    nothing
end


setindex!(D::ShmDict, val, key) = setindex!(D, _byte_repr(val), _byte_repr(key))
function setindex!(D::ShmDict, val::Vector{UInt8}, key::Vector{UInt8})
    lkey = length(key)
    lval = length(val)
    if D.keepkeys
        (lkey > D.maxkeysize) && error("key size $lkey greater than max allowed $(D.maxkeysize)")
        lval += (1 + lkey)
    end
    (lval > D.maxvalsize) && error("value size $(lval-lkey-1) greater than max allowed $(D.maxvalsize-D.maxkeysize-1)")
    khash = hash(key)
    bucket = (khash % D.capacity) + 1
    nextbucket = UInt32(0)
    if D.used[bucket]
        prevbucket = bucket
        while bucket > 0
            # navigate to matching entry or last entry
            (D.khash[bucket] === khash) && _key_matches(D, key, bucket) && break
            prevbucket = bucket
            bucket = D.next[bucket]
        end
        if bucket == 0
            # if no matching entry, find a free collision entry and chain it in
            bucket = findfirst(SubArray(D.used, (Int(D.capacity+1):Int(2*D.capacity),)), false)
            (bucket == 0) && error("no space left in dict")
            bucket += D.capacity
            D.next[prevbucket] = bucket
        else
            nextbucket = D.next[bucket]
        end
    end
    _setbucket(D, bucket, khash, key, val, nextbucket)
    val
end

delete!(D::ShmDict, key) = delete!(D, _byte_repr(key))
function delete!(D::ShmDict, key::Vector{UInt8})
    khash = hash(key)
    bucket = (khash % D.capacity) + 1
    if D.used[bucket]
        prevbucket = bucket
        while bucket > 0
            # navigate to matching entry
            (D.khash[bucket] === khash) && _key_matches(D, key, bucket) && break
            prevbucket = bucket
            bucket = D.next[bucket]
        end
        if bucket > 0
            nextbucket = D.next[bucket]
            if (prevbucket == bucket) && (nextbucket > 0)
                valstart = Int((D.maxvalsize * (nextbucket-1)) + 1)
                valend = Int(valstart + D.valsize[nextbucket] - 1)
                _setbucket(D, bucket, D.khash[nextbucket], SubArray(D.val, (valstart:valend,)), D.next[nextbucket])
                D.used[nextbucket] = false
            else
                D.next[prevbucket] = nextbucket
                D.used[bucket] = false
            end
            return D
        end
    end

    error("key not found")
end

function Base.empty!(D::ShmDict)
    memsz, offsets = _shmsize(D.capacity, D.maxvalsize)
    ccall(:memset, Ptr{Void}, (Ptr{Void}, Cint, Csize_t), D.shmptr, 0, memsz)
    D
end

function Base.delete!(D::ShmDict)
    shmrm(D.shmid)
    delete!(D.lck)
    nothing
end

function Base.close(D::ShmDict)
    shmdt(D.shmptr)
    close(D.lck)
    nothing
end
