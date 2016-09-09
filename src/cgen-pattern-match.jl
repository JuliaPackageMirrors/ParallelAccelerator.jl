#=
Copyright (c) 2015, Intel Corporation
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
- Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
THE POSSIBILITY OF SUCH DAMAGE.
=#


# math functions
libm_math_functions = Set([:sin, :cos, :tan, :asin, :acos, :acosh, :atanh, :log, :log2, :log10, :lgamma, :log1p,:asinh,:atan,:cbrt,:cosh,:erf,:exp,:expm1,:sinh,:sqrt,:tanh, :isnan])
#using Debug

function pattern_match_call_math(fun::Symbol, input::AbstractString, typ::Type, linfo)
    s = ""
    isDouble = typ == Float64
    isFloat = typ == Float32
    isComplex = typ <: Complex
    isInt = typ <: Integer
    if in(fun,libm_math_functions) && (isFloat || isDouble || isComplex)
        @dprintln(3,"FOUND ", fun)
        s = string(fun)*"("*input*");"
    end

    # abs() needs special handling since fabs() in math.h should be called for floats
    if is(fun,:abs) && (isFloat || isDouble || isComplex || isInt)
      @dprintln(3,"FOUND ", fun)
      fname = (isInt || isComplex) ? "abs" : (isFloat ? "fabsf" : "fabs")
      s = fname*"("*input*");"
    end
    return s
end

function pattern_match_call_math(fun::Symbol, input::RHSVar, linfo)
  pattern_match_call_math(fun, from_expr(input, linfo), getType(input, linfo), linfo)
end


function pattern_match_call_math(fun::GlobalRef, input, linfo)
    fun = Base.resolve(fun)
    if fun.mod == Base
        pattern_match_call_math(fun.name, input,linfo)
    else
        return ""
    end
end

function pattern_match_call_math(fun::ANY, input::ANY, linfo)
    return ""
end

function pattern_match_call_throw(fun::GlobalRef, input, linfo)
    s = ""
    if fun.name==:throw || fun.name==:error
        s = "(throw(\"Julia throw() or error() called.\"), 0)"
    end
    return s
end

function pattern_match_call_throw(fun::Symbol, input, linfo)
    s = ""
    if fun==:throw || fun==:error
        s = "(throw(\"Julia throw() or error() called.\"), 0)"
    end
    return s
end

function pattern_match_call_throw(fun::ANY, input::ANY, linfo)
    return ""
end

function pattern_match_call_powersq(fun, x::Number, y::Integer, linfo)
    s = ""
    if isBaseFunc(fun, :power_by_squaring)
        s = "cgen_pown("*from_expr(x,linfo)*","*from_expr(y,linfo)*")"
    end
    return s
end

function pattern_match_call_powersq(fun::ANY, x::ANY, y::ANY,linfo)
    return ""
end

function pattern_match_call_rand(linfo, fun, args...)
    @dprintln(3,"pattern_match_call_rand ", fun)
    res = ""
    if isBaseFunc(fun, :rand)
        if USE_OMP==1
            res = "cgen_distribution(cgen_rand_generator[omp_get_thread_num()]);\n"
        else
            res = "cgen_distribution(cgen_rand_generator);\n"
        end
    end
    @dprintln(3,"pattern_match_call_rand res = ", res)
    return res
end

function pattern_match_call_randn(linfo, fun, args...)
    @dprintln(3,"pattern_match_call_randn ", fun)
    res = ""
    if isBaseFunc(fun, :randn)
        if USE_OMP==1
            res = "cgen_n_distribution(cgen_rand_generator[omp_get_thread_num()]);\n"
        else
            res = "cgen_n_distribution(cgen_rand_generator);\n"
        end
    end
    @dprintln(3,"pattern_match_call_randn res = ", res)
    return res
end

function pattern_match_call_reshape(fun, inp::Any, shape::RHSVar, linfo)
    res = ""
    if isBaseFunc(fun, :reshape)
        typ = getSymType(shape, linfo)
        if istupletyp(typ)
            dim = length(typ.parameters)
            sh = from_expr(shape,linfo)
            shapes = mapfoldl(i->sh*".f"*string(i-1), (a,b) -> a*","*b, 1:dim)
            res = from_expr(inp,linfo) * ".reshape(" * shapes * ");\n"
        else
            error("call to reshape expects a tuple, but got ", typ)
        end
    end
    return res
