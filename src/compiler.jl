module Compiler

import ..Enzyme: Const, Active, Duplicated, DuplicatedNoNeed, Annotation, guess_activity, eltype
import ..Enzyme: API, TypeTree, typetree, only!, shift!, data0!,
                 TypeAnalysis, FnTypeInfo, Logic, allocatedinline

using LLVM, GPUCompiler, Libdl
import Enzyme_jll

import GPUCompiler: CompilerJob, FunctionSpec, codegen
using LLVM.Interop
import LLVM: Target, TargetMachine

if LLVM.has_orc_v1()
    include("compiler/orcv1.jl")
else
    include("compiler/orcv2.jl")
end

# User facing interface
abstract type AbstractThunk{F, RT, TT, DF} end

struct CombinedAdjointThunk{F, RT, TT, DF} <: AbstractThunk{F, RT, TT, DF}
    fn::F
    adjoint::Ptr{Cvoid}
    dfn::DF
end

struct ForwardModeThunk{F, RT, TT, DF} <: AbstractThunk{F, RT, TT, DF}
    fn::F
    adjoint::Ptr{Cvoid}
    dfn::DF
end

struct AugmentedForwardThunk{F, RT, TT, DF} <: AbstractThunk{F, RT, TT, DF}
    fn::F
    primal::Ptr{Cvoid}
    dfn::DF
end

struct ForwardThunk{F, RT, TT, DF} <: AbstractThunk{F, RT, TT, DF}
    fn::F
    primal::Ptr{Cvoid}
    dfn::DF
end

struct AdjointThunk{F, RT, TT, DF} <: AbstractThunk{F, RT, TT, DF}
    fn::F
    adjoint::Ptr{Cvoid}
    dfn::DF
end
return_type(::AbstractThunk{F, RT, TT, DF}) where {F, RT, TT, DF} = RT

using .JIT

function get_function!(builderF, mod, name)
    if haskey(functions(mod), name)
        return functions(mod)[name]
    else
        return builderF(mod, context(mod), name)
    end
end

if VERSION < v"1.7.0-DEV.1205"

declare_ptls!(mod) = get_function!(mod, "julia.ptls_states") do mod, ctx, name
    T_jlvalue = LLVM.StructType(LLVMType[]; ctx)
    T_pjlvalue = LLVM.PointerType(T_jlvalue)
    T_ppjlvalue = LLVM.PointerType(T_pjlvalue)

    funcT = LLVM.FunctionType(LLVM.PointerType(T_ppjlvalue))
    LLVM.Function(mod, name, funcT)
end

function emit_ptls!(B)
    curent_bb = position(B)
    fn = LLVM.parent(curent_bb)
    mod = LLVM.parent(fn)
    func = declare_ptls!(mod)
    return call!(B, func)
end

function get_ptls(func)
    entry_bb = first(blocks(func))
    ptls_func = declare_ptls!(LLVM.parent(func))

    for I in instructions(entry_bb)
        if I isa LLVM.CallInst && called_value(I) == ptls_func
            return I
        end
    end
    return nothing
end

function reinsert_gcmarker!(func)
	ptls = get_ptls(func) 
    if ptls === nothing
        B = Builder(context(LLVM.parent(func)))
        entry_bb = first(blocks(func))
        position!(B, first(instructions(entry_bb)))
        emit_ptls!(B)
	else
		ptls
    end
end

else

declare_pgcstack!(mod) = get_function!(mod, "julia.get_pgcstack") do mod, ctx, name
    T_jlvalue = LLVM.StructType(LLVMType[]; ctx)
    T_pjlvalue = LLVM.PointerType(T_jlvalue)
    T_ppjlvalue = LLVM.PointerType(T_pjlvalue)

    funcT = LLVM.FunctionType(LLVM.PointerType(T_ppjlvalue))
    LLVM.Function(mod, name, funcT)
end

function emit_pgcstack(B)
    curent_bb = position(B)
    fn = LLVM.parent(curent_bb)
    mod = LLVM.parent(fn)
    func = declare_pgcstack!(mod)
    return call!(B, func)
end

function get_pgcstack(func)
    entry_bb = first(blocks(func))
    pgcstack_func = declare_pgcstack!(LLVM.parent(func))

    for I in instructions(entry_bb)
        if I isa LLVM.CallInst && called_value(I) == pgcstack_func
            return I
        end
    end
    return nothing
end

function reinsert_gcmarker!(func)
	pgs = get_pgcstack(func)
    if pgs === nothing
        B = Builder(context(LLVM.parent(func)))
        entry_bb = first(blocks(func))
        position!(B, first(instructions(entry_bb)))
        emit_pgcstack(B)
	else
		pgs
    end
end

end

declare_allocobj!(mod) = get_function!(mod, "julia.gc_alloc_obj") do mod, ctx, name
    T_jlvalue = LLVM.StructType(LLVMType[]; ctx)
    T_prjlvalue = LLVM.PointerType(T_jlvalue, #= AddressSpace::Tracked =# 10)
    
	T_pjlvalue = LLVM.PointerType(T_jlvalue)
    T_ppjlvalue = LLVM.PointerType(T_pjlvalue)

	#TODO make size_t > 32 => 64, else 32
	T_size = LLVM.IntType((sizeof(Csize_t)*8) > 32 ? 64 : 32; ctx)
    funcT = LLVM.FunctionType(T_prjlvalue, [LLVM.PointerType(T_ppjlvalue), T_size, T_prjlvalue])
    LLVM.Function(mod, name, funcT)
end
function emit_allocobj!(B, T)
    curent_bb = position(B)
    fn = LLVM.parent(curent_bb)
    mod = LLVM.parent(fn)
	ctx = context(mod)
    func = declare_allocobj!(mod)
	
	T_size = parameters(eltype(llvmtype(func)))[2]
    
	T_jlvalue = LLVM.StructType(LLVMType[]; ctx)
    T_prjlvalue = LLVM.PointerType(T_jlvalue, #= AddressSpace::Tracked =# 10)

	ty = inttoptr!(B, LLVM.ConstantInt(convert(Int, pointer_from_objref(T)); ctx), LLVM.PointerType(T_jlvalue))
	ty = addrspacecast!(B, ty, T_prjlvalue)
	size = LLVM.ConstantInt(T_size, sizeof(T))
    args = [reinsert_gcmarker!(fn), size, ty]
	args[1] = bitcast!(B, args[1], parameters(eltype(llvmtype(func)))[1])
    return call!(B, func, args)
end
declare_pointerfromobjref!(mod) = get_function!(mod, "julia.pointer_from_objref") do mod, ctx, name
    T_jlvalue = LLVM.StructType(LLVMType[]; ctx)
    T_prjlvalue = LLVM.PointerType(T_jlvalue, #= AddressSpace::Tracked =# 11) 
    T_pjlvalue = LLVM.PointerType(T_jlvalue)
    funcT = LLVM.FunctionType(T_pjlvalue, [T_prjlvalue])
    LLVM.Function(mod, name, funcT)
end
function emit_pointerfromobjref!(B, T)
    curent_bb = position(B)
    fn = LLVM.parent(curent_bb)
    mod = LLVM.parent(fn)
    ctx = context(mod)
    func = declare_pointerfromobjref!(mod)
    return call!(B, func, [T])
end


function array_inner(::Type{<:Array{T}}) where T
    return T
end
function array_shadow_handler(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, numArgs::Csize_t, Args::Ptr{LLVM.API.LLVMValueRef})::LLVM.API.LLVMValueRef
    inst = LLVM.Instruction(OrigCI)
    mod = LLVM.parent(LLVM.parent(LLVM.parent(inst)))
    ctx = LLVM.context(LLVM.Value(OrigCI))

    ce = operands(inst)[1]
    while isa(ce, ConstantExpr)
        ce = operands(ce)[1]
    end
    ptr = reinterpret(Ptr{Cvoid}, convert(UInt64, ce))
    typ = array_inner(Base.unsafe_pointer_to_objref(ptr))

    b = LLVM.Builder(B)

    vals = LLVM.Value[]
    for i = 1:numArgs
        push!(vals, LLVM.Value(unsafe_load(Args, i)))
    end

    anti = LLVM.call!(b, LLVM.Value(LLVM.API.LLVMGetCalledValue(OrigCI)), vals)

    prod = LLVM.Value(unsafe_load(Args, 2))
    for i = 3:numArgs
        prod = LLVM.mul!(b, prod, LLVM.Value(unsafe_load(Args, i)))
    end

    isunboxed = allocatedinline(typ)
    elsz = sizeof(typ)

    isunion = typ <: Union

    LLT_ALIGN(x, sz) = (((x) + (sz)-1) & ~((sz)-1))

    if !isunboxed
        elsz = sizeof(Ptr{Cvoid})
        al = elsz;
    else
        al = 1 # check
        elsz = LLT_ALIGN(elsz, al)
    end

    tot = prod
    tot = LLVM.mul!(b, tot, LLVM.ConstantInt(LLVM.llvmtype(tot), elsz, false))

    if elsz == 1 && !isunion
        tot = LLVM.add!(b, t, LLVM.ConstantInt(LLVM.llvmtype(tot), 1, false))
    end
    if (isunion)
        # an extra byte for each isbits union array element, stored after a->maxsize
        tot = LLVM.add!(b, tot, prod)
    end

    i1 = LLVM.IntType(1; ctx)
    i8 = LLVM.IntType(8; ctx)
    ptrty = LLVM.PointerType(i8) #, LLVM.addrspace(LLVM.llvmtype(anti)))
    toset = LLVM.load!(b, LLVM.pointercast!(b, anti, LLVM.PointerType(ptrty, LLVM.addrspace(LLVM.llvmtype(anti)))))

    memtys = LLVM.LLVMType[ptrty, LLVM.llvmtype(tot)]
    memset = LLVM.Function(mod, LLVM.Intrinsic("llvm.memset"), memtys)
    memargs = LLVM.Value[toset, LLVM.ConstantInt(i8, 0, false), tot, LLVM.ConstantInt(i1, 0, false)]

    mcall = LLVM.call!(b, memset, memargs)
    ref::LLVM.API.LLVMValueRef = Base.unsafe_convert(LLVM.API.LLVMValueRef, anti)
    return ref
end

function null_free_handler(B::LLVM.API.LLVMBuilderRef, ToFree::LLVM.API.LLVMValueRef, Fn::LLVM.API.LLVMValueRef)::LLVM.API.LLVMValueRef
    return C_NULL
end

dedupargs() = ()
dedupargs(a, da, args...) = (a, dedupargs(args...)...)


function runtime_newtask_fwd(fn::Any, dfn::Any, post::Any, ssize::Int)
    tt′ = Tuple{}
    args = ()
    tt = Tuple{map(x->eltype(Core.Typeof(x)), args)...}
    rt = Core.Compiler.return_type(fn, tt)
    forward = thunk(fn, dfn, Const, tt′, Val(API.DEM_ForwardMode))

    taperef = Ref{Ptr{Cvoid}}(C_NULL)

    function fclosure()
        res = forward()
        if length(res) > 1
            return res[1]
        else
            return nothing
        end
    end

    return ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), fclosure, post, ssize)
end

function runtime_newtask_augfwd(ret_ptr::Ptr{Any}, fn::Any, dfn::Any, post::Any, ssize::Int)

    tt′ = Tuple{}
    args = ()
    tt = Tuple{map(x->eltype(Core.Typeof(x)), args)...}
    rt = Core.Compiler.return_type(fn, tt)
    forward, adjoint = thunk(fn, dfn, Const, tt′, Val(API.DEM_ReverseModePrimal))

    taperef = Ref{Ptr{Cvoid}}(C_NULL)

    function fclosure()
        res = forward()
        taperef[] = res[1]
        if length(res) > 1
            return res[2]
        else
            return nothing
        end
    end

    ftask = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), fclosure, post, ssize)

    function rclosure()
        adjoint(taperef[])
        return 0
    end
    
    rtask = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), rclosure, post, ssize)
    
    Base.unsafe_store!(ret_ptr, ftask, 1)
    Base.unsafe_store!(ret_ptr, rtask, 2)
    return nothing
end

struct Tape
    thunk::AdjointThunk
    internal_tape::Ptr{Cvoid}
    shadow_return::Any
    resT::DataType
end

