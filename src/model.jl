using LinearAlgebra
using Suppressor

export get_de, get_abc, inverse_order_of_dynare_decision_rule

function inverse_order_of_dynare_decision_rule(m::Model)
    inverse_order_var = Vector{Int64}(undef, m.endogenous_nbr)
    for i = 1:m.n_static
        inverse_order_var[m.i_static[i]] = i
    end

    offset = m.n_static
    for i = 1:m.n_bkwrd
        inverse_order_var[m.i_bkwrd[i]] = i + offset
    end

    offset += m.n_bkwrd
    for i = 1:m.n_both
        inverse_order_var[m.i_both[i]] = i + offset
    end

    offset += m.n_both
    for i = 1:m.n_fwrd
        inverse_order_var[m.i_fwrd[i]] = i + offset
    end

    inverse_order_states = sortperm(cat(m.i_bkwrd,m.i_both;dims=1))

    (inverse_order_var, inverse_order_states)
end

function load_dynare_function(modname::String, compileoption::Bool)::Module
    if compileoption
        fun = readlines(modname*".jl")
        return(eval(Meta.parse(join(fun, "\n"))))
    else
        push!(LOAD_PATH, dirname(modname))
        name = basename(modname)
        eval(Meta.parse("using "*name))
        pop!(LOAD_PATH)
        return(eval(Symbol(name)))
    end
end

function get_initial_dynamic_endogenous_variables!(y::AbstractVector{Float64},
                                                   data::AbstractVector{Float64},
                                                   initialvalues::AbstractVector{Float64},
                                                   lli::Matrix{Int64},
                                                   period::Int64)
    m, n = size(lli)
    p = (period - 2)*n
    for j = 1:n
        k = lli[1, j]
        if k > 0
            y[k] = initialvalues[p + j]
        end
    end
    @inbounds for i = 2:m
        for j = 1:n
            k = lli[i, j]
            if k > 0
                y[k] = data[p + j]
            end
        end
        p += n
    end
end

function get_terminal_dynamic_endogenous_variables!(y::AbstractVector{Float64},
                                                    data::AbstractVector{Float64},
                                                    terminalvalues::AbstractVector{Float64},
                                                    lli::Matrix{Int64},
                                                    period::Int64)
    m, n = size(lli)
    p = (period - 2)*n
    @inbounds for i = 1:m-1
        for j = 1:n
            k = lli[i, j]
            if k > 0
                y[k] = data[p + j]
            end
        end
        p += n
    end
    for j = 1:n
        k = lli[m, j]
        if k > 0
            y[k] = terminalvalues[j]
        end
    end
end

function get_dynamic_endogenous_variables!(y::AbstractVector{Float64},
                                           data::AbstractVector{Float64},
                                           lli::Matrix{Int64},
                                           period::Int64)
    m, n = size(lli)
    p = (period - 2)*n
    @inbounds for i = 1:m
        for j = 1:n
            k = lli[i, j]
            if k > 0
                y[k] = data[p + j]
            end
        end
        p += n
    end
end


"""
get_dynamic_endogenous_variables!(y::Vector{Float64}, data::Vector{Float64}, lli::Matrix{Int64})

sets the vector of dynamic variables ``y``, evaluated at the same values 
for all leads and lags and taken in ``data`` vector 
"""
function get_dynamic_endogenous_variables!(y::Vector{Float64}, data::AbstractVector{Float64}, lli::Matrix{Int64})
    for i = 1:size(lli,2)
        value = data[i]
        for j = 1:size(lli,1)
            k = lli[j, i]
            if k > 0
                y[k] = value
            end
        end
    end
end

"""
get_dynamic_endogenous_variables!(y::Vector{Float64}, data::Matrix{Float64}, lli::Matrix{Int64}, m::Model, period::Int64)

sets the vector of dynamic variables ``y`` with values in as many rows of ``data`` matrix
as there are leads and lags in the model. ``period`` is the current period.
"""
function get_dynamic_endogenous_variables!(y::Vector{Float64}, data::AbstractMatrix{Float64}, lli::Matrix{Int64}, m::Model, period::Int64)
    for i = 1:size(lli,2)
        p = period - m.maximum_lag - 1
        for j = 1:size(lli,1)
            k = lli[j, i]
            if k > 0
                y[k] = data[p + j, i]
            end
        end
    end
end

"""
get_dynamic_endogenous_variables!(y::Vector{Float64}, data::Vector{Float64}, lli::Matrix{Int64}, m::Model, period::Int64)

sets the vector of dynamic variables ``y`` with values in as many rows of ``data`` matrix
as there are leads and lags in the model. ``period`` is the current period.
"""
function get_dynamic_endogenous_variables!(y::Vector{Float64}, data::AbstractVector{Float64}, lli::Matrix{Int64}, m::Model, period::Int64)
    n = m.endogenous_nbr
    p = (period - m.maximum_lag - 1)*n
    for j = 1:size(lli,1)
        for i = 1:n
            k = lli[j, i]
            if k > 0
                y[k] = data[p + i]
            end
        end
        p += n
    end
