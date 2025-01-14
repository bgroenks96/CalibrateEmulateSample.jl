# Script to run Emulation and Sampling on data from GCM

# Import modules
using Distributions  # probability distributions and associated functions
using LinearAlgebra
using Plots
using Random
using JLD2
# CES 
using CalibrateEmulateSample.Emulators
using CalibrateEmulateSample.MarkovChainMonteCarlo
using CalibrateEmulateSample.ParameterDistributions
using CalibrateEmulateSample.DataContainers

@time begin

    rng_seed = 2413798
    Random.seed!(rng_seed)

    #    expname = "vrf-nondiag-logdet_newprior"
    #emulator_type ∈ ["GPR","ScalarRFR","VectorRFR-svd-diag","VectorRFR-svd-nondiag", "VectorRFR-nondiag"]
    #    emulator_type = "GPR"
    #    expname = "gpr"

    #    emulator_type = "ScalarRFR"
    #    expname = "srf"

    #    emulator_type = "VectorRFR-svd-diag"
    #    expname = "vrf-svd-diag"

    #    emulator_type = "VectorRFR-svd-nondiag"
    #    expname = "vrf-svd-nondiag"

    emulator_type = "VectorRFR-nondiag"
    expname = "vrf-nondiag_standardized"

    # Output figure save directory
    example_directory = @__DIR__
    println(example_directory)
    figure_save_directory = joinpath(example_directory, "output")
    data_save_directory = joinpath(example_directory, "output")
    if !isdir(figure_save_directory)
        mkdir(figure_save_directory)
    end
    if !isdir(data_save_directory)
        mkdir(data_save_directory)
    end

    # Load data from file
    datafile = "data_from_eki_inflateyonly_100.jld2"
    inputs = load(datafile)["inputs"] #100 x 2 x 10
    outputs = load(datafile)["outputs"] #100 x 96 x 10
    truth = load(datafile)["truth"] # 96
    obs_noise_cov = load(datafile)["obs_noise_cov"] # 96 x 96

    #take only first 400 points
    iter_mask = 1:4
    #data_mask = 1:32
    #    data_mask= 33:64
    #    data_mask= 65:96
    data_mask = 1:96
    #data_mask = [5*i for i = 1:Int(floor(96/5))]

    inputs = inputs[:, :, iter_mask]
    outputs = outputs[:, data_mask, iter_mask]
    obs_noise_cov = obs_noise_cov[data_mask, data_mask]
    truth = truth[data_mask]

    # priorfile = "priors.jld2"
    # prior = load(priorfile)["prior"]

    # derived quantities
    N_ens, input_dim, N_iter = size(inputs)
    output_dim = size(outputs, 2)

    stacked_inputs = reshape(permutedims(inputs, (1, 3, 2)), (N_ens * N_iter, input_dim))
    stacked_outputs = reshape(permutedims(outputs, (1, 3, 2)), (N_ens * N_iter, output_dim))
    input_output_pairs = PairedDataContainer(stacked_inputs, stacked_outputs, data_are_columns = false) #data are rows
    normalized = true

    # setup random features
    eki_options_override = Dict("tikhonov" => 0, "multithread" => "ensemble") #faster than tullio multithread for training


    if emulator_type == "VectorRFR-svd-nondiag" || emulator_type == "VectorRFR-nondiag"
        if emulator_type == "VectorRFR-svd-nondiag"
            println("Running Vector RF model - using SVD and assuming non-diagonal variance ")
        elseif emulator_type == "VectorRFR-nondiag"
            println("Running Vector RF model - without SVD and assuming non-diagonal variance ")
        end

        n_features = 80 * Int(floor(5 * sqrt(N_ens * N_iter)))
        println("build RF with $(N_ens*N_iter) training points and $(n_features) random features.")


        mlt = VectorRandomFeatureInterface(n_features, input_dim, output_dim, optimizer_options = eki_options_override)

    elseif emulator_type == "VectorRFR-svd-diag"

        println("Running Vector RF model - using SVD and assuming diagonal variance")
        n_features = 20 * Int(floor(5 * sqrt(N_ens * N_iter)))
        println("build RF with $(N_ens*N_iter) training points and $(n_features) random features.")

        mlt = VectorRandomFeatureInterface(
            n_features,
            input_dim,
            output_dim,
            diagonalize_output = true,
            optimizer_options = eki_options_override,
        )

    elseif emulator_type == "ScalarRFR"
        println("Running Scalar RF model")
        n_features = 5 * Int(floor(5 * sqrt(N_ens * N_iter)))
        mlt = ScalarRandomFeatureInterface(n_features, input_dim, optimizer_options = eki_options_override)

    else
        emulator_type == "GPR"
        println("Running Gaussian Process model")
        gppackage = SKLJL()
        mlt = GaussianProcess(gppackage, noise_learn = false)

    end

    if emulator_type == "VectorRFR-nondiag"
        #standardizing with data median for each data object seems reasonable in this setting.
        standards = vec(
            hcat(
                median(stacked_outputs[:, 1:32], dims = 1),
                median(stacked_outputs[:, 33:64], dims = 1),
                median(stacked_outputs[:, 65:96], dims = 1),
            ),
        )
        println(standards)
        emulator = Emulator(
            mlt,
            input_output_pairs;
            obs_noise_cov = obs_noise_cov,
            normalize_inputs = normalized,
            standardize_outputs = true,
            standardize_outputs_factors = standards,
            decorrelate = false,
        )
    else
        emulator = Emulator(mlt, input_output_pairs; obs_noise_cov = obs_noise_cov, normalize_inputs = normalized)

    end
    optimize_hyperparameters!(emulator)

    #
    # save the emulator!
    # 
    @save joinpath(data_save_directory, "emulator_" * expname * ".jld2") emulator

    #
    # predict at some validation points
    #
    validate_id = ["phys", "mean", "rand"]

    for vid in validate_id
        if vid == "phys"
            new_input = [log(0.7 / 0.3) log(7200)]' # physical parameter value (at truth)
        elseif vid == "mean"
            new_input = [log(0.5 / (1 - 0.5)) log(43200)]' # mean-of-prior parameter value ("near-ish" truth)
        elseif vid == "rand"
            new_input = [log(0.31735951644387783 / (1 - 0.31735951644387783)) log(90632.50269636544)]' # random parameter value ("far" from truth
        end

        pred_mean, pred_cov = predict(emulator, new_input, transform_to_real = true)
        pred_sd = sqrt.([max(10 * eps(), pred_cov[1][i, i]) for i in 1:size(pred_cov[1], 1)])


        # NB pred_cov is a vector of matrices
        tobj = load("truthobj_" * vid * "param.jld2")["truthobj"]
        t_mean = tobj.mean[data_mask]
        t_cov = tobj.cov[data_mask, data_mask]

        println("prediction error at truth for " * vid * " case:")
        println("    mean: ", norm(t_mean - pred_mean))
        println("     cov: ", norm(t_cov - pred_cov[1]))

        save(
            joinpath(data_save_directory, vid * "_" * expname * "_results.jld2"),
            "pred_mean",
            pred_mean,
            "pred_cov",
            pred_cov,
            "pred_sd",
            pred_sd,
        )
        save(joinpath(data_save_directory, vid * "_" * expname * "_truth.jld2"), "true_mean", t_mean, "true_cov", t_cov)
    end

    plot_input = [log(0.7 / 0.3) log(7200)]' # physical parameter value (at truth)
    plot_mean, plot_cov = predict(emulator, plot_input, transform_to_real = true)
    plot_sd = sqrt.([max(10 * eps(), plot_cov[1][i, i]) for i in 1:size(plot_cov[1], 1)])


    ids = [1:32, 33:64, 65:96]
    plotnames = ["rh", "pr", "ext"]

    for (id, pn) in zip(ids, plotnames)
        if data_mask == 1:96
            plt = plot(
                collect(id),
                plot_mean[id],
                show = true,
                ribbon = [2 * plot_sd[id]; 2 * plot_sd[id]],
                linewidth = 5,
                size = (600, 600),
                label = "",
            )
            figpath = joinpath(figure_save_directory, "predict_" * expname * "_" * pn * "_at_truth.png")
            savefig(figpath)
            println("plot saved at " * figpath)
        else
            if data_mask == id
                plot_mask = 1:length(data_mask)
                plt = plot(
                    collect(id),
                    plot_mean[plot_mask],
                    show = true,
                    ribbon = [2 * plot_sd[plot_mask]; 2 * plot_sd[plot_mask]],
                    linewidth = 5,
                    size = (600, 600),
                    label = "",
                )
                figpath = joinpath(figure_save_directory, "predict_" * expname * "_" * pn * "_at_truth.png")
                savefig(figpath)
                println("plot saved at " * figpath)
            end
        end

    end



end # for @time