function runtime_generic_fwd(ret_ptr::Ptr{Any}, fn::Any, arg_ptr::Ptr{Any}, shadow_ptr::Ptr{Any}, activity_ptr::Ptr{UInt8}, arg_size::UInt32)

    if fn == Base.println || fn == Base.print || fn == Base.show || fn == Base.flush

        args = Any[]
        for i in 1:arg_size
            push!(args, Base.unsafe_load(arg_ptr, i))
        end

        res = fn(args...)
        Base.unsafe_store!(ret_ptr, res, 1)
        Base.unsafe_store!(ret_ptr, res, 2)
        return nothing
    end

    # Note: We shall not unsafe_wrap any of the Ptr{Any}, since these are stack allocations
    #       As an example, if the Array created by unsafe_wrap get's moved to the remset it
    #       will constitute a leak of the stack allocation, and GC will find delicous garbage.
    __activity = Base.unsafe_wrap(Array, activity_ptr, arg_size)
    args = Any[]
    
    for i in 1:arg_size
        p = Base.unsafe_load(arg_ptr, i)
        if __activity[i] != 0
            s = Base.unsafe_load(shadow_ptr, i)
            push!(args, Duplicated(p, s))
        else
            push!(args, Const(p))
        end
    end

    # TODO: Annotation of return value
    tt = Tuple{map(x->eltype(Core.Typeof(x)), args)...}
    rt = Core.Compiler.return_type(fn, tt)
    annotation = guess_activity(rt, API.DEM_ForwardMode)
    if annotation <: DuplicatedNoNeed
        annotation = Duplicated
    end

    tt′ = Tuple{map(Core.Typeof, args)...}
    forward = thunk(fn, #=dfn=#nothing, annotation, tt′, Val(API.DEM_ForwardMode))

    res = forward(args...)
    if annotation == Duplicated
        Base.unsafe_store!(ret_ptr, res[1], 1)
        Base.unsafe_store!(ret_ptr, res[2], 2)
    else
        Base.unsafe_store!(ret_ptr, nothing, 1)
        Base.unsafe_store!(ret_ptr, nothing, 2)
    end
    return nothing
end
function runtime_generic_augfwd(ret_ptr::Ptr{Any}, fn::Any, arg_ptr::Ptr{Any}, shadow_ptr::Ptr{Any}, activity_ptr::Ptr{UInt8}, arg_size::UInt32)

    if fn == Base.println || fn == Base.print || fn == Base.show || fn == Base.flush

        args = Any[]
        for i in 1:arg_size
            push!(args, Base.unsafe_load(arg_ptr, i))
        end

        res = fn(args...)
        Base.unsafe_store!(ret_ptr, res, 1)
        Base.unsafe_store!(ret_ptr, res, 2)
        Base.unsafe_store!(ret_ptr, nothing, 3)
        return nothing
    end

    # Note: We shall not unsafe_wrap any of the Ptr{Any}, since these are stack allocations
    #       As an example, if the Array created by unsafe_wrap get's moved to the remset it
    #       will constitute a leak of the stack allocation, and GC will find delicous garbage.
    __activity = Base.unsafe_wrap(Array, activity_ptr, arg_size)
    args = Any[]
    
    for i in 1:arg_size
        p = Base.unsafe_load(arg_ptr, i)
        if __activity[i] != 0
            if typeof(p) <: AbstractFloat || typeof(p) <: Complex{<:AbstractFloat}
                push!(args, Active(p))
            else
                s = Base.unsafe_load(shadow_ptr, i)
                push!(args, Duplicated(p, s))
            end
        else
            push!(args, Const(p))
        end
    end

    # TODO: Annotation of return value
    tt = Tuple{map(x->eltype(Core.Typeof(x)), args)...}
    rt = Core.Compiler.return_type(fn, tt)
    annotation = guess_activity(rt)

    tt′ = Tuple{map(Core.Typeof, args)...}
    forward, adjoint = thunk(fn, #=dfn=#nothing, annotation, tt′, Val(API.DEM_ReverseModePrimal))

    res = forward(args...)
    if length(res) > 1
        origRet = res[2]
        resT = typeof(origRet)
    else
        origRet = nothing
        resT = Nothing
    end
    Base.unsafe_store!(ret_ptr, origRet, 1)

    if annotation <: Active
        # This assumes that we have an Immutable object here that got passed as a boxed value
        shadow_return = Ref(zero(resT))
        Base.unsafe_store!(ret_ptr, shadow_return, 2) # due to this store we need typetag
    elseif annotation <: Const
        Base.unsafe_store!(ret_ptr, origRet, 2)
        shadow_return = nothing
    elseif annotation <: Duplicated ||  annotation <: DuplicatedNoNeed
        Base.unsafe_store!(ret_ptr, res[3], 2)
        shadow_return = nothing
    else
        error("Unknown annotation")
    end
    internal_tape = res[1]

    tape = Tape(adjoint, internal_tape, shadow_return, resT)
    Base.unsafe_store!(ret_ptr, tape, 3)
    return nothing
end

function runtime_generic_rev(fn::Any, arg_ptr::Ptr{Any}, shadow_ptr::Ptr{Any}, activity_ptr::Ptr{UInt8}, arg_size::UInt32, tape::Any)
    if fn == Base.println || fn == Base.print || fn == Base.show || fn == Base.flush
        args = Any[]
        for i in 1:arg_size
            push!(args, Base.unsafe_load(arg_ptr, i))
        end

        res = fn(args...)
        return nothing
    end

    __activity = Base.unsafe_wrap(Array, activity_ptr, arg_size)
    args = []
    actives = []
    for i in 1:arg_size
        p = Base.unsafe_load(arg_ptr, i)
        if __activity[i] != 0
            if typeof(p) <: AbstractFloat || typeof(p) <: Complex{<:AbstractFloat}
                push!(args, Active(p))
                push!(actives, (shadow_ptr, i))
            else
                s = Base.unsafe_load(shadow_ptr, i)
                push!(args, Duplicated(p, s))
            end
        else
            push!(args, Const(p))
        end
    end


    tape = tape::Tape

    if tape.shadow_return !== nothing
        val = tape.shadow_return
        if !(val isa tape.resT)
            val = tape.shadow_return[]
        end
        push!(args, val)
    end
    if tape.internal_tape !== nothing
        push!(args, tape.internal_tape)
    end

    tup = tape.thunk(args...)

    for (d, (s, i)) in zip(tup, actives)
        a = unsafe_load(s, i)
        # While `RefValue{T}` and boxed T for immutable are bitwise compatible
        # they are not idempotent on the Julia level. We could "force" `a` to be
        # a boxed T, but would lose the mutable memory semantics that Enzyme requires
        if a isa Base.RefValue
            @assert eltype(a) == typeof(d)
            a[] += d
        else
            ref = unsafe_load(reinterpret(Ptr{Ptr{typeof(a)}}, s), i)
            unsafe_store!(ref, d+a)
        end
    end
    
    return nothing
end

function runtime_invoke_fwd(ret_ptr::Ptr{Any}, mi::Any, arg_ptr::Ptr{Any}, shadow_ptr::Ptr{Any}, activity_ptr::Ptr{UInt8}, arg_size::UInt32)
    __activity = Base.unsafe_wrap(Array, activity_ptr, arg_size)

    fn = Base.unsafe_load(arg_ptr, 1)
    args = []
    for i in 2:arg_size
        val = Base.unsafe_load(arg_ptr, i)
        if __activity[i] != 0
            # TODO use only for non mutable
            push!(args, Duplicated(val, Base.unsafe_load(shadow_ptr, i)))
        else
            push!(args, Const(val))
        end
    end

    specTypes = mi.specTypes.parameters
    F = specTypes[1]
    @assert F == typeof(fn)
    @assert in(mi.def, methods(fn))
    
    tt = Tuple{specTypes[2:end]...}
    rt = Core.Compiler.return_type(fn, tt)
    annotation = guess_activity(rt, API.DEM_ForwardMode)
    if annotation <: DuplicatedNoNeed
        annotation = Duplicated
    end

    tt′ = Tuple{map(Core.Typeof, args)...}
    forward = thunk(F, #=dfn=#nothing, Duplicated, tt′, Val(API.DEM_ForwardMode))

    res = forward(args...)
    if annotation <: Duplicated
        Base.unsafe_store!(ret_ptr, res[1], 1)
        Base.unsafe_store!(ret_ptr, res[2], 2)
    else
        Base.unsafe_store!(ret_ptr, nothing, 1)
        Base.unsafe_store!(ret_ptr, nothing, 2)
    end
    return nothing
end

function runtime_invoke_augfwd(ret_ptr::Ptr{Any}, mi::Any, arg_ptr::Ptr{Any}, shadow_ptr::Ptr{Any}, activity_ptr::Ptr{UInt8}, arg_size::UInt32)
    __activity = Base.unsafe_wrap(Array, activity_ptr, arg_size)

    fn = Base.unsafe_load(arg_ptr, 1)
    
    if fn == Base.println || fn == Base.print || fn == Base.show || fn == Base.flush
        res::Any = ccall(:jl_invoke, Any, (Any, Ptr{Any}, UInt32, Any), fn, args, length(args), mi)
        Base.unsafe_store!(ret_ptr, res, 1)
        Base.unsafe_store!(ret_ptr, res, 2)
        Base.unsafe_store!(ret_ptr, nothing, 3)
        return nothing
    end
    
    # TODO actually use the mi rather than fn
    @assert in(mi.def, methods(fn))

    # Note: We shall not unsafe_wrap any of the Ptr{Any}, since these are stack allocations
    #       As an example, if the Array created by unsafe_wrap get's moved to the remset it
    #       will constitute a leak of the stack allocation, and GC will find delicous garbage.
    __activity = Base.unsafe_wrap(Array, activity_ptr, arg_size)
    args = Any[]
    for (i, typ) in zip(2:arg_size, mi.specTypes.parameters[2:end])
        p = Base.unsafe_load(arg_ptr, i)
        if __activity[i] != 0
            if typeof(p) <: AbstractFloat || typeof(p) <: Complex{<:AbstractFloat}
                push!(args, Active(p))
            else
                s = Base.unsafe_load(shadow_ptr, i)
                push!(args, Duplicated(p, s))
            end
        else
            push!(args, Const(p))
        end
    end

    # TODO: Annotation of return value
    tt = Tuple{map(x->eltype(Core.Typeof(x)), args)...}
    rt = Core.Compiler.return_type(fn, tt)
    annotation = guess_activity(rt)

    tt′ = Tuple{map(Core.Typeof, args)...}
    forward, adjoint = thunk(fn, #=dfn=#nothing, annotation, tt′, Val(API.DEM_ReverseModePrimal))

    res = forward(args...)
    if length(res) > 1
        origRet = res[2]
        resT = typeof(origRet)
    else
        origRet = nothing
        resT = Nothing
    end
    Base.unsafe_store!(ret_ptr, origRet, 1)

    if annotation <: Active
        # This assumes that we have an Immutable object here that got passed as a boxed value
        shadow_return = Ref(zero(resT))
        Base.unsafe_store!(ret_ptr, shadow_return, 2) # due to this store we need typetag
    elseif annotation <: Const
        Base.unsafe_store!(ret_ptr, origRet, 2)
        shadow_return = nothing
    elseif annotation <: Duplicated ||  annotation <: DuplicatedNoNeed
        Base.unsafe_store!(ret_ptr, res[3], 2)
        shadow_return = nothing
    else
        error("Unknown annotation")
    end
    internal_tape = res[1]

    tape = Tape(adjoint, internal_tape, shadow_return, resT)
    Base.unsafe_store!(ret_ptr, tape, 3)
    return nothing
end

function runtime_invoke_rev(mi::Any, arg_ptr::Ptr{Any}, shadow_ptr::Ptr{Any}, activity_ptr::Ptr{UInt8}, arg_size::UInt32, tape::Any)
    fn = Base.unsafe_load(arg_ptr, 1)
    if fn == Base.println || fn == Base.print || fn == Base.show || fn == Base.flush
        args = Any[]
        for i in 1:arg_size
            push!(args, Base.unsafe_load(arg_ptr, i))
        end

        res = fn(args...)
        return nothing
    end
    
    # TODO actually use the mi rather than fn
    @assert in(mi.def, methods(fn))

    __activity = Base.unsafe_wrap(Array, activity_ptr, arg_size)
    args = []
    actives = []
    for (i, typ) in zip(2:arg_size, mi.specTypes.parameters[2:end])
        p = Base.unsafe_load(arg_ptr, i)
        if __activity[i] != 0
            if typeof(p) <: AbstractFloat || typeof(p) <: Complex{<:AbstractFloat}
                push!(args, Active(p))
                push!(actives, (shadow_ptr, i))
            else
                s = Base.unsafe_load(shadow_ptr, i)
                push!(args, Duplicated(p, s))
            end
        else
            push!(args, Const(p))
        end
    end
    
    tape = tape::Tape

    if tape.shadow_return !== nothing
        val = tape.shadow_return
        if !(val isa tape.resT)
            val = tape.shadow_return[]
        end
        push!(args, val)
    end
    if tape.internal_tape !== nothing
        push!(args, tape.internal_tape)
    end

    tup = tape.thunk(args...)

    for (d, (s, i)) in zip(tup, actives)
        a = unsafe_load(s, i)
        # While `RefValue{T}` and boxed T for immutable are bitwise compatible
        # they are not idempotent on the Julia level. We could "force" `a` to be
        # a boxed T, but would lose the mutable memory semantics that Enzyme requires
        if a isa Base.RefValue
            @assert eltype(a) == typeof(d)
            a[] += d
        else
            ref = unsafe_load(reinterpret(Ptr{Ptr{typeof(a)}}, s), i)
            unsafe_store!(ref, d+a)
        end
    end
    
    return nothing
end

function runtime_apply_latest_fwd(ret_ptr::Ptr{Any}, fn::Any, arg_ptr::Ptr{Any}, shadow_ptr::Ptr{Any}, activity_ptr::Ptr{UInt8}, arg_size::UInt32)
    # Note: We shall not unsafe_wrap any of the Ptr{Any}, since these are stack allocations
    #       As an example, if the Array created by unsafe_wrap get's moved to the remset it
    #       will constitute a leak of the stack allocation, and GC will find delicous garbage.
    __activity = Base.unsafe_wrap(Array, activity_ptr, arg_size)

    args = Any[]
    for i in 1:arg_size
        p = Base.unsafe_load(arg_ptr, i)
        if __activity[i] != 0
            s = Base.unsafe_load(shadow_ptr, i)
            push!(args, Duplicated(p, s))
        else
            push!(args, Const(p))
        end
    end

    tt = Tuple{map(x->eltype(Core.Typeof(x)), args)...}
    rt = Core.Compiler.return_type(fn, tt)
    annotation = guess_activity(rt, API.DEM_ForwardMode)
    if annotation <: DuplicatedNoNeed
        annotation = Duplicated
    end

    tt′ = Tuple{map(Core.Typeof, args)...}
    forward = thunk(fn, #=dfn=#nothing, Duplicated, tt′, Val(API.DEM_ForwardMode))

    res = forward(args...)
    if annotation <: Duplicated
        Base.unsafe_store!(ret_ptr, res[1], 1)
        Base.unsafe_store!(ret_ptr, res[2], 2)
    else
        Base.unsafe_store!(ret_ptr, nothing, 1)
        Base.unsafe_store!(ret_ptr, nothing, 2)
    end
    return nothing
end

function runtime_apply_latest_augfwd(ret_ptr::Ptr{Any}, fn::Any, arg_ptr::Ptr{Any}, shadow_ptr::Ptr{Any}, activity_ptr::Ptr{UInt8}, arg_size::UInt32)
    # Note: We shall not unsafe_wrap any of the Ptr{Any}, since these are stack allocations
    #       As an example, if the Array created by unsafe_wrap get's moved to the remset it
    #       will constitute a leak of the stack allocation, and GC will find delicous garbage.
    __activity = Base.unsafe_wrap(Array, activity_ptr, arg_size)

    args = Any[]
    for i in 1:arg_size
        p = Base.unsafe_load(arg_ptr, i)
        if __activity[i] != 0
            if typeof(p) <: AbstractFloat || typeof(p) <: Complex{<:AbstractFloat}
                push!(args, Active(p))
            else
                s = Base.unsafe_load(shadow_ptr, i)
                push!(args, Duplicated(p, s))
            end
        else
            push!(args, Const(p))
        end
    end

    tt = Tuple{map(x->eltype(Core.Typeof(x)), args)...}
    rt = Core.Compiler.return_type(fn, tt)
    annotation = guess_activity(rt)

    tt′ = Tuple{map(Core.Typeof, args)...}
    forward, adjoint = thunk(fn, #=dfn=#nothing, annotation, tt′, Val(API.DEM_ReverseModePrimal))

    res = forward(args...)
    origRet = res[2]
    resT = typeof(origRet)
    Base.unsafe_store!(ret_ptr, origRet, 1)

    if annotation <: Active
        shadow_return = Ref(zero(resT))
        Base.unsafe_store!(ret_ptr, shadow_return, 2) # due to this store we need typetag
    elseif annotation <: Const
        Base.unsafe_store!(ret_ptr, origRet, 2)
        shadow_return = nothing
    elseif annotation <: Duplicated ||  annotation <: DuplicatedNoNeed
        shadow_return = nothing
        Base.unsafe_store!(ret_ptr, res[3], 2)
    else
        error("Unknown annotation")
    end
    internal_tape = res[1]

    tape = Tape(adjoint, internal_tape, shadow_return, resT)
    Base.unsafe_store!(ret_ptr, tape, 3)
    return nothing
end

function runtime_apply_latest_rev(fn::Any, arg_ptr::Ptr{Any}, shadow_ptr::Ptr{Any}, activity_ptr::Ptr{UInt8}, arg_size::UInt32, tape::Any)
    __activity = Base.unsafe_wrap(Array, activity_ptr, arg_size)
    args = []
    actives = []
    for i in 1:arg_size
        p = Base.unsafe_load(arg_ptr, i)
        if __activity[i] != 0
            if typeof(p) <: AbstractFloat || typeof(p) <: Complex{<:AbstractFloat}
                push!(args, Active(p))
                push!(actives, (shadow_ptr, i))
            else
                s = Base.unsafe_load(shadow_ptr, i)
                push!(args, Duplicated(p, s))
            end
        else
            push!(args, Const(p))
        end
    end

    tape = tape::Tape

    if tape.shadow_return !== nothing
        val = tape.shadow_return
        if !(val isa tape.resT)
            val = tape.shadow_return[]
        end
        push!(args, val)
    end
    if tape.internal_tape !== nothing
        push!(args, tape.internal_tape)
    end

    tup = tape.thunk(args...)

    for (d, (s, i)) in zip(tup, actives)
        a = unsafe_load(s, i)
        # While `RefValue{T}` and boxed T for immutable are bitwise compatible
        # they are not idempotent on the Julia level. We could "force" `a` to be
        # a boxed T, but would lose the mutable memory semantics that Enzyme requires
        if a isa Base.RefValue
            @assert eltype(a) == typeof(d)
            a[] += d
        else
            ref = unsafe_load(reinterpret(Ptr{Ptr{typeof(a)}}, s), i)
            unsafe_store!(ref, d+a)
        end
    end
    
    return nothing
end

function emit_gc_preserve_begin(B::LLVM.Builder, args=LLVM.Value[])
    curent_bb = position(B)
    fn = LLVM.parent(curent_bb)
    mod = LLVM.parent(fn)
    ctx = context(mod)

    func = get_function!(mod, "llvm.julia.gc_preserve_begin") do mod, ctx, name
        funcT = LLVM.FunctionType(LLVM.TokenType(ctx), vararg=true)
        LLVM.Function(mod, name, funcT)
    end

    token = call!(B, func, args)
    return token
end

function emit_gc_preserve_end(B::LLVM.Builder, token)
    curent_bb = position(B)
    fn = LLVM.parent(curent_bb)
    mod = LLVM.parent(fn)
    ctx = context(mod)

    func = get_function!(mod, "llvm.julia.gc_preserve_end") do mod, ctx, name
        funcT = LLVM.FunctionType(LLVM.VoidType(ctx), [LLVM.TokenType(ctx)])
        LLVM.Function(mod, name, funcT)
    end

    call!(B, func, [token])
    return
end

function genericSetup(orig, gutils, start, ctx::LLVM.Context, B::LLVM.Builder, fun, numRet, lookup, tape)
    T_int8 = LLVM.Int8Type(ctx)
    T_pint8 = LLVM.PointerType(T_int8)
    T_int32 = LLVM.Int32Type(ctx)
    T_jlvalue = LLVM.StructType(LLVMType[]; ctx)
    T_prjlvalue = LLVM.PointerType(T_jlvalue, #= AddressSpace::Tracked =# 10)
    T_pprjlvalue = LLVM.PointerType(T_prjlvalue)

    ops = collect(operands(orig))[(start+1):end-1]

    num = convert(UInt32, length(ops))
    llnum = LLVM.ConstantInt(num; ctx)

    EB = LLVM.Builder(ctx)
    position!(EB, LLVM.BasicBlock(API.EnzymeGradientUtilsAllocationBlock(gutils)))

    # TODO: Optimization by emitting liverange
    ret = numRet == 0 ? LLVM.null(T_pprjlvalue) : LLVM.alloca!(EB, LLVM.ArrayType(T_prjlvalue, numRet))
    primal = LLVM.alloca!(EB, LLVM.ArrayType(T_prjlvalue, num))
    shadow = LLVM.alloca!(EB, LLVM.ArrayType(T_prjlvalue, num))
    activity = LLVM.alloca!(EB, LLVM.ArrayType(T_int8, num))

    for i in 1:numRet
        idx = LLVM.Value[LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(i-1; ctx)]
        LLVM.store!(B, LLVM.null(T_prjlvalue), LLVM.inbounds_gep!(B, ret, idx))
    end

    jl_fn = API.EnzymeGradientUtilsNewFromOriginal(gutils, operands(orig)[start])
    if lookup
        jl_fn = API.EnzymeGradientUtilsLookup(gutils, jl_fn, B)
    end
    vals = LLVM.Value[LLVM.Value(jl_fn), primal, shadow, activity, llnum]
    if numRet != 0
        pushfirst!(vals, ret)
    end

    # to_preserve = LLVM.Value[primal, shadow]
    to_preserve = LLVM.Value[]


    for (i, op) in enumerate(ops)
        idx = LLVM.Value[LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(i-1; ctx)]
        val = LLVM.Value(API.EnzymeGradientUtilsNewFromOriginal(gutils, op))
        if lookup
            val = LLVM.Value(API.EnzymeGradientUtilsLookup(gutils, val, B))
        end
        push!(to_preserve, val)
        LLVM.store!(B, val, LLVM.inbounds_gep!(B, primal, idx))

        active = API.EnzymeGradientUtilsIsConstantValue(gutils, op) == 0
        activeC = LLVM.ConstantInt(T_int8, active)
        LLVM.store!(B, activeC, LLVM.inbounds_gep!(B, activity, idx))

        if active
            inverted = LLVM.Value(API.EnzymeGradientUtilsInvertPointer(gutils, op, B))
            if lookup
                inverted = LLVM.Value(API.EnzymeGradientUtilsLookup(gutils, inverted, B))
            end
            push!(to_preserve, inverted)
            LLVM.store!(B, inverted,
                        LLVM.inbounds_gep!(B, shadow, idx))
        else
            LLVM.store!(B, LLVM.null(llvmtype(op)),
                        LLVM.inbounds_gep!(B, shadow, idx))
        end
    end


    T_args = LLVM.LLVMType[T_prjlvalue, LLVM.llvmtype(primal), LLVM.llvmtype(shadow), LLVM.llvmtype(activity), T_int32]
    if tape != C_NULL
        push!(T_args, T_prjlvalue)
        push!(vals, LLVM.Value(tape))
        push!(to_preserve, LLVM.Value(tape))
    end
    if numRet != 0
        pushfirst!(T_args, LLVM.llvmtype(ret))
        push!(to_preserve, ret)
    end
    token = emit_gc_preserve_begin(B, to_preserve)
    fnT = LLVM.FunctionType(LLVM.VoidType(ctx), T_args)
    rtfn = LLVM.inttoptr!(B, LLVM.ConstantInt(convert(UInt64, fun); ctx), LLVM.PointerType(fnT))
    cal = LLVM.call!(B, rtfn, vals)
    if numRet != 0
        @static if VERSION >= v"1.7.0" # LLVM12+
            sret_attr = TypeAttribute("sret", LLVM.llvmtype(ret); ctx)
        else
            sret_attr = EnumAttribute("sret"; ctx)
        end
        LLVM.API.LLVMAddCallSiteAttribute(cal, reinterpret(LLVM.API.LLVMAttributeIndex, Int32(1)), sret_attr)
    end

    # TODO: GC, ret
    return ret, token
end

function generic_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    orig = LLVM.Instruction(OrigCI)
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    shadow = (unsafe_load(shadowR) != C_NULL) ? LLVM.Instruction(unsafe_load(shadowR)) : nothing
    mod = LLVM.parent(LLVM.parent(LLVM.parent(orig)))
    ctx = LLVM.context(orig)

    conv = LLVM.API.LLVMGetInstructionCallConv(orig)
    # https://github.com/JuliaLang/julia/blob/5162023b9b67265ddb0bbbc0f4bd6b225c429aa0/src/codegen_shared.h#L20
    @assert conv == 37

    B = LLVM.Builder(B)

    ret, token = genericSetup(orig, gutils, #=start=#1, ctx, B, @cfunction(runtime_generic_fwd, Cvoid, (Ptr{Any}, Any, Ptr{Any}, Ptr{Any}, Ptr{UInt8}, UInt32)), #=numRet=#2, false, C_NULL)

    if shadowR != C_NULL
        shadow = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(1; ctx)]))
        unsafe_store!(shadowR, shadow.ref)
    end

    if normalR != C_NULL
        normal = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(0; ctx)]))
        unsafe_store!(normalR, normal.ref)
    end

    emit_gc_preserve_end(B, token)

    return nothing
end
function generic_augfwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    orig = LLVM.Instruction(OrigCI)
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    shadow = (unsafe_load(shadowR) != C_NULL) ? LLVM.Instruction(unsafe_load(shadowR)) : nothing
    mod = LLVM.parent(LLVM.parent(LLVM.parent(orig)))
    ctx = LLVM.context(orig)

    conv = LLVM.API.LLVMGetInstructionCallConv(orig)
    # https://github.com/JuliaLang/julia/blob/5162023b9b67265ddb0bbbc0f4bd6b225c429aa0/src/codegen_shared.h#L20
    @assert conv == 37

    B = LLVM.Builder(B)

    ret, token = genericSetup(orig, gutils, #=start=#1, ctx, B, @cfunction(runtime_generic_augfwd, Cvoid, (Ptr{Any}, Any, Ptr{Any}, Ptr{Any}, Ptr{UInt8}, UInt32)), #=numRet=#3, false, C_NULL)

    if shadowR != C_NULL
        shadow = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(1; ctx)]))
        unsafe_store!(shadowR, shadow.ref)
    end

    if normalR != C_NULL
        normal = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(0; ctx)]))
        unsafe_store!(normalR, normal.ref)
    end

    tape = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(2; ctx)]))
    unsafe_store!(tapeR, tape.ref)

    emit_gc_preserve_end(B, token)

    return nothing
