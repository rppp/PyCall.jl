__precompile__()

module PyCall

export pycall, pyimport, pybuiltin, PyObject, PyReverseDims,
       PyPtr, pyincref, pydecref, pyversion, PyArray, PyArray_Info,
       pyerr_check, pyerr_clear, pytype_query, PyAny, @pyimport, PyDict,
       pyisinstance, pywrap, pytypeof, pyeval, PyVector, pystring,
       pyraise, pytype_mapping, pygui, pygui_start, pygui_stop,
       pygui_stop_all, @pylab, set!, PyTextIO, @pysym, PyNULL, @pydef

import Base: size, ndims, similar, copy, getindex, setindex!, stride,
       convert, pointer, summary, convert, show, haskey, keys, values,
       eltype, get, delete!, empty!, length, isempty, start, done,
       next, filter!, hash, splice!, pop!, ==, isequal, push!,
       unshift!, shift!, append!, insert!, prepend!, writemime, mimewritable

# Python C API is not interrupt-save.  In principle, we should
# use sigatomic for every ccall to the Python library, but this
# should really be fixed in Julia (#2622).  However, we will
# use the sigatomic_begin/end functions to protect pycall and
# similar long-running (or potentially long-running) code.
import Base: sigatomic_begin, sigatomic_end

## Compatibility import for v0.4, v0.5
using Compat
import Base.unsafe_convert

#########################################################################

const depfile = joinpath(dirname(@__FILE__), "..", "deps", "deps.jl")
isfile(depfile) || error("PyCall not properly installed. Please run Pkg.build(\"PyCall\")")
include(depfile) # generated by Pkg.build("PyCall")

macro pysym(func)
    :(($func, libpython))
end
macro pyglobal(name)
    :(cglobal(($name, libpython)))
end
macro pyglobalobj(name)
    :(cglobal(($name, libpython), PyObject_struct))
end

#########################################################################

# Mirror of C PyObject struct (for non-debugging Python builds).
# We won't actually access these fields directly; we'll use the Python
# C API for everything.  However, we need to define a unique Ptr type
# for PyObject*, and we might as well define the actual struct layout
# while we're at it.
immutable PyObject_struct
    ob_refcnt::Int
    ob_type::Ptr{Void}
end

typealias PyPtr Ptr{PyObject_struct} # type for PythonObject* in ccall

const PyPtr_NULL = PyPtr(C_NULL)

#########################################################################
# Wrapper around Python's C PyObject* type, with hooks to Python reference
# counting and conversion routines to/from C and Julia types.
"""
    PyObject(juliavar)

This converts a julia variable to a PyObject, which is a reference to a Python object.
You can convert back to native julia types using `convert(T, o::PyObject)`, or using `PyAny(o)`.

Given `o::PyObject`, `o[:attribute]` is equivalent to `o.attribute` in Python, with automatic type conversion.

Given `o::PyObject`, `get(o, key)` is equivalent to `o[key]` in Python, with automatic type conversion.
"""
type PyObject
    o::PyPtr # the actual PyObject*
    function PyObject(o::PyPtr)
        po = new(o)
        finalizer(po, pydecref)
        return po
    end
end

PyNULL() = PyObject(PyPtr_NULL)

function pydecref(o::PyObject)
    ccall(@pysym(:Py_DecRef), Void, (PyPtr,), o.o)
    o.o = PyPtr_NULL
    o
end

function pyincref(o::PyObject)
    ccall((@pysym :Py_IncRef), Void, (PyPtr,), o)
    o
end

# doing an incref *before* creating a PyObject may safer in the
# case of borrowed references, to ensure that no exception or interrupt
# induces a double decref.
function pyincref(o::PyPtr)
    ccall((@pysym :Py_IncRef), Void, (PyPtr,), o)
    PyObject(o)
end

