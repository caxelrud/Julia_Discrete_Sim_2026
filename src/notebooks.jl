# =============================================================================
# notebooks.jl -- Pluto notebooks as deliverables: validation and headless runs.
#
# The notebooks are part of the product, so they are checked the way an executor
# checks them: every code cell must parse, must hold exactly one top-level
# expression (the rule Pluto itself enforces), must not reference a global that
# never got defined, and the notebook must write its printout and print its PDF.
# On top of the static check, `run_notebook` runs a notebook headless through
# Pluto itself, so a CI can prove that every notebook executes from a cold start.
# =============================================================================

"""Pluto's cell delimiter and the marker of its `Cell order` section."""
const PLUTO_CELL_MARKER = string("# ", Char(0x2554), Char(0x2550), Char(0x2561))
const PLUTO_ORDER_MARKER = string(PLUTO_CELL_MARKER, " Cell order:")
const PLUTO_ORDER_PREFIX = string("# ", Char(0x2560), Char(0x2550))

"""
    notebook_files(dir = "notebooks") -> Vector{String}

The notebook files of a repository, in reading order (numeric prefix first),
skipping Pluto's `backup` copies.
"""
function notebook_files(dir::AbstractString = "notebooks")
    isdir(dir) || return String[]
    files = sort(filter(f -> endswith(f, ".jl") && !occursin("backup", lowercase(f)) &&
                                occursin(r"^\d", f), readdir(dir)))
    return joinpath.(dir, files)
end

"""
    notebook_cells(path) -> (lines, Vector{(id, code)})

Read a Pluto notebook: its raw lines and its cells as `(cell id, code)` pairs.
"""
function notebook_cells(path::AbstractString)
    lines = readlines(path)
    cells = Tuple{String,String}[]
    current = nothing
    buffer = String[]
    for line in lines
        if startswith(line, PLUTO_ORDER_MARKER)
            current === nothing || push!(cells, (current, strip(join(buffer, "\n"))))
            current = nothing
            break
        elseif startswith(line, PLUTO_CELL_MARKER)
            current === nothing || push!(cells, (current, strip(join(buffer, "\n"))))
            current = strip(replace(line, PLUTO_CELL_MARKER => ""; count = 1))
            buffer = String[]
        elseif current !== nothing
            push!(buffer, line)
        end
    end
    current === nothing || push!(cells, (current, strip(join(buffer, "\n"))))
    return lines, cells
end

"""`true` when the cell body is a Markdown cell (`md"..."`)."""
is_markdown_cell(code::AbstractString) = startswith(code, "md\"\"\"")

"""Cell ids listed in the `Cell order` section of the file."""
function cell_order_section(lines::Vector{String})
    ids = String[]
    seen = false
    for line in lines
        if startswith(line, PLUTO_ORDER_MARKER)
            seen = true
            continue
        end
        seen || continue
        startswith(line, "# ") || continue
        id = strip(replace(replace(line, "# " => ""; count = 1), PLUTO_CELL_MARKER => "";
                count = 1), [Char(0x2560), Char(0x2554), Char(0x2550), Char(0x2561), ' '])
        isempty(id) || push!(ids, id)
    end
    return ids
end

## ---- static analysis of notebook cells -------------------------------------------

"""Name bound by a left-hand side pattern (`:none` when there is none)."""
function bound_name(x)
    x isa Symbol && return x
    x isa Expr || return :none
    n = length(x.args)
    x.head === :(::) && n >= 1 && return bound_name(x.args[1])
    x.head === :call && n >= 1 && return bound_name(x.args[1])
    x.head === :curly && n >= 1 && return bound_name(x.args[1])
    x.head === :where && n >= 1 && return bound_name(x.args[1])
    x.head === :ref && n >= 1 && return bound_name(x.args[1])
    x.head === :tuple && n >= 1 && return bound_name(x.args[1])
    x.head === :. && n >= 2 && return bound_name(x.args[2])
    x.head === :. && n == 1 && return bound_name(x.args[1])   # `using X` wraps X alone
    return :none
end

"""Record every name bound by a left-hand side pattern (tuple patterns included)."""
function bind_names(x, acc::Set{Symbol})
    if x isa Expr && x.head in (:tuple, :parameters)
        for a in x.args
            bind_names(a, acc)
        end
    else
        n = bound_name(x)
        n === :none || push!(acc, n)
    end
    return acc
end