end

function generic_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    orig = LLVM.Instruction(OrigCI)
    mod = LLVM.parent(LLVM.parent(LLVM.parent(orig)))
    ctx = LLVM.context(orig)

    B = LLVM.Builder(B)

    _, token = genericSetup(orig, gutils, #=start=#1, ctx, B, @cfunction(runtime_generic_rev, Cvoid, (Any, Ptr{Any}, Ptr{Any}, Ptr{UInt8}, UInt32, Any)), #=numRet=#0, true, tape)
    emit_gc_preserve_end(B, token)

    return nothing
end


function invoke_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    orig = LLVM.Instruction(OrigCI)
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    shadow = (unsafe_load(shadowR) != C_NULL) ? LLVM.Instruction(unsafe_load(shadowR)) : nothing
    mod = LLVM.parent(LLVM.parent(LLVM.parent(orig)))
    ctx = LLVM.context(orig)

    conv = LLVM.API.LLVMGetInstructionCallConv(orig)
    # https://github.com/JuliaLang/julia/blob/5162023b9b67265ddb0bbbc0f4bd6b225c429aa0/src/codegen_shared.h#L20
    @assert conv == 38

    B = LLVM.Builder(B)

    ret, token = genericSetup(orig, gutils, #=start=#1, ctx, B, @cfunction(runtime_invoke_fwd, Cvoid, (Ptr{Any}, Any, Ptr{Any}, Ptr{Any}, Ptr{UInt8}, UInt32)), #=numRet=#2, false, C_NULL)

    if shadowR != C_NULL
        shadow = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(1; ctx)]))
        unsafe_store!(shadowR, shadow.ref)
    end

    if normalR != C_NULL
        normal = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(0; ctx)]))
        unsafe_store!(normalR, normal.ref)
    end

    emit_gc_preserve_end(B, token)

    return nothing
end
function invoke_augfwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    orig = LLVM.Instruction(OrigCI)
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    shadow = (unsafe_load(shadowR) != C_NULL) ? LLVM.Instruction(unsafe_load(shadowR)) : nothing
    mod = LLVM.parent(LLVM.parent(LLVM.parent(orig)))
    ctx = LLVM.context(orig)

    conv = LLVM.API.LLVMGetInstructionCallConv(orig)
    # https://github.com/JuliaLang/julia/blob/5162023b9b67265ddb0bbbc0f4bd6b225c429aa0/src/codegen_shared.h#L20
    @assert conv == 38

    B = LLVM.Builder(B)

    ret, token = genericSetup(orig, gutils, #=start=#1, ctx, B, @cfunction(runtime_invoke_augfwd, Cvoid, (Ptr{Any}, Any, Ptr{Any}, Ptr{Any}, Ptr{UInt8}, UInt32)), #=numRet=#3, false, C_NULL)

    if shadowR != C_NULL
        shadow = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(1; ctx)]))
        unsafe_store!(shadowR, shadow.ref)
    end

    if normalR != C_NULL
        normal = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(0; ctx)]))
        unsafe_store!(normalR, normal.ref)
    end

    tape = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(2; ctx)]))
    unsafe_store!(tapeR, tape.ref)

    emit_gc_preserve_end(B, token)

    return nothing
end

function invoke_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    orig = LLVM.Instruction(OrigCI)
    mod = LLVM.parent(LLVM.parent(LLVM.parent(orig)))
    ctx = LLVM.context(orig)
    
    conv = LLVM.API.LLVMGetInstructionCallConv(orig)
    # https://github.com/JuliaLang/julia/blob/5162023b9b67265ddb0bbbc0f4bd6b225c429aa0/src/codegen_shared.h#L20
    @assert conv == 38

    B = LLVM.Builder(B)

    _, token = genericSetup(orig, gutils, #=start=#1, ctx, B, @cfunction(runtime_invoke_rev, Cvoid, (Any, Ptr{Any}, Ptr{Any}, Ptr{UInt8}, UInt32, Any)), #=numRet=#0, true, tape)
    emit_gc_preserve_end(B, token)

    return nothing
end

function apply_latest_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    orig = LLVM.Instruction(OrigCI)
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    shadow = (unsafe_load(shadowR) != C_NULL) ? LLVM.Instruction(unsafe_load(shadowR)) : nothing
    mod = LLVM.parent(LLVM.parent(LLVM.parent(orig)))
    ctx = LLVM.context(orig)

    conv = LLVM.API.LLVMGetInstructionCallConv(orig)
    # https://github.com/JuliaLang/julia/blob/5162023b9b67265ddb0bbbc0f4bd6b225c429aa0/src/codegen_shared.h#L20
    @assert conv == 37

    B = LLVM.Builder(B)

    ret, token = genericSetup(orig, gutils, #=start=#2, ctx, B, @cfunction(runtime_apply_latest_fwd, Cvoid, (Ptr{Any}, Any, Ptr{Any}, Ptr{Any}, Ptr{UInt8}, UInt32)), #=numRet=#2, false, C_NULL)

    if shadowR != C_NULL
        shadow = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(1; ctx)]))
        unsafe_store!(shadowR, shadow.ref)
    end

    if normalR != C_NULL
        normal = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(0; ctx)]))
        unsafe_store!(normalR, normal.ref)
    end

    emit_gc_preserve_end(B, token)

    return nothing
end

function apply_latest_augfwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    orig = LLVM.Instruction(OrigCI)
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    shadow = (unsafe_load(shadowR) != C_NULL) ? LLVM.Instruction(unsafe_load(shadowR)) : nothing
    mod = LLVM.parent(LLVM.parent(LLVM.parent(orig)))
    ctx = LLVM.context(orig)

    conv = LLVM.API.LLVMGetInstructionCallConv(orig)
    # https://github.com/JuliaLang/julia/blob/5162023b9b67265ddb0bbbc0f4bd6b225c429aa0/src/codegen_shared.h#L20
    @assert conv == 37

    B = LLVM.Builder(B)

    ret, token = genericSetup(orig, gutils, #=start=#2, ctx, B, @cfunction(runtime_apply_latest_augfwd, Cvoid, (Ptr{Any}, Any, Ptr{Any}, Ptr{Any}, Ptr{UInt8}, UInt32)), #=numRet=#3, false, C_NULL)

    if shadowR != C_NULL
        shadow = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(1; ctx)]))
        unsafe_store!(shadowR, shadow.ref)
    end

    if normalR != C_NULL
        normal = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(0; ctx)]))
        unsafe_store!(normalR, normal.ref)
    end

    tape = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx), LLVM.ConstantInt(2; ctx)]))
    unsafe_store!(tapeR, tape.ref)

    emit_gc_preserve_end(B, token)

    return nothing
end