"""
"Steal" a reference from a PyObject: return the raw PyPtr, while
setting the corresponding `o.o` field to `NULL` so that no decref
will be performed when `o` is garbage collected.  (This means that
you can no longer use `o`.)  Used for passing objects to Python.
"""
function pystealref!(o::PyObject)
    optr = o.o
    o.o = PyPtr_NULL # don't decref when o is gc'ed
    return optr
end

function Base.copy!(dest::PyObject, src::PyObject)
    pydecref(dest)
    dest.o = src.o
    return pyincref(dest)
end

pyisinstance(o::PyObject, t::PyObject) =
  t.o != C_NULL && ccall((@pysym :PyObject_IsInstance), Cint, (PyPtr,PyPtr), o, t.o) == 1

pyisinstance(o::PyObject, t::Union{Ptr{Void},PyPtr}) =
  t != C_NULL && ccall((@pysym :PyObject_IsInstance), Cint, (PyPtr,PyPtr), o, t) == 1

pyquery(q::Ptr{Void}, o::PyObject) =
  ccall(q, Cint, (PyPtr,), o) == 1

pytypeof(o::PyObject) = o.o == C_NULL ? throw(ArgumentError("NULL PyObjects have no Python type")) : pycall(TypeType, PyObject, o)

# conversion to pass PyObject as ccall arguments:
unsafe_convert(::Type{PyPtr}, po::PyObject) = po.o

# use constructor for generic conversions to PyObject
convert(::Type{PyObject}, o) = PyObject(o)
PyObject(o::PyObject) = o

#########################################################################

include("pyinit.jl")
include("exception.jl")
include("gui.jl")

#########################################################################

include("gc.jl")

# make a PyObject that embeds a reference to keep, to prevent Julia
# from garbage-collecting keep until o is finalized.
PyObject(o::PyPtr, keep::Any) = pyembed(PyObject(o), keep)

#########################################################################

include("pybuffer.jl")
include("conversions.jl")
include("pytype.jl")
include("pyclass.jl")
include("callback.jl")
include("io.jl")

#########################################################################
# Pretty-printing PyObject

function pystring(o::PyObject)
    if o.o == C_NULL
        return "NULL"
    else
        s = ccall((@pysym :PyObject_Repr), PyPtr, (PyPtr,), o)
        if (s == C_NULL)
            pyerr_clear()
            s = ccall((@pysym :PyObject_Str), PyPtr, (PyPtr,), o)
            if (s == C_NULL)
                pyerr_clear()
                return string(o.o)
            end
        end
        return convert(AbstractString, PyObject(s))
    end
end

function show(io::IO, o::PyObject)
    print(io, "PyObject $(pystring(o))")
end

function Base.Docs.doc(o::PyObject)
    Base.Docs.Text(haskey(o, "__doc__") ?
                   convert(AbstractString, o["__doc__"]) :
                   "Python object (no docstring found)")
end

#########################################################################
# computing hashes of PyObjects

const pysalt = hash("PyCall.PyObject") # "salt" to mix in to PyObject hashes
hashsalt(x) = hash(x, pysalt)

function hash(o::PyObject)
    if o.o == C_NULL
        hashsalt(C_NULL)
    elseif is_pyjlwrap(o)
        # call native Julia hash directly on wrapped Julia objects,
        # since on 64-bit Windows the Python 2.x hash is only 32 bits
        hashsalt(unsafe_pyjlwrap_to_objref(o.o))
    else
        h = ccall((@pysym :PyObject_Hash), Py_hash_t, (PyPtr,), o)
        if h == -1 # error
            pyerr_clear()
            return hashsalt(o.o)
        end
        hashsalt(h)
    end
end

#########################################################################
# PyObject equality

const Py_EQ = convert(Cint, 2) # from Python's object.h

function ==(o1::PyObject, o2::PyObject)
    if o1.o == C_NULL || o2.o == C_NULL
        return o1.o == o2.o
    elseif is_pyjlwrap(o1)
        if is_pyjlwrap(o2)
            return unsafe_pyjlwrap_to_objref(o1.o) ==
                   unsafe_pyjlwrap_to_objref(o2.o)
        else
            return false
        end
    else
        val = ccall((@pysym :PyObject_RichCompareBool), Cint,
                    (PyPtr, PyPtr, Cint), o1, o2, Py_EQ)
        return val == -1 ? o1.o == o2.o : Bool(val)
    end