"""Symbols bound by an expression (assignments, loops, imports, definitions)."""
function cell_bindings(expr, acc::Set{Symbol} = Set{Symbol}())
    expr isa Expr || return acc
    if expr.head in (:const, :global, :local) && length(expr.args) == 1
        return cell_bindings(expr.args[1], acc)
    elseif expr.head in (:(=), :(+=), :(-=))
        bind_names(expr.args[1], acc)
        return cell_bindings(expr.args[2], acc)
    elseif expr.head in (:function, :struct, :macro)
        push!(acc, bound_name(expr.args[1]))
    elseif expr.head in (:for, :let)
        for a in expr.args[1:(end - 1)]
            bind_names(a, acc)
        end
    elseif expr.head === :(->)
        ## an anonymous function binds its parameters in the body
        bind_names(expr.args[1], acc)
        return cell_bindings(expr.args[2], acc)
    elseif expr.head in (:import, :using)
        for a in expr.args
            push!(acc, bound_name(a))
        end
    elseif expr.head === :macrocall
        ## `@bind x element` binds `x` (that is what the macro expands to), so a
        ## later cell may refer to it without the validator complaining.
        name = expr.args[1]
        if length(expr.args) >= 3 && name isa Symbol &&
           String(name) in ("@bind", "@bind!")
            bind_names(expr.args[3], acc)
        end
    end
    for a in expr.args
        cell_bindings(a, acc)
    end
    return acc
end

"""Symbols referenced by an expression, ignoring field names and keyword keys."""
function cell_references(expr, acc::Set{Symbol} = Set{Symbol}())
    expr isa Symbol && (push!(acc, expr); return acc)
    expr isa Expr || return acc
    expr.head === :quote && return acc
    for (i, a) in enumerate(expr.args)
        if expr.head === :. && i == 2
            continue                              # field / property name
        elseif expr.head in (:kw, :(=)) && i == 1
            continue                              # keyword name or assignment target
        elseif expr.head === :macrocall && i == 1
            continue                              # macro name
        elseif expr.head === :(::) && i == 2 && a isa Symbol
            continue                              # type annotation
        elseif expr.head === :parameters && i == 1
            continue
        elseif expr.head === :(->) && i == 1
            continue                              # the parameters bind themselves
        elseif expr.head === :ref && a === :end
            continue                              # the `end` of an index
        end
        cell_references(a, acc)
    end
    return acc
end

"""
    known_notebook_names() -> Set{Symbol}

The global context a notebook may legitimately use: everything `Base`, `Core` and
the packages the notebooks load export, the conventional notebook variables
(`bundle`, `cfg`, `σ`, ...) and the names the Pluto header always brings in.
"""
function known_notebook_names()
    known = Set{Symbol}([:Pkg, :ROOT, :bundle, :study, :cfg, :σ, :h, :cal, :run, :exp,
        :res, :figs, :preview, :report, :counts, :session, :args, :io, :ans, :HTML, :html,
        :Markdown, :InteractiveUtils, :md, :md_str, :DiscreteSim, :PlutoUI, :Plots,
        :Statistics, :Random, :Printf, :Dates, :JSON3, :Distributions, :Tables,
        :TableOfContents, :Slider, :Select, :MultiSelect, :NumberField, :CheckBox,
        :Text, :TextField, :Button, :Label, :bond, :tooltip, :with_terminal])
    for m in (Base, Core, DiscreteSim, Statistics, Dates, Printf, Random)
        for n in names(m; all = true)
            push!(known, n)
        end
    end
    return known
end

"""
    validate_notebook(path; known = known_notebook_names()) -> NamedTuple

Check one notebook the way Pluto will run it: the header line, unique cell ids, a
cell order that lists every cell, every code cell parsing to exactly one top-level
expression and referring only to globals that are defined earlier (or are known
names), and at least one cell writing the printout.
"""
function validate_notebook(path::AbstractString; known::Set{Symbol} = known_notebook_names())
    lines, cells = notebook_cells(path)
    problems = String[]

    (isempty(lines) || lines[1] == "### A Pluto.jl notebook ###") ||
        push!(problems, "missing Pluto header line")

    ids = first.(cells)
    length(unique(ids)) == length(ids) || push!(problems, "duplicate cell ids")
    order = cell_order_section(lines)
    Set(order) == Set(ids) ||
        push!(problems, string("Cell order lists ", length(order), " ids for ",
            length(ids), " cells"))

    code_cells = [c for c in cells if !is_markdown_cell(last(c))]
    markdown_cells = [c for c in cells if is_markdown_cell(last(c))]
    printout_cells = 0
    defined = copy(known)

    for (id, code) in code_cells
        parsed = try
            Meta.parseall(code)
        catch err
            push!(problems, string("cell ", first(id, 8), " does not parse: ",
                sprint(showerror, err)))
            continue
        end
        if Meta.isexpr(parsed, :error)
            push!(problems, string("cell ", first(id, 8), " has a syntax error: ",
                first(replace(string(parsed.args[1]), "\n" => " "), 160)))
            continue
        end
        via_input_line = try
            Base.parse_input_line(code)
        catch err
            push!(problems, string("cell ", first(id, 8), " does not parse: ",
                sprint(showerror, err)))
            continue
        end
        if Meta.isexpr(via_input_line, :error)
            push!(problems, string("cell ", first(id, 8), " has a syntax error: ",
                first(replace(string(via_input_line.args[1]), "\n" => " "), 160)))
            continue
        elseif Meta.isexpr(via_input_line, :incomplete)
            push!(problems, string("cell ", first(id, 8), " is incomplete: ",
                first(replace(string(via_input_line.args[1]), "\n" => " "), 160)))
            continue
        elseif Meta.isexpr(via_input_line, :toplevel) &&
               count(a -> !(a isa LineNumberNode), via_input_line.args) > 1
            push!(problems, string("cell ", first(id, 8),
                " holds more than one top-level expression; wrap it in begin ... end"))
        end
        without = setdiff(cell_references(parsed), union(defined, cell_bindings(parsed)))
        isempty(without) || push!(problems, string("cell ", first(id, 8),
            " references undefined ", join(sort(string.(without)), ", ")))
        union!(defined, cell_bindings(parsed))
        occursin("print_section_pdf", code) && (printout_cells += 1)
    end

    printout_cells > 0 || push!(problems, "no cell writes the notebook printout/PDF")

    return (notebook = Sym(basename(path)), path = String(path), ok = isempty(problems),
        problems = problems, cells = length(cells), code_cells = length(code_cells),
        markdown_cells = length(markdown_cells), printout_cells = printout_cells)
