function [hmm, Gamma, Xi, vpath, GammaInit, residuals, fehist, feterms, markovTrans, rho] = ...
    hmmmar (data,T,options)
% Main function to train the HMM-MAR model, compute the Viterbi path and,
% if requested, obtain the cross-validated sum of prediction quadratic errors.
%
% INPUT
% data          observations, either a struct with X (time series) and C (classes, optional)
%                             or just a matrix containing the time series
% T             length of series
% options       structure with the training options - see documentation
%
% OUTPUT
% hmm           estimated HMMMAR model
% Gamma         Time courses of the states probabilities given data
% Xi            joint probability of past and future states conditioned on data
% vpath         most likely state path of hard assignments
% GammaInit     Time courses used after initialisation.
% residuals     if the model is trained on the residuals, the value of those
% fehist        historic of the free energies across iterations
%
% Author: Diego Vidaurre, OHBA, University of Oxford (2015)

if iscell(T)
    for i = 1:length(T)
        if size(T{i},1)==1, T{i} = T{i}'; end
    end
    N = numel(cell2mat(T));
else
    N = length(T);
end

stochastic_learn = isfield(options,'BIGNbatch') && ...
    (options.BIGNbatch < N && options.BIGNbatch > 0);
options = checkspelling(options);

if stochastic_learn, 
    if ~iscell(data)
       dat = cell(N,1); TT = cell(N,1);
       for i=1:N
          t = 1:T(i);
          dat{i} = data(t,:); TT{i} = T(i);
          try data(t,:) = []; 
          catch, error('The dimension of data does not correspond to T');
          end
       end
       if ~isempty(data), 
           error('The dimension of data does not correspond to T');
       end 
       data = dat; T = TT; clear dat TT
    end
    options = checkBIGoptions(options,T);
else
    if iscell(data)
        if size(data,1)==1, data = data'; end
        data = cell2mat(data);
    end
    if iscell(T)
        if size(T,1)==1, T = T'; end
        T = cell2mat(T);
    end
    [options,data] = checkoptions(options,data,T,0);
end

% if ~isfield(options,'tmp_folder')
%     tmp_folder = tempdir;
% end
    
ver = version('-release');
oldMatlab = ~isempty(strfind(ver,'2010')) || ~isempty(strfind(ver,'2010')) ...
    || ~isempty(strfind(ver,'2011')) || ~isempty(strfind(ver,'2012'));

% set the matlab parallel computing environment
if options.useParallel==1 && usejava('jvm')
    if oldMatlab
        if matlabpool('size')==0
            matlabpool
        end
    else
        gcp;
    end
end

gatherStats = 0;
if isfield(options,'DirStats')
    profile on
    gatherStats = 1; 
    DirStats = options.DirStats;
    options = rmfield(options,'DirStats'); 
    % to avoid recurrent calls to hmmmar to do the same
end

if stochastic_learn
    
    [hmm,info] = hmmsinit(data,T,options);
    [hmm,markovTrans,fehist,feterms,rho] = hmmstrain(data,T,hmm,info,options);
    Gamma = []; Xi = []; vpath = []; GammaInit = []; residuals = [];
    if options.BIGcomputeGamma && nargout >= 2
       [Gamma,Xi] = hmmdecode(data,T,hmm,0,[],[],markovTrans); 
    end
    if options.BIGdecodeGamma && nargout >= 4
       vpath = hmmdecode(data.X,T,hmm,1,[],[],markovTrans); 
    end
    