end

isequal(o1::PyObject, o2::PyObject) = o1 == o2 # Julia 0.2 compatibility

#########################################################################
# For o::PyObject, make o["foo"] and o[:foo] equivalent to o.foo in Python,
# with the former returning an raw PyObject and the latter giving the PyAny
# conversion.

function getindex(o::PyObject, s::AbstractString)
    if (o.o == C_NULL)
        throw(ArgumentError("ref of NULL PyObject"))
    end
    p = ccall((@pysym :PyObject_GetAttrString), PyPtr, (PyPtr, Cstring), o, s)
    if p == C_NULL
        pyerr_clear()
        throw(KeyError(s))
    end
    return PyObject(p)
end

getindex(o::PyObject, s::Symbol) = convert(PyAny, getindex(o, string(s)))

function setindex!(o::PyObject, v, s::Union{Symbol,AbstractString})
    if (o.o == C_NULL)
        throw(ArgumentError("assign of NULL PyObject"))
    end
    if -1 == ccall((@pysym :PyObject_SetAttrString), Cint,
                   (PyPtr, Cstring, PyPtr), o, s, PyObject(v))
        pyerr_clear()
        throw(KeyError(s))
    end
    o
end

function haskey(o::PyObject, s::Union{Symbol,AbstractString})
    if (o.o == C_NULL)
        throw(ArgumentError("haskey of NULL PyObject"))
    end
    return 1 == ccall((@pysym :PyObject_HasAttrString), Cint,
                      (PyPtr, Cstring), o, s)
end

#########################################################################

keys(o::PyObject) = Symbol[m[1] for m in pycall(inspect["getmembers"],
                                PyVector{Tuple{Symbol,PyObject}}, o)]

#########################################################################
# Create anonymous composite w = pywrap(o) wrapping the object o
# and providing access to o's members (converted to PyAny) as w.member.

# we skip wrapping Julia reserved words (which cannot be type members)
const reserved = Set{ASCIIString}(["while", "if", "for", "try", "return", "break", "continue", "function", "macro", "quote", "let", "local", "global", "const", "abstract", "typealias", "type", "bitstype", "immutable", "ccall", "do", "module", "baremodule", "using", "import", "export", "importall", "pymember", "false", "true", "Tuple"])

"""
    pywrap(o::PyObject)

This returns a wrapper `w` that is an anonymous module which provides (read) access to converted versions of o's members as w.member.

For example, `@pyimport module as name` is equivalent to `const name = pywrap(pyimport("module"))`

If the Python module contains identifiers that are reserved words in Julia (e.g. function), they cannot be accessed as `w.member`; one must instead use `w.pymember(:member)` (for the PyAny conversion) or w.pymember("member") (for the raw PyObject).
"""
function pywrap(o::PyObject, mname::Symbol=:__anon__)
    members = convert(Vector{Tuple{AbstractString,PyObject}},
                      pycall(inspect["getmembers"], PyObject, o))
    filter!(m -> !(m[1] in reserved), members)
    m = Module(mname, false)
    consts = [Expr(:const, Expr(:(=), symbol(x[1]), convert(PyAny, x[2]))) for x in members]
    exports = try
                  convert(Vector{Symbol}, o["__all__"])
              catch
                  [symbol(x[1]) for x in filter(x -> x[1][1] != '_', members)]
              end
    eval(m, Expr(:toplevel, consts..., :(pymember(s) = $(getindex)($(o), s)),
                 Expr(:export, exports...)))
    m
end

#########################################################################

