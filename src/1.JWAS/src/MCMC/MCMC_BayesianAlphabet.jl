################################################################################
#MCMC for RR-BLUP, GBLUP, BayesABC, and conventional (no markers) methods
#
#GBLUP: pseudo markers are used.
#y = μ + a + e with mean(a)=0,var(a)=Gσ²=MM'σ² and G = LDL' <==>
#y = μ + Lα +e with mean(α)=0,var(α)=D*σ² : L orthogonal
#y2hat = cov(a2,a)*inv(var(a))*L*αhat =>
#      = (M2*M')*inv(MM')*L*αhat = (M2*M')*(L(1./D)L')(Lαhat)=(M2*M'*L(1./D))αhat
#
#Threshold trait:
#1)Sorensen and Gianola, Likelihood, Bayesian, and MCMC Methods in Quantitative
#Genetics
#2)Wang et al.(2013). Bayesian methods for estimating GEBVs of threshold traits.
#Heredity, 110(3), 213–219.
################################################################################
function MCMC_BayesianAlphabet(mme,df)
    ############################################################################
    chain_length             = mme.MCMCinfo.chain_length
    burnin                   = mme.MCMCinfo.burnin
    output_samples_frequency = mme.MCMCinfo.output_samples_frequency
    output_samples_file      = mme.MCMCinfo.output_samples_file
    estimate_variance        = mme.MCMCinfo.estimate_variance
    Rinv                     = mme.invweights
    update_priors_frequency  = mme.MCMCinfo.update_priors_frequency
    categorical_trait        = mme.MCMCinfo.categorical_trait
    missing_phenotypes       = mme.MCMCinfo.missing_phenotypes
    constraint               = mme.MCMCinfo.constraint
    causal_structure         = mme.causal_structure
    is_multi_trait           = mme.nModels != 1
    ############################################################################
    # Categorical Traits (starting values for maker effects defaulting to 0s)
    ############################################################################
    if categorical_trait == true
        category_obs,threshold = categorical_trait_setup!(mme)
    end
    ############################################################################
    # Working Variables
    # 1) samples at current iteration (starting values default to zeros)
    # 2) posterior mean and variance at current iteration (zeros at the beginning)
    # 3) ycorr: phenotypes corrected for all effects
    ############################################################################
    #location parameters
    #mme.sol (its starting values were set in runMCMC)
    mme.solMean, mme.solMean2  = zero(mme.sol),zero(mme.sol)
    #residual variance
    if categorical_trait == true
        mme.R  = mme.meanVare = mme.meanVare2 = 1.0
    else
        mme.meanVare  = zero(mme.R)
        mme.meanVare2 = zero(mme.R)
    end
    #polygenic effects (pedigree), e.g, Animal+ Maternal
    if mme.pedTrmVec != 0
       mme.G0Mean,mme.G0Mean2  = zero(mme.Gi),zero(mme.Gi)
    end
    #marker effects
    if mme.M != 0
        for Mi in mme.M
            #Mi.α  (starting values were set in get_genotypes)
            mGibbs    = GibbsMats(Mi.genotypes,Rinv)
            Mi.mArray,Mi.mRinvArray,Mi.mpRinvm  = mGibbs.xArray,mGibbs.xRinvArray,mGibbs.xpRinvx

            if Mi.method=="BayesB" #α=β.*δ
                Mi.G        = fill(Mi.G,Mi.nMarkers) #a scalar in BayesC but a vector in BayeB
                if is_multi_trait
                    Mi.nLoci = zeros(Mi.ntraits)
                end
            end
            if Mi.method=="BayesL"         #in the MTBayesLasso paper
                if mme.nModels == 1
                    Mi.G   /= 8           #mme.M.G is the scale Matrix, Sigma
                    Mi.scale /= 8
                    gammaDist  = Gamma(1, 8) #8 is the scale parameter of the Gamma distribution (1/8 is the rate parameter)
                else
                    Mi.G         /= 4*(Mi.ntraits+1)
                    Mi.scale     /= 4*(Mi.ntraits+1)
                    gammaDist     = Gamma((Mi.ntraits+1)/2, 8) #8 (1/8): the scale (rate) parameter
                end
                Mi.gammaArray = rand(gammaDist,Mi.nMarkers)
            end
            if Mi.method=="GBLUP"
                GBLUP_setup(Mi)
            end
            Mi.β                  = [copy(Mi.α[traiti]) for traiti = 1:Mi.ntraits] #partial marker effeccts used in BayesB
            Mi.δ                  = [ones(typeof(Mi.α[traiti][1]),Mi.nMarkers) for traiti = 1:Mi.ntraits] #inclusion indicator for marker effects
            Mi.meanAlpha          = [zero(Mi.α[traiti]) for traiti = 1:Mi.ntraits] #marker effects
            Mi.meanAlpha2         = [zero(Mi.α[traiti]) for traiti = 1:Mi.ntraits] #marker effects
            Mi.meanDelta          = [zero(Mi.δ[traiti]) for traiti = 1:Mi.ntraits] #inclusion indicator for marker effects
            Mi.meanVara           = zero(mme.R)  #posterir mean of variance for marker effect
            Mi.meanVara2          = zero(mme.R)  #variable to save variance for marker effect
            Mi.meanScaleVara      = zero(mme.R) #variable to save Scale parameter for prior of marker effect variance
            Mi.meanScaleVara2     = zero(mme.R)  #variable to save Scale parameter for prior of marker effect variance
            if !is_multi_trait
                Mi.mean_pi,Mi.mean_pi2 = 0.0,0.0                #inclusion probability
            else
                Mi.π,Mi.mean_pi,Mi.mean_pi2 = copy(Mi.π),copy(Mi.π),copy(Mi.π)
                if Mi.estimatePi == true
                  for key in keys(Mi.mean_pi)
                    Mi.mean_pi[key]=0.0
                    Mi.mean_pi2[key]=0.0
                  end
                end
                #if methods == "BayesCC"  labels,BigPi,BigPiMean=setPi(Pi)  end
            end
        end
    end
    #phenotypes corrected for all effects
    ycorr = vec(Matrix(mme.ySparse)-mme.X*mme.sol)
    if mme.M != 0
        for Mi in mme.M
            for traiti in 1:mme.nModels
                if Mi.α[traiti] != zero(Mi.α[traiti])
                    ycorr[(traiti-1)*Mi.nObs+1 : traiti*Mi.nObs] = ycorr[(traiti-1)*Mi.nObs+1 : traiti*Mi.nObs]
                                                                 - Mi.genotypes*Mi.α[traiti]
                end
            end
        end
    end
    ############################################################################
    #More on Multi-Trait
    ############################################################################
    if is_multi_trait
        wArray = Array{Union{Array{Float64,1},Array{Float32,1}}}(undef,mme.nModels)
        for traiti = 1:mme.nModels
            startPosi             = (traiti-1)*length(mme.obsID)  + 1
            ptr                   = pointer(ycorr,startPosi)
            wArray[traiti]        = unsafe_wrap(Array,ptr,length(mme.obsID))
        end

        #Starting value for Ri is made based on missing value pattern
        #(imputed phenotypes will not used to compute first mmeRhs)
        Ri         = mkRi(mme,df,mme.invweights)
    end
    ############################################################################
    # Starting values for SEM
    ############################################################################
    if causal_structure != false
        Y,Λy,causal_structure_outfile = SEM_setup(wArray,causal_structure,mme)
    end

    ############################################################################
    #  SET UP OUTPUT MCMC samples
    ############################################################################
    if output_samples_frequency != 0
        outfile=output_MCMC_samples_setup(mme,chain_length-burnin,
                                          output_samples_frequency,
                                          output_samples_file)
    end
    ############################################################################
    # MCMC (starting values for sol (zeros);  mme.RNew; G0 are used)
    ############################################################################
    @showprogress "running MCMC ..." for iter=1:chain_length
        ########################################################################
        # 0. Categorical traits (liabilities)
        ########################################################################
        if categorical_trait == true
            ycorr = categorical_trait_sample_liabilities(mme,ycorr,category_obs,threshold)
        end
        ########################################################################
        # 1. Non-Marker Location Parameters
        ########################################################################
        # 1.1 Update Left-hand-side of MME
        if is_multi_trait
            mme.mmeLhs =  mme.X'Ri* mme.X #normal equation, Ri is changed
        end
        addVinv(mme)
        # 1.2 Update Right-hand-side of MME
        if is_multi_trait
            if mme.MCMCinfo.missing_phenotypes==true
              ycorr[:]=sampleMissingResiduals(mme,ycorr)
            end
        end
        ycorr[:] = ycorr + mme.X*mme.sol
        if is_multi_trait
            mme.mmeRhs =  mme.X'Ri*ycorr
        else
            mme.mmeRhs = (Rinv == false) ? mme.X'ycorr : mme.X'Diagonal(Rinv)*ycorr
        end
        # 1.3 Gibbs sampler
        if is_multi_trait
            Gibbs(mme.mmeLhs,mme.sol,mme.mmeRhs)
        else
            Gibbs(mme.mmeLhs,mme.sol,mme.mmeRhs,mme.R)
        end
        ycorr[:] = ycorr - mme.X*mme.sol
        ########################################################################
        # 2. Marker Effects
        ########################################################################
        if mme.M !=0
            for Mi in mme.M
                ########################################################################
                # Marker Effects
                ########################################################################
                if Mi.method in ["BayesC","BayesB","BayesA"]
                    locus_effect_variances = (Mi.method == "BayesC" ? fill(Mi.G,Mi.nMarkers) : Mi.G)
                    if is_multi_trait
                        MTBayesABC!(Mi,wArray,mme.R,locus_effect_variances)
                    else
                        BayesABC!(Mi,ycorr,mme.R,locus_effect_variances)
                    end
                elseif Mi.method =="RR-BLUP"
                    if is_multi_trait
                        MTBayesC0!(Mi,wArray,mme.R)
                    else
                        BayesC0!(Mi,ycorr,mme.R)
                    end
                elseif Mi.method == "BayesL"
                    if is_multi_trait
                        MTBayesL!(Mi,wArray,mme.R)
                    else
                        BayesL!(Mi,ycorr,mme.R)
                    end
                elseif Mi.method == "GBLUP"
                    if is_multi_trait
                        MTGBLUP!(Mi,wArray,ycorr,mme.R,Rinv)
                    else
                        GBLUP!(Mi,ycorr,mme.R,Rinv)
                    end
                end
                ########################################################################
                # Marker Inclusion Probability
                ########################################################################
                if Mi.estimatePi == true
                    if is_multi_trait
                        samplePi(Mi.δ,Mi.π) #samplePi(deltaArray,Mi.π,labels)
                    else
                        Mi.π = samplePi(Mi.nLoci, Mi.nMarkers)
                    end
                end
                ########################################################################
                # Marker Effects Variance XXXXXXX???????
                ########################################################################
                if Mi.estimateVariance == true #methd specific estimate_variance
                    sample_marker_effect_variance(Mi)
                end
                ########################################################################
                # Scale Parameter in Priors for Marker Effect Variances
                ########################################################################
                if Mi.estimateScale == true
                    if !is_multi_trait
                        a = size(Mi.G,1)*Mi.df/2   + 1
                        b = sum(Mi.df ./ (2*Mi.G)) + 1
                        Mi.scale = rand(Gamma(a,1/b))
                    end
                end
            end
        end
        ########################################################################
        # 3. Non-marker Variance Components
        ########################################################################
        if estimate_variance == true
            ########################################################################
            # 3.1 Variance of Non-marker Random Effects
            # e.g, iid; polygenic effects (pedigree)
            ########################################################################
            sampleVCs(mme,mme.sol)
            ########################################################################
            # 3.2 Residual Variance
            ########################################################################
            if is_multi_trait
                sample_variance(mme,ycorr,Rinv,constraint=constraint)
                Ri = kron(inv(mme.R),spdiagm(0=>Rinv))
            else
                if categorical_trait == false
                    mme.ROld = mme.R
                    mme.R    = sample_variance(ycorr.* (Rinv!=false ? sqrt.(Rinv) : 1.0),
                                               length(ycorr), mme.df.residual, mme.scaleRes)
                end
            end
        end
        ########################################################################
        # 4. Causal Relationships among Phenotypes (Structure Equation Model)
        ########################################################################
        if is_multi_trait && causal_structure != false
            sample4λ = get_Λ(Y,mme.R,ycorr,Λy,mme.ySparse,causal_structure) #no missing phenotypes
        end
        ########################################################################
        # 5. Update priors using posteriors (empirical) LATER
        ########################################################################
        if update_priors_frequency !=0 && iter%update_priors_frequency==0
            if mme.M!=0 && methods != "BayesB"
                if is_multi_trait
                    mme.M.scale = meanVara*(mme.df.marker-ntraits-1)
                else
                    mme.M.scale   = meanVara*(mme.df.marker-2)/mme.df.marker
                end
            end
            if mme.pedTrmVec != 0
                mme.scalePed  = mme.G0Mean*(mme.df.polygenic - size(mme.pedTrmVec,1) - 1)
            end
            mme.scaleRes  =  mme.meanVare*(mme.df.residual-2)/mme.df.residual
            println("\n Update priors from posteriors.")
        end
        ########################################################################
        # 3.1 Save MCMC samples
        ########################################################################
        if iter>burnin && (iter-burnin)%output_samples_frequency == 0
            #MCMC samples from posterior distributions
            nsamples       = (iter-burnin)/output_samples_frequency
            output_posterior_mean_variance(mme,nsamples)
            #mean and variance of posterior distribution
            output_MCMC_samples(mme,mme.sol,mme.R,(mme.pedTrmVec!=0 ? inv(mme.Gi) : false),outfile)
            if causal_structure != false
                writedlm(causal_structure_outfile,sample4λ',',')
            end
        end
        ########################################################################
        # 3.2 Printout
        ########################################################################
        if iter%mme.MCMCinfo.printout_frequency==0 && iter>burnin
            println("\nPosterior means at iteration: ",iter)
            println("Residual variance: ",round.(mme.meanVare,digits=6))
        end
    end

    ############################################################################
    # After MCMC
    ############################################################################
    if output_samples_frequency != 0
      for (key,value) in outfile
        close(value)
      end
      if causal_structure != false
        close(causal_structure_outfile)
      end
    end
    if methods == "GBLUP"
        for Mi in mme.M
            mv(output_samples_file*"_marker_effects_variances"*"_"*Mi.name*".txt",
               output_samples_file*"_genetic_variance(REML)"*"_"*Mi.name*".txt")
        end
    end
    output=output_result(mme,output_samples_file,
                         mme.solMean,mme.meanVare,
                         mme.pedTrmVec!=0 ? mme.G0Mean : false,
                         mme.solMean2,mme.meanVare2,
                         mme.pedTrmVec!=0 ? mme.G0Mean2 : false)
    return output
end
