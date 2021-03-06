classdef MixMvnVbFitEng < FitEng
    
    
    properties
        diagnostics;
        verbose;
        nrestarts;
    end
    
    
    methods
        
        function eng = MixMvnVbFitEng(varargin)
            [eng.nrestarts,eng.verbose] = processArgs(varargin,'-nrestarts',3,'-verbose',true);
        end
        
        function model = fit(eng,model,data)
            
            nrestarts = eng.nrestarts;
            L = zeros(nrestarts, 1);
            fittedDistrib = cell(nrestarts,1);
            fittedMix = cell(nrestarts,1);
            vbFcn = @(d)VBforMixMvn(model.mixtureComps,model.mixingDist,d);
            for r=1:nrestarts
                [fittedDistrib{r}, fittedMix{r}, L(r)] = vbFcn(data);
            end
            best = argmax(L);
            model.mixtureComps = fittedDistrib{best};
            model.mixtureDist = fittedMix{best};
        end
        
    end
    
end




%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% special purpose code at this point
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function [fittedDistrib, fittedMix, Lfinal] = VBforMixMvn(distributions, mixingPrior, X, varargin)
    % Variational Bayes EM algorithm for Gaussian Mixture Model
    % This implementation is based on Bishop's Book
    % Refer to Bishop's book for notation and details
    % @book{bishop2006pra,
    %   title={{Pattern recognition and machine learning}},
    %   author={Bishop, C.M.},
    %   year={2006},
    %   publisher={Springer}
    % }
    %#author Emtiyaz, CS, UBC
    % June, 2007
    %#modified Cody Severinski, May 2009
    
    [tol, maxIter, verbose] = processArgs(varargin, ...
        '-tol',       1e-3, ...
        '-maxIter',   100, ...
        '-verbose',   false);
    
    % extract values of interest
    alpha0 = mixingPrior.params.alpha';
    K = numel(alpha0);
    [n,d] = size(X);
    m0 = zeros(K,d);
    k0 = zeros(1,K);
    invT0 = zeros(d,d,K);
    v0 = zeros(1,K);
    for k=1:K
        m0(k,:) = distributions{k}.params.mu';
%         switch covtype{k}
%             case 'full'
                k0(k) = distributions{k}.params.k;
                v0(k) = distributions{k}.params.dof;
                invT0(:,:,k) = distributions{k}.params.Sigma;