"""
    pyimport(s::AbstractString)

Import the Python module `s` (a string or symbol) and return a pointer to it (a `PyObject`). Functions or other symbols in the module may then be looked up by s[name] where name is a string (for the raw PyObject) or symbol (for automatic type-conversion). Unlike the @pyimport macro, this does not define a Julia module and members cannot be accessed with `s.name`
"""
pyimport(name::AbstractString) =
    PyObject(@pycheckn ccall((@pysym :PyImport_ImportModule), PyPtr,
                             (Cstring,), name))
pyimport(name::Symbol) = pyimport(string(name))

# convert expressions like :math or :(scipy.special) into module name strings
modulename(s::Symbol) = string(s)
function modulename(e::Expr)
    if e.head == :.
        string(modulename(e.args[1]), :., modulename(e.args[2]))
    elseif e.head == :quote
        modulename(e.args...)
    else
        throw(ArgumentError("invalid module"))
    end
end

# separate this function in order to make it easier to write more
# pyimport-like functions
function pyimport_name(name, optional_varname)
    len = length(optional_varname)
    if len > 0 && (len != 2 || optional_varname[1] != :as)
        throw(ArgumentError("usage @pyimport module [as name]"))
    elseif len == 2
        optional_varname[2]
    elseif typeof(name) == Symbol
        name
    else
        mname = modulename(name)
        throw(ArgumentError("$mname is not a valid module variable name, use @pyimport $mname as <name>"))
    end
end

macro pyimport(name, optional_varname...)
    mname = modulename(name)
    Name = pyimport_name(name, optional_varname)
    quote
        if !isdefined($(Expr(:quote, Name)))
            const $(esc(Name)) = pywrap(pyimport($mname))
        elseif !isa($(esc(Name)), Module)
            error("@pyimport: ", $(Expr(:quote, Name)), " already defined")
        end
        nothing
    end
end

#########################################################################

# look up a global builtin
"""
    pybuiltin(s::AbstractString)

Look up a string or symbol `s` among the global Python builtins. If `s` is a string it returns a PyObject, while if `s` is a symbol it returns the builtin converted to `PyAny`.
"""
function pybuiltin(name)
    builtin[name]
end

#########################################################################

typealias TypeTuple{N} Union{Type,NTuple{N, Type}}

"""
    pycall(o::Union{PyObject,PyPtr}, returntype::TypeTuple, args...; kwargs...)

Call the given Python function (typically looked up from a module) with the given args... (of standard Julia types which are converted automatically to the corresponding Python types if possible), converting the return value to returntype (use a returntype of PyObject to return the unconverted Python object reference, or of PyAny to request an automated conversion)
"""
function pycall(o::Union{PyObject,PyPtr}, returntype::TypeTuple, args...; kwargs...)
    oargs = map(PyObject, args)
    nargs = length(args)
    sigatomic_begin()
    try
        arg = PyObject(@pycheckn ccall((@pysym :PyTuple_New), PyPtr, (Int,),
                                       nargs))
        for i = 1:nargs
            @pycheckz ccall((@pysym :PyTuple_SetItem), Cint,
                             (PyPtr,Int,PyPtr), arg, i-1, oargs[i])
            pyincref(oargs[i]) # PyTuple_SetItem steals the reference
        end
        if isempty(kwargs)
            ret = PyObject(@pycheckn ccall((@pysym :PyObject_Call), PyPtr,
                                          (PyPtr,PyPtr,PyPtr), o, arg, C_NULL))
        else
            kw = PyObject((AbstractString=>Any)[string(k) => v for (k, v) in kwargs])
            ret = PyObject(@pycheckn ccall((@pysym :PyObject_Call), PyPtr,
                                            (PyPtr,PyPtr,PyPtr), o, arg, kw))
        end
        jret = convert(returntype, ret)
        return jret
    finally
        sigatomic_end()
    end
end

# call overloading
if VERSION < v"0.5.0-dev+9814" # julia PR#13412 deprecated Base.call in 0.5
    Base.call(o::PyObject, args...; kws...) = pycall(o, PyAny, args...; kws...)

    # can't use default call(PyAny, o) since it has a ::PyAny typeassert
    Base.call(::Type{PyAny}, o::PyObject) = convert(PyAny, o)
