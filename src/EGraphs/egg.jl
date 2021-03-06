# Functional implementation of https://egraphs-good.github.io/
# https://dl.acm.org/doi/10.1145/3434304

using DataStructures
using StaticArrays

"""
Abstract type representing an [`EGraph`](@ref) analysis,
attaching values from a join semi-lattice domain to
an EGraph
"""
abstract type AbstractAnalysis end

const ClassMem = Dict{Int64, AbstractVector{Any}}
const HashCons = Dict{Any,Int64}
const Parent = Tuple{Any,Int64} # parent enodes and eclasses
const ParentMem = Dict{Int64,AbstractVector{Parent}}
const AnalysisData = Dict{Int64,Any}
const Analyses = Vector{AbstractAnalysis}

"""
A concrete type representing an [`EGraph`].
See the [egg paper](https://dl.acm.org/doi/pdf/10.1145/3434304)
for implementation details
"""
mutable struct EGraph
    """stores the equality relations over e-class ids"""
    U::IntDisjointSets
    """map from eclass id to eclasses"""
    M::ClassMem             #
    H::HashCons             # hashcons
    parents::ParentMem
    """worklist for ammortized upwards merging"""
    dirty::Vector{Int64}
    root::Int64
    """A vector of analyses associated to the EGraph"""
    analyses::Analyses
end

EGraph() = EGraph(
    IntDisjointSets(0),
    ClassMem(),
    HashCons(),
    ParentMem(),
    Vector{Int64}(),
    0,
    Analyses(),
)

function EGraph(e)
    G = EGraph()
    rootclass = addexpr!(G, e)
    G.root = rootclass.id
    G
end

function addparent!(G::EGraph, a::Int64, parent::Parent)
    @assert isenode(parent[1])
    if !haskey(G.parents, a)
        G.parents[a] = SA[parent]
    else
        G.parents[a] = G.parents[a] ∪ SA[parent]
    end
end

"""
Inserts an e-node in an [`EGraph`](@ref)
"""
function add!(G::EGraph, n)::EClass
    @debug("adding ", n)
    canonicalize!(G.U, n)
    if haskey(G.H, n)
        return find(G, G.H[n]) |> EClass
    end
    @debug(n, " not found in H")
    id = push!(G.U) # create new singleton eclass
    !haskey(G.parents, id) && (G.parents[id] = SA[])
    getfunargs(n) .|> x -> addparent!(G, x.id, (n, id))

    G.H[n] = id
    G.M[id] = SA[n]

    # make analyses for new enode
    for analysis ∈ G.analyses
        if !islazy(analysis)
            analysis[id] = make(analysis, n)
            modify!(analysis, id)
        end
    end

    return EClass(id)
end
add!(g::EGraph, c::EClass)::EClass = EClass(find(g, c))

"""
Recursively traverse an [`Expr`](@ref) and insert terms into an
[`EGraph`](@ref). If `e` is not an [`Expr`](@ref), then directly
insert the literal into the [`EGraph`](@ref).
"""
function addexpr!(G::EGraph, e)::EClass
    e = cleanast(e)
    df_walk((x -> add!(G, x)), e; skip_call = true)
end

function mergeparents!(G::EGraph, from::Int64, to::Int64)
    !haskey(G.parents, from) && (G.parents[from] = SA[]; return)
    !haskey(G.parents, to) && (G.parents[to] = SA[])

    G.parents[to] = G.parents[to] ∪ G.parents[from]
    delete!(G.parents, from)
end


"""
Given an [`EGraph`](@ref) and two e-class ids, set
the two e-classes as equal.
"""
function Base.merge!(G::EGraph, a::Int64, b::Int64)::Int64
    id_a = find(G, a)
    id_b = find(G, b)
    id_a == id_b && return id_a
    id_u = union!(G.U, id_a, id_b)

    @debug "merging" id_a id_b

    from, to = if (id_u == id_a)
        id_b, id_a
    elseif (id_u == id_b)
        id_a, id_b
    else
        error("egraph invariant maintenance error")
    end

    push!(G.dirty, id_u)

    clean(t) = begin
        delete!(G.H, t)
        canonicalize!(G.U, t)
        G.H[t] = to
        t
    end

    G.M[from] = map(clean, G.M[from])
    G.M[to] = map(clean, G.M[to])
    G.M[to] = G.M[from] ∪ G.M[to]

    if from == G.root
        G.root = to
    end

    delete!(G.M, from)
    mergeparents!(G, from, to)
    for analysis ∈ G.analyses
        if haskey(analysis, from) && haskey(analysis, to)
            analysis[to] = join(analysis, analysis[from], analysis[to])
            delete!(analysis, from)
        end
    end

    return id_u
end

"""
Returns the canonical e-class id for a given e-class.
"""
find(G::EGraph, a::Int64)::Int64 = find_root!(G.U, a)
find(G::EGraph, a::EClass)::Int64 = find_root!(G.U, a.id)

"""
This function restores invariants and executes
upwards merging in an [`EGraph`](@ref). See
the [egg paper](https://dl.acm.org/doi/pdf/10.1145/3434304)
for more details.
"""
function rebuild!(G::EGraph)
    while !isempty(G.dirty)
        todo = unique([find(G, id) for id ∈ G.dirty])
        empty!(G.dirty)
        foreach(todo) do x
            repair!(G, x)
        end
    end

    if G.root != 0
        G.root = find(G, G.root)
    end
end

function repair!(G::EGraph, id::Int64)
    id = find(G, id)
    @debug "repairing " id

    for (p_enode, p_eclass) ∈ G.parents[id]
        #old_id = G.H[p_enode]
        #delete!(G.M, old_id)
        delete!(G.H, p_enode)
        @debug "deleted from H " p_enode
        n = canonicalize(G.U, p_enode)
        n_id = find(G, p_eclass)
        G.H[n] = n_id
    end

    new_parents = OrderedDict{Any,Int64}()

    for (p_enode, p_eclass) ∈ G.parents[id]
        canonicalize!(G.U, p_enode)
        # deduplicate parents
        if haskey(new_parents, p_enode)
            @debug "merging classes" p_eclass (new_parents[p_enode])
            merge!(G, p_eclass, new_parents[p_enode])
        end
        new_parents[p_enode] = find(G, p_eclass)
    end
    G.parents[id] = collect(new_parents) .|> Tuple
    @debug "updated parents " id G.parents[id]


    # Analysis invariant maintenance
    for an ∈ G.analyses
        haskey(an, id) && modify!(an, id)
        # modify!(an, id)
        id = find(G, id)
        for (p_enode, p_eclass) ∈ G.parents[id]
            # p_eclass = find(G, p_eclass)
            if !islazy(an) && !haskey(an, p_eclass)
                an[p_eclass] = make(an, p_enode)
            end
            if haskey(an, p_eclass)
                new_data = join(an, an[p_eclass], make(an, p_enode))
                if new_data != an[p_eclass]
                    an[p_eclass] = new_data
                    push!(G.dirty, p_eclass)
                end
            end
        end
    end
end


# TODO iterative version
"""
Recursive function that traverses an [`EGraph`](@ref) and
returns a vector of all reachable e-classes from a given e-class id.
"""
function reachable(g::EGraph, id::Int64; hist=Int64[])
    id = find(g, id)
    hist = hist ∪ [id]
    for n ∈ g.M[id]
        if n isa Expr
            for child_eclass ∈ getfunargs(n)
                c_id = child_eclass.id
                if c_id ∉ hist
                    hist = hist ∪ reachable(g, c_id; hist=hist)
                end
            end
        end
    end

    return hist
end
