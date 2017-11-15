const Cftok = UInt32

const IPC_RMID = 0 # remove identifier
const IPC_SET  = 1 # set options
const IPC_STAT = 2 # get options

const IPC_CREAT  = 0o1000 # create entry if key does not exist
const IPC_EXCL   = 0o2000 # fail if key exists
const IPC_NOWAIT = 0o4000 # error if request must wait

ftok(path::String, id::Int) = ccall(:ftok, Cftok, (Cstring,Cint), path, id)

function shmget(tok::Cftok, size::Int; create::Bool=true, create_exclusive::Bool=false, permission::Integer=0o660)
    flags = Cint(permission)
    if create
        flags |= IPC_CREAT
        if create_exclusive
            flags |= IPC_EXCL
        end
    end
    id = ccall(:shmget, Cint, (Cftok, Csize_t, Cint), tok, size, flags)
    systemerror("error creating shared memory segment", id < 0)
    id
end

function shmat(id::Cint)
    ptr = ccall(:shmat, Ptr{Void}, (Cint, Ptr{Void}, Cint), id, C_NULL, 0)
    systemerror("error attaching shared memory segment", convert(Int, ptr) == -1)
    ptr
end

function shmdt(ptr::Ptr{Void})
    ret = ccall(:shmdt, Cint, (Ptr{Void},), ptr)
    systemerror("error detaching shared memory segment", ret == -1)
    nothing
end

function shmrm(id::Cint)
    ret = ccall(:shmctl, Cint, (Cint, Cint, Ptr{Void}), id, IPC_RMID, C_NULL)
    systemerror("error removing shared memory segment", ret == -1)
    nothing
end

struct SysVSharedArray{T,N}
    path::String
    id::Cint
    size::Int
    shmid::Cint
    shmptr::Ptr{Void}
    A::Array{T,N}
end

function SysVSharedVector{T}(path::Union{String,Tuple{String,Integer}}, size::Integer, ::Type{T}; create::Bool=true, create_exclusive::Bool=false, permission::Integer=0o660)
    id = 0
    if isa(path, Tuple) 
        path,id = path
    end
    tok = ftok(path, id)
    shmid = shmget(tok, size*sizeof(T); create=create, create_exclusive=create_exclusive, permission=permission)
    shmptr = shmat(shmid)
    A = unsafe_wrap(Array, convert(Ptr{T}, shmptr), (size,))
    SysVSharedArray{T,1}(path, id, size, shmid, shmptr, A)
end

close(vec::SysVSharedArray) = shmdt(vec.shmptr)
delete!(vec::SysVSharedArray) = shmrm(vec.shmid)