function apply_latest_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    orig = LLVM.Instruction(OrigCI)
    ctx = LLVM.context(orig)

    B = LLVM.Builder(B)

    _, token = genericSetup(orig, gutils, #=start=#2, ctx, B, @cfunction(runtime_apply_latest_rev, Cvoid, (Any, Ptr{Any}, Ptr{Any}, Ptr{UInt8}, UInt32, Any)), #=numRet=#0, true, tape)
    emit_gc_preserve_end(B, token)

    return nothing
end

function emit_error(B::LLVM.Builder, string)
    curent_bb = position(B)
    fn = LLVM.parent(curent_bb)
    mod = LLVM.parent(fn)
    ctx = context(mod)

    # 1. get the error function
    func = get_function!(mod, "jl_error") do mod, ctx, name
        funcT = LLVM.FunctionType(LLVM.VoidType(ctx), LLVMType[LLVM.PointerType(LLVM.Int8Type(ctx))])
        func = LLVM.Function(mod, name, funcT)
        push!(function_attributes(func), EnumAttribute("noreturn"; ctx))
        return func
    end

    # 2. Call error function and insert unreachable
    call!(B, func, LLVM.Value[globalstring_ptr!(B, string)])

    # FIXME(@wsmoses): Allow for emission of new BB in this code path
    # unreachable!(B)

    # 3. Change insertion point so that we don't stumble later
    # after_error = BasicBlock(fn, "after_error"; ctx)
    # position!(B, after_error)
end

function noop_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    orig = LLVM.Instruction(OrigCI)
    return nothing
end

function noop_augfwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    orig = LLVM.Instruction(OrigCI)
    return nothing
end

function duplicate_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    orig = LLVM.Instruction(OrigCI)
    newg = API.EnzymeGradientUtilsNewFromOriginal(gutils, orig)
    
    B = LLVM.Builder(B)

    real_ops = collect(operands(orig))
    ops = [LLVM.Value(API.EnzymeGradientUtilsLookup(gutils, API.EnzymeGradientUtilsNewFromOriginal(gutils, o), B)) for o in real_ops]
    call!(B, ops[end], ops[1:end-1])
    return nothing
end

function threadsfor_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    orig = LLVM.Instruction(OrigCI)
    mod = LLVM.parent(LLVM.parent(LLVM.parent(orig)))
    ctx = LLVM.context(orig)

    fun = @cfunction(runtime_newtask_fwd, Any, (Any, Any, Any, Int))

    B = LLVM.Builder(B)
    emit_error("fast pfor not implemented");
    return nothing
end

let counter = Ref{Int64}(0)
    global getid() = counter[] += 1
end
const leaked_objs = Base.Dict{Int64, Any}()

if VERSION < v"1.8-"
function runtime_pfor_augfwd(func, dfunc)::Int64
	# tape = vec{Any}(numthreads())
	# pfor threads tape[i] = aug(func, dfunc)
    
	tt = Tuple{}
    # TODO with the MI itself, we should be able to hoist the thunk generation into
    # the original compilation (rather than runtime JIT compiling)
    forward, adjoint = thunk(func, dfunc, Const, tt, Val(API.DEM_ReverseModePrimal))

	tapes = Vector{Ptr{Cvoid}}(undef, Base.Threads.nthreads())
    # tapes = unsafe_convert(Ptr{Ptr{Cvoid}}, Libc.malloc(sizeof(Ptr{Cvoid})*Base.Threads.nthreads))
	function fwd()
		tapes[Base.Threads.threadid()] = forward()[1]
	end
	adj = () -> adjoint(tapes[Base.Threads.threadid()])
    id = getid()
    leaked_objs[id] = adj
	Base.Threads.threading_run(fwd)
    # Note: `adj` is an immutable object, and thus has pass-by-value semantics
    #       directly returning here allocates a heap object whose pointer is then leaked
    #       onto the tape and GC, will kill it. Until we have proper tape+GC support,
    #       we stash the object in a global dict, and return the id of the object
    return id
end

function runtime_pfor_rev(id::Int64)
    tape = leaked_objs[id]
    delete!(leaked_objs, id)
	Base.Threads.threading_run(tape)
    return nothing
end
else 
function runtime_pfor_augfwd(func, dfunc, dynamic)::Int64
	# tape = vec{Any}(numthreads())
	# pfor threads tape[i] = aug(func, dfunc)
    
	tt = Tuple{}
    # TODO with the MI itself, we should be able to hoist the thunk generation into
    # the original compilation (rather than runtime JIT compiling)
    forward, adjoint = thunk(func, dfunc, Const, tt, Val(API.DEM_ReverseModePrimal))

	tapes = Vector{Ptr{Cvoid}}(undef, Base.Threads.nthreads())
    # tapes = unsafe_convert(Ptr{Ptr{Cvoid}}, Libc.malloc(sizeof(Ptr{Cvoid})*Base.Threads.nthreads))
	function fwd()
		tapes[Base.Threads.threadid()] = forward()[1]
	end
	adj = () -> adjoint(tapes[Base.Threads.threadid()])
    id = getid()
    leaked_objs[id] = adj
	Base.Threads.threading_run(fwd, dynamic)
    # Note: `adj` is an immutable object, and thus has pass-by-value semantics
    #       directly returning here allocates a heap object whose pointer is then leaked
    #       onto the tape and GC, will kill it. Until we have proper tape+GC support,
    #       we stash the object in a global dict, and return the id of the object
    return id
end

function runtime_pfor_rev(id::Int64, dynamic)
    tape = leaked_objs[id]
    delete!(leaked_objs, id)
	Base.Threads.threading_run(tape, dynamic)
    return nothing
end
end

function threadsfor_augfwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    orig = LLVM.Instruction(OrigCI)
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    shadow = (unsafe_load(shadowR) != C_NULL) ? LLVM.Instruction(unsafe_load(shadowR)) : nothing

    mod = LLVM.parent(LLVM.parent(LLVM.parent(orig)))
    ctx = LLVM.context(orig)

    llvmfn = LLVM.called_value(orig)
    mi = nothing
    for fattr in collect(function_attributes(llvmfn))
        if isa(fattr, LLVM.StringAttribute)
            if kind(fattr) == "enzymejl_mi"
                ptr = reinterpret(Ptr{Cvoid}, parse(Int, LLVM.value(fattr)))
                mi = Base.unsafe_pointer_to_objref(ptr)
                break
            end
        end
    end

	funcT = mi.specTypes.parameters[2]

@static if VERSION < v"1.8-"
    tt = Tuple{funcT, funcT} #annotate_tuple_type(mi.specTypes, activity)
    extraArgs = 0
else
    tt = Tuple{funcT, funcT, Bool}
    extraArgs = 1
end
    @warn "active variables passeed by value to jl_threadsfor are not yet supported"
    funcspec = FunctionSpec(runtime_pfor_augfwd, tt, #=kernel=# false, #=name=# nothing)

    # 3) Use the MI to create the correct augmented fwd/reverse
    # TODO:
    #  - GPU support
    #  - When OrcV2 only use a MaterializationUnit to avoid mutation of the module here


    target = GPUCompiler.NativeCompilerTarget()
    params = Compiler.PrimalCompilerParams()
    job    = CompilerJob(target, funcspec, params)  

    otherMod, meta = GPUCompiler.codegen(:llvm, job; optimize=false, validate=false, ctx)
    entry = name(meta.entry)

    # 4) Link the corresponding module
    LLVM.link!(mod, otherMod)

    # 5) Call the function
    entry = functions(mod)[entry]

    B = LLVM.Builder(B)
    
    T_int64 = LLVM.Int64Type(ctx)
    T_jlvalue = LLVM.StructType(LLVMType[]; ctx)
    T_prjlvalue = LLVM.PointerType(T_jlvalue, #= AddressSpace::Tracked =# 10)
    T_pprjlvalue = LLVM.PointerType(T_prjlvalue)

    ops = collect(operands(orig))[1:end-1]


	vals = LLVM.Value[]
	# TODO check if ghost type
	if length(ops) > extraArgs
		for real in [ LLVM.Value(API.EnzymeGradientUtilsNewFromOriginal(gutils, ops[1])), LLVM.Value(API.EnzymeGradientUtilsInvertPointer(gutils, ops[1], B))]
			push!(vals, real)
		end
        to_preserve = LLVM.Value[vals[1], vals[2]]
        T_args = LLVM.LLVMType[T_prjlvalue, T_prjlvalue]
    else
        to_preserve = LLVM.Value[]
        T_args = LLVM.LLVMType[]
	end
@static if VERSION < v"1.8-"
else
        push!(vals, LLVM.Value(API.EnzymeGradientUtilsNewFromOriginal(gutils, ops[end])))
end
    token = emit_gc_preserve_begin(B, to_preserve)

    T_args = LLVM.LLVMType[T_int64,]
    tape = LLVM.call!(B, entry, vals)
    
    emit_gc_preserve_end(B, token)

    # Delete the primal code
    if normal !== nothing
        unsafe_store!(normalR, C_NULL)
    else
        LLVM.API.LLVMInstructionEraseFromParent(LLVM.Instruction(API.EnzymeGradientUtilsNewFromOriginal(gutils, orig)))
    end

    unsafe_store!(tapeR, tape.ref)

    return nothing
end

function threadsfor_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    orig = LLVM.Instruction(OrigCI)
    tape = LLVM.Value(tape)
    ctx = LLVM.context(orig)
@static if VERSION < v"1.8-"
    fun = @cfunction(runtime_pfor_rev, Cvoid, (Int64,))
else
    fun = @cfunction(runtime_pfor_rev, Cvoid, (Int64,Bool))
end
    
	B = LLVM.Builder(B)
    ops = collect(operands(orig))[1:end-1]
    
	vals = LLVM.Value[tape]
    to_preserve = LLVM.Value[vals[1]]
    token = emit_gc_preserve_begin(B, to_preserve)
    T_jlvalue = LLVM.StructType(LLVMType[]; ctx)
    T_prjlvalue = LLVM.PointerType(T_jlvalue, #= AddressSpace::Tracked =# 10)
    T_int64 = LLVM.Int64Type(ctx)

@static if VERSION < v"1.8-"
    T_args = LLVM.LLVMType[T_int64]
else
    T_args = LLVM.LLVMType[T_int64, LLVM.Int8Type(ctx)]
end
    fnT = LLVM.FunctionType(LLVM.VoidType(ctx), T_args)
    rtfn = LLVM.inttoptr!(B, LLVM.ConstantInt(convert(UInt64, fun); ctx), LLVM.PointerType(fnT))
@static if VERSION < v"1.8-"
else
        push!(vals, LLVM.Value(API.EnzymeGradientUtilsLookup(gutils, API.EnzymeGradientUtilsNewFromOriginal(gutils, ops[end]), B)))
end
    LLVM.call!(B, rtfn, vals)
    
    emit_gc_preserve_end(B, token)
    return nothing
end

include("pmap.jl")

function newtask_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    orig = LLVM.Instruction(OrigCI)
    mod = LLVM.parent(LLVM.parent(LLVM.parent(orig)))
    ctx = LLVM.context(orig)

    fun = @cfunction(runtime_newtask_fwd, Any, (Any, Any, Any, Int))

    B = LLVM.Builder(B)
    
    T_int64 = LLVM.Int64Type(ctx)
    T_jlvalue = LLVM.StructType(LLVMType[]; ctx)
    T_prjlvalue = LLVM.PointerType(T_jlvalue, #= AddressSpace::Tracked =# 10)
    T_pprjlvalue = LLVM.PointerType(T_prjlvalue)

    ops = collect(operands(orig))

    vals = LLVM.Value[ LLVM.Value(API.EnzymeGradientUtilsNewFromOriginal(gutils, ops[1])),
                       LLVM.Value(API.EnzymeGradientUtilsInvertPointer(gutils, ops[1], B)),
                       LLVM.Value(API.EnzymeGradientUtilsNewFromOriginal(gutils, ops[2])),
                       LLVM.Value(API.EnzymeGradientUtilsNewFromOriginal(gutils, ops[3]))]

    to_preserve = LLVM.Value[vals[1], vals[2], vals[3]]
    token = emit_gc_preserve_begin(B, to_preserve)

    T_args = LLVM.LLVMType[T_prjlvalue, T_prjlvalue, T_prjlvalue, T_int64]
    
    fnT = LLVM.FunctionType(T_prjlvalue, T_args)
    rtfn = LLVM.inttoptr!(B, LLVM.ConstantInt(convert(UInt64, fun); ctx), LLVM.PointerType(fnT))
    ntask = LLVM.call!(B, rtfn, vals)

    # TODO: GC, ret
    if shadowR != C_NULL
        unsafe_store!(shadowR, ntask.ref)
    end

    if normalR != C_NULL
        unsafe_store!(normalR, ntask.ref)
    end

    emit_gc_preserve_end(B, token)

    return nothing
end

function newtask_augfwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    # fn, dfn = augmentAndGradient(fn)
    # t = jl_new_task(fn)
    # # shadow t
    # dt = jl_new_task(dfn)
    orig = LLVM.Instruction(OrigCI)
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    shadow = (unsafe_load(shadowR) != C_NULL) ? LLVM.Instruction(unsafe_load(shadowR)) : nothing
    mod = LLVM.parent(LLVM.parent(LLVM.parent(orig)))
    ctx = LLVM.context(orig)

    @warn "active variables passeed by value to jl_new_task are not yet supported"
    fun = @cfunction(runtime_newtask_augfwd, Cvoid, (Ptr{Any}, Any, Any, Any, Int))

    B = LLVM.Builder(B)
    
    T_int64 = LLVM.Int64Type(ctx)
    T_jlvalue = LLVM.StructType(LLVMType[]; ctx)
    T_prjlvalue = LLVM.PointerType(T_jlvalue, #= AddressSpace::Tracked =# 10)
    T_pprjlvalue = LLVM.PointerType(T_prjlvalue)

    ops = collect(operands(orig))[1:end-1]

    EB = LLVM.Builder(ctx)
    position!(EB, LLVM.BasicBlock(API.EnzymeGradientUtilsAllocationBlock(gutils)))

    # TODO: Optimization by emitting liverange
    ret = LLVM.array_alloca!(EB, T_prjlvalue, LLVM.ConstantInt(2; ctx))

    for i in 1:2
        idx = LLVM.Value[LLVM.ConstantInt(i-1; ctx)]
        LLVM.store!(B, LLVM.null(T_prjlvalue), LLVM.inbounds_gep!(B, ret, idx))
    end

    vals = LLVM.Value[ret,
                       LLVM.Value(API.EnzymeGradientUtilsNewFromOriginal(gutils, ops[1])),
                       LLVM.Value(API.EnzymeGradientUtilsInvertPointer(gutils, ops[1], B)),
                       LLVM.Value(API.EnzymeGradientUtilsNewFromOriginal(gutils, ops[2])),
                       LLVM.Value(API.EnzymeGradientUtilsNewFromOriginal(gutils, ops[3]))]

    to_preserve = LLVM.Value[vals[2], vals[3]]
    token = emit_gc_preserve_begin(B, to_preserve)

    T_args = LLVM.LLVMType[T_pprjlvalue, T_prjlvalue, T_prjlvalue, T_prjlvalue, T_int64]
    
    fnT = LLVM.FunctionType(LLVM.VoidType(ctx), T_args)
    rtfn = LLVM.inttoptr!(B, LLVM.ConstantInt(convert(UInt64, fun); ctx), LLVM.PointerType(fnT))
    LLVM.call!(B, rtfn, vals)

    # TODO: GC, ret
    if shadowR != C_NULL
        shadow = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(1; ctx)]))
        unsafe_store!(shadowR, shadow.ref)
    end

    if normalR != C_NULL
        normal = LLVM.load!(B, LLVM.inbounds_gep!(B, ret, [LLVM.ConstantInt(0; ctx)]))
        unsafe_store!(normalR, normal.ref)
    end

    emit_gc_preserve_end(B, token)

    return nothing
end

function newtask_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    return nothing
end

function enq_work_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    if shadowR != C_NULL && normal !== nothing
        unsafe_store!(shadowR, normal.ref)
    end

    return nothing
end

function enq_work_augfwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    if shadowR != C_NULL && normal !== nothing
        unsafe_store!(shadowR, normal.ref)
    end

    return nothing
end

function find_match(mod, name)
    for f in functions(mod)
        iter = function_attributes(f)
        elems = Vector{LLVM.API.LLVMAttributeRef}(undef, length(iter))
        LLVM.API.LLVMGetAttributesAtIndex(iter.f, iter.idx, elems)
        for eattr in elems
            at = Attribute(eattr)
            if isa(at, LLVM.StringAttribute)
                if kind(at) == "enzyme_math"
                    if value(at) == name
                        return f
                    end
                end
            end
        end
    end
    return nothing
end

function enq_work_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    # jl_wait(shadow(t)) 
    orig = LLVM.Instruction(OrigCI)
    origops = LLVM.operands(orig)
    mod = LLVM.parent(LLVM.parent(LLVM.parent(orig)))
    waitfn = find_match(mod, "jl_wait")
    @assert waitfn !== nothing
    shadowtask = LLVM.Value(API.EnzymeGradientUtilsLookup(gutils, API.EnzymeGradientUtilsInvertPointer(gutils, origops[1], B), B))
    cal = LLVM.call!(LLVM.Builder(B), waitfn, [shadowtask])
    API.EnzymeGradientUtilsSetDebugLocFromOriginal(gutils, cal, orig)
    conv = LLVM.API.LLVMGetInstructionCallConv(orig)
    LLVM.API.LLVMSetInstructionCallConv(cal, conv)
    return nothing
end

function wait_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    if shadowR != C_NULL && normal !== nothing
        unsafe_store!(shadowR, normal.ref)
    end
    return nothing
end

function wait_augfwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    if shadowR != C_NULL && normal !== nothing
        unsafe_store!(shadowR, normal.ref)
    end
    return nothing
end

function wait_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    # jl_enq_work(shadow(t)) 
    orig = LLVM.Instruction(OrigCI)
    origops = LLVM.operands(orig)
    mod = LLVM.parent(LLVM.parent(LLVM.parent(orig)))
    enq_work_fn = find_match(mod, "jl_enq_work")
    @assert enq_work_fn !== nothing
    shadowtask = LLVM.Value(API.EnzymeGradientUtilsLookup(gutils, API.EnzymeGradientUtilsInvertPointer(gutils, origops[1], B), B))
    cal = LLVM.call!(LLVM.Builder(B), enq_work_fn, [shadowtask])
    API.EnzymeGradientUtilsSetDebugLocFromOriginal(gutils, cal, orig)
    conv = LLVM.API.LLVMGetInstructionCallConv(orig)
    LLVM.API.LLVMSetInstructionCallConv(cal, conv)
    return nothing
end

function arraycopy_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    
    orig = LLVM.Instruction(OrigCI)
    origops = LLVM.operands(orig)

    shadowin = LLVM.Value(API.EnzymeGradientUtilsInvertPointer(gutils, origops[1], B))
    shadowres = LLVM.call!(LLVM.Builder(B), LLVM.called_value(orig), [shadowin])
 
    unsafe_store!(shadowR, shadowres.ref)
	
	return nothing
end

function arraycopy_common(fwd, B, orig, origArg, gutils)
    # size_t len = jl_array_len(ary);
    # size_t elsz = ary->elsize;
    # memcpy(new_ary->data, ary->data, len * elsz);
	# JL_EXTENSION typedef struct {
	# 	JL_DATA_TYPE
	# 	void *data;
	# #ifdef STORE_ARRAY_LEN
	# 	size_t length;
	# #endif
	# 	jl_array_flags_t flags;
	# 	uint16_t elsize;  // element size including alignment (dim 1 memory stride)

	tt = TypeTree(API.EnzymeGradientUtilsAllocAndGetTypeTree(gutils, orig))
    mod = LLVM.parent(LLVM.parent(LLVM.parent(orig)))
	dl = string(LLVM.datalayout(mod))
	API.EnzymeTypeTreeLookupEq(tt, 1, dl)
	data0!(tt)
    ct = API.EnzymeTypeTreeInner0(tt)

    @assert ct != API.DT_Unknown
    ctx = LLVM.context(orig)
    secretty = API.EnzymeConcreteTypeIsFloat(ct, ctx)

    off = sizeof(Cstring)
    if true # STORE_ARRAY_LEN
        off += sizeof(Csize_t)
    end
    #jl_array_flags_t
    off += 2

    actualOp = LLVM.Value(API.EnzymeGradientUtilsNewFromOriginal(gutils, origArg))
    if fwd
        B0 = B
    elseif typeof(actualOp) <: LLVM.Argument
        B0 = LLVM.Builder(ctx)
        position!(B0, first(instructions(LLVM.BasicBlock(API.EnzymeGradientUtilsNewFromOriginal(gutils, LLVM.entry(LLVM.parent(LLVM.parent(orig))))))))
    else
        B0 = LLVM.Builder(ctx)
        position!(B0, LLVM.Instruction(LLVM.API.LLVMGetNextInstruction(actualOp)))
    end
    
    actualOp = pointercast!(B0, actualOp, LLVM.PointerType(LLVM.IntType(8; ctx), LLVM.addrspace(LLVM.llvmtype(actualOp))))

    elSize = gep!(B0, actualOp, [LLVM.ConstantInt(LLVM.IntType(64; ctx), off)])
    elSize = pointercast!(B0, elSize, LLVM.PointerType(LLVM.IntType(16; ctx), LLVM.addrspace(LLVM.llvmtype(actualOp))))
    elSize = LLVM.load!(B0, elSize)
    elSize = LLVM.zext!(B0, elSize, LLVM.IntType(8*sizeof(Csize_t); ctx))

    len = gep!(B0, actualOp, [LLVM.ConstantInt(LLVM.IntType(64; ctx), sizeof(Cstring))])
    len = pointercast!(B0, len, LLVM.PointerType(LLVM.IntType(8*sizeof(Csize_t); ctx), LLVM.addrspace(LLVM.llvmtype(actualOp))))
    len = LLVM.load!(B0, len)

    length = LLVM.mul!(B0, len, elSize)
    isVolatile = LLVM.ConstantInt(LLVM.IntType(1; ctx), 0)

    # forward pass copy already done by underlying call
    allowForward = false
    intrinsic = LLVM.Intrinsic("llvm.memcpy").id

    shadowdst = LLVM.Value(API.EnzymeGradientUtilsInvertPointer(gutils, orig, B))
    if !fwd
        shadowdst = LLVM.Value(API.EnzymeGradientUtilsLookup(gutils, shadowdst, B))
    end
    shadowdst = load!(B, bitcast!(B, shadowdst, LLVM.PointerType(LLVM.PointerType(LLVM.IntType(8; ctx), 13), LLVM.addrspace(LLVM.llvmtype(shadowdst)))))
    shadowsrc = LLVM.Value(API.EnzymeGradientUtilsInvertPointer(gutils, origArg, B))
    if !fwd
        shadowsrc = LLVM.Value(API.EnzymeGradientUtilsLookup(gutils, shadowsrc, B))
    end
    shadowsrc = load!(B, bitcast!(B, shadowsrc, LLVM.PointerType(LLVM.PointerType(LLVM.IntType(8; ctx), 13), LLVM.addrspace(LLVM.llvmtype(shadowsrc)))))

    API.EnzymeGradientUtilsSubTransferHelper(gutils, fwd ? API.DEM_ReverseModePrimal : API.DEM_ReverseModeGradient, secretty, intrinsic, #=dstAlign=#1, #=srcAlign=#1, #=offset=#0, false, shadowdst, false, shadowsrc, length, isVolatile, orig, allowForward, #=shadowsLookedUp=#!fwd)

    return nothing
end

function arraycopy_augfwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    
    orig = LLVM.Instruction(OrigCI)
    origops = LLVM.operands(orig)

    shadowin = LLVM.Value(API.EnzymeGradientUtilsInvertPointer(gutils, origops[1], B))
    shadowres = LLVM.call!(LLVM.Builder(B), LLVM.called_value(orig), [shadowin])
 
    unsafe_store!(shadowR, shadowres.ref)

    arraycopy_common(#=fwd=#true, LLVM.Builder(B), orig, origops[1], gutils)
	
	return nothing
end

function arraycopy_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    orig = LLVM.Instruction(OrigCI)
    origops = LLVM.operands(orig)
    arraycopy_common(#=fwd=#false, LLVM.Builder(B), orig, origops[1], gutils)
    return nothing
end

function f_tuple_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    emit_error(LLVM.Builder(B), "Enzyme: Not yet implemented augmented forward for jl_f_tuple")

    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    if shadowR != C_NULL && normal !== nothing
        unsafe_store!(shadowR, normal.ref)
    end

    return nothing
end

function f_tuple_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    emit_error(LLVM.Builder(B), "Enzyme: Not yet implemented reverse for jl_f_tuple")
    return nothing
end

function apply_iterate_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    emit_error(LLVM.Builder(B), "Enzyme: Not yet implemented augmented forward for jl_f__apply_iterate")

    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    if shadowR != C_NULL && normal !== nothing
        unsafe_store!(shadowR, normal.ref)
    end

    return nothing
end

function apply_iterate_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    emit_error(LLVM.Builder(B), "Enzyme: Not yet implemented reverse for jl_f__apply_iterate")
    return nothing
end

function new_structv_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    emit_error(LLVM.Builder(B), "Enzyme: Not yet implemented augmented forward for jl_new_struct")

    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    if shadowR != C_NULL && normal !== nothing
        unsafe_store!(shadowR, normal.ref)
    end

    return nothing
end

function new_structv_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    emit_error(LLVM.Builder(B), "Enzyme: Not yet implemented reverse for jl_new_struct")
    return nothing
end

function gcpreserve_begin_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    orig = LLVM.Instruction(OrigCI)

    ops = collect(operands(orig))[1:end-1]

    to_preserve = LLVM.Value[]

    for op in ops
        val = LLVM.Value(API.EnzymeGradientUtilsNewFromOriginal(gutils, op))
        push!(to_preserve, val)

        active = API.EnzymeGradientUtilsIsConstantValue(gutils, op) == 0

        if active
            push!(to_preserve, LLVM.Value(API.EnzymeGradientUtilsInvertPointer(gutils, op, B)))
        end
    end

    token = emit_gc_preserve_begin(LLVM.Builder(B), to_preserve)
    unsafe_store!(normalR, token.ref)

    return nothing
end

function gcpreserve_begin_augfwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    orig = LLVM.Instruction(OrigCI)

    ops = collect(operands(orig))[1:end-1]

    to_preserve = LLVM.Value[]

    for op in ops
        val = LLVM.Value(API.EnzymeGradientUtilsNewFromOriginal(gutils, op))
        push!(to_preserve, val)

        active = API.EnzymeGradientUtilsIsConstantValue(gutils, op) == 0

        if active
            push!(to_preserve, LLVM.Value(API.EnzymeGradientUtilsInvertPointer(gutils, op, B)))
        end
    end

    token = emit_gc_preserve_begin(LLVM.Builder(B), to_preserve)
    unsafe_store!(normalR, token.ref)

    return nothing
end

const GCToks = Dict{LLVM.Instruction, LLVM.Instruction}()

function gcpreserve_begin_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    builder = LLVM.Builder(B)
    orig = LLVM.Instruction(OrigCI)
    if haskey(GCToks, orig)
        token = GCToks[orig]
        delete!(GCToks, orig)
    else
        f   = LLVM.parent(orig)
        mod = LLVM.parent(f)
        ctx = LLVM.context(mod)

        
        token = emit_gc_preserve_begin(LLVM.Builder(B))
        # token = LLVM.phi!(builder, LLVM.TokenType(ctx), "placeholder")
        GCToks[orig] = token
    end
    emit_gc_preserve_end(builder, token)
    return nothing
end

function gcpreserve_end_augfwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    return nothing
end

function gcpreserve_end_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    orig = LLVM.Instruction(OrigCI)
    origPres = operands(orig)[1]

    ops = collect(operands(origPres))[1:end-1]

    to_preserve = LLVM.Value[]

    for op in ops
        val = LLVM.Value(API.EnzymeGradientUtilsLookup(gutils, API.EnzymeGradientUtilsNewFromOriginal(gutils, op), B))
        push!(to_preserve, val)

        active = API.EnzymeGradientUtilsIsConstantValue(gutils, op) == 0

        if active
            push!(to_preserve, LLVM.Value(API.EnzymeGradientUtilsLookup(gutils, API.EnzymeGradientUtilsInvertPointer(gutils, op, B), B)))
        end
    end

    token = emit_gc_preserve_begin(LLVM.Builder(B), to_preserve)

    if haskey(GCToks, origPres)
        placeHolder = GCToks[origPres]
        LLVM.replace_uses!(placeHolder, token)
        delete!(GCToks, origPres)
        LLVM.API.LLVMInstructionEraseFromParent(placeHolder)
    else
        GCToks[origPres] = token
    end

    return nothing
end


function setfield_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    emit_error(LLVM.Builder(B), "Enzyme: unhandled augmented forward for jl_f_setfield")
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    if shadowR != C_NULL && normal !== nothing
        unsafe_store!(shadowR, normal.ref)
    end
    return nothing
end

function setfield_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    emit_error(LLVM.Builder(B), "Enzyme: unhandled reverse for jl_f_setfield")
    return nothing
end

function get_binding_or_error_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    CI = API.EnzymeGradientUtilsNewFromOriginal(gutils, OrigCI)
    err = emit_error(LLVM.Builder(B), "Enzyme: unhandled augmented forward for jl_get_binding_or_error")
    API.moveBefore(CI, err)
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    if shadowR != C_NULL && normal !== nothing
        unsafe_store!(shadowR, normal.ref)
    end
    return nothing
end

function get_binding_or_error_augfwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    CI = API.EnzymeGradientUtilsNewFromOriginal(gutils, OrigCI)
    err = emit_error(LLVM.Builder(B), "Enzyme: unhandled augmented forward for jl_get_binding_or_error")
    API.moveBefore(CI, err)
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    if shadowR != C_NULL && normal !== nothing
        unsafe_store!(shadowR, normal.ref)
    end
    return nothing
end

function get_binding_or_error_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    emit_error(LLVM.Builder(B), "Enzyme: unhandled reverse for jl_get_binding_or_error")
    return nothing
end

function finalizer_fwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    CI = API.EnzymeGradientUtilsNewFromOriginal(gutils, OrigCI)
    err = emit_error(LLVM.Builder(B), "Enzyme: unhandled augmented forward for jl_gc_add_finalizer_th")
    API.moveBefore(CI, err)
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    if shadowR != C_NULL && normal !== nothing
        unsafe_store!(shadowR, normal.ref)
    end
    return nothing
end

function finalizer_augfwd(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, normalR::Ptr{LLVM.API.LLVMValueRef}, shadowR::Ptr{LLVM.API.LLVMValueRef}, tapeR::Ptr{LLVM.API.LLVMValueRef})::Cvoid
    orig = LLVM.Instruction(OrigCI)
    CI = API.EnzymeGradientUtilsNewFromOriginal(gutils, OrigCI)
    # err = emit_error(LLVM.Builder(B), "Enzyme: unhandled augmented forward for jl_gc_add_finalizer_th")
    # API.moveBefore(CI, err)
    normal = (unsafe_load(normalR) != C_NULL) ? LLVM.Instruction(unsafe_load(normalR)) : nothing
    if shadowR != C_NULL && normal !== nothing
        unsafe_store!(shadowR, normal.ref)
    end
    # Delete the primal code
    if normal !== nothing
        unsafe_store!(normalR, C_NULL)
    else
        LLVM.API.LLVMInstructionEraseFromParent(LLVM.Instruction(API.EnzymeGradientUtilsNewFromOriginal(gutils, orig)))
    end
    return nothing
end

function finalizer_rev(B::LLVM.API.LLVMBuilderRef, OrigCI::LLVM.API.LLVMValueRef, gutils::API.EnzymeGradientUtilsRef, tape::LLVM.API.LLVMValueRef)::Cvoid
    # emit_error(LLVM.Builder(B), "Enzyme: unhandled reverse for jl_gc_add_finalizer_th")
    return nothing
end


function register_handler!(variants, augfwd_handler, rev_handler, fwd_handler=nothing)
    for variant in variants
        API.EnzymeRegisterCallHandler(variant, augfwd_handler, rev_handler)
        if fwd_handler !== nothing
            API.EnzymeRegisterFwdCallHandler(variant, fwd_handler)
        end
    end
end

function register_alloc_handler!(variants, alloc_handler, free_handler)
    for variant in variants
        API.EnzymeRegisterAllocationHandler(variant, alloc_handler, free_handler)
    end
end

struct CompilationException <: Base.Exception
    msg::String
end
function Base.showerror(io::IO, ece::CompilationException)
    print(io, "Enzyme compilation failed with: ")
    print(io, ece.msg)
end

function julia_error(cstr::Cstring)
    throw(CompilationException(Base.unsafe_string(cstr)))
end

function __init__()
    API.EnzymeSetHandler(@cfunction(julia_error, Cvoid, (Cstring,)))
    register_alloc_handler!(
        ("jl_alloc_array_1d", "ijl_alloc_array_1d"),
        @cfunction(array_shadow_handler, LLVM.API.LLVMValueRef, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, Csize_t, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(null_free_handler, LLVM.API.LLVMValueRef, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, LLVM.API.LLVMValueRef))
    )
    register_alloc_handler!(
        ("jl_alloc_array_2d", "ijl_alloc_array_2d"),
        @cfunction(array_shadow_handler, LLVM.API.LLVMValueRef, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, Csize_t, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(null_free_handler, LLVM.API.LLVMValueRef, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, LLVM.API.LLVMValueRef))
    )
    register_alloc_handler!(
        ("jl_alloc_array_3d", "ijl_alloc_array_3d"),
        @cfunction(array_shadow_handler, LLVM.API.LLVMValueRef, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, Csize_t, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(null_free_handler, LLVM.API.LLVMValueRef, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, LLVM.API.LLVMValueRef))
    )
    register_handler!(
        ("jl_apply_generic", "ijl_apply_generic"),
        @cfunction(generic_augfwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(generic_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
        @cfunction(generic_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
    )
    register_handler!(
        ("jl_invoke", "ijl_invoke", "jl_f_invoke"),
        @cfunction(invoke_augfwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(invoke_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
        @cfunction(invoke_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
    )
    register_handler!(
        ("jl_f__apply_latest", "jl_f__call_latest"),
        @cfunction(apply_latest_augfwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(apply_latest_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
        @cfunction(apply_latest_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
    )
    register_handler!(
        ("jl_threadsfor",),
        @cfunction(threadsfor_augfwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(threadsfor_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
        @cfunction(threadsfor_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
    )
    register_handler!(
        ("jl_pmap",),
        @cfunction(pmap_augfwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(pmap_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
        @cfunction(pmap_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
    )
    register_handler!(
        ("jl_new_task", "ijl_new_task"),
        @cfunction(newtask_augfwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(newtask_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
        @cfunction(newtask_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
    )
    register_handler!(
        ("jl_enq_work",),
        @cfunction(enq_work_augfwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(enq_work_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
        @cfunction(enq_work_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}))
    )
    register_handler!(
        ("jl_wait",),
        @cfunction(wait_augfwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(wait_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
        @cfunction(wait_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
    )
    register_handler!(
        ("jl_","jl_breakpoint"),
        @cfunction(noop_augfwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(duplicate_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
        @cfunction(noop_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
    )
    register_handler!(
        ("jl_array_copy","ijl_array_copy"),
        @cfunction(arraycopy_augfwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(arraycopy_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
        @cfunction(arraycopy_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
    )
    register_handler!(
        ("llvm.julia.gc_preserve_begin",),
        @cfunction(gcpreserve_begin_augfwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(gcpreserve_begin_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
        @cfunction(gcpreserve_begin_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
    )
    register_handler!(
        ("llvm.julia.gc_preserve_end",),
        @cfunction(gcpreserve_end_augfwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(gcpreserve_end_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
    )
    register_handler!(
        ("jl_f_setfield",),
        @cfunction(setfield_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(setfield_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
    )
    register_handler!(
        ("jl_f_tuple",),
        @cfunction(f_tuple_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(f_tuple_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
    )
    register_handler!(
        ("jl_f__apply_iterate",),
        @cfunction(apply_iterate_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(apply_iterate_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
    )
    register_handler!(
        ("jl_new_structv",),
        @cfunction(new_structv_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(new_structv_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
    )
    register_handler!(
        ("jl_get_binding_or_error", "ijl_get_binding_or_error"),
        @cfunction(get_binding_or_error_augfwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(get_binding_or_error_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
        @cfunction(get_binding_or_error_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
    )
    register_handler!(
        ("jl_gc_add_finalizer_th",),
        @cfunction(finalizer_augfwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
        @cfunction(finalizer_rev, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, LLVM.API.LLVMValueRef)),
        @cfunction(finalizer_fwd, Cvoid, (LLVM.API.LLVMBuilderRef, LLVM.API.LLVMValueRef, API.EnzymeGradientUtilsRef, Ptr{LLVM.API.LLVMValueRef}, Ptr{LLVM.API.LLVMValueRef})),
    )
end

# Define EnzymeTarget
Base.@kwdef struct EnzymeTarget <: AbstractCompilerTarget
end
GPUCompiler.llvm_triple(::EnzymeTarget) = Sys.MACHINE

# GPUCompiler.llvm_datalayout(::EnzymeTarget) =  nothing

function GPUCompiler.llvm_machine(::EnzymeTarget)
    return tm[]
end

module Runtime
    # the runtime library
    signal_exception() = return
    malloc(sz) = ccall("extern malloc", llvmcall, Csize_t, (Csize_t,), sz)
    report_oom(sz) = return
    report_exception(ex) = return
    report_exception_name(ex) = return
    report_exception_frame(idx, func, file, line) = return
end

abstract type AbstractEnzymeCompilerParams <: AbstractCompilerParams end
struct EnzymeCompilerParams <: AbstractEnzymeCompilerParams
    adjoint::FunctionSpec
    mode::API.CDerivativeMode
    rt::Type{<:Annotation}
    run_enzyme::Bool
    dupClosure::Bool
    abiwrap::Bool
end

struct PrimalCompilerParams <: AbstractEnzymeCompilerParams
end

include("compiler/interpreter.jl")
## job

# TODO: We shouldn't blanket opt-out
GPUCompiler.check_invocation(job::CompilerJob{EnzymeTarget}, entry::LLVM.Function) = nothing

GPUCompiler.runtime_module(::CompilerJob{<:Any,<:AbstractEnzymeCompilerParams}) = Runtime
# GPUCompiler.isintrinsic(::CompilerJob{EnzymeTarget}, fn::String) = true
# GPUCompiler.can_throw(::CompilerJob{EnzymeTarget}) = true

# TODO: encode debug build or not in the compiler job
#       https://github.com/JuliaGPU/CUDAnative.jl/issues/368
GPUCompiler.runtime_slug(job::CompilerJob{EnzymeTarget}) = "enzyme"

# provide a specific interpreter to use.
GPUCompiler.get_interpreter(job::CompilerJob{<:Any,<:AbstractEnzymeCompilerParams}) =
    EnzymeInterpeter(GPUCompiler.ci_cache(job), GPUCompiler.method_table(job), job.source.world)

include("compiler/optimize.jl")

"""
Create the `FunctionSpec` pair, and lookup the primal return type.
"""
@inline function fspec(f::F, tt::TT) where {F, TT}
    # Entry for the cache look-up
    adjoint = FunctionSpec(f, tt, #=kernel=# false, #=name=# nothing)

    # primal function. Inferred here to get return type
    _tt = (tt.parameters...,)

    primal_tt = Tuple{map(eltype, _tt)...}
    primal = FunctionSpec(f, primal_tt, #=kernel=# false, #=name=# nothing)

    return primal, adjoint
end

##
# Enzyme compiler step
##

const inactivefns = Set{String}((
    "jl_gc_queue_root", "gpu_report_exception", "gpu_signal_exception",
    "julia.ptls_states", "julia.write_barrier", "julia.typeof", "jl_box_int64", "jl_box_int32",
    "jl_subtype", "julia.get_pgcstack", "jl_in_threaded_region", "jl_object_id_", "jl_object_id",
    "jl_breakpoint",
    "llvm.julia.gc_preserve_begin","llvm.julia.gc_preserve_end", "jl_get_ptls_states",
    "jl_f_fieldtype",
    "jl_symbol_n",
    "jl_stored_inline", "ijl_stored_inline"
    # "jl_"
))

const activefns = Set{String}((
    "jl_",
))

function annotate!(mod, mode)
    ctx = context(mod)
    inactive = LLVM.StringAttribute("enzyme_inactive", ""; ctx)
    active = LLVM.StringAttribute("enzyme_active", ""; ctx)
    fns = functions(mod)

    for inactivefn in inactivefns
        if haskey(fns, inactivefn)
            fn = fns[inactivefn]
            push!(function_attributes(fn), inactive)
        end
    end

    for activefn in activefns
        if haskey(fns, activefn)
            fn = fns[activefn]
            push!(function_attributes(fn), active)
        end
    end

    for fname in ("julia.typeof",)
        if haskey(fns, fname)
            fn = fns[fname]
            push!(function_attributes(fn), LLVM.EnumAttribute("readnone", 0; ctx))
            push!(function_attributes(fn), LLVM.StringAttribute("enzyme_shouldrecompute"; ctx))
        end
    end

    for fname in ("julia.get_pgcstack", "julia.ptls_states", "jl_get_ptls_states")
        if haskey(fns, fname)
            fn = fns[fname]
            # TODO per discussion w keno perhaps this should change to readonly / inaccessiblememonly
            push!(function_attributes(fn), LLVM.EnumAttribute("readnone", 0; ctx))
        end
    end

    for fname in ("julia.pointer_from_objref",)
        if haskey(fns, fname)
            fn = fns[fname]
            push!(function_attributes(fn), LLVM.EnumAttribute("readnone", 0; ctx))
        end
    end

    for boxfn in ("jl_box_float32", "jl_box_float64", "jl_box_int32", "jl_box_int64", "julia.gc_alloc_obj",
                  "jl_alloc_array_1d", "jl_alloc_array_2d", "jl_alloc_array_3d",
                  "ijl_alloc_array_1d", "ijl_alloc_array_2d", "ijl_alloc_array_3d")
        if haskey(fns, boxfn)
            fn = fns[boxfn]
            push!(return_attributes(fn), LLVM.EnumAttribute("noalias", 0; ctx))
            push!(function_attributes(fn), LLVM.EnumAttribute("inaccessiblememonly", 0; ctx))
        end
    end

    for gc in ("llvm.julia.gc_preserve_begin", "llvm.julia.gc_preserve_end")
        if haskey(fns, gc)
            fn = fns[gc]
            push!(function_attributes(fn), LLVM.EnumAttribute("inaccessiblememonly", 0; ctx))
        end
    end

    for rfn in ("jl_object_id_", "jl_object_id")
        if haskey(fns, rfn)
            fn = fns[rfn]
            push!(function_attributes(fn), LLVM.EnumAttribute("readonly", 0; ctx))
        end
    end

    for rfn in ("jl_in_threaded_region_", "jl_in_threaded_region")
        if haskey(fns, rfn)
            fn = fns[rfn]
            push!(function_attributes(fn), LLVM.EnumAttribute("readonly", 0; ctx))
            push!(function_attributes(fn), LLVM.EnumAttribute("inaccessiblememonly", 0; ctx))
        end
    end
end

function noop_rule(direction::Cint, ret::API.CTypeTreeRef, args::Ptr{API.CTypeTreeRef}, known_values::Ptr{API.IntList}, numArgs::Csize_t, val::LLVM.API.LLVMValueRef)::UInt8
    return UInt8(false)
end

function alloc_obj_rule(direction::Cint, ret::API.CTypeTreeRef, args::Ptr{API.CTypeTreeRef}, known_values::Ptr{API.IntList}, numArgs::Csize_t, val::LLVM.API.LLVMValueRef)::UInt8
    inst = LLVM.Instruction(val)
    ce = operands(inst)[3]
    while isa(ce, ConstantExpr)
        ce = operands(ce)[1]
    end
    ptr = reinterpret(Ptr{Cvoid}, convert(UInt64, ce))
    typ = Base.unsafe_pointer_to_objref(ptr)

    ctx = LLVM.context(LLVM.Value(val))
    dl = string(LLVM.datalayout(LLVM.parent(LLVM.parent(LLVM.parent(inst)))))

    rest = typetree(typ, ctx, dl)
    only!(rest, -1)
    API.EnzymeMergeTypeTree(ret, rest)
    return UInt8(false)
end

function int_return_rule(direction::Cint, ret::API.CTypeTreeRef, args::Ptr{API.CTypeTreeRef}, known_values::Ptr{API.IntList}, numArgs::Csize_t, val::LLVM.API.LLVMValueRef)::UInt8
    TT = TypeTree(API.DT_Integer, LLVM.context(LLVM.Value(val)))
    only!(TT, -1)
    API.EnzymeSetTypeTree(ret, TT)
    return UInt8(false)
end

function i64_box_rule(direction::Cint, ret::API.CTypeTreeRef, args::Ptr{API.CTypeTreeRef}, known_values::Ptr{API.IntList}, numArgs::Csize_t, val::LLVM.API.LLVMValueRef)::UInt8
    TT = TypeTree(API.DT_Integer, LLVM.context(LLVM.Value(val)))
    only!(TT, -1)
    API.EnzymeSetTypeTree(unsafe_load(args), TT)
    dl = string(LLVM.datalayout(LLVM.parent(LLVM.parent(LLVM.parent(LLVM.Instruction(val))))))
    shift!(TT,  dl, #=off=#0, #=maxSize=#8, #=addOffset=#0)
    API.EnzymeSetTypeTree(ret, TT)
    return UInt8(false)
end


function f32_box_rule(direction::Cint, ret::API.CTypeTreeRef, args::Ptr{API.CTypeTreeRef}, known_values::Ptr{API.IntList}, numArgs::Csize_t, val::LLVM.API.LLVMValueRef)::UInt8
    TT = TypeTree(API.DT_Float, LLVM.context(LLVM.Value(val)))
    only!(TT, -1)
    API.EnzymeSetTypeTree(unsafe_load(args), TT)
    dl = string(LLVM.datalayout(LLVM.parent(LLVM.parent(LLVM.parent(LLVM.Instruction(val))))))
    shift!(TT,  dl, #=off=#0, #=maxSize=#8, #=addOffset=#0)
    API.EnzymeSetTypeTree(ret, TT)
    return UInt8(false)
end

function ptr_rule(direction::Cint, ret::API.CTypeTreeRef, args::Ptr{API.CTypeTreeRef}, known_values::Ptr{API.IntList}, numArgs::Csize_t, val::LLVM.API.LLVMValueRef)::UInt8
    TT = TypeTree(API.DT_Pointer, LLVM.context(LLVM.Value(val)))
    only!(TT, -1)
    API.EnzymeSetTypeTree(ret, TT)
    return UInt8(false)
end

function inout_rule(direction::Cint, ret::API.CTypeTreeRef, args::Ptr{API.CTypeTreeRef}, known_values::Ptr{API.IntList}, numArgs::Csize_t, val::LLVM.API.LLVMValueRef)::UInt8
    if (direction & API.UP) != 0
        API.EnzymeMergeTypeTree(unsafe_load(args), ret)
    end
    if (direction & API.DOWN) != 0
        API.EnzymeMergeTypeTree(ret, unsafe_load(args))
    end
    return UInt8(false)
end

function alloc_rule(direction::Cint, ret::API.CTypeTreeRef, args::Ptr{API.CTypeTreeRef}, known_values::Ptr{API.IntList}, numArgs::Csize_t, val::LLVM.API.LLVMValueRef)::UInt8
    inst = LLVM.Instruction(val)
    ce = operands(inst)[1]
    while isa(ce, ConstantExpr)
        ce = operands(ce)[1]
    end
    ptr = reinterpret(Ptr{Cvoid}, convert(UInt64, ce))
    typ = Base.unsafe_pointer_to_objref(ptr)

    ctx = LLVM.context(LLVM.Value(val))
    dl = string(LLVM.datalayout(LLVM.parent(LLVM.parent(LLVM.parent(inst)))))

    rest = typetree(typ, ctx, dl)
    only!(rest, -1)
    API.EnzymeMergeTypeTree(ret, rest)

    for i = 1:numArgs
        API.EnzymeMergeTypeTree(unsafe_load(args, i), TypeTree(API.DT_Integer, -1, ctx))
    end
    return UInt8(false)
end

function enzyme!(job, mod, primalf, adjoint, mode, parallel, actualRetType, dupClosure, wrap)
    rt  = job.params.rt
    ctx = context(mod)
    dl  = string(LLVM.datalayout(mod))
    F   = typeof(adjoint.f)

    tt = [adjoint.tt.parameters...,]

    if eltype(rt) === Union{}
        error("return type is Union{}, giving up.")
    end

    args_activity     = API.CDIFFE_TYPE[]
    uncacheable_args  = Bool[]
    args_typeInfo     = TypeTree[]
    args_known_values = API.IntList[]

    ctx = LLVM.context(mod)
    if !GPUCompiler.isghosttype(F) && !Core.Compiler.isconstType(F)
        typeTree = typetree(F, ctx, dl)
        push!(args_typeInfo, typeTree)
        if dupClosure
            push!(args_activity, API.DFT_DUP_ARG)
        else
            push!(args_activity, API.DFT_CONSTANT)
        end
        if mode == API.DEM_ReverseModeCombined
            push!(uncacheable_args, false)
        else
            push!(uncacheable_args, true)
        end
        push!(args_known_values, API.IntList())
    end

    for T in tt
        source_typ = eltype(T)
        if GPUCompiler.isghosttype(source_typ) || Core.Compiler.isconstType(source_typ)
            if !(T <: Const)
                error("Type of ghost or constant is marked as differentiable.")
            end
            continue
        end
        isboxed = GPUCompiler.deserves_argbox(source_typ)

        if T <: Const
            push!(args_activity, API.DFT_CONSTANT)
        elseif T <: Active

            if isboxed
                push!(args_activity, API.DFT_DUP_ARG)
            else
                push!(args_activity, API.DFT_OUT_DIFF)
            end
        elseif  T <: Duplicated
            push!(args_activity, API.DFT_DUP_ARG)
        elseif T <: DuplicatedNoNeed
            push!(args_activity, API.DFT_DUP_NONEED)
        else
            error("illegal annotation type")
        end
        T = source_typ
        if isboxed
            T = Ptr{T}
        end
        typeTree = typetree(T, ctx, dl)
        push!(args_typeInfo, typeTree)
        if mode == API.DEM_ReverseModeCombined
            push!(uncacheable_args, false)
        else
            push!(uncacheable_args, true)
        end
        push!(args_known_values, API.IntList())
    end

    # The return of createprimal and gradient has this ABI
    #  It returns a struct containing the following values
    #     If requested, the original return value of the function
    #     If requested, the shadow return value of the function
    #     For each active (non duplicated) argument
    #       The adjoint of that argument
    if rt <: Const
        retType = API.DFT_CONSTANT
    elseif rt <: Active
        retType = API.DFT_OUT_DIFF
    elseif rt <: Duplicated
        retType = API.DFT_DUP_ARG
    elseif rt <: DuplicatedNoNeed
        retType = API.DFT_DUP_NONEED
    else
        error("Unhandled return type $rt")
    end

    rules = Dict{String, API.CustomRuleType}(
        "jl_apply_generic" => @cfunction(ptr_rule,
                                           UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                   Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
        "ijl_apply_generic" => @cfunction(ptr_rule,
                                           UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                   Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
        "julia.gc_alloc_obj" => @cfunction(alloc_obj_rule,
                                           UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                   Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
        "jl_box_float32" => @cfunction(f32_box_rule,
                                           UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                   Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
        "jl_box_int64" => @cfunction(i64_box_rule,
                                           UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                   Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
        "jl_box_uint64" => @cfunction(i64_box_rule,
                                            UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                    Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
        "jl_array_copy" => @cfunction(inout_rule,
                                           UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                   Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
        "jl_alloc_array_1d" => @cfunction(alloc_rule,
                                            UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                    Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
        "jl_alloc_array_2d" => @cfunction(alloc_rule,
                                            UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                    Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
        "jl_alloc_array_3d" => @cfunction(alloc_rule,
                                            UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                    Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
        "ijl_alloc_array_1d" => @cfunction(alloc_rule,
                                            UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                    Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
        "ijl_alloc_array_2d" => @cfunction(alloc_rule,
                                            UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                    Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
        "ijl_alloc_array_3d" => @cfunction(alloc_rule,
                                            UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                    Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
        "julia.pointer_from_objref" => @cfunction(inout_rule,
                                            UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                    Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
        "jl_wait" => @cfunction(noop_rule,
                                            UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                    Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
        "jl_enq_work" => @cfunction(noop_rule,
                                            UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                    Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),

        "enz_noop" => @cfunction(noop_rule,
                                            UInt8, (Cint, API.CTypeTreeRef, Ptr{API.CTypeTreeRef},
                                                    Ptr{API.IntList}, Csize_t, LLVM.API.LLVMValueRef)),
    )

    logic = Logic()
    TA = TypeAnalysis(logic, rules)

    retTT = typetree(GPUCompiler.deserves_argbox(actualRetType) ? Ptr{actualRetType} : actualRetType, ctx, dl)

    typeInfo = FnTypeInfo(retTT, args_typeInfo, args_known_values)

    if mode == API.DEM_ReverseModePrimal || mode == API.DEM_ReverseModeGradient
        returnUsed = !(GPUCompiler.isghosttype(actualRetType) || Core.Compiler.isconstType(actualRetType))
        shadowReturnUsed = returnUsed && (retType == API.DFT_DUP_ARG || retType == API.DFT_DUP_NONEED)
        augmented = API.EnzymeCreateAugmentedPrimal(
            logic, primalf, retType, args_activity, TA, #=returnUsed=# returnUsed,
            #=shadowReturnUsed=#shadowReturnUsed,
            typeInfo, uncacheable_args, #=forceAnonymousTape=# true, #=atomicAdd=# parallel)

        # 2. get new_primalf and tape
        augmented_primalf = LLVM.Function(API.EnzymeExtractFunctionFromAugmentation(augmented))
        tape = API.EnzymeExtractTapeTypeFromAugmentation(augmented)
        if wrap
          augmented_primalf = create_abi_wrapper(augmented_primalf, F, tt, rt, actualRetType, API.DEM_ReverseModePrimal, augmented, dupClosure)
        end

        # TODOs:
        # 1. Handle mutable or !pointerfree arguments by introducing caching
        #     + specifically by setting uncacheable_args[i] = true

        adjointf = LLVM.Function(API.EnzymeCreatePrimalAndGradient(
            logic, primalf, retType, args_activity, TA,
            #=returnValue=#false, #=dretUsed=#false, #=mode=#API.DEM_ReverseModeGradient, 1,
            #=additionalArg=#tape, typeInfo,
            uncacheable_args, augmented, #=atomicAdd=# parallel))
        if wrap
          adjointf = create_abi_wrapper(adjointf, F, tt, rt, actualRetType, API.DEM_ReverseModeGradient, augmented, dupClosure)
        end
    elseif mode == API.DEM_ReverseModeCombined
        adjointf = LLVM.Function(API.EnzymeCreatePrimalAndGradient(
            logic, primalf, retType, args_activity, TA,
            #=returnValue=#false, #=dretUsed=#false, #=mode=#API.DEM_ReverseModeCombined, 1,
            #=additionalArg=#C_NULL, typeInfo,
            uncacheable_args, #=augmented=#C_NULL, #=atomicAdd=# parallel))
        augmented_primalf = nothing
        if wrap
          adjointf = create_abi_wrapper(adjointf, F, tt, rt, actualRetType, API.DEM_ReverseModeCombined, nothing, dupClosure)
        end
    elseif mode == API.DEM_ForwardMode
        adjointf = LLVM.Function(API.EnzymeCreateForwardDiff(
            logic, primalf, retType, args_activity, TA,
            #=returnValue=#rt <: Duplicated, #=mode=#API.DEM_ForwardMode, 1,
            #=additionalArg=#C_NULL, typeInfo,
            uncacheable_args))
        augmented_primalf = nothing
        if wrap
          adjointf = create_abi_wrapper(adjointf, F, tt, rt, actualRetType, API.DEM_ForwardMode, nothing, dupClosure)
        end
    else
        @assert "Unhandled derivative mode", mode
    end
    return adjointf, augmented_primalf
end

function create_abi_wrapper(enzymefn::LLVM.Function, F, argtypes, rettype, actualRetType, Mode::API.CDerivativeMode, augmented, dupClosure)
    is_adjoint = Mode == API.DEM_ReverseModeGradient || Mode == API.DEM_ReverseModeCombined
    is_split   = Mode == API.DEM_ReverseModeGradient || Mode == API.DEM_ReverseModePrimal
    needs_tape = Mode == API.DEM_ReverseModeGradient



    mod = LLVM.parent(enzymefn)
    ctx = LLVM.context(mod)

    push!(function_attributes(enzymefn), EnumAttribute("alwaysinline", 0; ctx))
    T_void = convert(LLVMType, Nothing; ctx)
    ptr8 = LLVM.PointerType(LLVM.IntType(8; ctx))
    T_jlvalue = LLVM.StructType(LLVMType[]; ctx)
    T_prjlvalue = LLVM.PointerType(T_jlvalue, #= AddressSpace::Tracked =# 10)

    # Create Enzyme calling convention
    T_wrapperargs = LLVMType[] # Arguments of the wrapper

    T_JuliaSRet = LLVMType[]  # Struct return of all objects
                              # + If the adjoint this will be all Active variables (includes all of T_EnzymeSRet)
                              # + If the forward, this will be ?return, ?shadowReturn, ?tape

    if !GPUCompiler.isghosttype(F) && !Core.Compiler.isconstType(F)
        isboxed = GPUCompiler.deserves_argbox(F)
        llvmT = isboxed ? T_prjlvalue : convert(LLVMType, F; ctx)
        push!(T_wrapperargs, llvmT)
        if dupClosure
            push!(T_wrapperargs, llvmT)
        end
    end

    for T in argtypes
        source_typ = eltype(T)
        if GPUCompiler.isghosttype(source_typ) || Core.Compiler.isconstType(source_typ)
            @assert T <: Const
            continue
        end

        isboxed = GPUCompiler.deserves_argbox(source_typ)
        llvmT = isboxed ? T_prjlvalue : convert(LLVMType, source_typ; ctx)

        push!(T_wrapperargs, llvmT)

        T <: Const && continue

        if T <: Active
            if is_adjoint
                # Use deserves_argbox??
                llvmT = convert(LLVMType, source_typ; ctx)
                push!(T_JuliaSRet, llvmT)
            end
        elseif T <: Duplicated || T <: DuplicatedNoNeed
            push!(T_wrapperargs, llvmT)
        else
            error("calling convention should be annotated, got $T")
        end
    end

    # API.DFT_OUT_DIFF
    if is_adjoint && rettype <: Active
        @assert allocatedinline(actualRetType)
        push!(T_wrapperargs, convert(LLVMType, actualRetType; ctx))
    end

    data    = Array{Int64}(undef, 3)
    existed = Array{UInt8}(undef, 3)
    if Mode == API.DEM_ReverseModePrimal
        API.EnzymeExtractReturnInfo(augmented, data, existed)
        # tape -- todo ??? on wrap
        if existed[1] != 0
            tape = API.EnzymeExtractTapeTypeFromAugmentation(augmented)
            push!(T_JuliaSRet, LLVM.LLVMType(tape))
        else
            error("Assuming always has a tape")
        end
        
        isboxed = GPUCompiler.deserves_argbox(actualRetType)
        llvmT = isboxed ? T_prjlvalue : convert(LLVMType, actualRetType; ctx)
        
        # primal return
        if existed[2] != 0
            push!(T_JuliaSRet, llvmT)
        end
        # shadow return
        if existed[3] != 0
            push!(T_JuliaSRet, llvmT)
        else
            @assert rettype <: Const || rettype <: Active
        end
    end
    if Mode == API.DEM_ForwardMode
        returnUsed = !(GPUCompiler.isghosttype(actualRetType) || Core.Compiler.isconstType(actualRetType))
        if returnUsed
            isboxed = GPUCompiler.deserves_argbox(actualRetType)
            llvmT = isboxed ? T_prjlvalue : convert(LLVMType, actualRetType; ctx)
            if rettype <: Duplicated
                push!(T_JuliaSRet, llvmT)
            end
            if !(rettype <: Const)
                push!(T_JuliaSRet, llvmT)
            end
        end
    end

    # sret argument
    if !isempty(T_JuliaSRet)
        pushfirst!(T_wrapperargs, LLVM.PointerType(LLVM.StructType(T_JuliaSRet; ctx)))
    end

    if needs_tape
        push!(T_wrapperargs, LLVM.LLVMType(API.EnzymeExtractTapeTypeFromAugmentation(augmented)))
    end

    FT = LLVM.FunctionType(T_void, T_wrapperargs)
    llvm_f = LLVM.Function(mod, LLVM.name(enzymefn)*"wrap", FT)
    dl = datalayout(mod)

    params = [parameters(llvm_f)...]
    target =  !isempty(T_JuliaSRet) ? 2 : 1

    intrinsic_typ = LLVM.FunctionType(T_void, [ptr8, LLVM.IntType(8; ctx), LLVM.IntType(64; ctx), LLVM.IntType(1; ctx)])
    memsetIntr = LLVM.Function(mod, "llvm.memset.p0i8.i64", intrinsic_typ)
    LLVM.Builder(ctx) do builder
        entry = BasicBlock(llvm_f, "entry"; ctx)
        position!(builder, entry)

        realparms = LLVM.Value[]
        i = target

        if !isempty(T_JuliaSRet)
            sret = params[1]
        end

        activeNum = 0

        if !GPUCompiler.isghosttype(F) && !Core.Compiler.isconstType(F)
            push!(realparms, params[i])
            i+=1
            if dupClosure
                push!(realparms, params[i])
                i+=1
            end
        end

        for T in argtypes
            T′ = eltype(T)

            if GPUCompiler.isghosttype(T′) || Core.Compiler.isconstType(T′)
                continue
            end
            push!(realparms, params[i])
            i += 1
            if T <: Const
            elseif T <: Active
                isboxed = GPUCompiler.deserves_argbox(T′)
                if isboxed
                    @assert !is_split
                    ptr = gep!(builder, sret, [LLVM.ConstantInt(LLVM.IntType(64; ctx), 0), LLVM.ConstantInt(LLVM.IntType(32; ctx), activeNum)])
                    cst = pointercast!(builder, ptr, ptr8)
                    push!(realparms, ptr)

                    cparms = LLVM.Value[cst,
                    LLVM.ConstantInt(LLVM.IntType(8; ctx), 0),
                    LLVM.ConstantInt(LLVM.IntType(64; ctx), LLVM.storage_size(dl, Base.eltype(LLVM.llvmtype(ptr)) )),
                    LLVM.ConstantInt(LLVM.IntType(1; ctx), 0)]
                    call!(builder, memsetIntr, cparms)
                end
                activeNum += 1
            elseif T <: Duplicated || T <: DuplicatedNoNeed
                push!(realparms, params[i])
                i += 1
            end
        end

        if is_adjoint && rettype <: Active
            push!(realparms, params[i])
            i += 1
        end

        if needs_tape
            push!(realparms, params[i])
            i += 1
        end

        val = call!(builder, enzymefn, realparms)

        if Mode == API.DEM_ReverseModePrimal
            returnNum = 0
            for i in 1:3
                if existed[i] != 0
                    eval = val
                    if data[i] != -1
                        eval = extract_value!(builder, val, data[i])
                    end
                    store!(builder, eval, gep!(builder, sret, [LLVM.ConstantInt(LLVM.IntType(64; ctx), 0), LLVM.ConstantInt(LLVM.IntType(32; ctx), returnNum)]))
                    returnNum+=1
                end
            end
        elseif Mode == API.DEM_ForwardMode
            for returnNum in 0:(length(T_JuliaSRet)-1)
                eval = val
                if length(T_JuliaSRet) > 1
                    eval = extract_value!(builder, val, returnNum)
                end
                store!(builder, eval, gep!(builder, sret, [LLVM.ConstantInt(LLVM.IntType(64; ctx), 0), LLVM.ConstantInt(LLVM.IntType(32; ctx), returnNum)]))
            end
        else
            activeNum = 0
            returnNum = 0
            for T in argtypes
                T′ = eltype(T)
                isboxed = GPUCompiler.deserves_argbox(T′)
                if T <: Active
                    if !isboxed
                        eval = extract_value!(builder, val, returnNum)
                        store!(builder, eval, gep!(builder, sret, [LLVM.ConstantInt(LLVM.IntType(64; ctx), 0), LLVM.ConstantInt(LLVM.IntType(32; ctx), activeNum)]))
                        returnNum+=1
                    end
                    activeNum+=1
                end
            end
        end
        ret!(builder)
    end

    # make sure that arguments are rooted if necessary
    reinsert_gcmarker!(llvm_f)

    return llvm_f
end

function fixup_metadata!(f::LLVM.Function)
    for param in parameters(f)
        if isa(llvmtype(param), LLVM.PointerType)
            # collect all uses of the pointer
            worklist = Vector{LLVM.Instruction}(user.(collect(uses(param))))
            while !isempty(worklist)
                value = popfirst!(worklist)

                # remove the invariant.load attribute
                md = metadata(value)
                if haskey(md, LLVM.MD_invariant_load)
                    delete!(md, LLVM.MD_invariant_load)
                end
                if haskey(md, LLVM.MD_tbaa)
                    delete!(md, LLVM.MD_tbaa)
                end

                # recurse on the output of some instructions
                if isa(value, LLVM.BitCastInst) ||
                   isa(value, LLVM.GetElementPtrInst) ||
                   isa(value, LLVM.AddrSpaceCastInst)
                    append!(worklist, user.(collect(uses(value))))
                end

                # IMPORTANT NOTE: if we ever want to inline functions at the LLVM level,
                # we need to recurse into call instructions here, and strip metadata from
                # called functions (see CUDAnative.jl#238).
            end
        end
    end
end

# Modified from GPUCompiler classify_arguments
function classify_arguments(source_sig::Type, codegen_ft::LLVM.FunctionType, has_sret)
    source_types = [source_sig.parameters...]
    codegen_types = parameters(codegen_ft)

    args = []
    codegen_i = has_sret ? 2 : 1
    for (source_i, source_typ) in enumerate(source_types)
        if isghosttype(source_typ) || Core.Compiler.isconstType(source_typ)
            push!(args, (cc=GPUCompiler.GHOST, typ=source_typ))
            continue
        end
        codegen_typ = codegen_types[codegen_i]
        if codegen_typ isa LLVM.PointerType && !issized(eltype(codegen_typ))
            push!(args, (cc=GPUCompiler.MUT_REF, typ=source_typ,
                         codegen=(typ=codegen_typ, i=codegen_i)))
        elseif codegen_typ isa LLVM.PointerType && issized(eltype(codegen_typ)) &&
               !(source_typ <: Ptr) && !(source_typ <: Core.LLVMPtr)
            push!(args, (cc=GPUCompiler.BITS_REF, typ=source_typ,
                         codegen=(typ=codegen_typ, i=codegen_i)))
        else
            push!(args, (cc=GPUCompiler.BITS_VALUE, typ=source_typ,
                         codegen=(typ=codegen_typ, i=codegen_i)))
        end
        codegen_i += 1
    end

    return args
end


# Modified from GPUCompiler/src/irgen.jl:365 lower_byval
function lower_convention(functy::Type, mod::LLVM.Module, entry_f::LLVM.Function, actualRetType::Type)
    ctx = context(mod)
    entry_ft = eltype(llvmtype(entry_f)::LLVM.PointerType)::LLVM.FunctionType

    RT = LLVM.return_type(entry_ft)

    # generate the wrapper function type & definition
    wrapper_types = LLVM.LLVMType[]
    sret = false
    if !isempty(parameters(entry_f)) && any(map(k->kind(k)==kind(EnumAttribute("sret"; ctx)), collect(parameter_attributes(entry_f, 1))))
        # TODO sret is now TypeAttribute
        RT = eltype(llvmtype(first(parameters(entry_f))))
        sret = true
    end
    
	args = classify_arguments(functy, entry_ft, sret)
    filter!(args) do arg
        arg.cc != GPUCompiler.GHOST
    end

    # TODO use rettype for sret calculation instead
    rettype = actualRetType
    
    for (parm, arg) in zip(collect(parameters(entry_f))[1+sret:end], args)
        typ = if !GPUCompiler.deserves_argbox(arg.typ) && arg.cc == GPUCompiler.BITS_REF
            eltype(arg.codegen.typ)
        else
            llvmtype(parm)
        end
        push!(wrapper_types, typ)
    end
    wrapper_fn = LLVM.name(entry_f)
    LLVM.name!(entry_f, wrapper_fn * ".inner")
    wrapper_ft = LLVM.FunctionType(RT, wrapper_types)
    wrapper_f = LLVM.Function(mod, LLVM.name(entry_f), wrapper_ft)

    hasReturnsTwice = any(map(k->kind(k)==kind(EnumAttribute("returns_twice"; ctx)), collect(function_attributes(entry_f))))
    push!(function_attributes(wrapper_f), EnumAttribute("returns_twice"; ctx))
    push!(function_attributes(entry_f), EnumAttribute("returns_twice"; ctx))

    # emit IR performing the "conversions"
    let builder = Builder(ctx)
        toErase = LLVM.CallInst[]
        for u in LLVM.uses(entry_f)
            ci = LLVM.user(u)
            if !isa(ci, LLVM.CallInst) || called_value(ci) != entry_f
                continue
            end
            ops = collect(operands(ci))[1:end-1]
            position!(builder, ci)
            nops = LLVM.Value[]
            start = sret ? 2 : 1
            for (parm, arg) in zip(ops[1+sret:end], args)
                if !GPUCompiler.deserves_argbox(arg.typ) && arg.cc == GPUCompiler.BITS_REF
                    push!(nops, load!(builder, parm))
                else
                    push!(nops, parm)
                end
            end
            res = call!(builder, wrapper_f, nops)
            if sret
              store!(builder, res, ops[1])
            end
            push!(toErase, ci)
        end
        for e in toErase
            LLVM.API.LLVMInstructionEraseFromParent(e)
        end

        entry = BasicBlock(wrapper_f, "entry"; ctx)
        position!(builder, entry)

        wrapper_args = Vector{LLVM.Value}()

        if sret
            sretPtr = alloca!(builder, eltype(llvmtype(parameters(entry_f)[1])))
            push!(wrapper_args, sretPtr)
        end

        # perform argument conversions
        for (parm, arg) in zip(collect(parameters(entry_f))[1+sret:end], args)
            if !GPUCompiler.deserves_argbox(arg.typ) && arg.cc == GPUCompiler.BITS_REF
                # copy the argument value to a stack slot, and reference it.
                ty = llvmtype(parm)
                if !isa(ty, LLVM.PointerType)
                    @show entry_f, args, parm, ty
                end
                @assert isa(ty, LLVM.PointerType)
                ptr = alloca!(builder, eltype(ty))
                if LLVM.addrspace(ty) != 0
                    ptr = addrspacecast!(builder, ptr, ty)
                end
                store!(builder, parameters(wrapper_f)[arg.codegen.i-sret], ptr)
                push!(wrapper_args, ptr)
            else
                push!(wrapper_args, parameters(wrapper_f)[arg.codegen.i-sret])
                for attr in collect(parameter_attributes(entry_f, arg.codegen.i))
                    push!(parameter_attributes(wrapper_f, arg.codegen.i-sret), attr)
                end
            end
        end
        res = call!(builder, entry_f, wrapper_args)

        if LLVM.get_subprogram(entry_f) !== nothing
            metadata(res)[LLVM.MD_dbg] = DILocation(ctx, 0, 0, LLVM.get_subprogram(entry_f) )
        end
    
        LLVM.API.LLVMSetInstructionCallConv(res, LLVM.callconv(entry_f))

        if sret
            ret!(builder, load!(builder, sretPtr))
        elseif LLVM.return_type(entry_ft) == LLVM.VoidType(ctx)
            ret!(builder)
        else
            ret!(builder, res)
        end

        dispose(builder)
    end

    # early-inline the original entry function into the wrapper
    push!(function_attributes(entry_f), EnumAttribute("alwaysinline", 0; ctx))
    linkage!(entry_f, LLVM.API.LLVMInternalLinkage)

    fixup_metadata!(entry_f)
	
	ModulePassManager() do pm
        always_inliner!(pm)
        run!(pm, mod)
    end
    if !hasReturnsTwice
        LLVM.API.LLVMRemoveEnumAttributeAtIndex(wrapper_f, reinterpret(LLVM.API.LLVMAttributeIndex, LLVM.API.LLVMAttributeFunctionIndex), kind(EnumAttribute("returns_twice"; ctx)))
    end
    ModulePassManager() do pm
        # Kill the temporary staging function
        global_dce!(pm)
        global_optimizer!(pm)
        run!(pm, mod)
    end
    if haskey(globals(mod), "llvm.used")
        unsafe_delete!(mod, globals(mod)["llvm.used"])
        for u in user.(collect(uses(entry_f)))
            if isa(u, LLVM.GlobalVariable) && endswith(LLVM.name(u), "_slot") && startswith(LLVM.name(u), "julia")
                unsafe_delete!(mod, u)
            end
        end
    end
    verify(wrapper_f)
    return wrapper_f
end

function adim(::Array{T, N}) where {T, N}
    return N
end

function GPUCompiler.codegen(output::Symbol, job::CompilerJob{<:EnzymeTarget};
                 libraries::Bool=true, deferred_codegen::Bool=true, optimize::Bool=true, ctx = nothing,
                 strip::Bool=false, validate::Bool=true, only_entry::Bool=false, parent_job::Union{Nothing, CompilerJob} = nothing)
    params  = job.params
    mode   = params.mode
    adjoint = params.adjoint
    dupClosure = params.dupClosure
    abiwrap = params.abiwrap
    primal  = job.source

    if parent_job === nothing
        primal_target = GPUCompiler.NativeCompilerTarget()
        primal_params = Compiler.PrimalCompilerParams()
        primal_job    = CompilerJob(primal_target, primal, primal_params)
    else
        primal_job = similar(parent_job, job.source)
    end
    mod, meta = GPUCompiler.codegen(:llvm, primal_job; optimize=false, validate=false, parent_job=parent_job, ctx)
    primalf = meta.entry
    check_ir(job, mod)

    @assert ctx == context(mod)
    custom = Dict{String, LLVM.API.LLVMLinkage}()
    must_wrap = false

    # Julia function to LLVM stem and arity
    known_ops = Dict(
        Base.cbrt => (:cbrt, 1),
        Base.sqrt => (:sqrt, 1),
        Base.sin => (:sin, 1),
        Base.sincos => (:__fd_sincos_1, 1),
        Base.:^ => (:pow, 2),
        Base.cos => (:cos, 1),
        Base.tan => (:tan, 1),
        Base.exp => (:exp, 1),
        Base.log => (:log, 1),
        Base.asin => (:asin, 1),
        Base.tanh => (:tanh, 1),
        Base.ldexp => (:ldexp, 2),
        Base.FastMath.tanh_fast => (:tanh, 1)
    )
    actualRetType = nothing
    for (mi, k) in meta.compiled
        k_name = GPUCompiler.safe_name(k.specfunc)
        haskey(functions(mod), k_name) || continue

        llvmfn = functions(mod)[k_name]
        if llvmfn == primalf
            actualRetType = k.ci.rettype
        end

        meth = mi.def
        name = meth.name
        jlmod  = meth.module

        Base.isbindingresolved(jlmod, name) && isdefined(jlmod, name) || continue
        func = getfield(jlmod, name)

        function handleCustom(name, attrs=[], setlink=true)
            attributes = function_attributes(llvmfn)
            custom[k_name] = linkage(llvmfn)
            if setlink
              linkage!(llvmfn, LLVM.API.LLVMExternalLinkage)
            end
            for a in attrs
                push!(attributes, a)
            end
            push!(attributes, StringAttribute("enzymejl_mi", string(convert(Int, pointer_from_objref(mi))); ctx))
            push!(attributes, StringAttribute("enzyme_math", name; ctx))
            push!(attributes, EnumAttribute("noinline", 0; ctx))
            must_wrap |= llvmfn == primalf
            nothing
        end


        sparam_vals = mi.specTypes.parameters[2:end] # mi.sparam_vals
        if func == Base.println || func == Base.print || func == Base.show ||
            func == Base.flush || func == Base.string || func == Base.print_to_string
            handleCustom("enz_noop", [StringAttribute("enzyme_inactive"; ctx)])
            continue
        end
        if func == Base.copy && length(sparam_vals) == 1 && first(sparam_vals) <: Array
            AT = first(sparam_vals)
            T = eltype(AT)
            N = adim(AT)
            bitsunion = Base.isbitsunion(T)
            error("jl_copy unhandled")
        end
        if func == Base.enq_work && length(sparam_vals) == 1 && first(sparam_vals) <: Task 
            handleCustom("jl_enq_work")
            continue
        end
        if func == Base.Threads.threadid || func == Base.Threads.nthreads
            name = (func == Base.Threads.threadid) ? "jl_threadid" : "jl_nthreads"
            handleCustom(name,
                   [EnumAttribute("readonly", 0; ctx),
                    EnumAttribute("inaccessiblememonly", 0; ctx),
                    EnumAttribute("speculatable", 0; ctx),
                    StringAttribute("enzyme_shouldrecompute"; ctx),
                    StringAttribute("enzyme_inactive"; ctx),
                                  ])
            continue
        end
        if func == Base.wait || func == Base._wait
            if length(sparam_vals) == 0 || 
                (length(sparam_vals) == 1 && first(sparam_vals) <: Task)
                handleCustom("jl_wait")
            end
            continue
        end
        if func == Base.Threads.threading_run
            if length(sparam_vals) == 1 || length(sparam_vals) == 2
                handleCustom("jl_threadsfor")
            end
            continue
        end
        if func == Enzyme.pmap
            source_sig = Base.signature_type(func, sparam_vals)
            primal = llvmfn == primalf
            llvmfn = lower_convention(source_sig, mod, llvmfn, k.ci.rettype)
            k_name = LLVM.name(llvmfn)
            if primal
                primalf = llvmfn
            end
            handleCustom("jl_pmap", [], false)
            continue
        end

        func ∈ keys(known_ops) || continue
        name, arity = known_ops[func]
        length(sparam_vals) == arity || continue

        T = first(sparam_vals)
        isfloat = T ∈ (Float32, Float64)
        if !isfloat
            continue
        end
        if name == :ldexp
           sparam_vals[2] <: Integer || continue
        elseif name == :pow
           if sparam_vals[2] <: Integer 
              name = :powi
           elseif sparam_vals[2] != T
              continue
           end
        else
           all(==(T), sparam_vals) || continue
        end

        if name == :__fd_sincos_1
          source_sig = Base.signature_type(func, sparam_vals)
          llvmfn = lower_convention(source_sig, mod, llvmfn, k.ci.rettype)
          k_name = LLVM.name(llvmfn)
        end

        name = string(name)
        name = T == Float32 ? name*"f" : name

        handleCustom(name, [EnumAttribute("readnone", 0; ctx),
                    StringAttribute("enzyme_shouldrecompute"; ctx)])
    end

    @assert actualRetType !== nothing

    if must_wrap
        llvmfn = primalf
        FT = eltype(llvmtype(llvmfn)::LLVM.PointerType)::LLVM.FunctionType

        wrapper_f = LLVM.Function(mod, LLVM.name(llvmfn)*"mustwrap", FT)

        let builder = Builder(ctx)
            entry = BasicBlock(wrapper_f, "entry"; ctx)
            position!(builder, entry)

            res = call!(builder, llvmfn, collect(parameters(wrapper_f)))

            if LLVM.return_type(FT) == LLVM.VoidType(ctx)
                ret!(builder)
            else
                ret!(builder, res)
            end

            dispose(builder)
        end
        primalf = wrapper_f
    end

    source_sig = Base.signature_type(job.source.f, job.source.tt)::Type
    primalf = lower_convention(source_sig, mod, primalf, actualRetType)

    if primal_job.target isa GPUCompiler.NativeCompilerTarget
        target_machine = JIT.get_tm()
    else
        target_machine = GPUCompiler.llvm_machine(primal_job.target)
    end

    parallel = Threads.nthreads() > 1
    process_module = false
    if parent_job !== nothing
        if parent_job.target isa GPUCompiler.PTXCompilerTarget ||
           parent_job.target isa GPUCompiler.GCNCompilerTarget
            parallel = true
        end
        if parent_job.target isa GPUCompiler.GCNCompilerTarget
           process_module = true
        end
    end


    # annotate
    annotate!(mod, mode)

    # Run early pipeline
    optimize!(mod, target_machine)

    if process_module
        GPUCompiler.optimize_module!(parent_job, mod)
    end

    if params.run_enzyme
        # Generate the adjoint
        adjointf, augmented_primalf = enzyme!(job, mod, primalf, adjoint, mode, parallel, actualRetType, dupClosure, abiwrap)
    else
        adjointf = primalf
        augmented_primalf = nothing
    end

    for (fname, lnk) in custom
        haskey(functions(mod), fname) || continue
        f = functions(mod)[fname]
        linkage!(f, lnk)
        iter = function_attributes(f)
        elems = Vector{LLVM.API.LLVMAttributeRef}(undef, length(iter))
        LLVM.API.LLVMGetAttributesAtIndex(iter.f, iter.idx, elems)
        for eattr in elems
            at = Attribute(eattr)
            if isa(at, LLVM.EnumAttribute)
                if kind(at) == kind(EnumAttribute("noinline"; ctx))
                    delete!(iter, at)
                    break
                end
            end
        end
    end
    for fname in ["__enzyme_float", "__enzyme_double", "__enzyme_integer", "__enzyme_pointer"]
        haskey(functions(mod), fname) || continue
        f = functions(mod)[fname]
        for u in uses(f)
            st = LLVM.user(u)
            LLVM.API.LLVMInstructionEraseFromParent(st)
        end
        LLVM.unsafe_delete!(mod, f)
    end

    linkage!(adjointf, LLVM.API.LLVMExternalLinkage)
    adjointf_name = name(adjointf)

    if augmented_primalf !== nothing
        linkage!(augmented_primalf, LLVM.API.LLVMExternalLinkage)
        augmented_primalf_name = name(augmented_primalf)
    end

    restore_lookups(mod)

    if parent_job !== nothing
        reinsert_gcmarker!(adjointf)
        augmented_primalf !== nothing && reinsert_gcmarker!(augmented_primalf)
        post_optimze!(mod, target_machine)
    end

    adjointf = functions(mod)[adjointf_name]

    # API.EnzymeRemoveTrivialAtomicIncrements(adjointf)

    if process_module
        GPUCompiler.process_module!(parent_job, mod)
    end

    adjointf = functions(mod)[adjointf_name]
    push!(function_attributes(adjointf), EnumAttribute("alwaysinline", 0; ctx=context(mod)))
    if augmented_primalf !== nothing
        augmented_primalf = functions(mod)[augmented_primalf_name]
    end

    for fn in functions(mod)
        fn == adjointf && continue
        augmented_primalf !== nothing && fn === augmented_primalf && continue
        isempty(LLVM.blocks(fn)) && continue
        linkage!(fn, LLVM.API.LLVMLinkerPrivateLinkage)
    end
    
    return mod, (;adjointf, augmented_primalf, entry=adjointf, compiled=meta.compiled)
end

##
# Thunk
##

# Compiler result
struct Thunk
    adjoint::Ptr{Cvoid}
    primal::Ptr{Cvoid}
end

@inline (thunk::CombinedAdjointThunk{F, RT, TT, DF})(args...) where {F, DF, RT, TT} =
   enzyme_call(thunk.adjoint, CombinedAdjointThunk, TT, RT, thunk.fn, thunk.dfn, args...)

@inline (thunk::ForwardModeThunk{F, RT, TT, DF})(args...) where {F, DF, RT, TT} =
   enzyme_call(thunk.adjoint, ForwardModeThunk, TT, RT, thunk.fn, thunk.dfn, args...)

@inline (thunk::AdjointThunk{F, RT, TT, DF})(args...) where {F, DF, RT, TT} =
   enzyme_call(thunk.adjoint, AdjointThunk, TT, RT, thunk.fn, thunk.dfn, args...)

@inline (thunk::AugmentedForwardThunk{F, RT, TT, DF})(args...) where {F, DF, RT, TT} =
   enzyme_call(thunk.primal, AugmentedForwardThunk, TT, RT, thunk.fn, thunk.dfn, args...)

function jl_set_typeof(v::Ptr{Cvoid}, T)
    tag = reinterpret(Ptr{Any}, reinterpret(UInt, v) - 8)
    Base.unsafe_store!(tag, T) # set tag
    return nothing
end

@generated function enzyme_call(fptr::Ptr{Cvoid}, ::Type{CC}, tt::Type{T},
                                rt::Type{RT}, f::F, df::DF, args::Vararg{Any, N}) where {F, T, RT, DF, N, CC}

    is_forward = CC <: AugmentedForwardThunk || CC <: ForwardModeThunk
    is_adjoint = CC <: AdjointThunk || CC <: CombinedAdjointThunk
    is_split   = CC <: AdjointThunk || CC <: AugmentedForwardThunk
    needs_tape = CC <: AdjointThunk

    argtt    = tt.parameters[1]
    rettype  = rt.parameters[1]
    argtypes = DataType[argtt.parameters...]
    argexprs = Union{Expr, Symbol}[:(args[$i]) for i in 1:N]
    if rettype <: Active
        @assert length(argtypes) + is_adjoint + needs_tape == length(argexprs)
    elseif rettype <: Const
        @assert length(argtypes)              + needs_tape == length(argexprs)
    else
        @assert length(argtypes)              + needs_tape == length(argexprs)
    end

    types = DataType[]

    if eltype(rettype) === Union{}
        error("return type is Union{}, giving up.")
    end

    sret_types  = DataType[]  # Julia types of all returned variables
    # By ref values we create and need to preserve
    ccexprs = Union{Expr, Symbol}[] # The expressions passed to the `llvmcall`

    if !GPUCompiler.isghosttype(F) && !Core.Compiler.isconstType(F)
        isboxed = GPUCompiler.deserves_argbox(F)
        argexpr = :(f)
        if isboxed
            push!(types, Any)
        else
            push!(types, F)
        end

        push!(ccexprs, argexpr)
        if DF != Nothing
            argexpr = :(df)
            if isboxed
                push!(types, Any)
            else
                push!(types, F)
            end
            push!(ccexprs, argexpr)
        end
    end

    for (i, T) in enumerate(argtypes)
        source_typ = eltype(T)
        if GPUCompiler.isghosttype(source_typ) || Core.Compiler.isconstType(source_typ)
            @assert T <: Const
            continue
        end
        expr = argexprs[i]

        isboxed = GPUCompiler.deserves_argbox(source_typ)
        argexpr = Expr(:., expr, QuoteNode(:val))
        if isboxed
            push!(types, Any)
        else
            push!(types, source_typ)
        end

        push!(ccexprs, argexpr)

        T <: Const && continue

        if T <: Active
            if is_adjoint
                push!(sret_types, source_typ)
            end
        elseif T <: Duplicated || T <: DuplicatedNoNeed
            argexpr =  Expr(:., expr, QuoteNode(:dval))
            if isboxed
                push!(types, Any)
            else
                push!(types, source_typ)
            end
            push!(ccexprs, argexpr)
        else
            error("calling convention should be annotated, got $T")
        end
    end

    # API.DFT_OUT_DIFF
    if is_adjoint && rettype <: Active
        @assert allocatedinline(eltype(rettype))
        push!(types, eltype(rettype))
        idx = length(argtypes) + 1
        push!(ccexprs, argexprs[idx])
    end

    if needs_tape
        # TODO
        push!(types, Ptr{Cvoid})
        push!(ccexprs, last(argexprs))
    end

    if is_forward
        # Tape
        if CC <: AugmentedForwardThunk 
            push!(sret_types, Ptr{Cvoid})
        end

        returnUsed = !(GPUCompiler.isghosttype(eltype(rettype)) || Core.Compiler.isconstType(eltype(rettype)))
        if returnUsed
            if CC <: AugmentedForwardThunk || (CC <: ForwardModeThunk && rettype <: Duplicated)
                push!(sret_types, eltype(rettype))
            end
            if rettype <: Duplicated || rettype <: DuplicatedNoNeed
                push!(sret_types, eltype(rettype))
            end
        end
    end


	# calls fptr
	ctx = LLVM.Context()
	llvmtys = LLVMType[convert(LLVMType, x; ctx, allow_boxed=true) for x in types]
    if !isempty(sret_types)
      llsret_types = LLVMType[convert(LLVMType, x; ctx, allow_boxed=true) for x in sret_types]
      T_sjoint = LLVM.StructType(llsret_types; ctx)
      if in(Any, sret_types)
        for T in llsret_types
          pushfirst!(llvmtys, convert(LLVMType, Ptr{Cvoid}; ctx))
        end
      else
        pushfirst!(llvmtys, convert(LLVMType, Ptr{Cvoid}; ctx))
      end
	end
    pushfirst!(llvmtys, convert(LLVMType, Ptr{Cvoid}; ctx))
    T_void = convert(LLVMType, Nothing; ctx)
	llvm_f, _ = LLVM.Interop.create_function(T_void, llvmtys)
	mod = LLVM.parent(llvm_f)
    i64 = LLVM.IntType(64; ctx)
	LLVM.Builder(ctx) do builder
		entry = BasicBlock(llvm_f, "entry"; ctx)
		position!(builder, entry)
		params = collect(LLVM.Value, parameters(llvm_f))
		lfn = @inbounds params[1]
		params = params[2:end]
        callparams = params
        if in(Any, sret_types)
            callparams = params[(length(sret_types)+1):end]
            alloc = LLVM.alloca!(builder, T_sjoint)
            pushfirst!(callparams, alloc)
        end
		lfn = inttoptr!(builder, lfn, LLVM.PointerType(LLVM.FunctionType(T_void, [llvmtype(x) for x in callparams])))
		call!(builder, lfn, callparams)
        if in(Any, sret_types)
            for (i, (parm, sret)) in enumerate(zip(params[1:length(sret_types)], llsret_types))
                out = LLVM.load!(builder, LLVM.gep!(builder, alloc, [LLVM.ConstantInt(LLVM.IntType(64; ctx), 0), LLVM.ConstantInt(LLVM.IntType(32; ctx), i-1)]))
                parm = LLVM.inttoptr!(builder, parm, LLVM.PointerType(sret))
                LLVM.store!(builder, out, parm)
            end
		end
        ret!(builder)
	end

	ir = string(mod)
	fn = LLVM.name(llvm_f)

    @assert length(types) == length(ccexprs)
    if !isempty(sret_types)

        if in(Any, sret_types)
       
        msrets = (:($(Symbol(:ref, i)) = Ref{$x}()) for (i, x) in enumerate(sret_types))
        gcsrets = (:($(Symbol(:ref, i))) for (i, x) in enumerate(sret_types))
        tptrs = (:($(Symbol(:tptr, i)) = Base.unsafe_convert(Ptr{Cvoid}, Base.unsafe_convert(Ptr{$x}, $(Symbol(:ref,i)) ) ) ) for (i, x) in enumerate(sret_types))
        voidptrs = (:(Ptr{Cvoid}) for _ in 1:length(sret_types))
        tptrres = (:($(Symbol(:tptr, i)) ) for (i, x) in enumerate(sret_types))
        results = (:($(Symbol(:ref, i))[] ) for (i, x) in enumerate(sret_types))
        return quote
            Base.@_inline_meta

            let $(msrets...)
            GC.@preserve $(gcsrets...) begin
                $(tptrs...)
                Base.llvmcall(($ir, $fn), Cvoid,
                    Tuple{Ptr{Cvoid},
                    $(voidptrs...),
                    $(types...)},
                    fptr,
                    $(tptrres...),
                    $(ccexprs...))
            end
            return ( $(results...), )
            end
        end

        else

        return quote
            Base.@_inline_meta
            sret = Ref{$(Tuple{sret_types...})}()
            GC.@preserve sret begin
                tptr = Base.unsafe_convert(Ptr{$(Tuple{sret_types...})}, sret)
                tptr = Base.unsafe_convert(Ptr{Cvoid}, tptr)
                Base.llvmcall(($ir, $fn), Cvoid,
                    Tuple{Ptr{Cvoid}, Ptr{Cvoid}, $(types...)},
                    fptr, tptr, $(ccexprs...))
            end
            return sret[]
        end
        end
    else
        return quote
            Base.@_inline_meta
            Base.llvmcall(($ir, $fn), Cvoid,
                Tuple{Ptr{Cvoid}, $(types...),},
                fptr, $(ccexprs...))
            return ()
        end
    end
end

##
# JIT
##

function _link(job, (mod, adjoint_name, primal_name, ctx))
    params = job.params
    adjoint = params.adjoint

    primal = job.source
    rt = Core.Compiler.return_type(primal.f, primal.tt)

    # Now invoke the JIT
    jitted_mod = JIT.add!(mod)
    if VERSION >= v"1.9.0-DEV.115"
        LLVM.dispose(ctx)
    else
        # we cannot dispose of the global unique context
    end
    adjoint_addr = JIT.lookup(jitted_mod, adjoint_name)

    adjoint_ptr  = pointer(adjoint_addr)
    if adjoint_ptr === C_NULL
        throw(GPUCompiler.InternalCompilerError(job, "Failed to compile Enzyme thunk, adjoint not found"))
    end
    if primal_name === nothing
        primal_ptr = C_NULL
    else
        primal_addr = JIT.lookup(jitted_mod, primal_name)
        primal_ptr  = pointer(primal_addr)
        if primal_ptr === C_NULL
            throw(GPUCompiler.InternalCompilerError(job, "Failed to compile Enzyme thunk, primal not found"))
        end
    end

    return Thunk(adjoint_ptr, primal_ptr)
end

# actual compilation
function _thunk(job)
    params = job.params

    # TODO: on 1.9, this actually creates a context. cache those.
    ctx = JuliaContext()
    mod, meta = codegen(:llvm, job; optimize=false, ctx)

    adjointf, augmented_primalf = meta.adjointf, meta.augmented_primalf

    adjoint_name = name(adjointf)

    if augmented_primalf !== nothing
        primal_name = name(augmented_primalf)
    else
        primal_name = nothing
    end

    # Enzyme kills dead instructions, and removes the ptls call
    # which we need for correct GC handling in LateLowerGC
    reinsert_gcmarker!(adjointf)
    augmented_primalf !== nothing && reinsert_gcmarker!(augmented_primalf)

    # Run post optimization pipeline
    post_optimze!(mod, JIT.get_tm())
    return (mod, adjoint_name, primal_name, ctx)
end

const cache = Dict{UInt, Dict{UInt, Any}}()

function thunk(f::F,df::DF, ::Type{A}, tt::TT=Tuple{},::Val{Mode}=Val(API.DEM_ReverseModeCombined)) where {F, DF, A<:Annotation, TT<:Type, Mode}
    primal, adjoint = fspec(f, tt)

    if A isa UnionAll
        rt = Core.Compiler.return_type(primal.f, primal.tt)
        rt = A{rt}
    else
        @assert A isa DataType
        # Can we relax this condition?
        @assert eltype(A) == Core.Compiler.return_type(primal.f, primal.tt)
        rt = A
    end

    if eltype(rt) == Union{}
        error("Return type inferred to be Union{}. Giving up.")
    end

    # We need to use primal as the key, to lookup the right method
    # but need to mixin the hash of the adjoint to avoid cache collisions
    # This is counter-intuitive since we would expect the cache to be split
    # by the primal, but we want the generated code to be invalidated by
    # invalidations of the primal, which is managed by GPUCompiler.
    local_cache = get!(Dict{Int, Any}, cache, hash(adjoint, hash(rt, UInt64(Mode))))

    target = Compiler.EnzymeTarget()

    params = Compiler.EnzymeCompilerParams(adjoint, Mode, rt, true, DF != Nothing, #=abiwrap=#true)
    job    = Compiler.CompilerJob(target, primal, params)

    thunk = GPUCompiler.cached_compilation(local_cache, job, _thunk, _link)::Thunk
    if Mode == API.DEM_ReverseModePrimal || Mode == API.DEM_ReverseModeGradient
        augmented = AugmentedForwardThunk{F, rt, adjoint.tt, DF}(f, thunk.primal, df)
        adjoint  = AdjointThunk{F, rt, adjoint.tt, DF}(f, thunk.adjoint, df)
        return (augmented, adjoint)
    elseif Mode == API.DEM_ReverseModeCombined
        return CombinedAdjointThunk{F, rt, adjoint.tt, DF}(f, thunk.adjoint, df)
    elseif Mode == API.DEM_ForwardMode
        return ForwardModeThunk{F, rt, adjoint.tt, DF}(f, thunk.adjoint, df)
    else
        @assert false
    end
end

import GPUCompiler: deferred_codegen_jobs

@generated function deferred_codegen(::Val{f}, ::Val{tt}, ::Val{rt}, ::Val{DupClosure}=Val(false),::Val{Mode}=Val(API.DEM_ReverseModeCombined)) where {f,tt, rt, DupClosure, Mode}
    primal, adjoint = fspec(f, tt)
    target = EnzymeTarget()
    params = EnzymeCompilerParams(adjoint, Mode, rt, true, DupClosure, #=abiwrap=#true)
    job    = CompilerJob(target, primal, params)

    addr = get_trampoline(job)
    id = Base.reinterpret(Int, pointer(addr))

    deferred_codegen_jobs[id] = job
    trampoline = reinterpret(Ptr{Cvoid}, id)

    quote
        ccall("extern deferred_codegen", llvmcall, Ptr{Cvoid}, (Ptr{Cvoid},), $trampoline)
    end
end

include("compiler/reflection.jl")
include("compiler/validation.jl")

end
