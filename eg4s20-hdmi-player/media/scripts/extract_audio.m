function extract_audio(source_file, work_dir)
% Extract 48 kHz mono signed 16-bit little-endian PCM without gain changes.
media_dir = fileparts(fileparts(mfilename('fullpath')));
if nargin < 1
    source_file = fullfile(fileparts(media_dir), 'Video.mp4');
end
if nargin < 2
    work_dir = fullfile(media_dir, 'work');
end
if ~isfolder(work_dir)
    mkdir(work_dir);
end

[source, fs] = audioread(source_file);
assert(fs == 48000, 'Expected 48 kHz input; no resampling is performed.');
assert(~isempty(source) && all(isfinite(source), 'all'), 'Invalid audio samples.');
mono = mean(source, 2);
pcm = int16(round(mono * 32768));
pcm_file = fullfile(work_dir, 'audio_s16le.pcm');
fid = fopen(pcm_file, 'w', 'ieee-le');
assert(fid >= 0, 'Cannot open PCM output.');
close_pcm = onCleanup(@() fclose(fid));
written = fwrite(fid, pcm, 'int16');
clear close_pcm;
assert(written == numel(pcm), 'Incomplete PCM output.');
output = dir(pcm_file);
assert(output.bytes == 2 * numel(pcm), 'Unexpected PCM byte count.');

info = struct('source_file', source_file, 'format', 's16le', ...
    'sample_rate', fs, 'fs', fs, 'channels', 1, 'source_channels', size(source, 2), ...
    'sample_count', numel(pcm), 'duration_seconds', numel(pcm) / fs, ...
    'byte_count', output.bytes, 'peak', max(abs(mono)), ...
    'rms', sqrt(mean(mono .^ 2)), ...
    'source_channel_peak', max(abs(source), [], 1), ...
    'source_channel_rms', sqrt(mean(source .^ 2, 1)), ...
    'pcm_min', double(min(pcm)), 'pcm_max', double(max(pcm)), ...
    'saturated_samples', sum(mono > 32767 / 32768 | mono < -1), ...
    'mix', 'arithmetic channel mean; no gain normalization');
json = jsonencode(info, PrettyPrint=true);
fid = fopen(fullfile(work_dir, 'audio_info.json'), 'w', 'n', 'UTF-8');
assert(fid >= 0, 'Cannot open audio metadata output.');
close_info = onCleanup(@() fclose(fid));
fprintf(fid, '%s\n', json);
clear close_info;
fprintf('%s\n', json);
fprintf('PASS: %d mono samples, %d bytes\n', numel(pcm), output.bytes);
end