%             case 'diagonal'
%                 k0(k) = distributions{k}.Sigma;
%                 v0(k) = distributions{k}.a(1);
%                 invT0(:,:,k) = diag(distributions{k}.b);
%             case 'spherical'
%                 k0(k) = distributions{k}.Sigma;
%                 v0(k) = distributions{k}.a;
%                 invT0(:,:,k) = distributions{k}.b * eye(d);
%         end
    end
    
    % initialize variables
    converged = false;
    E = zeros(n,K);
    logLambdaTilde = zeros(1,K);
    
    % initialization of responsibilities
    [center, assign] = kmeansSimple(X, K);
    rnk = normalize(histc(assign,1:K)' + alpha0) + sqrt(eps); % + sqrt(eps) to avoid issues with zero SSn(k)
    rnk = repmat(rnk,n,1);
    Nk = sum(rnk);
    xbar = center;
    S = zeros(d,d,K);
    for k=1:K
        C = cov(X(assign == k,:));
        S(:,:,k) =  C + 0.01*diag(diag(C));
    end
    
    % M-step
    % CB 10.58,10.60-10.63.
    [alphan, kn, mn, Tn, vn] = VBemM(Nk, xbar, S, alpha0, k0, m0, invT0, v0, 'full');
    
    iter = 1;
    % Main loop of algorithm
    while(iter <= maxIter && ~converged)
        % Calculate r
        logPiTilde = digamma(alphan) - digamma(sum(alphan));
        for k = 1:K
%             switch lower(covtype{k})
%                 case 'full' % Wishart Dist on precision
                    logLambdaTilde(k) = sum(digamma(1/2*(vn(k) + 1 - [1:d]))) + d*log(2)  + logdet(Tn(:,:,k));
%                 case {'diagonal', 'spherical'} % Gamma dist on precision
%                     logLambdaTilde(k) = digamma(vn(k)) - logdet(Tn(:,:,k));
%             end
            XC = bsxfun(@minus, X, mn(k,:));
            E(:,k) = d./kn(k) + vn(k)*sum((XC*Tn(:,:,k)).*XC,2);
        end
        logrho = repmat(logPiTilde + 0.5*logLambdaTilde - d/2*log(2*pi), n,1) - 0.5*E;
        rnk = exp(normalizeLogspace(logrho)) + sqrt(eps); % + sqrt(eps) to avoid issues with zero SSn(k)
        
        [Nk, xbar, S] = emSS(X, K, rnk);
        
        
        % compute Lower bound (refer to Bishop for these terms)
        %10.71
        ElogpX = zeros(1,K);
        for k=1:K
            xbarc = xbar(k,:) - mn(k,:);
            ElogpX(k) = Nk(k)*(logLambdaTilde(k) - d/kn(k) - vn(k)*trace(S(:,:,k)*Tn(:,:,k)) - vn(k)*sum((xbarc*Tn(:,:,k)).*xbarc,2) - d*log(2*pi));
        end
        ElogpX = 1/2*sum(ElogpX);
        %10.72
        ElogpZ = sum(Nk.*logPiTilde);
        %10.73
        Elogppi = gammaln(sum(alpha0)) - sum(gammaln(alpha0)) + sum((alpha0-1).*logPiTilde);
        %10.74
        ElogpmuSigma = zeros(1,K);
        for k=1:K
            mc = mn(k,:) - m0(k,:);
            ElogpmuSigma(k) = d*log(k0(k)/(2*pi)) + logLambdaTilde(k) - d*k0(k)/kn(k) - k0(k)*vn(k)*sum((mc*Tn(:,:,k)).*mc,2);
%             switch lower(covtype{k})
%                 case 'full'
                    ElogpmuSigma(k) = ElogpmuSigma(k) - vn(k)*trace(invT0(:,:,k)*Tn(:,:,k)) + (v0(k) - d - 1)*logLambdaTilde(k) + 2*logWishartConst(invT0(:,:,k), v0(k));
                    % Factor of 2 on the last term as we then sum and then divide by 2 in the next line
%                 case {'diagonal', 'spherical'}
%                     ElogpmuSigma(k) = ElogpmuSigma(k) + 2*(vn(k)*logdet(Tn(:,:,k)) - gammaln(vn(k)) + (vn(k)-1)*logLambdaTilde(k) - vn(k));
%             end
        end
        ElogpmuSigma = 1/2*sum(ElogpmuSigma);
        %10.75
        ElogqZ = sum(sum(bsxfun(@times, rnk, log(rnk))));
        %10.76
        Elogqpi = sum((alphan - 1).*logPiTilde) + gammaln(sum(alphan)) - sum(gammaln(alphan));
        %10.77
        ElogqmuSigma = zeros(1,K);
        for k=1:K
            ElogqmuSigma(k) = 1/2*logLambdaTilde(k) + d/2*log(kn(k)/(2*pi)) - d/2;% - WishartEntropy(logLambdaTilde(k), Tn(:,:,k), vn(k));
%             switch lower(covtype{k})
%                 case 'full'
                    H = vn(k)/2*logdet(Tn(:,:,k)) + vn(k)*d/2*log(2) + mvtGammaln(d,vn(k)/2) - (vn(k) - d - 1)/2*logLambdaTilde(k) + vn(k)*d/2;
%                 case {'diagonal', 'spherical'}
%                     %H = sum(gammaln(vn(k)) - (vn(k)-1)*digamma(vn(k)) - log(diag(Tn(:,:,k))) + vn(k));
%                     H = vn(k)*logdet(Tn(:,:,k)) - log(gammaln(vn(k))) + (vn(k)-1)*logLambdaTilde(k) - vn(k);
%             end
            ElogqmuSigma(k) = ElogqmuSigma(k) - H;
        end
        ElogqmuSigma = sum(ElogqmuSigma);
        
        L(iter) = ElogpX + ElogpZ + Elogppi + ElogpmuSigma - ElogqZ - Elogqpi - ElogqmuSigma;
        
        if(verbose), fprintf('Iteration %d. loglik = %3.2f \n', iter, L(iter)); end;
        % warning  if lower bound decreses
        if iter>2 && L(iter)<L(iter-1)
            warning('VBforMixMvn:lowerBound','Lower bound decreased by %f ', L(iter)-L(iter-1));
        end
        
        % Begin M step
        [alphan, kn, mn, Tn, vn] = VBemM(Nk, xbar, S, alpha0, k0, m0, invT0, v0, 'full');
        
        % check if the  likelihood increase is less than threshold
        if iter>1, converged = convergenceTest(L(iter), L(iter-1), tol); end;
        if (converged || iter == maxIter)
            Lfinal = L(end);
            if(iter == maxIter && ~ converged), warning('VBforMixMvn:failed2Converge', 'Warning: failed to converge'); end;
            % Convert notation: Inverse Wishart |--> Wishart Notation
            invTn = zeros(size(Tn));
            for k=1:K
                invTn(:,:,k) = inv(Tn(:,:,k));
            end
            param = struct('alpha', alphan, 'mu', mn, 'k', kn, 'T', invTn, 'dof', vn);
            fittedDistrib = distributions;
            fittedMix = mixingPrior;
            fittedMix.alpha = colvec(alphan);
            for k=1:K
                fittedDistrib{k}.mu = mn(k,:)';
%                 switch covtype{k}
%                     case 'full'
                        fittedDistrib{k}.k = kn(k);
                        fittedDistrib{k}.dof = vn(k);
                        fittedDistrib{k}.Sigma = invTn(:,:,k);
%                     case 'diagonal'
%                         fittedDistrib{k}.Sigma = kn(k);
%                         fittedDistrib{k}.a = vn(k)*ones(1,d);
%                         fittedDistrib{k}.b = diag(invTn(:,:,k));
%                     case 'spherical'
%                         fittedDistrib{k}.Sigma = kn(k);
%                         fittedDistrib{k}.a = vn(k);
%                         fittedDistrib{k}.b = invTn(1,1,k);
%                 end
            end
        end;
        iter = iter + 1;
    end
end


function [SSn, SSxbar, SSXX] = emSS(X, K, weights)
    % This is basically a specialized version of MvnDist().mkSuffStat for our purposes
    % From my collapsed Gibbs code.  Modified outputs
    d = size(X,2);
    SSn = sum(weights,1);
    SSxbar = zeros(K,d); SSXX = zeros(d,d,K);
    for k=1:K
        SSxbar(k,:) = sum(bsxfun(@times, X, weights(:,k))) / SSn(k);
        XC = bsxfun(@minus,X,SSxbar(k,:));
        SSXX(:,:,k) = bsxfun(@times, XC, weights(:,k))'*XC / SSn(k);
    end
end

function [alphan, kn, mn, Tn, vn] = VBemM(Nk, xbar, S, alpha0, k0, m0, invT0, v0, covtype)
    K = numel(alpha0);
    d = size(xbar,2);
    alphan = alpha0 + Nk;
    kn = k0 + Nk;
    mn = zeros(K,d);
    invTn = zeros(d,d,K); Tn = zeros(d,d,K);
    for k=1:K
        mn(k,:) = ( k0(k)*m0(k,:) + Nk(k)*xbar(k,:) ) / kn(k);
        invTn(:,:,k) = invT0(:,:,k) + Nk(k)*S(:,:,k) + (k0(k)*Nk(k) / (k0(k) + Nk(k)) ) * (xbar(k,:) - m0(k,:))'*(xbar(k,:) - m0(k,:));
%         switch lower(covtype{k})
%             case 'full'
                vn(k) = v0(k) + Nk(k);
%             case 'diagonal'
%                 vn(k) = v0(k) + Nk(k)/2;
%                 invTn(:,:,k) = diag(diag( invTn(:,:,k) ));
%             case 'spherical'
%                 vn(k) = v0(k) + Nk(k)*d/2;
%                 invTn(:,:,k) = sum(diag(invTn(:,:,k)))*eye(d);
%         end
%         Tn(:,:,k) = inv(invTn(:,:,k));
    end
end

% These aren't going to work for diagonal or spherical covariances
function [lnZ] = logWishartConst(S, v, covtype)
    d = size(S,1);
    lnZ = -(v*d/2)*log(2) - mvtGammaln(d,v/2) + (v/2)*logdet(S);
end

function [h] = WishartEntropy(T, S, v, covtype)
    d = size(S,1);
    h = + v/2*logdet(S) + v*d/2*log(2) + mvtGammaln(d,v/2) - (v - d - 1)/2*T + v*d/2;
end