else
        
    if length(options.embeddedlags)>1
        X = []; C = [];
        for in=1:length(T)
            [x, ind] = embedx(data.X(sum(T(1:in-1))+1:sum(T(1:in)),:),options.embeddedlags); X = [X; x ];
            c = data.C( sum(T(1:in-1))+1: sum(T(1:in)) , : ); c = c(ind,:); C = [C; c];
            T(in) = size(c,1);
        end
        data.X = X; data.C = C;
    end
    
    % if options.whitening>0
    %     mu = mean(data.X);
    %     data.X = bsxfun(@minus, data.X, mu);
    %     [V,D] = svd(data.X'*data.X);
    %     A = sqrt(size(data.X,1)-1)*V*sqrtm(inv(D + eye(size(D))*0.00001))*V';
    %     data.X = data.X*A;
    %     iA = pinv(A);
    % end
    
    if isempty(options.Gamma) && isempty(options.hmm)
        if options.K > 1
            Sind = options.Sind;
            if options.initrep>0 && ...
                    (strcmpi(options.inittype,'HMM-MAR') || strcmpi(options.inittype,'HMMMAR'))
                options.Gamma = hmmmar_init(data,T,options,Sind);
            elseif options.initrep>0 &&  strcmpi(options.inittype,'EM')
                warning('EM is deprecated; HMM-MAR initialisation is suggested instead')
                options.nu = sum(T)/200;
                options.Gamma = em_init(data,T,options,Sind);
            elseif options.initrep>0 && strcmpi(options.inittype,'GMM')
                options.Gamma = gmm_init(data,T,options);
            elseif strcmpi(options.inittype,'random')
                options.Gamma = initGamma_random(T-options.maxorder,options.K,options.DirichletDiag);
            else
                warning('Unknown init method, initialising at random')
            end
        else
            options.Gamma = ones(sum(T)-length(T)*options.maxorder,1);
        end
        GammaInit = options.Gamma;
        options = rmfield(options,'Gamma');
    elseif isempty(options.Gamma) && ~isempty(options.hmm)
        GammaInit = [];
    else % ~isempty(options.Gamma)
        GammaInit = options.Gamma;
        options = rmfield(options,'Gamma');
    end

    % Code below will start the iterations with reduced K, but this also has strange effects
    % with DirichletDiag
    % ----
    % if size(GammaInit,2) < options.K && any(isfinite(data.C(:)))
    %     % States were knocked out, but semisupervised in use, so put them back
    %     GammaInit = [GammaInit 0.0001*rand(size(GammaInit,1),options.K-size(GammaInit,2))];
    %     GammaInit = bsxfun(@rdivide,GammaInit,sum(GammaInit,2));
    % end
    % options.K = size(GammaInit,2);
    % data.C = data.C(:,1:options.K);
    % -----

    % Code below reproduces default usage
    % -----
    if size(GammaInit,2) < options.K 
        % States were knocked out, but semisupervised in use, so put them back
        GammaInit = [GammaInit 0.0001*rand(size(GammaInit,1),options.K-size(GammaInit,2))];
        GammaInit = bsxfun(@rdivide,GammaInit,sum(GammaInit,2));
    end

    % -----
    fehist = Inf;
    if isempty(options.hmm) % Initialisation of the hmm
        hmm_wr = struct('train',struct());
        hmm_wr.K = options.K;
        hmm_wr.train = options;
        %if options.whitening, hmm_wr.train.A = A; hmm_wr.train.iA = iA;  end
        hmm_wr = hmmhsinit(hmm_wr);
        [hmm_wr,residuals_wr] = obsinit(data,T,hmm_wr,GammaInit);
    else % using a warm restart from a previous run
        hmm_wr = options.hmm;
        options = rmfield(options,'hmm');
        hmm_wr.train = options;
        residuals_wr = getresiduals(data.X,T,hmm_wr.train.Sind,hmm_wr.train.maxorder,hmm_wr.train.order,...
            hmm_wr.train.orderoffset,hmm_wr.train.timelag,hmm_wr.train.exptimelag,hmm_wr.train.zeromean);
    end
    
    for it=1:options.repetitions
        hmm0 = hmm_wr;
        residuals0 = residuals_wr;
        [hmm0,Gamma0,Xi0,fehist0] = hmmtrain(data,T,hmm0,GammaInit,residuals0,options.fehist);
        if options.updateGamma==1 && fehist0(end)<fehist(end),
            fehist = fehist0; hmm = hmm0;
            residuals = residuals0; Gamma = Gamma0; Xi = Xi0;
        elseif options.updateGamma==0,
            fehist = []; hmm = hmm0;
            residuals = []; Gamma = GammaInit; Xi = [];
        end
    end
    
    if options.decodeGamma && nargout >= 4
        vpath = hmmdecode(data.X,T,hmm,1,residuals);
        if ~options.keepS_W
            for i=1:hmm.K
                hmm.state(i).W.S_W = [];
            end
        end
    else
        vpath = ones(size(Gamma,1),1);
    end
    hmm.train = rmfield(hmm.train,'Sind');
    
    markovTrans = []; feterms = []; rho = [];
    
end

if gatherStats==1
    hmm.train.DirStats = DirStats; 
    profile off
    profsave(profile('info'),hmm.train.DirStats)
end
    
end