else
    # need @eval here so that 0.4 does not fail to parse
    @eval (o::PyObject)(args...; kws...) = pycall(o, PyAny, args...; kws...)
    @eval (::Type{PyAny})(o::PyObject) = convert(PyAny, o)
end


#########################################################################
# Once Julia lets us overload ".", we will use [] to access items, but
# for now we can define "get".

function get(o::PyObject, returntype::TypeTuple, k, default)
    r = ccall((@pysym :PyObject_GetItem), PyPtr, (PyPtr,PyPtr), o,PyObject(k))
    if r == C_NULL
        pyerr_clear()
        default
    else
        convert(returntype, PyObject(r))
    end
end

get(o::PyObject, returntype::TypeTuple, k) =
    convert(returntype, PyObject(@pycheckn ccall((@pysym :PyObject_GetItem),
                                 PyPtr, (PyPtr,PyPtr), o, PyObject(k))))

get(o::PyObject, k, default) = get(o, PyAny, k, default)
get(o::PyObject, k) = get(o, PyAny, k)

function delete!(o::PyObject, k)
    e = ccall((@pysym :PyObject_DelItem), Cint, (PyPtr, PyPtr), o, PyObject(k))
    if e == -1
        pyerr_clear() # delete! ignores errors in Julia
    end
    return o
end

function set!(o::PyObject, k, v)
    @pycheckz ccall((@pysym :PyObject_SetItem), Cint, (PyPtr, PyPtr, PyPtr),
                     o, PyObject(k), PyObject(v))
    v
end

#########################################################################
# Support [] for integer keys, and other duck-typed sequence/list operations,
# as those don't conflict with symbols/strings used for attributes.

# Index conversion: Python is zero-based.  It also has -1 based
# backwards indexing, but we don't support this, in favor of the
# Julian syntax o[end-1] etc.
function ind2py(i)
    i <= 0 && throw(BoundsError())
    return i-1
end

getindex(o::PyObject, i::Integer) = convert(PyAny, PyObject(@pycheckn ccall((@pysym :PySequence_GetItem), PyPtr, (PyPtr, Int), o, ind2py(i))))
function setindex!(o::PyObject, v, i::Integer)
    @pycheckz ccall((@pysym :PySequence_SetItem), Cint, (PyPtr, Int, PyPtr), o, ind2py(i), PyObject(v))
    v
end
getindex(o::PyObject, i1::Integer, i2::Integer) = get(o, (ind2py(i1),ind2py(i2)))
setindex!(o::PyObject, v, i1::Integer, i2::Integer) = set!(o, (ind2py(i1),ind2py(i2)), v)
getindex(o::PyObject, I::Integer...) = get(o, map(ind2py, I))
setindex!(o::PyObject, v, I::Integer...) = set!(o, map(ind2py, I), v)
Base.endof(o::PyObject) = length(o)
length(o::PyObject) = @pycheckz ccall((@pysym :PySequence_Size), Int, (PyPtr,), o)

function splice!(a::PyObject, i::Integer)
    v = a[i]
    @pycheckz ccall((@pysym :PySequence_DelItem), Cint, (PyPtr, Int), a, i-1)
    v
end

pop!(a::PyObject) = splice!(a, length(a))
shift!(a::PyObject) = splice!(a, 1)

function empty!(a::PyObject)
    for i in length(a):-1:1
        @pycheckz ccall((@pysym :PySequence_DelItem), Cint, (PyPtr, Int), a, i-1)
    end
    a
end

# The following operations only work for the list type and subtypes thereof:
function push!(a::PyObject, item)
    @pycheckz ccall((@pysym :PyList_Append), Cint, (PyPtr, PyPtr),
                     a, PyObject(item))
    a
end

