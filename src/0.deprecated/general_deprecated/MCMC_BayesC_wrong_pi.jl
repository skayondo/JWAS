function MCMC_BayesC(nIter,mme,df,Pi;
                      sol=false,outFreq=100,thin=100,
                      output_files="marker_effects")

    if size(mme.mmeRhs)==()
       getMME(mme,df)
    end

    if sol == false
       sol=zeros(size(mme.mmeLhs,1))
    end #starting value for sol can be provided

    p = size(mme.mmeLhs,1)
    solMean = fill(0.0,p)

    #priors for residual covariance matrix
    ν       = 4
    nObs    = size(df,1)
    ntraits = size(mme.lhsVec,1)
    νR0     = ν + ntraits
    R0      = mme.R
    PRes    = R0*(νR0 - ntraits - 1)
    SRes    = zeros(Float64,ntraits,ntraits)
    R0Mean  = zeros(Float64,ntraits,ntraits)

    #priors for genetic variance matrix
    if mme.ped != 0
        ν         = 4
        pedTrmVec = mme.pedTrmVec
        k         = size(pedTrmVec,1)
        νG0       = ν + k
        G0        = inv(mme.Gi)
        P         = G0*(νG0 - k - 1)
        S         = zeros(Float64,k,k)
        G0Mean    = zeros(Float64,k,k)
    end

    #priors for marker covaraince matrix
    nObs,nMarkers  = size(mme.M.genotypes)

    if mme.M != 0
        dfEffectVar = 4.0

        mGibbs  = GibbsMats(mme.M.genotypes)
        nObs    = mGibbs.nrows
        nMarkers= mGibbs.ncols
        mArray  = mGibbs.xArray
        mpm     = mGibbs.xpx
        M       = mGibbs.X

        #makre marker effect variance considering π
        mme.M.G = make_valpha(mme.M.G,Pi;option="sqrt")
        vEff    = mme.M.G #already converted to marker effect variance
        νGM     = dfEffectVar + ntraits
        PM      = vEff*(νGM - ntraits - 1)
        SM      = zeros(Float64,ntraits,ntraits)
        GMMean  = zeros(Float64,ntraits,ntraits)
    end

    #starting values for marker effects are all zeros
    #starting values for other location parameters are sol

    ycorr          = vec(full(mme.ySparse))
    wArray         = Array(Array{Float64,1},ntraits)
    alphaArray     = Array(Array{Float64,1},ntraits)
    meanAlphaArray = Array(Array{Float64,1},ntraits)
    deltaArray     = Array(Array{Float64,1},ntraits)
    meanDeltaArray = Array(Array{Float64,1},ntraits)
    uArray         = Array(Array{Float64,1},ntraits)
    meanuArray     = Array(Array{Float64,1},ntraits)

    for traiti = 1:ntraits
        startPosi              = (traiti-1)*nObs  + 1
        ptr                    = pointer(ycorr,startPosi)
        wArray[traiti]         = pointer_to_array(ptr,nObs) #ycorr for different traits
                                                            #wArray is list version reference of ycor
        alphaArray[traiti]     = zeros(nMarkers)
        meanAlphaArray[traiti] = zeros(nMarkers)
        deltaArray[traiti]     = zeros(nMarkers)
        meanDeltaArray[traiti] = zeros(nMarkers)
        uArray[traiti]         = zeros(nMarkers)
        meanuArray[traiti]     = zeros(nMarkers)
    end

    logPi = [log(Pi);log(1-Pi)]

    outfile = Array{IOStream}(ntraits)
    for traiti in 1:ntraits
      outfile[traiti]=open(output_files*"_"*string(mme.lhsVec[traiti])*"_$(now()).txt","w")
    end

    if mme.M.markerID[1]!="NA"
      for traiti in 1:ntraits
        writedlm(outfile[traiti],mme.M.markerID')
      end
    end


    for iter=1:nIter
        #####################################
        #sample non-marker location parameter
        #####################################
        Gibbs(mme.mmeLhs,sol,mme.mmeRhs)
        ycorr[:] = ycorr[:] - mme.X*sol

        #####################################
        #sample marker effects
        #####################################
        iR0 = inv(mme.R)
        iGM = inv(mme.M.G)
        #sampleMarkerEffects!(mArray,mpm,wArray,alphaArray,meanAlphaArray,iR0,iGM,iter)
        sampleMarkerEffectsBayesC!(mArray,mpm,wArray,
                                   alphaArray,meanAlphaArray,
                                   deltaArray,meanDeltaArray,
                                   uArray,meanuArray,
                                   iR0,iGM,iter,logPi)

        #####################################
        #sample residual covariance matrix
        #AND marker covariance matrix
        #####################################
        resVec = ycorr
        #sampleMissingResiduals(mme,resVec)

        for traiti = 1:ntraits
            startPosi = (traiti-1)*nObs + 1
            endPosi   = startPosi + nObs - 1
            for traitj = traiti:ntraits
                startPosj = (traitj-1)*nObs + 1
                endPosj   = startPosj + nObs - 1
                SRes[traiti,traitj] = (resVec[startPosi:endPosi]'resVec[startPosj:endPosj])[1,1]
                SRes[traitj,traiti] = SRes[traiti,traitj]
                SM[traiti,traitj]   = (alphaArray[traiti]'alphaArray[traitj])[1]
                #  SM[traiti,traitj]   = (uArray[traiti]'uArray[traitj])[1]
                SM[traitj,traiti]   = SM[traiti,traitj]
            end
        end

        mme.M.G = rand(InverseWishart(νGM + nMarkers, PM + SM))
        R0    = rand(InverseWishart(νR0 + nObs, PRes + SRes))

        mme.R = R0
        #Ri   = mkRi(mme,df) #for missing value
        R0    = mme.R
        Ri    = kron(inv(R0),speye(nObs))

        X          = mme.X
        mme.mmeLhs = X'Ri*X
        ycorr[:]   = ycorr[:] + mme.X*sol
        mme.mmeRhs = mme.X'Ri*ycorr

        #####################################
        #sample genetic variance matrix (polygenic effects)
        #can make this more efficient by taking advantage of symmetry
        #####################################
        if mme.ped != 0
            for (i,trmi) = enumerate(pedTrmVec)
                pedTrmi  = mme.modelTermDict[trmi]
                startPosi  = pedTrmi.startPos
                endPosi    = startPosi + pedTrmi.nLevels - 1
                for (j,trmj) = enumerate(pedTrmVec)
                    pedTrmj  = mme.modelTermDict[trmj]
                    startPosj  = pedTrmj.startPos
                    endPosj    = startPosj + pedTrmj.nLevels - 1
                    S[i,j] = (sol[startPosi:endPosi]'*mme.Ai*sol[startPosj:endPosj])[1,1]
                end
            end
            pedTrm1 = mme.modelTermDict[pedTrmVec[1]]
            q = pedTrm1.nLevels
            G0 = rand(InverseWishart(νG0 + q, P + S))
            mme.Gi = inv(G0)
            addA(mme)

            G0Mean  += (G0  - G0Mean )/iter
        end

        solMean += (sol - solMean)/iter
        R0Mean  += (R0  - R0Mean )/iter
        GMMean  += (mme.M.G  - GMMean)/iter

        if iter%outFreq==0
            println("at sample: ",iter)
            println("Residual covariance matrix: \n",R0Mean)
            println("Marker effects covariance matrix: \n",GMMean,"\n")
        end

        if iter%thin==0
          for traiti in 1:ntraits
            writedlm(outfile[traiti],meanAlphaArray[traiti]')
          end
        end
    end

    for traiti in 1:ntraits
      close(outfile[traiti])
    end

    output = Dict()
    output["posterior mean of location parameters"]    = [getNames(mme) solMean]
    output["posterior mean of marker effects covariance matrix"]    = GMMean
    output["posterior mean of residual covaraince matrix"]          = R0Mean

    if mme.ped != 0
      output["posterior mean of polygenic effects covariance matrix"] = G0Mean
    end


    if mme.M.markerID[1]!="NA"
      markerout        = []
      for markerArray in meanAlphaArray
        push!(markerout,[mme.M.markerID markerArray])
      end
    else
      markerout        = meanAlphaArray
    end
    output["posterior mean of marker effects"] = markerout

    return output
end