end

"""
    validate_notebooks(dir = "notebooks") -> Vector{NamedTuple}

Validate every notebook of a repository.
"""
validate_notebooks(dir::AbstractString = "notebooks") =
    [validate_notebook(f) for f in notebook_files(dir)]

"""One line per notebook validation, with the first problems of the failures."""
function print_validation_report(results; io::IO = stdout)
    for r in results
        println(io, (r[:ok] ? "PASS  " : "FAIL  "), rpad(string(r[:notebook]), 32),
            lpad(string(r[:code_cells]), 3), " code cells ",
            lpad(string(r[:markdown_cells]), 3), " markdown")
        for p in r[:problems]
            println(io, "      ", p)
        end
    end
    ok = count(r -> r[:ok], results)
    println(io, "\n", ok, " / ", length(results), " notebooks valid")
    return io
end

"""`print_validation_report(io, results)`, for `sprint` and other IO-first callers."""
print_validation_report(io::IO, results) = print_validation_report(results; io = io)

## ---- running them headless -------------------------------------------------------

"""
    pluto_module()

`Pluto`, imported on first use so analysis-only sessions (and the test suite) do
not pay for loading the notebook server. The binding is fetched with
`invokelatest` because Julia 1.12 enforces world-age rules for globals defined at
runtime.
"""
function pluto_module()
    isdefined(@__MODULE__, :Pluto) || @eval import Pluto
    return Base.invokelatest(getfield, @__MODULE__, :Pluto)
end

"""
    run_notebook(path; passes = 2, save = true) -> NamedTuple

Run one notebook headless in Pluto and report the outcome. Each pass runs every
cell; the notebook passes when no cell reports an error. Two passes are allowed
because the first one may have to install the package into the notebook
environment before `using DiscreteSim` can succeed.
"""
function run_notebook(path::AbstractString; passes::Int = 2, save::Bool = true)
    pluto = pluto_module()
    t0 = time()
    report = Base.invokelatest(run_notebook_impl, pluto, String(path), passes, save)
    report[:seconds] = round(time() - t0, digits = 1)
    return report
end

"""Body of [`run_notebook`](@ref); called through `invokelatest` exactly once."""
function run_notebook_impl(pluto, path::String, passes::Int, save::Bool)
    session = pluto.ServerSession()
    nb = pluto.SessionActions.open(session, path; run_async = false)
    errors = Any[]
    for _ in 1:passes
        pluto.update_save_run!(session, nb, nb.cells; run_async = false, save = save)
        errors = [(i, c.output.body) for (i, c) in enumerate(nb.cells) if c.errored]
        isempty(errors) && break
    end
    save && pluto.save_notebook(nb)
    return Dict{Symbol,Any}(
        :notebook => Sym(basename(path)), :path => path, :ok => isempty(errors),
        :cells => length(nb.cells),
        :code_cells => count(c -> !isempty(strip(c.code)), nb.cells),
        :errors => errors, :seconds => 0.0)
end

"""
    print_notebook_report(result; io = stdout)

One line per notebook run, with the first lines of every cell error.
"""
function print_notebook_report(r::Dict{Symbol,Any}; io::IO = stdout)
    println(io, (r[:ok] ? "PASS  " : "FAIL  "), rpad(string(r[:notebook]), 28),
        lpad(string(r[:code_cells]), 3), " code cells ", lpad(string(r[:seconds]), 7), " s")
    for (i, msg) in r[:errors]
        println(io, "      cell ", i, " -> ", first(replace(string(msg), "\n" => " "), 400))
    end
    return io
end

"""Run every notebook of a repository headless and print a one-line report each."""
function run_notebooks(dir::AbstractString = "notebooks"; only = nothing, kwargs...)
    files = notebook_files(dir)
    only === nothing ||
        (files = [f for f in files if any(s -> startswith(basename(f), String(s)), only)])
    reports = Dict{Symbol,Any}[]
    for f in files
        push!(reports, run_notebook(f; kwargs...))
        print_notebook_report(reports[end])
    end
    return reports
end