function insert!(a::PyObject, i::Integer, item)
    @pycheckz ccall((@pysym :PyList_Insert), Cint, (PyPtr, Int, PyPtr),
                     a, ind2py(i), PyObject(item))
    a
end

unshift!(a::PyObject, item) = insert!(a, 1, item)

function prepend!(a::PyObject, items)
    for (i,x) in enumerate(items)
        insert!(a, i, x)
    end
    a
end

function append!(a::PyObject, items)
    for item in items
        push!(a, item)
    end
    return a
end

#########################################################################
# support IPython _repr_foo functions for writemime of PyObjects

for (mime, method) in ((MIME"text/html", "_repr_html_"),
                       (MIME"image/jpeg", "_repr_jpeg_"),
                       (MIME"image/png", "_repr_png_"),
                       (MIME"image/svg+xml", "_repr_svg_"),
                       (MIME"text/latex", "_repr_latex_"))
    T = istextmime(mime()) ? AbstractString : Vector{UInt8}
    @eval begin
        function writemime(io::IO, mime::$mime, o::PyObject)
            if o.o != C_NULL && haskey(o, $method)
                r = pycall(o[$method], PyObject)
                r.o != pynothing && return write(io, convert($T, r))
            end
            throw(MethodError(writemime, (io, mime, o)))
        end
        mimewritable(::$mime, o::PyObject) =
            o.o != C_NULL && haskey(o, $method) && let meth = o[$method]
                meth.o != pynothing &&
                pycall(meth, PyObject).o != pynothing
            end
    end
end

#########################################################################

const Py_single_input = 256  # from Python.h
const Py_file_input = 257
const Py_eval_input = 258

const pyeval_fname = bytestring("PyCall.jl") # filename for pyeval

# evaluate a python string, returning PyObject, given a dictionary
# (string/symbol => value) of local variables to use in the expression
function pyeval_(s::AbstractString, locals::PyDict, input_type)
    sb = bytestring(s) # use temp var to prevent gc before we are done with o
    sigatomic_begin()
    try
        o = PyObject(@pycheckn ccall((@pysym :Py_CompileString), PyPtr,
                                     (Cstring, Cstring, Cint),
                                     sb, pyeval_fname, input_type))
        main = @pycheckn ccall((@pysym :PyImport_AddModule),
                                PyPtr, (Cstring,), "__main__")
        maindict = @pycheckn ccall((@pysym :PyModule_GetDict), PyPtr,
                                    (PyPtr,), main)
        return PyObject(@pycheckn ccall((@pysym :PyEval_EvalCode),
                                         PyPtr, (PyPtr, PyPtr, PyPtr),
                                         o, maindict, locals))
    finally
        sigatomic_end()
    end
end

"""
    pyeval(s::AbstractString, returntype::TypeTuple=PyAny, locals=PyDict{AbstractString, PyObject}(),
                                input_type=Py_eval_input; kwargs...)

This evaluates `s` as a Python string and returns the result converted to `rtype` (which defaults to `PyAny`). The remaining arguments are keywords that define local variables to be used in the expression.

For example, `pyeval("x + y", x=1, y=2)` returns 3.
"""
function pyeval(s::AbstractString, returntype::TypeTuple=PyAny,
                locals=PyDict{AbstractString, PyObject}(),
                input_type=Py_eval_input; kwargs...)
    for (k, v) in kwargs
        locals[string(k)] = v
    end
    return convert(returntype, pyeval_(s, locals, input_type))
end

#########################################################################
# Precompilation: just an optimization to speed up initialization.
# Here, we precompile functions that are passed to cfunction by __init__,
# for the reasons described in JuliaLang/julia#12256.

precompile(jl_Function_call, (PyPtr,PyPtr,PyPtr))
precompile(pyjlwrap_dealloc, (PyPtr,))
precompile(pyjlwrap_repr, (PyPtr,))
precompile(pyjlwrap_hash, (PyPtr,))
precompile(pyjlwrap_hash32, (PyPtr,))

# TODO: precompilation of the io.jl functions

end # module PyCall
