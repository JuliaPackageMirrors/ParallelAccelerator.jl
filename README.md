# ParallelAccelerator

[![Build Status](https://magnum.travis-ci.com/IntelLabs/ParallelAccelerator.jl.svg?token=149Z9PxxcSTNz1n9bRpz&branch=master)](https://magnum.travis-ci.com/IntelLabs/ParallelAccelerator.jl)

This is the ParallelAccelerator Julia package, part of the High
Performance Scripting project at Intel Labs. 

## Prerequisites

  * **Julia v0.4.0.** If you don't have it yet, there are various ways
    to install Julia:
      * Go to http://julialang.org/downloads/ and download the
        appropriate version listed under "Current Release".
      * On Ubuntu or Debian variants, `sudo add-apt-repository
        ppa:staticfloat/juliareleases -y && sudo apt-get update -q &&
        sudo apt-get install julia -y` should work.
      * On OS X with Homebrew, `brew update && brew tap
        staticfloat/julia && brew install julia` should work.
    Check that you can run Julia and get to a `julia>` prompt.  You
    will know you're running the correct version if when you run it,
    you see `Version 0.4.0`.
  * **Either `gcc`/`g++` or `icc`/`icpc`.** We recommend GCC 4.8.4 or
    later and ICC 15.0.3 or later.  At package build time,
    ParallelAccelerator will check to see if you have ICC installed.
    If so, ParallelAccelerator will use it.  Otherwise, it will use
    GCC.
  * Platforms we have tested on so far include Ubuntu 14.04 and CentOS
    6.6 with both GCC and ICC.  We have limited support for OS X.

## Installation

At the `julia>` prompt, run these commands:

``` .julia
Pkg.clone("https://github.com/IntelLabs/CompilerTools.jl.git")        # Install the CompilerTools package on which this package depends.
Pkg.clone("https://github.com/IntelLabs/ParallelAccelerator.jl.git")  # Install this package.
Pkg.build("ParallelAccelerator")                                      # Build the C++ runtime component of the package.
Pkg.test("CompilerTools")                                             # Run CompilerTools tests.
Pkg.test("ParallelAccelerator")                                       # Run ParallelAccelerator tests.
```
 
If all of the above succeeded, you should be ready to use
ParallelAccelerator.

## Examples

The `examples/` subdirectory has a few example programs demonstrating
how to use ParallelAccelerator. You can run them at the command line.
For instance:

``` .bash
$ julia examples/laplace-3d/laplace-3d.jl
Run laplace-3d with size 300x300x300 for 100 iterations.
SELFPRIMED 18.663935711
SELFTIMED 1.527286803
checksum: 0.49989778
```

The `SELFTIMED` line in the printed output shows the running time,
while the `SELFPRIMED` line shows the time it takes to compile the
accelerated code and run it with a small "warm-up" input.

Pass the `--help` option to see usage information for each example:

``` .bash
$ julia examples/laplace-3d/laplace-3d.jl -- --help
laplace-3d.jl

Laplace 6-point 3D stencil.

Usage:
  laplace-3d.jl -h | --help
  laplace-3d.jl [--size=<size>] [--iterations=<iterations>]

Options:
  -h --help                  Show this screen.
  --size=<size>              Specify a 3d array size (<size> x <size> x <size>); defaults to 300.
  --iterations=<iterations>  Specify a number of iterations; defaults to 100.
```

You can also run the examples at the `julia>` prompt:

```
julia> include("examples/laplace-3d/laplace-3d.jl")
Run laplace-3d with size 300x300x300 for 100 iterations.
SELFPRIMED 18.612651534
SELFTIMED 1.355707121
checksum: 0.49989778
```

Some of the examples require additional Julia packages.  The top-level
`REQUIRE` file in this repository lists all registered packages that
examples depend on.

## Basic Usage

To start using ParallelAccelerator in you own program, first import the 
package by `using ParallelAccelerator`, and then put `@acc` macro before
the function you want to accelerate. A trivial example is given below:

``` .julia
julia> using ParallelAccelerator

julia> @acc f(x) = x .+ x .* x
f (generic function with 1 method)

julia> f([1,2,3,4,5])
5-element Array{Int64,1}:
  2
  6
 12
 20
 30
```

You can also use `@acc begin ... end`, and put multiple functions in the block
to have all of them accelerated. The `@acc` macro only works for top-level 
definitions.

## How It Works

ParallelAccelerator is essentially a domain-specific compiler written in Julia
that discovers and exploits the implicit parallelism in source programs that
use parallel programming patterns such as *map, reduction, comprehension, and
stencil*. For example, Julia array operators such as `.+, .-, .*, ./` are
translated by ParallelAccelerator internally into a *map* operation over all
elements of input arrays.  For the most part, these patterns are already
present in standard Julia, so programmers can use ParallelAccelerator to run
the same Julia program without (significantly) modifying its source code. 

The `@acc` macro provided by ParallelAccelerator first intercepts Julia
functions at macro level, and substitute the set of implicitly parallel
operations that we are targeting, and point them to those supplied in the
`ParallelAccelerator.API` module. It then creates a proxy function that when
called with concrete arguments (and known types) will try to compile the
original function to an optimized form. So the first time calling an
accelerated function would incur some compilation time, but all subsequent
calls to the same function will not.

ParallelAccelerator performs aggressive optimizations when it is safe to do so.
For example, it automatically infers equivalence relation among array
variables, and will fuse adjacent parallel loops into a single loop. Eventually
all parallel patterns are lowered into explicit parallel `for` loops internally
represented at the level of Julia's typed AST. 

Finally, functions with parallel for loops are translated into a C program with
OpenMP pragmas, and ParallelAccelerator will use an external C/C++ compiler to
compile it into binary form before loading it back into Julia as a dynamic
library for execution. This step of translating Julia to C currently imposes
certain constraints (see details below), and therefore we can only run user
programs that meet such constraints. 

## Advanced Usage

As mentioned above, ParallelAccelerator aims to optimize implicitly parallel
Julia programs that are safe to parallelize. It also tries to be non-invasive, 
which means a user function or program should continue to work as expected
even when only a part of it is accelerated. It is still important to know what
exactly are accelerated and what are not, however, and we encourage user to
write program using high-level array operations that are amenable to domain
specific analysis and optimizations, rather than writing explicit for-loops 
with unrestricted mutations or unknown side-effects. 


### Array Operations

Array operations that work uniformly on each elements and produce an output
array of equal size are called `point-wise` operations (and for binary
operations in Julia, they usually come with a `.` as a prefix to the operator).
They are translated into an internal `map` operation by ParallelAccelerator.
The following are recognized by `@acc` as `map` operation:

* Unary functions: 
```
-, +, acos, acosh, angle, asin, asinh, atan, atanh, cbrt,
cis, cos, cosh, exp10, exp2, exp, expm1, lgamma,
log10, log1p, log2, log, sin, sinh, sqrt, tan, tanh, 
abs, copy, erf:
```

* Binary functions:
```
-, +, .+, .-, .*, ./, .\, .%, .>, .<, .<=, .>=, .==, .<<, 
.>>, .^, div, mod, rem, &, |, $
```

Array assignment are also being recognized and converted into `in-place map`
operation.  Expressions like `a = a .+ b` will be turned into an `in-place map`
that takes two inputs arrays, `a` and `b`, and updates `a` in-place. 

Array operations that computes a single result by repeating an associative
and commutative operator among all input array elements is called `reduce`.
The follow are recognized by `@acc` as `reduce` operations: 

```
minimum, maximum, sum, prod, 
```

We also support range operations to a limited extent. So things like `a[r] =
b[r]` where `r` is either a `BitArray` or `UnitRange` like `1:s` are internally
converted into *inplace map* operations. However, such support is consider
experimental, and occasionally ParallelAccelerator will complain about not
being able to optimize them.

### Parallel Comprehension 

Array comprehensions in Julia are in general also parallelizable, because 
unlike general loops, their iteration variables have no inter-dependencies. 
So the `@acc` macro will turn them into an internal form that we call
`cartesianarray`:

```
A = Type[ f (x1, x2, ...) for x1 in r1, x2 in r2, ... ]
```
becomes
```
cartesianmap((i1,i2,...) -> begin x1 = r1[i1]; x2 = r2[i2]; f(x1,x2,...) end,
             Type,
             (length(r1), length(r2), ...))
```

This `cartesianarray` function is also exported by `ParallelAccelerator` and
can be directly used by the user. So the above two forms are equivalent 
in semantics, they both produce a N-dimentional (`N` being the number of `r`s,
and currently only up-to-3 dimensions are supported) array whose element is 
`Type`.


It should be noted, however, not all comprehensions are safe to parallelize,
for example, if the function `f` above reads and writes to an environment
variable, then making it run in parallel would produce non-deterministic
result. So please avoid using `@acc` should such situations arise.

### Stencil

Commonly found in image processing and scientific computing, a stencil
computation is one that computes new values for all elements of an array based
on the current values of their neighboring elements. Since Julia's base library
does not provide such an API, so ParallelAccelerator exports a general
`runStencil` interface to help with stencil programming:

```
runStencil(kernel :: Function, buffer1, buffer2, ..., 
           iteration :: Int, boundaryHandling :: Symbol)
```

As an example, the following (taken from Gausian Blur example) computes a
5x5 stencil computation (note the use of Julia's `do` syntax that lets
user write a lambda function):

```
runStencil(buf, img, iterations, :oob_skip) do b, a
       b[0,0] =
            (a[-2,-2] * 0.003  + a[-1,-2] * 0.0133 + a[0,-2] * 0.0219 + a[1,-2] * 0.0133 + a[2,-2] * 0.0030 +
             a[-2,-1] * 0.0133 + a[-1,-1] * 0.0596 + a[0,-1] * 0.0983 + a[1,-1] * 0.0596 + a[2,-1] * 0.0133 +
             a[-2, 0] * 0.0219 + a[-1, 0] * 0.0983 + a[0, 0] * 0.1621 + a[1, 0] * 0.0983 + a[2, 0] * 0.0219 +
             a[-2, 1] * 0.0133 + a[-1, 1] * 0.0596 + a[0, 1] * 0.0983 + a[1, 1] * 0.0596 + a[2, 1] * 0.0133 +
             a[-2, 2] * 0.003  + a[-1, 2] * 0.0133 + a[0, 2] * 0.0219 + a[1, 2] * 0.0133 + a[2, 2] * 0.0030)
       return a, b
    end
```

It take two input arrays, `buf` and `img`, and performs an iterative stencil
loop (ISL) of given `iterations`. The stencil kernel is specified by a lambda
function that takes two arrays `a` and `b` (that corresponds to `buf` and
`img`), and computes the value of the output buffer using relative indices
as if a cursor is traversing all array elements, where `[0,0]` represents
the current cursor position. The `return` statement in this lambda reverses
the position of `a` and `b` to specify a buffer rotation that should happen
in-between the stencil iterations. The use of `runStencil` will assume
all input and output buffers are of the same dimension and size.

Stencil boundary handling can be specified as one of the following symbols:

* `:oob_skip`. Writing to output is skipped when input indexing is out-of-bound.
* `:oob_wraparound`. Input indexing is `wrapped-around` at the image boundary, so they are always safe.
* `:oob_dst_zero`. Writing 0 to output buffer when any of the input indexing is out-of-bound.
* `:oob_src_zero`. Assume 0 is being returned from an input read when indexing is out-of-bound.

Just like parallel comprehension, accessing environment variables are allowed
in a stencil body. However, accessing array values in the environment is
not supported, and reading/writing the same environment variable will cause
non-determinism. Since `runStencil` do not impose a fixed buffer rotation
order, all arrays that need to be relatively indexed can be specified as
input buffers (just don't rotate them), and there can be mulitple
output buffers too.

### Faster compilation via userimg.jl

It is possible to embed a binary/compiled version of the ParallelAccelerator compiler and CompilerTools
into a Julia executable.  This has the potential to greatly reduce the time it takes for our compiler
to accelerate a given program.  To use this feature, start the Julia REPL and do the following:

importall ParallelAccelerator
ParallelAccelerator.embed()

This version of embed() tries to embed ParallelAccelerator into the Julia version used by the current REPL.

If you want to target a different Julia distribution, you can alternatively use the following
version of embed.

ParallelAccelerator.embed("<your/path/to/the/root/of/the/julia/distribution>")

This "embed" function takes a path and is expected to point to the root directory of a Julia source
distribution.  embed performs some simple checks to try to verify this fact.  Then, embed will try to
create a file base/userimg.jl that will tell the Julia build how to embed the compiled version into
the Julia executable.  Then, embed runs make in the Julia root directory to create the embedded
Julia version.

If there is already a userimg.jl file in the base directory then a new file is created called
ParallelAccelerator_userimg.jl and it then becomes the user's responsibility to merge that with the
existing userimg.jl and run make if they want this faster compile time.

After the call to embed finishes and you try to exit the Julia REPL, you may receive an exception
like: ErrorException("ccall: could not find function git_libgit2_shutdown in library libgit2").
This error does not effect the embedding process but we are working towards a solution to this
minor issue.

## Limitations 

ParallelAccelerator relies heavily on full type information being avaiable
in Julia's typed AST in order to work properly. Although we do not require
user functions to be explicitly typed, it is in general a good practice to
ensure the function to accelerate at least passes Julia's type inference
without leaving any `Any` type or `Union` type dangling. The use of Julia-to-C
translation also mandates this requirement, and will give error messages
on not being able to handle `Any` type. So we encourage users to use Julia's
`code_typed(f, (...type signature...))` (after removing `@acc`) to double 
check the AST of a function when ParallelAccelerator` fails to optimize it.


## Comments, Suggestions, and Bug Reports



