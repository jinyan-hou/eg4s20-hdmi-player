`timescale 1ns/1ps
module tb_show_video;
localparam integer PCM_SAMPLES = 1024;
reg video_clk = 0, sd_clk = 0;
always #20 video_clk = ~video_clk;
always #5 sd_clk = ~sd_clk;
reg rst = 1, mode_video = 1, replay_negative = 0;
reg pcm_we = 0, pcm_bank = 0;
reg [12:0] pcm_addr = 0;
reg [15:0] pcm_data = 0;
reg ready_toggle = 0, ready_bank = 0, ready_last = 0;
reg [31:0] ready_number = 0;
reg read_req = 0, read_ack = 0;
wire frame_ack, av_valid, audio_valid;
wire [1:0] disp_bank;
wire [31:0] sample_count;
wire [23:0] audio_left, audio_right;
wire [3:0] play_state;
avp_audio #(.SAMPLES_PER_FRAME(PCM_SAMPLES), .AUDIO_SHIFT(0)) audio (
    .video_clk(video_clk), .rst(rst), .paused(1'b0), .sd_clk(sd_clk),
    .pcm_we(pcm_we), .pcm_bank(pcm_bank), .pcm_addr(pcm_addr), .pcm_data(pcm_data),
    .frame_ready_toggle(ready_toggle), .frame_ready_bank(ready_bank), .frame_ready_last(ready_last),
    .frame_ready_number(ready_number), .frame_ack_toggle(frame_ack),
    .video_read_req(read_req), .video_read_req_ack(read_ack), .disp_buf_idx(disp_bank),
    .display_valid(av_valid), .sample_count(sample_count), .audio_valid(audio_valid),
    .audio_left_data(audio_left), .audio_right_data(audio_right), .play_state(play_state));

integer ack_delay = 0;
always @(posedge video_clk) begin
    if (rst) begin read_ack <= 0; ack_delay <= 0; end
    else if (read_req) begin read_ack <= 0; ack_delay <= 5; end
    else if (ack_delay != 0) begin
        ack_delay <= ack_delay - 1;
        if (ack_delay == 1) read_ack <= 1;
    end
end

reg in_hs = 1, in_vs = 1, in_de = 0;
reg [23:0] in_rgb = 0;
wire subtitle_hs, subtitle_vs, subtitle_de, bright_hs, bright_vs, bright_de;
wire out_hs, out_vs, out_de, axis_user, axis_valid, axis_last;
wire [23:0] subtitle_rgb, bright_rgb, out_rgb, axis_data;
wire wave_enable = mode_video && av_valid;
avp_subtitles subtitles (
    .video_clk(video_clk), .rst(rst), .sd_clk(sd_clk),
    .meta_we(1'b0), .meta_addr(13'd0), .meta_data(8'd0), .enable(1'b0), .sample_count(sample_count),
    .in_hs(in_hs), .in_vs(in_vs), .in_de(in_de), .in_rgb(in_rgb),
    .out_hs(subtitle_hs), .out_vs(subtitle_vs), .out_de(subtitle_de), .out_rgb(subtitle_rgb));
brightness_osd brightness (
    .video_clk(video_clk), .rst(rst), .enable(1'b1), .brightness_gray(2'b00),
    .fade_level(5'd16), .mode_video(1'b1), .video_paused(1'b0),
    .video_ended(play_state==8), .auto_play(1'b1),
    .in_hs(subtitle_hs), .in_vs(subtitle_vs), .in_de(subtitle_de), .in_rgb(subtitle_rgb),
    .out_hs(bright_hs), .out_vs(bright_vs), .out_de(bright_de), .out_rgb(bright_rgb));
audio_waveform wave (
    .video_clk(video_clk), .rst(rst), .enable(wave_enable), .audio_valid(audio_valid), .audio_data(audio_left),
    .in_hs(bright_hs), .in_vs(bright_vs), .in_de(bright_de), .in_rgb(bright_rgb),
    .out_hs(out_hs), .out_vs(out_vs), .out_de(out_de), .out_rgb(out_rgb));
video_rgb_to_axis_640x480 axis (
    .I_clk(video_clk), .I_rst(rst), .I_vs(out_vs), .I_de(out_de), .I_rgb(out_rgb),
    .O_video_user(axis_user), .O_video_valid(axis_valid), .O_video_last(axis_last), .O_video_data(axis_data));

function integer original_pcm;
    input integer bank, address;
    begin original_pcm = bank || replay_negative ? -24576-address : 24576+address; end
endfunction
function [23:0] source_pixel;
    input integer px, py;
    begin source_pixel = {8'(px), 8'(py), 8'(px+py)}; end
endfunction
function [23:0] dim_pixel;
    input integer px, py;
    begin dim_pixel = {8'((px%256)/4), 8'((py%256)/4), 8'(((px+py)%256)/4)}; end
endfunction

// The reference stores complete vectors; it has no RTL RAM, banks or read pipeline.
integer capture_vector[0:383], display_vector[0:383];
integer captured = 0, decimation_phase = 0, reference_y, j;
reg reference_pending = 0, reference_valid = 0;
integer swaps = 0, positive_vectors = 0, silent_vectors = 0;
reg all_positive, all_silent;
reg saved_display_bank = 1;
always @(posedge video_clk) begin
    if (rst || !wave_enable) begin
        captured = 0; decimation_phase = 0; reference_pending = 0; reference_valid = 0;
    end else if (reference_pending) begin
        if (!bright_vs) begin
            all_positive = 1; all_silent = 1;
            for (j=0; j<384; j=j+1) begin
                display_vector[j] = capture_vector[j];
                if (capture_vector[j] != 20) all_positive = 0;
                if (capture_vector[j] != 40) all_silent = 0;
            end
            swaps = swaps + 1;
            if (all_positive) positive_vectors = positive_vectors + 1;
            if (all_silent) silent_vectors = silent_vectors + 1;
            captured = 0; decimation_phase = 0; reference_pending = 0; reference_valid = 1;
        end
    end else if (audio_valid) begin
        decimation_phase = decimation_phase + 1;
        if (decimation_phase == 2) begin
            decimation_phase = 0;
            reference_y = $signed(audio_left) / 262144;
            // The fixed test PCM values are divisible by 262144 only at address zero;
            // floor toward -infinity matches an arithmetic shift for negative PCM.
            if ($signed(audio_left) < 0 && ($signed(audio_left) % 262144) != 0) reference_y = reference_y - 1;
            if (reference_y > 20) reference_y = 20;
            if (reference_y < -20) reference_y = -20;
            capture_vector[captured] = 40-reference_y;
            captured = captured + 1;
            if (captured == 384) reference_pending = 1;
        end
    end
    if (!rst && wave.sample_we && wave.display_valid && wave.capture_bank == wave.display_bank)
        $fatal(1, "Wave capture wrote the displayed bank");
    #1;
    if (!rst && wave_enable && wave.display_bank != saved_display_bank && bright_vs)
        $fatal(1, "Wave bank changed outside VS blank");
    saved_display_bank = wave.display_bank;
end

integer audio_accumulator = 0, old_consumed = 0, ticks = 0, real_samples = 0;
integer wait_zeros = 0, eof_zeros = 0, expected_pcm, bank_number, bank_address;
reg expected_audio_valid;
always @(posedge video_clk) begin
    if (rst) begin audio_accumulator = 0; old_consumed = 0; expected_audio_valid = 0; end
    else begin
        audio_accumulator = audio_accumulator + 48000;
        expected_audio_valid = audio_accumulator >= 25000000;
        if (expected_audio_valid) audio_accumulator = audio_accumulator - 25000000;
    end
    #1;
    if (!rst) begin
        if (audio_valid !== expected_audio_valid) $fatal(1, "48 kHz sample tick skipped or duplicated");
        if (audio_valid) begin
            ticks = ticks + 1;
            if (audio_right !== audio_left) $fatal(1, "Stereo sample mismatch");
            if (sample_count == old_consumed + 1) begin
                bank_number = old_consumed / PCM_SAMPLES; bank_address = old_consumed % PCM_SAMPLES;
                expected_pcm = original_pcm(bank_number, bank_address) * 256;
                if (audio_left !== 24'(expected_pcm)) $fatal(1, "PCM missing/corrupted at sample %0d: %h vs %h",old_consumed,audio_left,24'(expected_pcm));
                real_samples = real_samples + 1;
            end else if (sample_count == old_consumed) begin
                if (audio_left !== 0) $fatal(1, "WAIT/EOF emitted nonzero PCM");
                if (play_state == 8) eof_zeros = eof_zeros + 1;
                else wait_zeros = wait_zeros + 1;
            end else $fatal(1, "Consumed sample counter skipped samples");
        end else if (sample_count != old_consumed) $fatal(1, "PCM consumed without valid");
        old_consumed = sample_count;
    end
end

integer frame_pixels = 0, frame_lines = 0, frame_sofs = 0, frames = 0, total_pixels = 0;
integer x, y, column, upper_y, lower_y, positive_hits = 0, negative_hits = 0, silent_hits = 0;
reg [8:0] hs_history = 9'h1ff, vs_history = 9'h1ff, de_history = 0;
reg [23:0] expected_axis_rgb, expected_rgb;
reg trace_hit, digit_white;
always @(posedge video_clk) begin
    expected_axis_rgb = out_rgb;
    if (rst) begin hs_history=9'h1ff; vs_history=9'h1ff; de_history=0; end
    else begin
        hs_history={hs_history[7:0],in_hs};
        vs_history={vs_history[7:0],in_vs};
        de_history={de_history[7:0],in_de};
    end
    #1;
    if (rst) begin
        if ({axis_user,axis_valid,axis_last,axis_data} !== 27'd0) $fatal(1, "AXIS reset outputs");
    end else begin
        if ({out_hs,out_vs,out_de} !== {hs_history[7],vs_history[7],de_history[7]}) $fatal(1, "Wave RGB/sync latency mismatch");
        if (axis_valid !== de_history[8] || axis_data !== expected_axis_rgb) $fatal(1, "AXIS RGB/data alignment mismatch");
        if (axis_valid) begin
            x=frame_pixels%640; y=frame_pixels/640;
            if (axis_last !== (x==639) || axis_user !== (frame_pixels==0)) $fatal(1, "AXIS marker mismatch at (%0d,%0d)",x,y);
            if (x>=16 && x<208 && y>=16 && y<66) begin
                if ((x==140 && y==24) || (x==152 && (y==24 || y==26 || y==28))) begin
                    digit_white=x==152 && y==26;
                    if (axis_data !== (digit_white ? 24'hffffff : 24'd0)) $fatal(1, "Existing 25 percent brightness label changed");
                end
            end else begin
                expected_rgb=dim_pixel(x,y);
                if (wave_enable && x>=240 && x<624 && y>=16 && y<64) begin
                    column=x-240; trace_hit=0;
                    if (reference_valid) begin
                        upper_y=display_vector[column]; lower_y=column==0 ? upper_y : display_vector[column-1];
                        trace_hit=(y>=upper_y && y<=lower_y) || (y<=upper_y && y>=lower_y);
                    end
                    expected_rgb=trace_hit ? 24'h40ff80 : (x==240 || x==623 || y==16 || y==63) ? 24'h234536 : y==40 ? 24'h163323 : 24'd0;
                    if (trace_hit && y==20) positive_hits=positive_hits+1;
                    if (trace_hit && y==60) negative_hits=negative_hits+1;
                    if (trace_hit && y==40) silent_hits=silent_hits+1;
                end
                if (axis_data !== expected_rgb) $fatal(1, "Pixel changed frame=%0d (%0d,%0d) actual=%h expected=%h",frames,x,y,axis_data,expected_rgb);
            end
            frame_pixels=frame_pixels+1; total_pixels=total_pixels+1;
            if (axis_last) frame_lines=frame_lines+1;
            if (axis_user) frame_sofs=frame_sofs+1;
        end else if (axis_last || axis_user) $fatal(1, "AXIS markers outside valid");
    end
end

task fill_bank;
    input integer bank;
    integer address;
    begin
        for (address=0; address<PCM_SAMPLES; address=address+1) begin
            @(negedge sd_clk); pcm_we=1; pcm_bank=bank; pcm_addr=address; pcm_data=16'(original_pcm(bank,address));
        end
        @(negedge sd_clk); pcm_we=0;
    end
endtask
task publish_bank;
    input integer bank, last, number;
    begin
        @(negedge sd_clk); ready_bank=bank; ready_last=last; ready_number=number; ready_toggle=~ready_toggle;
    end
endtask
task send_frame;
    integer v,h;
    begin
        frame_pixels=0; frame_lines=0; frame_sofs=0;
        for(v=0; v<525; v=v+1)
            for(h=0; h<800; h=h+1) begin
                @(negedge video_clk);
                read_req=v==0 && h==0;
                in_hs=h>=96; in_vs=v>=2;
                in_de=v>=35 && v<515 && h>=144 && h<784;
                in_rgb=in_de ? source_pixel(h-144,v-35) : 0;
            end
        @(negedge video_clk); read_req=0; in_hs=1; in_vs=1; in_de=0; in_rgb=0;
        repeat(12) @(negedge video_clk);
        if(frame_pixels!=307200 || frame_lines!=480 || frame_sofs!=1) $fatal(1,"Frame counts: %0d pixels %0d TLAST %0d SOF",frame_pixels,frame_lines,frame_sofs);
        frames=frames+1;
    end
endtask
task reset_playback;
    begin
        @(negedge video_clk); rst=1; read_req=0; ready_toggle=0; ready_bank=0; ready_last=0; ready_number=0;
        repeat(8) @(negedge video_clk);
        if(wave.display_valid || wave.pending || wave.write_index!=0) $fatal(1,"Reset left stale waveform state");
        rst=0;
        repeat(8) @(negedge video_clk);
    end
endtask

integer f;
initial begin
    repeat(8) @(negedge video_clk); rst=0;
    fork
        begin
            fill_bank(0); fill_bank(1); publish_bank(0,0,0);
            wait(frame_ack==1); publish_bank(1,1,1);
            wait(frame_ack==0);
        end
        begin for(f=0;f<6;f=f+1) send_frame; end
    join
    if(sample_count!=2048 || play_state!=8) $fatal(1,"PCM producer did not play both banks through EOF");
    if(positive_vectors<1 || silent_vectors<1 || positive_hits<384 || negative_hits<384 || silent_hits<384)
        $fatal(1,"Wave positive/negative/silent traces not exercised");
    if(wait_zeros<768 || eof_zeros<768) $fatal(1,"WAIT/EOF silence too short to exercise complete captures");
    mode_video=0; reset_playback; send_frame;
    if(wave.display_valid || wave.pending) $fatal(1,"Image mode retained stale waveform");
    mode_video=1; replay_negative=1; reset_playback;
    fill_bank(0); publish_bank(0,1,0);
    wait(audio.pending_valid);
    send_frame;
    if(wave.display_valid) $fatal(1,"Replay displayed an old bank before a fresh complete capture/VS");
    @(negedge video_clk); in_vs=0;
    repeat(12) @(negedge video_clk);
    if(!wave.display_valid || !reference_valid) $fatal(1,"Replay capture did not commit during VS blank");
    if(frames!=8 || total_pixels!=2457600) $fatal(1,"Eight-frame integration count mismatch");
    $display("PASS show video: eight full frames, %0d exact 48k ticks, %0d real PCM samples, WAIT/EOF silence, signed extrema/zero vectors, RGB/OSD/AXIS alignment and mode/replay reset safety",ticks,real_samples);
    $finish;
end
initial begin #200000000; $fatal(1,"Wave integration timeout"); end
endmodule
