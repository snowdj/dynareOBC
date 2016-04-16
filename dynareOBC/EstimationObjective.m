function [ TwoNLogLikelihood, TwoNLogObservationLikelihoods, M, options, oo, dynareOBC ] = EstimationObjective( p, M, options, oo, dynareOBC, InitialRun )
    TwoNLogLikelihood = Inf;
    [ T, N ] = size( dynareOBC.EstimationData );
    if nargout > 1
        TwoNLogObservationLikelihoods = NaN( T, 1 );
    end

    M.params( dynareOBC.EstimationParameterSelect ) = p( 1 : length( dynareOBC.EstimationParameterSelect ) );
    MEVar = p( ( length( dynareOBC.EstimationParameterSelect ) + 1 ):end );
    
    options.qz_criterium = 1 - 1e-6;
    try
        [ Info, M, options, oo, dynareOBC ] = ModelSolution( false, M, options, oo, dynareOBC, InitialRun );
    catch
        return
    end
    if Info ~= 0
        return
    end

    global M_ options_ oo_ dynareOBC_
    M_ = M;
    options_ = options;
    oo_ = oo;
    dynareOBC_ = dynareOBC;
    
    NEndo = M.endo_nbr;
    NExo = dynareOBC.OriginalNumVarExo;
    NEndoMult = 2 .^ ( dynareOBC.Order - 1 );
    
    StateVariables = oo.dr.order_var( dynareOBC.SelectState );
    AugStateVariables = repmat( StateVariables, NEndoMult, 1 );
    NState = sum( StateVariables );
    NAugState = NEndoMult * NState;
   
    EstimationStdDevThreshold = dynareOBC.EstimationStdDevThreshold;
    
    RootQ = ObtainEstimateRootCovariance( M.Sigma_e( 1:NExo, 1:NExo ), EstimationStdDevThreshold );

    OriginalVarSelect = false( NEndo );
    OriginalVarSelect( 1:dynareOBC.OriginalNumVar ) = true;
    LagIndices = dynareOBC.OriginalLeadLagIncidence( 1, : ) > 0;
    CurrentIndices = dynareOBC.OriginalLeadLagIncidence( 2, : ) > 0;
    if size( dynareOBC.OriginalLeadLagIncidence, 1 ) > 2
        LeadIndices = dynareOBC.OriginalLeadLagIncidence( 3, : ) > 0;
    else
        LeadIndices = [];
    end
    FutureValues = nan( sum( LeadIndices ), 1 );
    NanShock = nan( 1, NExo );
    
    persistent FullMean;
    persistent FullRootCovariance;
    
    RecalculateMeanAndCovariance = InitialRun || isempty( FullMean ) || isempty( FullRootCovariance ) || any( size( FullMean ) ~= [ NAugState 1 ] ) || size( FullRootCovariance, 1 ) ~= NAugState || size( FullRootCovariance, 1 ) > NAugState || any( ~isfinite( FullMean ) ) || any( any( ~isfinite( FullRootCovariance ) ) );

    if RecalculateMeanAndCovariance
        OldMean = full( dynareOBC.Mean_z );
        OldMean = OldMean( dynareOBC.CoreSelectInAugmented );
        OldMean = OldMean( AugStateVariables );
        dr = oo.dr;

        if dynareOBC.Order == 1
            TempCovariance = full( dynareOBC.Var_z1 );
            TempCovarianceSelect = dr.inv_order_var( StateVariables );
        else
            TempCovariance = full( dynareOBC.Var_z2 );
            TempCovarianceSelect = [ dr.inv_order_var( StateVariables ); NEndo + dr.inv_order_var( StateVariables ) ];
        end
        
        TempOldRootCovariance = ObtainEstimateRootCovariance( TempCovariance( TempCovarianceSelect, TempCovarianceSelect ), EstimationStdDevThreshold );

        OldRootCovariance = zeros( NAugState, size( TempOldRootCovariance, 2 ) );
        OldRootCovariance( 1:size( TempOldRootCovariance, 1 ), : ) = TempOldRootCovariance; % handles 3rd order
    else
        OldMean = FullMean;
        OldRootCovariance = FullRootCovariance;
    end
    
    MParams = M.params;
    OoDrYs = oo.dr.ys( OriginalVarSelect );
    
    for t = 1:dynareOBC.EstimationFixedPointMaxIterations
        try
            [ Mean, RootCovariance ] = KalmanStep( nan( 1, N ), OldMean, OldRootCovariance, RootQ, MEVar, MParams, OoDrYs, dynareOBC, OriginalVarSelect, LagIndices, CurrentIndices, FutureValues, NanShock, AugStateVariables );
        catch
            Mean = [];
        end
        if isempty( Mean )
            break;
        end
        
        CompNew = RootCovariance * RootCovariance';
        CompNew = [ CompNew(:); Mean ];
        CompOld = OldRootCovariance * OldRootCovariance';
        CompOld = [ CompOld(:); OldMean ];

        OldMean = Mean; % 0.5 * Mean + 0.5 * OldMean;
        OldRootCovariance = RootCovariance; % 0.5 * RootCovariance + 0.5 * OldRootCovariance;
        
        LCompNew = log( abs( CompNew ) );
        SCompNew = isfinite( LCompNew );
        LCompOld = log( abs( CompOld ) );
        SCompOld = isfinite( LCompOld );
        if all( SCompNew == SCompOld )
            Error = max( max( abs( CompNew - CompOld ) ), max( abs( LCompNew( SCompNew ) - LCompOld( SCompOld ) ) ) );
            if Error < 1e-4
                FullMean = OldMean;
                FullRootCovariance = OldRootCovariance;
                break;
            end
        end
    end
    if isempty( OldMean ) || isempty( OldRootCovariance );
        return;
    end

    TwoNLogLikelihood = 0;
    for t = 1:T
        [ Mean, RootCovariance, TwoNLogObservationLikelihood ] = KalmanStep( dynareOBC.EstimationData( t, : ), OldMean, OldRootCovariance, RootQ, MEVar, MParams, OoDrYs, dynareOBC, OriginalVarSelect, LagIndices, CurrentIndices, FutureValues, NanShock, AugStateVariables );
        if isempty( Mean )
            TwoNLogLikelihood = Inf;
            return;
        end
        if nargout > 1
            TwoNLogObservationLikelihoods( t ) = TwoNLogObservationLikelihood;
        end
        OldMean = Mean;
        OldRootCovariance = RootCovariance;
        TwoNLogLikelihood = TwoNLogLikelihood + TwoNLogObservationLikelihood;
    end
end
