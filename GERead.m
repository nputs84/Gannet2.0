function [ MRS_struct ] = GERead(MRS_struct, fname)
            ii=MRS_struct.ii;
            MRS_struct.global_rescale=1;
%121106 RAEE moving code from GAnnetLoad to GERead (to match other file
%formats and tidy things up some.
            fid = fopen(fname,'r', 'ieee-be');
            if fid == -1
                tmp = [ 'Unable to locate Pfile ' fname ];
                disp(tmp);
                return;
            end
            % return error message if unable to read file type.
            % Determine size of Pfile header based on Rev number
            status = fseek(fid, 0, 'bof');
            [f_hdr_value, count] = fread(fid, 1, 'real*4');
            rdbm_rev_num = f_hdr_value(1);
            if( rdbm_rev_num == 7.0 );
                pfile_header_size = 39984;  % LX
            elseif ( rdbm_rev_num == 8.0 );
                pfile_header_size = 60464;  % Cardiac / MGD
            elseif (( rdbm_rev_num > 5.0 ) && (rdbm_rev_num < 6.0));
                pfile_header_size = 39940;  % Signa 5.5
            else
                % In 11.0 and later the header and data are stored as little-endian
                fclose(fid);
                fid = fopen(fname,'r', 'ieee-le');
                status = fseek(fid, 0, 'bof');
                [f_hdr_value, count] = fread(fid, 1, 'real*4');
                if (f_hdr_value == 9.0)  % 11.0 product release
                    pfile_header_size= 61464;
                elseif (f_hdr_value == 11.0);  % 12.0 product release
                    pfile_header_size= 66072;
                elseif (f_hdr_value > 11.0) & (f_hdr_value < 100.0)  % 14.0 and later
                    status = fseek(fid, 1468, 'bof');
                    pfile_header_size = fread(fid,1,'integer*4');
                else
                    err_msg = sprintf('Invalid Pfile header revision: %f', f_hdr_value );
                    return;
                end
            end

            % Read header information
            status = fseek(fid, 0, 'bof');
            [hdr_value, count] = fread(fid, 102, 'integer*2');
            npasses = hdr_value(33);
            nslices = hdr_value(35);
            nechoes = hdr_value(36);
            nframes = hdr_value(38);
            point_size = hdr_value(42);
            MRS_struct.npoints = hdr_value(52);
            MRS_struct.nrows = hdr_value(53);
            rc_xres = hdr_value(54);
            rc_yres = hdr_value(55);
            start_recv = hdr_value(101);
            stop_recv = hdr_value(102);
            nreceivers = (stop_recv - start_recv) + 1;


            % Specto Prescan pfiles
            if (MRS_struct.npoints == 1) & (MRS_struct.nrows == 1)
                MRS_struct.npoints = 2048;
            end
            
            % Determine number of slices in this Pfile:  this does not work for all cases.
            slices_in_pass = nslices/npasses;

            % Compute size (in bytes) of each frame, echo and slice
            data_elements = MRS_struct.npoints*2;
            frame_size = data_elements*point_size;
            echo_size = frame_size*MRS_struct.nrows;
            slice_size = echo_size*nechoes;
            mslice_size = slice_size*slices_in_pass;
            my_slice = 1;
            my_echo = 1;
            my_frame = 1;

            FullData=zeros(nreceivers, MRS_struct.npoints , MRS_struct.nrows-my_frame+1);

            %Start to read data into Eightchannel structure.
            totalframes=MRS_struct.nrows-my_frame+1;
            MRS_struct.nrows=totalframes;
            data_elements2 = data_elements*totalframes*nreceivers;

            %  % Compute offset in bytes to start of frame.
            file_offset = pfile_header_size + ((my_frame-1)*frame_size);

            status = fseek(fid, file_offset, 'bof');

            % read data: point_size = 2 means 16 bit data, point_size = 4 means EDR )
            if (point_size == 2 )
                [raw_data, count] = fread(fid, data_elements2, 'integer*2');
            else
                [raw_data, count] = fread(fid, data_elements2, 'integer*4');
            end

            fclose(fid);

            
            % 110303 CJE
            % calculate Navg from nframes, 8 water frames, 2 phase cycles
            % Needs to be specific to single experiment - for frame rejection
            MRS_struct.Navg(ii) = (nframes-8)*2;
            MRS_struct.Nwateravg = 8; %moved from MRSGABAinstunits RE 110726
            MRS_struct.TR = 1.8;
            ShapeData = reshape(raw_data,[2 MRS_struct.npoints totalframes nreceivers]);
            ZeroData = ShapeData(:,:,1,:);
            WaterData = ShapeData(:,:,2:9,:);
            FullData = ShapeData(:,:,10:end,:);

            totalframes = totalframes-9;
            MRS_struct.nrows=totalframes;

            Frames_for_Water = 8;

            FullData = FullData.*repmat([1;i],[1 MRS_struct.npoints totalframes nreceivers]);
            WaterData = WaterData.*repmat([1;i],[1 MRS_struct.npoints Frames_for_Water nreceivers]);

            FullData = squeeze(sum(FullData,1));
            FullData = permute(FullData,[3 1 2]);


            WaterData = squeeze(sum(WaterData,1));
            WaterData = permute(WaterData,[3 1 2]);
            % at this point, FullData(rx_channel, point, average)

            firstpoint=conj(WaterData(:,1,:));
            firstpoint=repmat(firstpoint, [1 MRS_struct.npoints 1]);
            % here firstpoint(rx_channel,[], average)


            % CJE March 10 - correct phase of each Water avg independently
            WaterData=WaterData.*firstpoint*MRS_struct.global_rescale;

            %Multiply the Eightchannel data by the firstpointvector
            % zeroth order phasing of spectra
            % CJE Nov 09: do global rescaling here too
            % don't really need the phasing step here if performing frame-by-frame phasing
            for receiverloop = 1:nreceivers
                FullData(receiverloop,:) = FullData(receiverloop,:)*firstpoint(receiverloop,1,1)*MRS_struct.global_rescale;
                % WaterData(receiverloop,:) = WaterData(receiverloop,:)*firstpoint(receiverloop,1,1)*MRS_struct.global_rescale;
            end

            % sum over Rx channels
            FullData = squeeze(sum(FullData,1));
            MRS_struct.data =FullData;
            WaterData = squeeze(sum(WaterData,1));
            MRS_struct.data_water=WaterData;
            MRS_struct.sw = 5000;  %should really pick this up from the header
            %%%%%% end of GE specific load
            rescale=1/1e11%necessary for GE data or numbers blow up.
            MRS_struct.data =MRS_struct.data*rescale;
            MRS_struct.data_water =MRS_struct.data_water*rescale;
            
end