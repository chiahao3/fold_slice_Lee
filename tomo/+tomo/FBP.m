% FBP filtered back projection - multiGPU FBP solver
%
% [rec,sinogram] = FBP(sinogram, cfg, vectors, varargin)
% 
% Inputs:
%     **sino        - sinogram (Nlayers x width x Nangles)
%     **cfg         - config struct from ASTRA_initialize
%     **vectors     - vectors of projection rotation generated by ASTRA_initialize
%  *optional*
%     ** split =[1,1,1]           - split the solved volume, split(3 is used to split in separated blocks, split(1:2) is used inside Atx_partial to du subplitting for ASTRA 
%     ** valid_angles =  []       - list of valid angles, []==all are valid
%     ** filter =   'ram-lak'     - name of the FBP filter 
%     ** filter_value =   1       - fitlering value for the FBP filter 
%     ** deformation_fields = {}  - cell 3x1 of deformation arrays 
%     ** GPU =  []                - list of GPUs to be used in reconstruction
%     ** split_sub =  [1,1,1]     - splitting of the sub block on smaller tasks in the Atx_partial method , 1 == no splitting 
%     ** verbose =  1             - verbose = 0 : quiet, verbose : standard info , verbose = 2: debug 
%     ** use_derivative =  false  - calculate reconstruction from the phase derivative 
%     ** extra_padding =  false   - surround the projection by void space to enforce zero around tomogram 
%     ** keep_on_GPU              - if false, move the reconstruction back from GPU before returning
%     ** determine_weights = true - reweight projections if the angles are not equidistant
%     ** mask =  []               - apply mask on reconstruction , inputs is 2D or 3D array 
%     ** padding =  0             - zero padding is improving standard tomography. 'symmetric' is good for lamino / local tomo 
%     ** only_filter_sinogram = false   - return filtered sinogram, do not backproject 
% *returns*
%     ++tomogram    - FBP reconstruction 

%*-----------------------------------------------------------------------*
%|                                                                       |
%|  Except where otherwise noted, this work is licensed under a          |
%|  Creative Commons Attribution-NonCommercial-ShareAlike 4.0            |
%|  International (CC BY-NC-SA 4.0) license.                             |
%|                                                                       |
%|  Copyright (c) 2017 by Paul Scherrer Institute (http://www.psi.ch)    |
%|                                                                       |
%|       Author: CXS group, PSI                                          |
%*-----------------------------------------------------------------------*
% You may use this code with the following provisions:
%
% If the code is fully or partially redistributed, or rewritten in another
%   computing language this notice should be included in the redistribution.
%
% If this code, or subfunctions or parts of it, is used for research in a 
%   publication or if it is fully or partially rewritten for another 
%   computing language the authors and institution should be acknowledged 
%   in written form in the publication: “Data processing was carried out 
%   using the “cSAXS matlab package” developed by the CXS group,
%   Paul Scherrer Institut, Switzerland.” 
%   Variations on the latter text can be incorporated upon discussion with 
%   the CXS group if needed to more specifically reflect the use of the package 
%   for the published work.
%
% A publication that focuses on describing features, or parameters, that
%    are already existing in the code should be first discussed with the
%    authors.
%   
% This code and subroutines are part of a continuous development, they 
%    are provided “as they are” without guarantees or liability on part
%    of PSI or the authors. It is the user responsibility to ensure its 
%    proper use and the correctness of the results.

function [rec,sinogram, H] = FBP(sinogram, cfg, vectors, varargin)

    par = inputParser;
    par.addOptional('split', [1,1,1])   % split the solved volume, split(3) is used to split in separated blocks, split(1:2) is used inside Atx_partial to du subplitting for ASTRA 
    par.addParameter('valid_angles', [])
    par.addParameter('filter',  'ram-lak' )
    par.addParameter('filter_value',  1 )
    par.addParameter('deformation_fields',  {} )  % cell 3x1 of deformation arrays 
    par.addOptional('GPU', [])   % list of GPUs to be used in reconstruction
    par.addOptional('split_sub', [1,1,1])   % splitting of the sub block on smaller tasks in the Atx_partial method , 1 == no splitting 
    par.addOptional('verbose', 1)   % verbose = 0 : quiet, verbose : standard info , verbose = 2: debug 
    par.addOptional('use_derivative', false)   % calculate reconstruction from the phase derivative 
    par.addOptional('extra_padding', false)   %  surround the projection by void space to enforce zero around tomogram 
    par.addOptional('keep_on_GPU', isa(sinogram, 'gpuArray'))     % if false, move the reconstruction back from GPU before returning
    par.addOptional('determine_weights', true)% reweight projections if the angles are not equidistant
    par.addOptional('mask', [])   % apply mask on reconstruction , inputs is 2D or 3D array 
    par.addOptional('padding', 0)   % zero padding is improving standard tomography. 'symmetric' is good for lamino / local tomo 
    par.addOptional('only_filter_sinogram', false)   % return filtered sinogram, do not backproject 

    par.parse(varargin{:})
    r = par.Results;
    
    if r.verbose>0
        disp('====== FBP ==========')
    end

    if ~isempty(r.valid_angles) && (~islogical(r.valid_angles) || any(~r.valid_angles))
        sinogram = sinogram(:,:,r.valid_angles);
        vectors = vectors(r.valid_angles,:);
    end
    
    [Nlayers,Nw,Nproj] = size(sinogram);
    cfg.iProjAngles = Nproj;
    assert(cfg.iProjU == Nw, 'Wrong sinogram width')
    assert(cfg.iProjV == Nlayers, 'Wrong sinogram height')
    assert(mod(Nw,2)==0, 'Only even width of sinogram is supported')
    if ~isempty(r.mask)
        assert(all(size(r.mask) == [cfg.iVolX, cfg.iVolY]), 'Wrong size of reconstruction mask')
    end


    if ~isreal(sinogram)
        r.use_derivative = true;
        sinogram = math.get_phase_gradient_1D(sinogram,2, 0.01);
    end
    
    % calculate the original angles 
    theta = pi-atan2(vectors(:,2),-vectors(:,1)); 
    lamino_angle = pi/2-atan2(vectors(:,3), vectors(:,1)./cos(theta)); 


    if ~strcmpi(r.filter, 'none')
        

        %%% Determine weights for uneven angular sampling %%%

        % if r.determine_weights  && any(theta<-pi/Nproj)
        %     warning('There are some theta < 0 angles. Using constant angular sampling code.')
        %     r.determine_weights = false;
        % end
        % if r.determine_weights  && any(theta>pi+pi/Nproj)
        %     warning('There are some theta >= 180 angles. Using constant angular sampling code.')
        %     r.determine_weights = false;
        % end
        % if r.determine_weights  && abs(max(theta)-min(theta)-pi) > 5*mean(diff(sort(theta)))
        %     warning('Missing wedge is to large for weighting')
        %     r.determine_weights = false;
        % end


        if r.determine_weights
            % determine weights in case of iregular fourier space sampling 
            theta = mod(theta - theta(1), pi) ; % assume the the first one is zero, assume that theta and theta+180 are the same projections 
            [theta_sort,ind_sort] = sort(theta);  % sort the angles 

            weights = zeros(Nproj,1);
            weights(2:end-1) = - theta_sort(1:end-2)/2 + theta_sort(3:end)/2;
            weights(1) = theta_sort(2)-theta_sort(1);
            weights(end) = theta_sort(end) - theta_sort(end-1);
            weights(ind_sort) = weights; % sort it back as given in 
            if any(weights > 2*median(weights))
                utils.verbose(2,'Too large angular jump for FBP weighting, assuming missing wedge tomo')
                weights(weights > 2*median(weights)) = median(weights); 
            end
            weights =  weights / mean(weights); 
        else
            weights =  1;  % constant weighting  
        end
        weights =  weights .* (pi/2/Nproj) .* sin(lamino_angle); 

        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    
        % Design the filter
        H = designFilter(r.filter, Nw, r.filter_value, r.use_derivative);


        % account for laminography tilt + unequal spacing of the tomo angles 
        H = bsxfun(@times, H', reshape(weights,1,1,[]));

        Nelements = size(H,2)*cfg.iProjV*cfg.iProjAngles; 

        if gpuDeviceCount
            % if possible, run in parallel on GPU
            gpu = gpuDevice; 
            % manually define the block size because default calculation in block_fun is not valid for this function 
            Nblocks =  ceil( (8*4* Nelements) /  gpu.AvailableMemory) ; 
            Nblocks = max(Nblocks,   Nelements/ double(intmax('int32'))); 
            Nblocks = max(Nblocks, length(r.GPU)); 
        else
            % CPU processing 
            max_block_size = min(utils.check_available_memory*1e6, 20e9); %% work with 10GB blocks 
            Nblocks  = ceil( (6*8* Nelements) / max_block_size) ; 
        end

        sinogram = tomo.block_fun(@applyFilter,sinogram, H, Nw, r.padding, ...
            struct('GPU_list', r.GPU, 'verbose_level', r.verbose, 'Nblocks', Nblocks, 'move_to_GPU', false));
    end
    
    % back-project the filtered arrays back to the volume space 
    if ~r.only_filter_sinogram
        if isa(sinogram, 'gpuArray') || max(cfg.iProjU, cfg.iProjV) < 4096 && cfg.iVolX*cfg.iVolY*cfg.iVolZ < intmax('int32') && length(r.GPU) <= 1 
            rec = astra.Atx_partial(sinogram, cfg, vectors, r.split_sub, 'verbose', r.verbose, 'deformation_fields', r.deformation_fields );
        else
            sinogram = gather(sinogram); 
            rec = tomo.Atx_sup_partial(sinogram, cfg, vectors, r.split,  'GPU', r.GPU, 'split_sub', r.split_sub, 'verbose', r.verbose, 'deformation_fields', r.deformation_fields );
        end
        % apply apodization function if provided 
        if ~isempty(r.mask)
            rec = tomo.block_fun(@(x)(x .* r.mask), rec, struct('use_GPU', false)); % run on CPU
        end 
    else
       rec = [];  
    end
    if ~r.keep_on_GPU 
        rec = gather(rec);
    end

end

function sinogram = applyFilter(sinogram, H, Nw, padding)
    
    sinogram = utils.Garray(sinogram); 
    
    % Zero pad projections, important to avoid negative values in air around 
    sinogram = padarray(sinogram,double([0,(size(H,2) - Nw)/2]),padding, 'both'); 

    % move directly to complex to include the expected memore requirements 
    sinogram = complex(sinogram);

    sinogram = math.fft_partial(sinogram,2,1);  % sinogram holds fft of projections

    sinogram = sinogram.*H; % frequency domain filtering
    
    sinogram = math.ifft_partial(sinogram,2,1); 
    
    sinogram = real(sinogram);
     
    sinogram = sinogram(:,1+end/2-Nw/2:end/2+Nw/2,:);   % Truncate the filtered projections

end

function filt = designFilter(filter, len, d, derivative)
% Returns the Fourier Transform of the filter which will be 
% used to filter the projections
%
% INPUT ARGS:   filter - either the string specifying the filter 
%               len    - the length of the projections
%               d      - the fraction of frequencies below the nyquist
%                        which we want to pass
%
% OUTPUT ARGS:  filt   - the filter to use on the projections

        order = max(64,2^nextpow2(2*len));
%         order = len;  % better for laminography 

    % First create a ramp filter - go up to the next highest
    % power of 2.
    if derivative
        filt = 0*( 0:(order/2) )+1;
    else
        filt = 2*( 0:(order/2) )./order;
    end
    w = 2*pi*(0:size(filt,2)-1)/order;   % frequency axis up to Nyquist 

    switch filter
    case 'ram-lak'
       % Do nothing
    case 'shepp-logan'
       % be careful not to divide by 0:
       filt(2:end) = filt(2:end) .* (sin(w(2:end)/(2*d))./(w(2:end)/(2*d)));
    case 'cosine'
       filt(2:end) = filt(2:end) .* cos(w(2:end)/(2*d));
    case 'hamming'  
       filt(2:end) = filt(2:end) .* (.54 + .46 * cos(w(2:end)/d));
    case 'hann'
       filt(2:end) = filt(2:end) .*(1+cos(w(2:end)./d)) / 2;
    case 'parzen'
       aux = parzenwin(round(2*size(filt,2)*d)-1)';
       aux = aux(round(size(aux,2)/2):round(size(aux,2)));
       filt(1:size(aux,2)) = filt(1:size(aux,2)).*aux;
       filt(size(aux,2)+1:end) = 0;
    otherwise
       eid = sprintf('Images:%s:invalidFilter',mfilename);
       msg = 'Invalid filter selected.';
       error(eid,'%s',msg);
    end

    filt(w>pi*d) = 0;                      % Crop the frequency response
    if derivative
        filt = [filt' ; -filt(end-1:-1:2)']/(1i*pi);    % Symmetry of the filter
    else
        filt = [filt' ; filt(end-1:-1:2)'];    % Symmetry of the filter
    end
end
