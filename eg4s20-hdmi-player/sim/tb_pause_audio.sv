`timescale 1ns/1ps
module tb_pause_audio;
localparam integer BANK_SAMPLES = 1024;
reg clk=0, sd_clk=0;
always #20 clk=~clk;
always #5 sd_clk=~sd_clk;
reg rst=1, paused=0, compare_baseline=1;
reg pcm_we=0, pcm_bank=0;
reg [12:0] pcm_addr=0;
reg [15:0] pcm_data=0;
reg ready_toggle=0, ready_bank=0, ready_last=0;
reg [31:0] ready_number=0;
reg read_req=0, read_ack=1;
wire frame_ack, display_valid, audio_valid;
wire [1:0] disp_bank;
wire [31:0] sample_count;
wire [23:0] left_data, right_data;
wire [3:0] play_state;
avp_audio #(.SAMPLES_PER_FRAME(BANK_SAMPLES)) dut (
    .video_clk(clk), .rst(rst), .paused(paused), .sd_clk(sd_clk),
    .pcm_we(pcm_we), .pcm_bank(pcm_bank), .pcm_addr(pcm_addr), .pcm_data(pcm_data),
    .frame_ready_toggle(ready_toggle), .frame_ready_bank(ready_bank), .frame_ready_last(ready_last),
    .frame_ready_number(ready_number), .frame_ack_toggle(frame_ack),
    .video_read_req(read_req), .video_read_req_ack(read_ack), .disp_buf_idx(disp_bank),
    .display_valid(display_valid), .sample_count(sample_count), .audio_valid(audio_valid),
    .audio_left_data(left_data), .audio_right_data(right_data), .play_state(play_state));
wire baseline_ack, baseline_display, baseline_valid;
wire [1:0] baseline_bank;
wire [31:0] baseline_count;
wire [23:0] baseline_left, baseline_right;
wire [3:0] baseline_state;
avp_audio_baseline #(.SAMPLES_PER_FRAME(BANK_SAMPLES), .AUDIO_SHIFT(0)) baseline (
    .video_clk(clk), .rst(rst), .sd_clk(sd_clk),
    .pcm_we(pcm_we), .pcm_bank(pcm_bank), .pcm_addr(pcm_addr), .pcm_data(pcm_data),
    .frame_ready_toggle(ready_toggle), .frame_ready_bank(ready_bank), .frame_ready_last(ready_last),
    .frame_ready_number(ready_number), .frame_ack_toggle(baseline_ack),
    .video_read_req(read_req), .video_read_req_ack(read_ack), .disp_buf_idx(baseline_bank),
    .display_valid(baseline_display), .sample_count(baseline_count), .audio_valid(baseline_valid),
    .audio_left_data(baseline_left), .audio_right_data(baseline_right), .play_state(baseline_state));

function integer pcm_value;
    input integer number, address;
    begin
        case(number)
            0: pcm_value=12000+address;
            1: pcm_value=-18000-address;
            default: pcm_value=6000+address;
        endcase
    end
endfunction

integer accumulator=0, old_count=0, ticks=0, real_samples=0, paused_ticks=0;
integer cases=0, expected_sample, saved_count, saved_addr;
reg expected_valid, saved_bank, saved_active, saved_started, saved_ack, saved_wait, saved_ack_low;
reg [1:0] saved_display;
reg saved_display_valid;
always @(posedge clk) begin
    saved_count=sample_count; saved_addr=dut.read_addr; saved_bank=dut.active_bank;
    saved_display=disp_bank; saved_display_valid=display_valid;
    saved_active=dut.active; saved_started=dut.started;
    saved_ack=frame_ack; saved_wait=dut.waiting_display_ack; saved_ack_low=dut.ack_low_seen;
    if(rst) begin accumulator=0; old_count=0; expected_valid=0; end
    else begin
        accumulator=accumulator+48000;
        expected_valid=accumulator>=25000000;
        if(expected_valid) accumulator=accumulator-25000000;
    end
    #1;
    if(!rst) begin
        if(audio_valid!==expected_valid) $fatal(1,"48k tick paused, skipped or duplicated");
        if(play_state!==(dut.ended ? 4'd8 : paused ? 4'd9 : dut.active ? 4'd6 : 4'd7))
            $fatal(1,"Pause/EOF status priority wrong");
        if(paused) begin
            if(sample_count!=saved_count || dut.read_addr!=saved_addr || dut.active_bank!==saved_bank ||
               disp_bank!==saved_display || display_valid!==saved_display_valid ||
               dut.active!==saved_active || dut.started!==saved_started) $fatal(1,"Pause advanced PCM/subtitle position or frame commit");
            if(frame_ack!==saved_ack && !(saved_wait && saved_ack_low && read_ack))
                $fatal(1,"Pause acknowledged an uncommitted frame");
        end
        if(audio_valid) begin
            ticks=ticks+1;
            if(left_data!==right_data) $fatal(1,"Stereo sample pair changed");
            if(paused) begin
                paused_ticks=paused_ticks+1;
                if(left_data!==0) $fatal(1,"Pause emitted nonzero PCM");
            end
            if(sample_count==old_count+1) begin
                expected_sample=pcm_value(old_count/BANK_SAMPLES,old_count%BANK_SAMPLES)*256;
                if(left_data!==24'(expected_sample)) $fatal(1,"PCM lost/duplicated at sample %0d",old_count);
                real_samples=real_samples+1;
            end else if(sample_count==old_count) begin
                if(left_data!==0) $fatal(1,"WAIT/pause/EOF emitted nonzero PCM");
            end else $fatal(1,"Consumed sample counter jumped");
        end else if(sample_count!=old_count) $fatal(1,"Consumed PCM without audio_valid");
        old_count=sample_count;
        if(compare_baseline && {frame_ack,display_valid,audio_valid,disp_bank,sample_count,left_data,right_data,play_state} !==
             {baseline_ack,baseline_display,baseline_valid,baseline_bank,baseline_count,baseline_left,baseline_right,baseline_state})
            $fatal(1,"Unpaused outputs differ from original video_wave RTL");
    end
end

task reset_case;
    input integer pause_at_reset;
    begin
        @(negedge clk); rst=1; paused=pause_at_reset;
        pcm_we=0; ready_toggle=0; ready_bank=0; ready_last=0; ready_number=0; read_req=0; read_ack=1;
        repeat(8) @(negedge clk);
        rst=0;
        repeat(8) @(negedge clk);
    end
endtask
task fill_bank;
    input integer bank, number;
    integer address;
    begin
        for(address=0;address<BANK_SAMPLES;address=address+1) begin
            @(negedge sd_clk); pcm_we=1; pcm_bank=bank; pcm_addr=address; pcm_data=16'(pcm_value(number,address));
        end
        @(negedge sd_clk); pcm_we=0;
    end
endtask
task publish;
    input integer bank, number, last;
    begin
        @(negedge sd_clk); ready_bank=bank; ready_number=number; ready_last=last; ready_toggle=~ready_toggle;
        wait(dut.pending_valid);
        @(negedge clk);
        if(dut.pending_bank!==bank[0] || dut.pending_number!=number || dut.pending_last!==last[0])
            $fatal(1,"Pending ready frame metadata lost");
    end
endtask
task request_frame;
    begin
        @(negedge clk); read_req=1;
        repeat(2) @(negedge clk);
        read_req=0;
        repeat(2) @(negedge clk);
    end
endtask
task drain_ack;
    input integer token;
    begin
        @(negedge clk); read_ack=0;
        repeat(3) @(negedge clk);
        read_ack=1;
        repeat(3) @(negedge clk);
        if(frame_ack!==token[0] || dut.waiting_display_ack) $fatal(1,"In-flight display ACK did not drain safely");
    end
endtask
task wait_ticks;
    input integer amount;
    integer done;
    begin
        done=0;
        while(done<amount) begin
            @(negedge clk);
            if(audio_valid) done=done+1;
        end
    end
endtask
task pause_for_ticks;
    input integer amount;
    begin
        @(negedge clk); paused=1;
        wait_ticks(amount);
        @(negedge clk); paused=0;
    end
endtask

initial begin
    // Exact behavioral comparison with original RTL for the whole unpaused stream.
    reset_case(0); fill_bank(0,0); fill_bank(1,1); publish(0,0,0);
    request_frame; drain_ack(1); publish(1,1,1);
    wait(sample_count==BANK_SAMPLES); request_frame; drain_ack(0);
    wait(dut.ended); wait_ticks(4);
    if(sample_count!=2048) $fatal(1,"Unpaused dual-bank playback incomplete");
    cases=cases+1; compare_baseline=0;

    // Paused before start, stale-high/in-flight ACK, midstream, final sample,
    // pending display commit and prefetch of a third bank all use actual PCM RAM.
    reset_case(1); fill_bank(0,0); fill_bank(1,1); publish(0,0,0);
    request_frame; wait_ticks(5);
    if(dut.started || display_valid || frame_ack || !dut.pending_valid) $fatal(1,"Pre-start pause consumed/acknowledged a frame");
    @(negedge clk); paused=0;
    request_frame;
    @(negedge clk); paused=1;
    wait_ticks(2);
    if(!dut.waiting_display_ack || frame_ack) $fatal(1,"Stale high ACK released a bank");
    drain_ack(1); publish(1,1,0); request_frame; wait_ticks(2);
    if(!dut.pending_valid || dut.active_bank || disp_bank!=0) $fatal(1,"Paused ready prefetch advanced active/display bank");
    @(negedge clk); paused=0;
    wait(sample_count==100); pause_for_ticks(5);
    wait(sample_count==1023);
    @(negedge clk); paused=1; wait_ticks(4);
    if(dut.read_addr!=1023 || dut.active_bank || !dut.pending_valid) $fatal(1,"Pause before last sample switched banks");
    @(negedge clk); paused=0;
    wait(sample_count==1024);
    @(negedge clk); paused=1;
    request_frame; wait_ticks(3);
    if(disp_bank!=0 || !dut.display_pending || frame_ack!==1'b1) $fatal(1,"Paused pending display committed or released bank");
    @(negedge clk); paused=0;
    request_frame;
    @(negedge clk); paused=1;
    if(disp_bank!=1 || !dut.waiting_display_ack) $fatal(1,"Resumed display failed to commit");
    drain_ack(0);
    fill_bank(0,2); publish(0,2,1); request_frame; wait_ticks(3);
    if(!dut.pending_valid || dut.active_bank!==1'b1 || disp_bank!=1) $fatal(1,"Second paused prefetch overwrote active/display bank");
    @(negedge clk); paused=0;
    wait(sample_count==2047); pause_for_ticks(4);
    wait(sample_count==2048); request_frame; drain_ack(1);
    wait(dut.ended); pause_for_ticks(4); wait_ticks(4);
    if(sample_count!=3072 || play_state!=8) $fatal(1,"Resume/EOF restarted or lost PCM");
    cases=cases+1;

    // An underrun's new ready frame must stay pending until resume.
    reset_case(0); fill_bank(0,0); fill_bank(1,1); publish(0,0,0);
    request_frame; drain_ack(1);
    wait(sample_count==1024 && !dut.active);
    @(negedge clk); paused=1;
    publish(1,1,1); request_frame; wait_ticks(4);
    if(dut.active || !dut.pending_valid || dut.display_pending || disp_bank!=0) $fatal(1,"Paused underrun resumed/committed a ready frame");
    @(negedge clk); paused=0;
    wait(dut.active); request_frame; drain_ack(0);
    wait(dut.ended); wait_ticks(4);
    if(sample_count!=2048) $fatal(1,"Underrun resume lost PCM");
    cases=cases+1;

    // EOF is deferred if its final real sample is paused, then stays EOF on resume.
    reset_case(0); fill_bank(0,0); publish(0,0,1); request_frame; drain_ack(1);
    wait(sample_count==1023);
    @(negedge clk); paused=1; wait_ticks(4);
    if(dut.ended || !dut.active || dut.read_addr!=1023) $fatal(1,"Pause prematurely reached EOF");
    @(negedge clk); paused=0;
    wait(dut.ended);
    @(negedge clk); paused=1; wait_ticks(4);
    if(play_state!=8 || sample_count!=1024) $fatal(1,"EOF status lost to pause");
    @(negedge clk); paused=0; wait_ticks(4);
    if(play_state!=8 || sample_count!=1024) $fatal(1,"EOF resumed as playback");
    cases=cases+1;
    if(cases!=4 || real_samples!=8192 || paused_ticks<40) $fatal(1,"Pause cases/sample coverage incomplete");
    $display("PASS pause audio: four cases, %0d exact real PCM samples, %0d continuous48k ticks (%0d paused zero ticks), baseline parity, ready/ACK/bank boundaries, underrun and EOF resume",real_samples,ticks,paused_ticks);
    $finish;
end
initial begin #300000000; $fatal(1,"Pause audio timeout"); end
endmodule
