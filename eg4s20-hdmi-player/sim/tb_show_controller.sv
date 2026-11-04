`timescale 1ns/1ps
module tb_show_controller;
reg video_clk=0, sd_clk=0;
always #20 video_clk=~video_clk;
always #5 sd_clk=~sd_clk;
reg rst=1, enable=1, short_toggle=0, auto_toggle=0, ready_toggle=0, ready_bank=0;
reg [2:0] image_count=0;
reg read_req=0, read_req_ack=1;
wire next_toggle, ack_toggle, display_bank, display_valid, auto_play;
wire [4:0] fade_level;
show_controller #(.HOLD_FRAMES(3)) ctrl (.*);
integer unit_commits=0, unit_nexts=0, unit_fades=0;
reg old_bank, old_valid, old_ack, old_next, old_wait, old_ack_low, sampled_tick;
reg [4:0] old_fade;
always @(posedge video_clk) begin
    old_bank=display_bank; old_valid=display_valid; old_fade=fade_level;
    old_ack=ack_toggle; old_next=next_toggle;
    old_wait=ctrl.waiting_ack; old_ack_low=ctrl.ack_low_seen;
    sampled_tick=read_req && !ctrl.read_req_last;
    #1;
    if(!rst && enable) begin
        if((old_bank!=display_bank || old_valid!=display_valid) && !sampled_tick)
            $fatal(1,"Display bank/valid changed outside frame read edge");
        if(fade_level!=old_fade) begin
            if(!sampled_tick || (fade_level!=old_fade+1 && fade_level+1!=old_fade)) $fatal(1,"Fade changed outside frame edge or skipped level");
            unit_fades=unit_fades+1;
        end
        if(old_bank!=display_bank || (!old_valid && display_valid)) begin
            unit_commits=unit_commits+1;
            if(old_valid && fade_level!=0) $fatal(1,"Next image committed before black fade");
        end
        if(ack_toggle!=old_ack && !(old_wait && old_ack_low && read_req_ack)) $fatal(1,"ACK released an unlatched image bank");
        if(next_toggle!=old_next) begin
            if(!(old_wait && old_ack_low && read_req_ack)) $fatal(1,"Prefetch requested before safe display ACK");
            unit_nexts=unit_nexts+1;
        end
        if(fade_level>16) $fatal(1,"Fade escaped0..16");
    end
end

task reset_unit;
    input integer count;
    begin
        @(negedge video_clk); rst=1; enable=1; short_toggle=0; auto_toggle=0; ready_toggle=0; ready_bank=0;
        image_count=count; read_req=0; read_req_ack=1;
        repeat(6) @(negedge video_clk); rst=0;
        repeat(6) @(negedge video_clk);
    end
endtask
task frame;
    begin
        @(negedge video_clk); read_req=1;
        repeat(3) @(negedge video_clk); read_req=0;
        repeat(5) @(negedge video_clk);
    end
endtask
task publish;
    input integer bank;
    begin
        @(negedge video_clk); ready_bank=bank; ready_toggle=~ready_toggle;
        repeat(6) @(negedge video_clk);
        if(!ctrl.pending_ready || ctrl.pending_bank!==bank[0]) $fatal(1,"Prepared bank not held through CDC");
    end
endtask
task ack;
    begin
        @(negedge video_clk); read_req_ack=0;
        repeat(3) @(negedge video_clk); read_req_ack=1;
        repeat(3) @(negedge video_clk);
        if(ctrl.waiting_ack) $fatal(1,"Fresh low/high ACK not accepted");
    end
endtask
task short_press;
    begin @(negedge video_clk); short_toggle=~short_toggle; repeat(6) @(negedge video_clk); end
endtask
task auto_press;
    begin @(negedge video_clk); auto_toggle=~auto_toggle; repeat(6) @(negedge video_clk); end
endtask
task fade_down;
    integer amount;
    begin
        for(amount=15;amount>=0;amount=amount-1) begin
            frame;
            if(fade_level!=amount) $fatal(1,"Fade-out level wrong: %0d expected %0d",fade_level,amount);
        end
    end
endtask
task fade_up;
    integer amount;
    begin
        for(amount=1;amount<=16;amount=amount+1) begin
            frame;
            if(fade_level!=amount) $fatal(1,"Fade-in level wrong: %0d expected %0d",fade_level,amount);
        end
    end
endtask

// Actual SD manager/parser integration, with the peer-reviewed 4x2 BMP sector fixture.
reg int_rst=1, int_enable=0, sd_init_done=0;
reg int_read_req=0, int_read_ack=1, write_req_ack=0, write_finish_toggle=0;
wire int_next, int_ack, int_ready, int_ready_bank, int_display, int_bank, int_auto;
wire [4:0] int_fade;
wire [2:0] int_count;
wire mgr_display, write_req, write_en, sd_req, sd_stop;
wire [1:0] write_bank, mgr_bank;
wire [3:0] mgr_state;
wire [31:0] write_data, sd_lba;
reg [7:0] sd_data=0;
reg sd_valid=0, sd_end=0;
show_controller #(.HOLD_FRAMES(3)) integrated_ctrl (
    .video_clk(video_clk), .rst(int_rst), .enable(int_enable), .short_toggle(1'b0), .auto_toggle(1'b0),
    .ready_toggle(int_ready), .ready_bank(int_ready_bank), .image_count(int_count),
    .read_req(int_read_req), .read_req_ack(int_read_ack), .next_toggle(int_next), .ack_toggle(int_ack),
    .display_bank(int_bank), .display_valid(int_display), .auto_play(int_auto), .fade_level(int_fade));
sd_card_bmp #(.SCAN_START_SECTOR(0),.SCAN_MAX_SECTOR(9),.SCAN_TARGET_COUNT(4)) manager (
    .clk(sd_clk),.rst(int_rst),.next_toggle(int_next),.commit_ack_toggle(int_ack),
    .ready_toggle(int_ready),.ready_bank(int_ready_bank),.image_count(int_count),
    .state_code(mgr_state),.bmp_width(16'd4),.bmp_height(16'd2),.display_valid(mgr_display),
    .write_finish_toggle(write_finish_toggle),.write_buf_idx(write_bank),.disp_buf_idx(mgr_bank),
    .write_req(write_req),.write_req_ack(write_req_ack),.write_en(write_en),.write_data(write_data),
    .sd_init_done(sd_init_done),.sd_sec_read(sd_req),.sd_sec_read_addr(sd_lba),.sd_read_stop(sd_stop),
    .sd_sec_read_data(sd_data),.sd_sec_read_data_valid(sd_valid),.sd_sec_read_end(sd_end));

function automatic [7:0] sector_byte(input integer lba,input integer offset);
    integer id,pixel,channel,value;
    begin
        sector_byte=0; id=(lba-1)/2;
        if(lba>=1 && lba<=7 && lba%2==1) begin
            case(offset)
                0: sector_byte="B"; 1: sector_byte="M"; 2: sector_byte=78;
                10: sector_byte=54; 14: sector_byte=40; 18: sector_byte=4;
                22: sector_byte=2; 26: sector_byte=1; 28: sector_byte=24; 34: sector_byte=24;
                default: if(offset>=54 && offset<78) begin
                    pixel=(offset-54)/3; channel=(offset-54)%3;
                    value=id*40+pixel+1+channel*10; sector_byte=value[7:0];
                end else if(offset>=78) sector_byte=8'hd7;
            endcase
        end
    end
endfunction
reg card_busy=0, served_request=0;
integer cursor=0, serving_sector=0, card_reads=0;
always @(negedge sd_clk) begin
    sd_valid=0; sd_end=0;
    if(int_rst || !sd_init_done) begin card_busy=0; served_request=0; cursor=0; end
    else begin
        if(!sd_req) served_request=0;
        if(!card_busy && sd_req && !served_request) begin
            card_busy=1; served_request=1; cursor=0; serving_sector=sd_lba; card_reads=card_reads+1;
        end else if(card_busy) begin
            if(cursor<512) begin sd_data=sector_byte(serving_sector,cursor); sd_valid=1; cursor=cursor+1; end
            else begin sd_end=1; card_busy=0; end
        end
    end
end
function automatic [31:0] expected_pixel(input integer id,input integer pixel);
    reg [7:0] r,g,b;
    begin b=id*40+pixel+1; g=b+10; r=b+20; expected_pixel={r,g,b,8'd0}; end
endfunction
integer loads=0, pixels=0, finished=0, loaded_id=0, memory_delay=0;
integer early_finishes=0, late_finishes=0, simultaneous_acks=0, manager_commits=0;
reg request_last=0, memory_pending=0, memory_late=0;
reg [1:0] memory_bank;
reg manager_ack_edge, manager_simultaneous;
always @(posedge sd_clk) begin
    if(int_rst) begin
        write_req_ack<=0; write_finish_toggle<=0; request_last=0; memory_pending=0;
        loads=0; finished=0; pixels=0; manager_commits=0;
    end else begin
        manager_ack_edge=manager.ready_pending && manager.ack_event;
        manager_simultaneous=manager_ack_edge && manager.next_event;
        write_req_ack<=write_req;
        if(write_req && !request_last) begin
            if(manager.ready_pending || (int_display && write_bank[0]==int_bank)) $fatal(1,"Manager overwrote held/displayed bank");
            loaded_id=(sd_lba-1)/2;
            if(loaded_id!=loads%4 || write_bank!=loads%2) $fatal(1,"ACK+next preload sequence wrong: load %0d id %0d bank %0d",loads,loaded_id,write_bank);
            memory_bank=write_bank; memory_late=loads%2;
            loads=loads+1; pixels=0; memory_pending=0; memory_delay=0;
        end
        request_last=write_req;
        if(write_en) begin
            if((int_display && memory_bank[0]==int_bank) || pixels>=8 || write_data!==expected_pixel(loaded_id,pixels))
                $fatal(1,"Real BMP parse/write pixel or bank mismatch");
            pixels=pixels+1;
            if(pixels==8) begin memory_pending=1; memory_delay=0; end
        end else if(memory_pending && (!memory_late || manager.bmp_ready)) begin
            memory_delay=memory_delay+1;
            if((!memory_late && memory_delay==1) || memory_delay==30) begin
                write_finish_toggle<=~write_finish_toggle; memory_pending=0; finished=finished+1;
                if(memory_late) late_finishes=late_finishes+1; else early_finishes=early_finishes+1;
            end
        end
        #1;
        if(manager_ack_edge) begin
            manager_commits=manager_commits+1;
            if(manager.load_start_pulse || manager.img_idx!=(manager_commits-1)%4 || mgr_bank!=(manager_commits-1)%2)
                $fatal(1,"Manager ACK committed/reloaded wrong image in same cycle");
        end
        if(manager_simultaneous) begin
            simultaneous_acks=simultaneous_acks+1;
            if(!manager.next_req_pending) $fatal(1,"Simultaneous real ACK+next request lost");
        end
    end
end

integer ack_delay=0, integrated_commits=0;
reg int_old_bank=0, int_old_display=0, int_tick;
reg [4:0] int_old_fade;
always @(posedge video_clk) begin
    if(int_rst) begin int_read_ack<=1; ack_delay<=0; end
    else if(int_read_req) begin int_read_ack<=0; ack_delay<=7; end
    else if(ack_delay!=0) begin
        ack_delay<=ack_delay-1;
        if(ack_delay==1) int_read_ack<=1;
    end
    int_old_bank=int_bank; int_old_display=int_display; int_old_fade=int_fade;
    int_tick=int_read_req && !integrated_ctrl.read_req_last;
    #1;
    if(!int_rst && int_enable) begin
        if(int_bank!=int_old_bank || (!int_old_display && int_display)) begin
            if(!int_tick || int_bank!==integrated_commits[0] || loaded_id!=integrated_commits%4)
                $fatal(1,"Controller/SD prepared bank commit mismatch");
            if(integrated_commits>0 && int_fade!=0) $fatal(1,"Integrated bank switched before black");
            integrated_commits=integrated_commits+1;
        end
        if(int_fade!=int_old_fade && !int_tick) $fatal(1,"Integrated fade changed during active interval");
    end
end
task integration_frame;
    begin
        @(negedge video_clk); int_read_req=1;
        @(negedge video_clk); int_read_req=0;
        repeat(254) @(negedge video_clk);
    end
endtask

integer i, before_commits, before_nexts;
initial begin
    reset_unit(0); short_press; auto_press; auto_press;
    repeat(20) frame;
    if(display_valid || next_toggle || fade_level!=16) $fatal(1,"Zero images started carousel");
    reset_unit(1); publish(0); frame; ack;
    before_commits=unit_commits; before_nexts=unit_nexts;
    short_press; auto_press; auto_press; repeat(20) frame;
    if(unit_commits!=before_commits || unit_nexts!=before_nexts || fade_level!=16) $fatal(1,"One image rotated/prefetched");

    reset_unit(4); publish(0); frame;
    repeat(4) frame;
    if(!display_valid || next_toggle || !ctrl.waiting_ack) $fatal(1,"First image accepted stale high ACK");
    ack;
    before_commits=unit_commits; before_nexts=unit_nexts;
    repeat(10) begin frame; if(fade_level!=16 || display_bank!=0) $fatal(1,"Late prepared image caused black/loading screen"); end
    publish(1);
    for(i=15;i>=12;i=i-1) begin frame; if(fade_level!=i) $fatal(1,"Initial fade-out skipped level"); end
    auto_press;
    if(auto_play) $fatal(1,"AUTO did not switch off");
    short_press; short_press; short_press;
    for(i=11;i>=0;i=i-1) begin frame; if(fade_level!=i) $fatal(1,"AUTO-off stopped in-flight fade"); end
    frame;
    if(display_bank!=1 || fade_level!=0) $fatal(1,"Prepared bank not committed at black");
    repeat(3) begin frame; if(fade_level!=0) $fatal(1,"Fade-in began before read ACK"); end
    ack; publish(0); fade_up;
    if(ctrl.state!=2 || !ctrl.pending_ready) $fatal(1,"Busy manual presses did not leave exactly one queued transition");
    fade_down; frame; ack; publish(1); fade_up;
    repeat(12) begin frame; if(fade_level!=16 || display_bank!=0) $fatal(1,"Busy presses accumulated extra transitions or AUTO-off rotated"); end
    if(unit_commits!=before_commits+2 || unit_nexts!=before_nexts+2) $fatal(1,"Busy manual queue is not bounded to one extra image");

    auto_press;
    for(i=0;i<3;i=i+1) begin frame; if(fade_level!=16) $fatal(1,"AUTO-on reused an old hold timer"); end
    fade_down; frame; ack; fade_up;
    if(display_bank!=1) $fatal(1,"AUTO-on did not rotate after fresh hold interval");
    @(negedge video_clk); enable=0;
    repeat(6) @(negedge video_clk);
    short_press; auto_press;
    if(display_valid || display_bank || next_toggle || ack_toggle || fade_level!=16 || ctrl.pending_ready || ctrl.manual_pending)
        $fatal(1,"Disable did not clear ownership/tokens");
    @(negedge video_clk); enable=1;
    repeat(6) @(negedge video_clk);
    if(display_valid || ctrl.manual_pending) $fatal(1,"Disabled key events replayed on enable");
    reset_unit(0);
    if(next_toggle || ack_toggle || display_valid || fade_level!=16 || !auto_play) $fatal(1,"Reset defaults wrong");
    @(negedge video_clk); enable=0;

    // Compress only logical frame interval; SD100MHz and video25MHz stay real.
    @(negedge video_clk); int_rst=0; int_enable=1; sd_init_done=1;
    while(integrated_commits<9 || int_fade!=16 || integrated_ctrl.state!=1) integration_frame;
    if(int_count!=4 || manager_commits!=9 || simultaneous_acks<9 || loads!=10 || finished!=10 || early_finishes==0 || late_finishes==0)
        $fatal(1,"Real controller/SD multi-wrap coverage incomplete: commits %0d mgr %0d simultaneous %0d loads %0d finish %0d",integrated_commits,manager_commits,simultaneous_acks,loads,finished);
    if(!manager.ready_pending || loaded_id!=1 || int_bank!=0 || mgr_bank!=0) $fatal(1,"Next image not held in non-displayed bank after wrap");
    @(negedge video_clk); int_enable=0;
    $display("PASS show controller: bounded manual queue, AUTO timer/re-enable, late/no ACK safety, frame-only fade/commit; actual100M SD/BMP +25M controller committed0,1,2,3,0,1,2,3,0 with %0d simultaneous ACK+next events and early/late memory completion",simultaneous_acks);
    $finish;
end
initial begin #10000000; $fatal(1,"Show controller integration timeout"); end
endmodule