end

struct DynamicJacobianWs
    dynamic_variables::Vector{Float64}
    jacobian::Matrix{Float64}
    exogenous_variables::Vector{Float64}
    residuals::Vector{Float64}
    temporary_values::Vector{Float64}
    function DynamicJacobianWs(endogenous_nbr::Int64,
                              exogenous_nbr::Int64,
                              dynamic_nbr::Int64,
                              tmp_nbr::Int64)
        dynamic_variables = Vector{Float64}(undef, dynamic_nbr)
        jacobian = Matrix{Float64}(undef, endogenous_nbr, dynamic_nbr + exogenous_nbr)
        exogenous_variables = Vector{Float64}(undef, exogenous_nbr)
        residuals = Vector{Float64}(undef, endogenous_nbr)
        temporary_values = Vector{Float64}(undef, tmp_nbr)
        new(dynamic_variables, jacobian, exogenous_variables, residuals, temporary_values)
    end
end

function DynamicJacobianWs(context::Context)
    m = context.models[1]
    dynamic_nbr = m.n_bkwrd + m.n_current + m.n_fwrd + 2*m.n_both
    tmp_nbr = sum(m.dynamic!.tmp_nbr[1:2])
    return DynamicJacobianWs(m.endogenous_nbr, m.exogenous_nbr,
                            dynamic_nbr, tmp_nbr)
end

struct StaticJacobianWs
    jacobian::Matrix{Float64}
    residuals::Vector{Float64}
    temporary_values::Vector{Float64}
    function StaticJacobianWs(endogenous_nbr::Int64,
                              tmp_nbr::Int64)
        jacobian = Matrix{Float64}(undef, endogenous_nbr, endogenous_nbr)
        residuals = Vector{Float64}(undef, endogenous_nbr)
        temporary_values = Vector{Float64}(undef, tmp_nbr)
        new(jacobian, residuals, temporary_values)
    end
end

function StaticJacobianWs(context::Context)
    m = context.models[1]
    tmp_nbr = sum(m.static!.tmp_nbr[1:2])
    return StaticJacobianWs(m.endogenous_nbr, tmp_nbr)
end

function get_exogenous_matrix(x::Vector{Float64}, exogenous_nbr::Int64)
    @debug "any(isnan.(x))=$(any(isnan.(x))) "
    x1 =  reshape(x, Int(length(x)/exogenous_nbr), exogenous_nbr)
    @debug "any(isnan.(x1))=$(any(isnan.(x1))) "
    return x1
end

"""
get_dynamic_jacobian!(ws::DynamicJacobianWs, params::Vector{Float64}, endogenous::AbstractVector{Float64}, exogenous::Vector{Float64}, m::Model, period::Int64)

sets the dynamic Jacobian matrix ``work.jacobian``, evaluated at ``endogenous`` and ``exogenous`` values, identical for all leads and lags
"""
function get_dynamic_jacobian!(ws::DynamicJacobianWs, params::Vector{Float64}, endogenous::AbstractVector{Float64}, exogenous::AbstractVector{Float64},
                       steadystate::Vector{Float64}, m::Model, period::Int64)
    lli = m.lead_lag_incidence
    get_dynamic_endogenous_variables!(ws.dynamic_variables, endogenous, lli)
    lx = length(ws.exogenous_variables)
    nrx = period + m.maximum_exo_lead
    required_lx = nrx*m.exogenous_nbr
    if lx < required_lx
        resize!(ws.exogenous_variables, required_lx)
        lx = required_lx
    end
    @debug "any(isnan.(ws.exognoues_variables))=$(any(isnan.(ws.exogenous_variables)))"
    x = get_exogenous_matrix(ws.exogenous_variables, m.exogenous_nbr)
    x .= transpose(exogenous)
    fill!(ws.jacobian, 0.0)
    Base.invokelatest(m.dynamic!.dynamic!,
                      ws.temporary_values,
                      ws.residuals,
                      ws.jacobian,
                      ws.dynamic_variables,
                      x,
                      params,
                      steadystate,
                      period)  
end

function get_initial_jacobian!(ws::DynamicJacobianWs, params::Vector{Float64}, endogenous::AbstractVector{Float64},
                       initialvalues::AbstractVector{Float64}, exogenous::AbstractMatrix{Float64},
                       steadystate::Vector{Float64}, m::Model, period::Int64)
    lli = m.lead_lag_incidence
    get_initial_dynamic_endogenous_variables!(ws.dynamic_variables, endogenous, initialvalues, lli, period)
 #   x = get_exogenous_matrix(ws.exogenous_variables, m.exogenous_nbr)
    fill!(ws.jacobian, 0.0)
    Base.invokelatest(m.dynamic!.dynamic!,
                      ws.temporary_values,
                      ws.residuals,
                      ws.jacobian,
                      ws.dynamic_variables,
                      exogenous,
                      params,
                      steadystate,
                      period)  