end

function pattern_match_call_reshape(fun::ANY, inp::ANY, shape::ANY,linfo)
    return ""
end

function getSymType(a, linfo)
    return lstate.symboltable[lookupVariableName(a, linfo)]
end

function pattern_match_call_gemm(fun::GlobalRef, C::RHSVar, tA::Char, tB::Char, A::RHSVar, B::RHSVar,linfo)
    if fun.mod!=Base.LinAlg || fun.name!=:gemm_wrapper!
        return ""
    end
    cblas_fun = ""
    typ = getSymType(A, linfo)
    if getSymType(B, linfo) != typ || getSymType(C, linfo) != typ
        return ""
    end
    if typ==Array{Float32,2}
        cblas_fun = "cblas_sgemm"
    elseif typ==Array{Float64,2}
        cblas_fun = "cblas_dgemm"
    else
        return ""
    end
    s = "$(from_expr(C,linfo)); "
    # GEMM wants dimensions after possible transpose
    m = (tA == 'N') ? from_arraysize(A,1,linfo) : from_arraysize(A,2,linfo)
    k = (tA == 'N') ? from_arraysize(A,2,linfo) : from_arraysize(A,1,linfo)
    n = (tB == 'N') ? from_arraysize(B,2,linfo) : from_arraysize(B,1,linfo)

    lda = from_arraysize(A,1,linfo)
    ldb = from_arraysize(B,1,linfo)
    ldc = m

    CblasNoTrans = 111
    CblasTrans = 112
    _tA = tA == 'N' ? CblasNoTrans : CblasTrans
    _tB = tB == 'N' ? CblasNoTrans : CblasTrans
    CblasColMajor = 102


    if mkl_lib!="" || openblas_lib!="" || sys_blas==1
        s *= "$(cblas_fun)((CBLAS_ORDER)$(CblasColMajor),(CBLAS_TRANSPOSE)$(_tA),(CBLAS_TRANSPOSE)$(_tB),$m,$n,$k,1.0,
        $(from_expr(A,linfo)).data, $lda, $(from_expr(B,linfo)).data, $ldb, 0.0, $(from_expr(C,linfo)).data, $ldc)"
    else
        println("WARNING: MKL and OpenBLAS not found. Matrix multiplication might be slow.
        Please install MKL or OpenBLAS and rebuild ParallelAccelerator for better performance.")
        s *= "cgen_$(cblas_fun)($(from_expr(tA!='N',linfo)), $(from_expr(tB!='N',linfo)), $m,$n,$k, $(from_expr(A,linfo)).data, $lda, $(from_expr(B,linfo)).data, $ldb, $(from_expr(C,linfo)).data, $ldc)"
    end

    return s
end

function pattern_match_call_gemm(fun::ANY, C::ANY, tA::ANY, tB::ANY, A::ANY, B::ANY,linfo)
    return ""
end

function pattern_match_call_gemv(fun::GlobalRef, y::RHSVar, tA::Char, A::RHSVar, x::RHSVar,linfo)
    if !((fun.mod==Base.LinAlg || fun.mod==Base.LinAlg.BLAS) && fun.name==:gemv!)
        return ""
    end
    cblas_fun = ""
    typ = eltype(getSymType(A, linfo))

    if typ==Float32
        cblas_fun = "cblas_sgemv"
    elseif typ==Float64
        cblas_fun = "cblas_dgemv"
    else
        return ""
    end

    s = "$(from_expr(y,linfo)); "

    m = from_arraysize(A,1,linfo)
    n = from_arraysize(A,2,linfo)


    lda = from_arraysize(A,1,linfo)

    CblasNoTrans = 111
    CblasTrans = 112
    _tA = tA == 'N' ? CblasNoTrans : CblasTrans
    CblasColMajor = 102


    if mkl_lib!="" || openblas_lib!="" || sys_blas==1
        s *= "$(cblas_fun)((CBLAS_ORDER)$(CblasColMajor),(CBLAS_TRANSPOSE)$(_tA),$m,$n, 1.0,
        $(from_expr(A,linfo)).data, $lda, $(from_expr(x,linfo)).data, 1, 0.0, $(from_expr(y,linfo)).data, 1)"
    else
        println("WARNING: MKL and OpenBLAS not found. Matrix-vector multiplication might be slow.
        Please install MKL or OpenBLAS and rebuild ParallelAccelerator for better performance.")
        s *= "cgen_$(cblas_fun)($(from_expr(tA!='N',linfo)), $m,$n, $(from_expr(A,linfo)).data, $lda, $(from_expr(y,linfo)).data, $(from_expr(x,linfo)).data)"
    end

    return s
end

function pattern_match_call_gemv(fun::ANY, C::ANY, tA::ANY, A::ANY, B::ANY,linfo)
    return ""
end

function pattern_match_call_chol(fun::GlobalRef, A::RHSVar, vUL::Type, linfo)
    if fun.mod!=Base.LinAlg || fun.name!=:chol!
        return ""
    end

    cblas_fun = ""
    typ = eltype(getSymType(A, linfo))

    if typ==Float32
        lapack_fun = "LAPACKE_spotrf"
    elseif typ==Float64
        lapack_fun = "LAPACKE_dpotrf"
    else
        return ""
    end

    s = ".data=$(from_expr(A,linfo)); "

    n = from_arraysize(A,1,linfo)


    lda = from_arraysize(A,1,linfo)


    LAPACK_COL_MAJOR = 102
    uplo = vUL==Val{:U} ? 'U' : 'L'


    if mkl_lib!="" || openblas_lib!="" || sys_blas==1
        s *= "$(lapack_fun)($(LAPACK_COL_MAJOR), '$uplo', $n, $(from_expr(A,linfo)).data, $lda)"
    else
        println("WARNING: MKL and OpenBLAS not found. Matrix multiplication might be slow.
        Please install MKL or OpenBLAS and rebuild ParallelAccelerator for better performance.")
        error("MKL LAPACK required for cholesky (TODO: support other lapack libraries and include a sequential implementation)")
        #s *= "cgen_$(cblas_fun)($(from_expr(tA!='N',linfo)), $m,$n, $(from_expr(A,linfo)).data, $lda, $(from_expr(y,linfo)).data, $(from_expr(x,linfo)).data)"
    end

    return s
end

function pattern_match_call_chol(fun::ANY, C::ANY, tA::ANY, linfo)
    return ""
end

function pattern_match_assignment_chol(lhs::LHSVar, rhs::Expr, linfo)
    call = ""
    if isCall(rhs) || isInvoke(rhs)
        fun = getCallFunction(rhs)
        args = getCallArguments(rhs)
        if length(args) == 2
            call *= pattern_match_call_chol(fun,args[1],args[2],linfo)
        end
    end
    if call!=""
        return from_expr(lhs,linfo)*call
    end
    return ""
end

function pattern_match_assignment_chol(lhs::ANY, rhs::ANY, linfo)
    return ""
end

function pattern_match_assignment_transpose(lhs::LHSVar, rhs::Expr, linfo)
    @dprintln(3, "pattern_match_assignment_transpose ", lhs, " ", rhs)
    call = ""
    if isCall(rhs) || isInvoke(rhs)
        fun = getCallFunction(rhs)
        args = getCallArguments(rhs)
        res = pattern_match_call_transpose(linfo, fun, lhs, args...)
        return res
    end
    return ""
end

function pattern_match_assignment_transpose(lhs::ANY, rhs::ANY, linfo)
    return ""
end

function pattern_match_call_trtrs(fun::GlobalRef, uplo::Char, trans::Char, diag::Char, A::RHSVar,B::RHSVar,  linfo)
    if fun.mod!=Base.LinAlg.LAPACK || fun.name!=:trtrs!
        return ""
    end

    cblas_fun = ""
    typ = eltype(getSymType(A, linfo))

    if typ==Float32
        lapack_fun = "LAPACKE_strtrs"
    elseif typ==Float64
        lapack_fun = "LAPACKE_dtrtrs"
    else
        return ""
    end

    s = "$(from_expr(B,linfo)); "

    n = from_arraysize(A,1,linfo)
    nrhs = from_arraysize(B,2,linfo)


    lda = from_arraysize(A,1,linfo)
    ldb = n

    LAPACK_COL_MAJOR = 102

    if mkl_lib!="" || openblas_lib!="" || sys_blas==1
        s *= "$(lapack_fun)($(LAPACK_COL_MAJOR), '$uplo', '$trans', '$diag', $n, $nrhs, $(from_expr(A,linfo)).data, $lda, $(from_expr(B,linfo)).data, $ldb)"
    else
        println("WARNING: MKL and OpenBLAS not found. Matrix multiplication might be slow.
        Please install MKL or OpenBLAS and rebuild ParallelAccelerator for better performance.")
        error("MKL LAPACK required for triangular solution (TODO: support other lapack libraries and include a sequential implementation)")
        #s *= "cgen_$(cblas_fun)($(from_expr(tA!='N',linfo)), $m,$n, $(from_expr(A,linfo)).data, $lda, $(from_expr(y,linfo)).data, $(from_expr(x,linfo)).data)"
    end

    return s
end

function pattern_match_call_trtrs(fun::ANY, C::ANY, tA::ANY,A::ANY, t::ANY, d::ANY, linfo)
    return ""
end

function pattern_match_call_copy!(linfo, fun, A, i, B, j, n)
    if isBaseFunc(fun, :copy!)
        "j2c_array_copyto(" *
          from_expr(A, linfo) * ", " *
          from_expr(i, linfo) * ", " *
          from_expr(B, linfo) * ", " *
          from_expr(j, linfo) * ", " *
          from_expr(n, linfo) * ")"
    else
        ""
    end
end

function pattern_match_call_transpose(linfo, fun::GlobalRef, fun1::GlobalRef, B::RHSVar, A::RHSVar)
    pattern_match_call_transpose(linfo, fun, B, A)
end

function pattern_match_call_transpose(linfo, fun::GlobalRef, B::RHSVar, A::RHSVar)
    dprintln(3, "pattern_match_call_transpose, ", (fun, B, A), " mkl_lib=", mkl_lib, " openblas=",openblas_lib, " sys_blas=",sys_blas)
    if !(fun.mod==Base && fun.name==:transpose! || fun.name ==:transpose_f! || fun.name == :transpose)
        return ""
    end
    blas_fun = ""
    typ = eltype(getSymType(A, linfo))
    ctyp = toCtype(typ)

    if typ==Float32
        blas_fun = "somatcopy"
    elseif typ==Float64
        blas_fun = "domatcopy"
    else
        blas_fun = ""
    end

    #s = "$(from_expr(B,linfo)); "
    s = ""

    m = from_arraysize(A,1,linfo)
    n = from_arraysize(A,2,linfo)

    lda = from_arraysize(A,1,linfo)
    ldb = from_arraysize(A,2,linfo)

    if mkl_lib!="" && blas_fun!=""
        s *= "mkl_$(blas_fun)('C','T',$m,$n, 1.0,
             $(from_expr(A,linfo)).data, $lda, $(from_expr(B,linfo)).data, $ldb)"
    elseif (openblas_lib!="" || sys_blas==1) && blas_fun!=""
        s *= "cblas_$(blas_fun)(CblasColMajor,CblasTrans,$m,$n, 1.0,
             $(from_expr(A,linfo)).data, $lda, $(from_expr(B,linfo)).data, $ldb)"
    else
        #println("""WARNING: MKL and OpenBLAS not found. Matrix-vector multiplication might be slow.
        #Please install MKL or OpenBLAS and rebuild ParallelAccelerator for better performance.""")
        #s *= "cgen_$(blas_fun)($m,$n,
        #     $(from_expr(A,linfo)).data, $lda, $(from_expr(B,linfo)).data, $ldb)"
        s *= "for(int i=0; i<$m; i++) {\n"
        s *= "    for(int j=0; j<$n; j++) {\n"
        s *= "     $(from_expr(B,linfo)).data[j+i*$ldb] = $(from_expr(A,linfo)).data[i+j*$lda];\n"
        s *= "    }\n"
        s *= "}\n"
    end
    s = (fun.name == :transpose ? (from_expr(B,linfo) * " = j2c_array<$ctyp>::new_j2c_array_2d(NULL, $n, $m);\n"): "") * s
    s = from_expr(B,linfo)*"; "*s
    return s
end

function pattern_match_call_transpose(args...)
    return ""
end

function pattern_match_call_linalgtypeof(fun::GlobalRef, C::ANY,linfo)
    if fun.mod==Base.LinAlg && fun.name==:typeof
        return " "
    end
    return ""
end

function pattern_match_call_linalgtypeof(fun::ANY, C::ANY,linfo)
    return ""
end

function pattern_match_call_vecnorm(fun::GlobalRef, y::RHSVar, p::Int,linfo)
    if fun.mod!=Base.LinAlg || fun.name!=:vecnorm
        return ""
    end
    cblas_fun = ""
    typ = eltype(getSymType(y, linfo))

    if typ==Float32
        cblas_fun = "cblas_s"
    elseif typ==Float64
        cblas_fun = "cblas_d"
    else
        return ""
    end

    if p==1
        cblas_fun *= "asum"
    elseif p==2
        cblas_fun *= "nrm2"
    else
        println("norm ",p)
        error("vector norm not support")
    end

    s = ""

    n = from_arraysize(y,1,linfo)


    if mkl_lib!="" || openblas_lib!="" || sys_blas==1
        s *= "$(cblas_fun)( $n, $(from_expr(y,linfo)).data, 1)"
    else
        #println("WARNING: MKL and OpenBLAS not found. Matrix-vector multiplication might be slow.
        #Please install MKL or OpenBLAS and rebuild ParallelAccelerator for better performance.")
        s *= "cgen_$(cblas_fun)( $n, $(from_expr(y,linfo)).data)"
    end

    return s
end

function pattern_match_call_vecnorm(fun::ANY, C::ANY, tA::ANY,linfo)
    return ""
end


function pattern_match_call(ast::Array{Any, 1},linfo)
    @dprintln(3,"pattern matching ",ast)
    s = ""

    if(length(ast)==2)
        s = pattern_match_call_throw(ast[1],ast[2],linfo)
        s *= pattern_match_call_math(ast[1],ast[2],linfo)
        s *= pattern_match_call_linalgtypeof(ast[1],ast[2],linfo)
    end

    if s=="" && (length(ast)==3) # randn! call has 3 args
        #sa*= pattern_match_call_powersq(ast[1],ast[2], ast[3])
        s *= pattern_match_call_reshape(ast[1],ast[2],ast[3],linfo)
        s *= pattern_match_call_transpose(linfo, ast...)
        s *= pattern_match_call_vecnorm(ast[1],ast[2],ast[3],linfo)
    end
    if s=="" && (length(ast)>=1) # rand can have 1 or more arg
        s *= pattern_match_call_transpose(linfo, ast...)
        s *= pattern_match_call_randn(linfo, ast...)
        s *= pattern_match_call_rand(linfo, ast...)
    end
    # gemv calls have 5 args
    if s=="" && (length(ast)==5)
        s *= pattern_match_call_gemv(ast[1],ast[2],ast[3],ast[4],ast[5],linfo)
    end
    # gemm calls have 6 args
    if s=="" && (length(ast)==6)
        s *= pattern_match_call_copy!(linfo, ast...)
        s *= pattern_match_call_gemm(ast[1],ast[2],ast[3],ast[4],ast[5],ast[6],linfo)
        s *= pattern_match_call_trtrs(ast[1],ast[2],ast[3],ast[4],ast[5],ast[6],linfo)
    end
    return s
end


function from_assignment_match_hvcat(lhs, rhs::Expr, linfo)
    s = ""
    # if this is a hvcat call, the array should be allocated and initialized
    if (isCall(rhs) || isInvoke(rhs)) && (isBaseFunc(getCallFunction(rhs),:typed_hvcat) || checkGlobalRefName(getCallFunction(rhs),:hvcat))
        @dprintln(3,"Found hvcat assignment: ", lhs," ", rhs)

        is_typed::Bool = isBaseFunc(getCallFunction(rhs),:typed_hvcat)

        rows = Int64[]
        values = Any[]
        typ = "double"
        args = getCallArguments(rhs)

        if is_typed
            atyp = args[1]
            if isa(atyp, GlobalRef)
                atyp = eval(args[1].name)
            end
            @assert isa(atyp, DataType) ("hvcat expects the first argument to be a type, but got " * args[1])
            typ = toCtype(atyp)
            rows = lstate.tupleTable[args[2]]
            values = args[3:end]
        else

            rows = lstate.tupleTable[args[1]]
            values = args[2:end]
            atyp, arr_dims = parseArrayType(getSymType(lhs, linfo))
            typ = toCtype(atyp)
        end

        nr = length(rows)
        nc = rows[1] # all rows should have the same size
        s *= from_expr(lhs,linfo) * " = j2c_array<$typ>::new_j2c_array_2d(NULL, $nr, $nc);\n"
        s *= mapfoldl((i) -> from_setindex([lhs,values[i],convert(Int64,ceil(i/nc)),(i-1)%nc+1],linfo)*";", (a, b) -> "$a $b", 1:length(values))
    end
    return s
end

function from_assignment_match_hvcat(lhs, rhs::ANY, linfo)
    return ""
end

function from_assignment_match_cat_t(lhs, rhs::Expr, linfo)
    s = ""
    if (isCall(rhs) || isInvoke(rhs)) && isBaseFunc(getCallFunction(rhs), :cat_t)
        args = getCallArguments(rhs)
        dims = args[1]
        @assert dims==2 "CGen: only 2d cat_t() is supported now"
        size = length(args[3:end])
        typ = toCtype(eval(args[2].name))
        s *= from_expr(lhs,linfo) * " = j2c_array<$typ>::new_j2c_array_$(dims)d(NULL, 1,$size);\n"
        values = args[3:end]
        s *= mapfoldl((i) -> from_setindex([lhs,values[i],i],linfo)*";", (a, b) -> "$a $b", 1:length(values))
    end
    return s
end

function from_assignment_match_cat_t(lhs, rhs::ANY, linfo)
    return ""
end

function from_assignment_match_hcat(lhs, rhs::Expr, linfo)
    s = ""
    if (isCall(rhs) || isInvoke(rhs)) && isBaseFunc(getCallFunction(rhs), :hcat)
        args = getCallArguments(rhs)
        for a in args
            atyp = getType(a, linfo)
            @assert atyp<:Array && ndims(atyp)==1 "CGen only supports hcat of 1D arrays"
        end
        typ = eltype(getType(args[1], linfo))
        size = length(args)
        ctyp = toCtype(typ)
        len = from_arraysize(args[1],1,linfo)
        clhs = from_expr(lhs,linfo)
        s *= "$clhs = j2c_array<$ctyp>::new_j2c_array_2d(NULL, $len, $size);\n"
        s *= "for(int i=0; i<$len; i++) {\n"
        for j in 1:size
            arr = from_expr(args[j],linfo)
            s *= "$clhs.data[i*$size+$(j-1)] = $arr.data[i];\n"
        end
        s *= "}\n"
    end
    return s
end

function from_assignment_match_hcat(lhs, rhs::ANY, linfo)
    return ""
end

function from_assignment_match_iostream(lhs, rhs::GlobalRef, linfo)
    s = ""
    ltype = getType(lhs, linfo)
    @dprintln(3, "from_assignment_match_iostream ltype = ", ltype)
    if (ltype == IOStream)
        if rhs.mod == Base && rhs.name == :STDOUT
            lhsO = from_expr(lhs, linfo)
            s *= lhsO * ".handle = (void**)&(std::cout);"
        end
    end
    return s
end

function from_assignment_match_iostream(lhs, rhs::ANY, linfo)
    return ""
end
