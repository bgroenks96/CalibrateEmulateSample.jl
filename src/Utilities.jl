module Utilities

using DocStringExtensions
using LinearAlgebra
using Statistics
using StatsBase
using Random
using ..Observations
using ..EnsembleKalmanProcesses
EnsembleKalmanProcess = EnsembleKalmanProcesses.EnsembleKalmanProcess
using ..DataContainers

export get_training_points
export get_obs_sample
export orig2zscore
export zscore2orig
export posdef_correct
"""
$(DocStringExtensions.TYPEDSIGNATURES)

Extract the training points needed to train the Gaussian process regression.

- `ekp` - EnsembleKalmanProcess holding the parameters and the data that were produced
  during the Ensemble Kalman (EK) process.
- `train_iterations` - Number (or indices) EK layers/iterations to train on.

"""
function get_training_points(
    ekp::EnsembleKalmanProcess{FT, IT, P},
    train_iterations::Union{IT, AbstractVector{IT}},
) where {FT, IT, P}

    if !isa(train_iterations, AbstractVector)
        # Note u[end] does not have an equivalent g
        iter_range = (get_N_iterations(ekp) - train_iterations + 1):get_N_iterations(ekp)
    else
        iter_range = train_iterations
    end

    u_tp = []
    g_tp = []
    for i in iter_range
        push!(u_tp, get_u(ekp, i)) #N_parameters x N_ens
        push!(g_tp, get_g(ekp, i)) #N_data x N_ens
    end
    u_tp = hcat(u_tp...) # N_parameters x (N_ek_it x N_ensemble)]
    g_tp = hcat(g_tp...) # N_data x (N_ek_it x N_ensemble)

    training_points = PairedDataContainer(u_tp, g_tp, data_are_columns = true)

    return training_points
end


"""
$(DocStringExtensions.TYPEDSIGNATURES)

Return a random sample from the observations, for use in the MCMC.

 - `rng` - optional RNG object used to pick random sample; defaults to `Random.GLOBAL_RNG`.
 - `obs` - Observation struct with the observations (extract will pick one
           of the sample observations to train).
 - `rng_seed` - optional kwarg; if provided, used to re-seed `rng` before sampling.
"""
function get_obs_sample(
    rng::Random.AbstractRNG,
    obs::Observation;
    rng_seed::Union{IT, Nothing} = nothing,
) where {IT <: Int}
    # Ensuring reproducibility of the sampled parameter values: 
    # re-seed the rng *only* if we're given a seed
    if rng_seed !== nothing
        rng = Random.seed!(rng, rng_seed)
    end
    row_idxs = StatsBase.sample(rng, axes(obs.samples, 1), 1; replace = false, ordered = false)
    return obs.samples[row_idxs...]
end
# first arg optional; defaults to GLOBAL_RNG (as in Random, StatsBase)
get_obs_sample(obs::Observation; kwargs...) = get_obs_sample(Random.GLOBAL_RNG, obs; kwargs...)

function orig2zscore(X::AbstractVector{FT}, mean::AbstractVector{FT}, std::AbstractVector{FT}) where {FT}
    # Compute the z scores of a vector X using the given mean
    # and std
    Z = zeros(size(X))
    for i in 1:length(X)
        Z[i] = (X[i] - mean[i]) / std[i]
    end
    return Z
end

function orig2zscore(X::AbstractMatrix{FT}, mean::AbstractVector{FT}, std::AbstractVector{FT}) where {FT}
    # Compute the z scores of matrix X using the given mean and
    # std. Transformation is applied column-wise.
    Z = zeros(size(X))
    n_cols = size(X)[2]
    for i in 1:n_cols
        Z[:, i] = (X[:, i] .- mean[i]) ./ std[i]
    end
    return Z
end

function zscore2orig(Z::AbstractVector{FT}, mean::AbstractVector{FT}, std::AbstractVector{FT}) where {FT}
    # Transform X (a vector of z scores) back to the original
    # values
    X = zeros(size(Z))
    for i in 1:length(X)
        X[i] = Z[i] .* std[i] .+ mean[i]
    end
    return X
end

function zscore2orig(Z::AbstractMatrix{FT}, mean::AbstractVector{FT}, std::AbstractVector{FT}) where {FT}
    X = zeros(size(Z))
    # Transform X (a matrix of z scores) back to the original
    # values. Transformation is applied column-wise.
    n_cols = size(Z)[2]
    for i in 1:n_cols
        X[:, i] = Z[:, i] .* std[i] .+ mean[i]
    end
    return X
end


"""
$(DocStringExtensions.TYPEDSIGNATURES)

Makes square matrix `mat` positive definite, by symmetrizing and bounding the minimum eigenvalue below by `tol`
"""
function posdef_correct(mat::AbstractMatrix; tol::Real = 1e8 * eps())
    if !issymmetric(mat)
        out = 0.5 * (mat + permutedims(mat, (2, 1))) #symmetrize
        if isposdef(out)
            # very often, small numerical errors cause asymmetry, so cheaper to add this branch
            return out
        end
    else
        out = mat
    end

    nugget = abs(minimum(eigvals(out)))
    for i in 1:size(out, 1)
        out[i, i] += nugget + tol #add to diag
    end
    return out
end




end # module