end

function get_terminal_jacobian!(ws::DynamicJacobianWs, params::Vector{Float64}, endogenous::AbstractVector{Float64},
                                terminalvalues::AbstractVector{Float64}, exogenous::AbstractMatrix{Float64},
                                steadystate::Vector{Float64}, m::Model, period::Int64)
    lli = m.lead_lag_incidence
    get_terminal_dynamic_endogenous_variables!(ws.dynamic_variables, endogenous, terminalvalues, lli, period)
#    x = get_exogenous_matrix(ws.exogenous_variables, m.exogenous_nbr)
    fill!(ws.jacobian, 0.0)
    Base.invokelatest(m.dynamic!.dynamic!,
                      ws.temporary_values,
                      ws.residuals,
                      ws.jacobian,
                      ws.dynamic_variables,
                      exogenous,
                      params,
                      steadystate,
                      period)  
end

"""
get_dynamic_jacobian!(ws::Work, endogenous::Matrix{Float64}, exogenous::Matrix{Float64}, m::Model, period::Int64)

sets the dynamic Jacobian matrix ``ws.jacobian``, evaluated with ``endogenous`` and ``exogenous`` values taken
around ``period`` 
"""
function get_dynamic_jacobian!(ws::DynamicJacobianWs, params::Vector{Float64}, endogenous::AbstractVecOrMat{Float64}, exogenous::Matrix{Float64}, steadystate::Vector{Float64}, m::Model, period::Int64)
    lli = m.lead_lag_incidence
    get_dynamic_endogenous_variables!(ws.dynamic_variables, endogenous, lli, m, period)
#    x = get_exogenous_matrix(ws.exogenous_variables, m.exogenous_nbr)
    Base.invokelatest(m.dynamic!.dynamic!,
                      ws.temporary_values,
                      ws.residuals,
                      ws.jacobian,
                      ws.dynamic_variables,
                      exogenous,
                      params,
                      steadystate,
                      period)
end

"""
get_static_jacobian!(ws::StaticJacobianWs, params::Vector{Float64}, endogenous::AbstractVector{Float64}, exogenous::Vector{Float64})

sets the static Jacobian matrix ``work.jacobian``, evaluated at ``endogenous`` and ``exogenous`` values
"""
function get_static_jacobian!(ws::StaticJacobianWs,
                              params::Vector{Float64},
                              endogenous::AbstractVector{Float64},
                              exogenous::AbstractVector{Float64})
    @debug "any(isnan.(exognous))=$(any(isnan.(exogenous)))"
    fill!(ws.jacobian, 0.0)
    Base.invokelatest(context.models[1].static!.static!,
                      ws.temporary_values,
                      ws.residuals,
                      ws.jacobian,
                      endogenous,
                      exogenous,
                      params)
end

function get_abc!(a::AbstractMatrix{Float64},
                  b::AbstractMatrix{Float64},
                  c::AbstractMatrix{Float64},
                  jacobian::AbstractMatrix{Float64},
                  m::Model)
    i_rows = (m.n_static + 1):m.endogenous_nbr
    fill!(a, 0.0)
    fill!(b, 0.0)
    fill!(c, 0.0)
    ws.a[:, ws.forward_indices_d] .= view(jacobian, i_rows, ws.backward_nbr .+ ws.current_nbr .+ (1:ws.forward_nbr))
    ws.b[:, ws.current_dynamic_indices_d] .= view(jacobian, i_rows, ws.backward_nbr .+ ws.current_dynamic_indices)
    ws.c[:, ws.backward_indices_d] .= view(jacobian, i_rows, 1:ws.backward_nbr)
end

function get_de!(ws::LinearRationalExpectationsWs, jacobian::AbstractMatrix{Float64})
    n1 = ws.backward_nbr + ws.forward_nbr - ws.both_nbr
    fill!(ws.d, 0.0)
    fill!(ws.e, 0.0)
    i_rows = (ws.static_nbr + 1):ws.endogenous_nbr
    ws.d[1:n1, ws.icolsD] .= jacobian[i_rows, ws.jcolsD]
    ws.e[1:n1, ws.icolsE] .= -jacobian[i_rows, ws.jcolsE]
    u = Matrix{Float64}(I, ws.both_nbr, ws.both_nbr)                                    
    i_rows = n1 .+ (1:ws.both_nbr)
    ws.d[i_rows, ws.colsUD] .= u
    ws.e[i_rows, ws.colsUE] .= u
end



