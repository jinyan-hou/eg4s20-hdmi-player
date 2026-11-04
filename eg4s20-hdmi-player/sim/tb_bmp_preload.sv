`timescale 1ns/1ps
module tb_bmp_preload;
reg clk=0;
always #5 clk=~clk;
reg rst=1, sd_init_done=0, next_toggle=0, commit_ack_toggle=0;
reg write_finish_toggle=0, write_req_ack=0;
reg [7:0] sd_sec_read_data=0;
reg sd_sec_read_data_valid=0, sd_sec_read_end=0;
wire ready_toggle, ready_bank, display_valid;
wire [2:0] image_count;
wire [3:0] state_code;
wire [1:0] write_buf_idx, disp_buf_idx;
wire write_req, write_en, sd_sec_read, sd_read_stop;
wire [31:0] write_data, sd_sec_read_addr;
sd_card_bmp #(.CLK_FREQ_HZ(1000),.SCAN_START_SECTOR(0),.SCAN_MAX_SECTOR(9),.SCAN_TARGET_COUNT(4)) dut (
    .clk(clk),.rst(rst),.next_toggle(next_toggle),.commit_ack_toggle(commit_ack_toggle),
    .ready_toggle(ready_toggle),.ready_bank(ready_bank),.image_count(image_count),
    .state_code(state_code),.bmp_width(16'd4),.bmp_height(16'd2),.display_valid(display_valid),
    .write_finish_toggle(write_finish_toggle),.write_buf_idx(write_buf_idx),.disp_buf_idx(disp_buf_idx),
    .write_req(write_req),.write_req_ack(write_req_ack),.write_en(write_en),.write_data(write_data),
    .sd_init_done(sd_init_done),.sd_sec_read(sd_sec_read),.sd_sec_read_addr(sd_sec_read_addr),
    .sd_read_stop(sd_read_stop),.sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),.sd_sec_read_end(sd_sec_read_end));

reg button_in=1;
wire press_pulse, button_level;
key_press_debounce #(.CLK_FREQ_HZ(1000),.DEBOUNCE_MS(3)) button (
    .clk(clk),.rst(rst),.button_in(button_in),.press_pulse(press_pulse),.button_level(button_level));
integer presses=0;
always @(posedge clk) if (!rst && press_pulse) presses=presses+1;

integer catalogue_count=0, memory_late=0;
integer card_bytes=0, card_reads=0, cursor=0, serving_sector=0;
reg card_busy=0, served_request=0;
// Independent sectors contain complete 4x2 BGR BMPs plus trailing SD padding.
function automatic [7:0] sector_byte(input integer lba,input integer offset);
    integer id, pixel, channel, value;
    begin
        sector_byte=0;
        id=(lba-1)/2;
        if (lba>=1 && lba<=7 && lba%2==1 && id<catalogue_count) begin
            case(offset)
                0: sector_byte="B";
                1: sector_byte="M";
                2: sector_byte=78; // 54-byte header plus eight 24-bit pixels.
                10: sector_byte=54;
                14: sector_byte=40;
                18: sector_byte=4;
                22: sector_byte=2;
                26: sector_byte=1;
                28: sector_byte=24;
                34: sector_byte=24;
                default: if (offset>=54 && offset<78) begin
                    pixel=(offset-54)/3; channel=(offset-54)%3;
                    value=id*40+pixel+1+channel*10;
                    sector_byte=value[7:0];
                end else if (offset>=78) sector_byte=8'hd7;
            endcase
        end
    end
endfunction
always @(negedge clk) begin
    sd_sec_read_data_valid=0;
    sd_sec_read_end=0;
    if (rst || !sd_init_done) begin
        card_busy=0; served_request=0; cursor=0;
        if (rst) begin card_reads=0; card_bytes=0; end
    end else begin
        if (!sd_sec_read) served_request=0;
        if (!card_busy && sd_sec_read && !served_request) begin
            card_busy=1; served_request=1; cursor=0;
            serving_sector=sd_sec_read_addr; card_reads=card_reads+1;
        end else if (card_busy) begin
            if (cursor<512) begin
                sd_sec_read_data=sector_byte(serving_sector,cursor);
                sd_sec_read_data_valid=1;
                cursor=cursor+1; card_bytes=card_bytes+1;
            end else begin
                sd_sec_read_end=1; card_busy=0;
            end
        end
    end
end

function automatic [31:0] expected_pixel(input integer id,input integer pixel);
    reg [7:0] r,g,b;
    begin b=id*40+pixel+1; g=b+10; r=b+20; expected_pixel={r,g,b,8'd0}; end
endfunction
integer load_count=0, finished_count=0, pixel_count=0, loaded_id=0, memory_delay=0;
integer loaded_images [0:31];
integer loaded_banks [0:31];
reg request_last=0, memory_pending=0;
reg [1:0] memory_bank=0;
always @(posedge clk) begin
    if (rst) begin
        write_req_ack<=0; write_finish_toggle<=0;
        load_count=0; finished_count=0; pixel_count=0;
        request_last=0; memory_pending=0; memory_delay=0;
    end else begin
        write_req_ack<=write_req;
        if (write_req && !request_last) begin
            if (dut.ready_pending) $fatal(1,"New write request before display ACK");
            if (display_valid && write_buf_idx==disp_buf_idx)
                $fatal(1,"Write request selected displayed bank");
            if (load_count>=32) $fatal(1,"Unexpected repeated loading");
            memory_bank=write_buf_idx;
            loaded_id=(sd_sec_read_addr-1)/2;
            loaded_images[load_count]=loaded_id; loaded_banks[load_count]=write_buf_idx;
            load_count=load_count+1; pixel_count=0;
            memory_pending=0; memory_delay=0;
        end
        request_last=write_req;
        if (write_en) begin
            if (display_valid && memory_bank==disp_buf_idx)
                $fatal(1,"Pixel overwrote displayed bank");
            if (write_buf_idx!=memory_bank || pixel_count>=8)
                $fatal(1,"Pixel count/bank wrong");
            if (write_data!==expected_pixel(loaded_id,pixel_count))
                $fatal(1,"Actual BMP parser pixel %0d image %0d got %h",pixel_count,loaded_id,write_data);
            pixel_count=pixel_count+1;
            if (pixel_count==8) begin memory_pending=1; memory_delay=0; end
        end else if (memory_pending) begin
            if (!memory_late || dut.bmp_ready) begin
                memory_delay=memory_delay+1;
                if ((!memory_late && memory_delay==1) || memory_delay==30) begin
                    write_finish_toggle<=~write_finish_toggle;
                    finished_count=finished_count+1;
                    memory_pending=0;
                end
            end
        end
    end
end

integer publications=0, commits=0, early_completions=0, late_completions=0, simultaneous_commits=0;
reg last_ready=0, held_bank=0;
reg [1:0] prior_disp=0;
reg prior_valid=0, commit_edge=0, simultaneous_edge=0;
always @(posedge clk) begin
    commit_edge=dut.ready_pending && dut.ack_event;
    simultaneous_edge=commit_edge && dut.next_event;
    if (rst) begin
        publications=0; commits=0; last_ready=0;
        prior_disp=0; prior_valid=0; held_bank=0;
    end else begin
        if (dut.load_busy && dut.write_finish_pulse) begin
            if (dut.bmp_ready) late_completions=late_completions+1;
            else early_completions=early_completions+1;
        end
        #1;
        if (commit_edge && dut.load_start_pulse)
            $fatal(1,"ACK/next started load in ACK cycle");
        if (simultaneous_edge) begin
            simultaneous_commits=simultaneous_commits+1;
            if (!dut.next_req_pending) $fatal(1,"Simultaneous ACK+next lost queued request");
        end
        if (sd_init_done) begin
            if (ready_toggle!=last_ready) begin
                if (!dut.bmp_ready || finished_count<=publications || !dut.ready_pending)
                    $fatal(1,"Ready published before BMP and memory both finished");
                if (ready_bank!==loaded_banks[load_count-1][0]) $fatal(1,"Ready bank wrong");
                publications=publications+1; held_bank=ready_bank;
            end else if (dut.ready_pending && ready_bank!=held_bank)
                $fatal(1,"Published metadata changed before ACK");
            if ((disp_buf_idx!=prior_disp || display_valid!=prior_valid) && !commit_edge)
                $fatal(1,"Display committed before controller ACK");
            if (commit_edge) begin
                commits=commits+1;
                if (!display_valid || disp_buf_idx[0]!=ready_bank || dut.load_busy)
                    $fatal(1,"ACK failed to commit pending bank");
            end
        end
        last_ready=ready_toggle; prior_disp=disp_buf_idx; prior_valid=display_valid;
    end
end

task automatic reset_case(input integer count,input integer late);
    begin
        @(negedge clk); rst=1; sd_init_done=0; next_toggle=0; commit_ack_toggle=0;
        catalogue_count=count; memory_late=late; button_in=1;
        repeat(6) @(negedge clk);
        rst=0;
    end
endtask
task automatic request_next;
    begin @(negedge clk); next_toggle=~next_toggle; repeat(10) @(negedge clk); end
endtask
task automatic commit_ready(input bit request_too);
    integer before_load, before_commit;
    begin
        if (!dut.ready_pending) $fatal(1,"Test ACK without published bank");
        before_load=load_count; before_commit=commits;
        @(negedge clk);
        commit_ack_toggle=~commit_ack_toggle;
        if (request_too) next_toggle=~next_toggle;
        wait(commits==before_commit+1);
        if (load_count!=before_load) $fatal(1,"Load started in simultaneous ACK cycle");
        repeat(8) @(negedge clk);
    end
endtask
task automatic wait_ready(input integer count);
    begin wait(publications==count); repeat(4) @(negedge clk); end
endtask
task automatic hold_ready(input integer clocks);
    integer before_load, before_pixels;
    reg token, bank;
    begin
        before_load=load_count; before_pixels=pixel_count; token=ready_toggle; bank=ready_bank;
        repeat(clocks) @(negedge clk);
        if (load_count!=before_load || pixel_count!=before_pixels ||
            ready_toggle!=token || ready_bank!=bank || !dut.ready_pending)
            $fatal(1,"No-ACK hold reloaded/overwrote metadata");
    end
endtask
integer i, before_load;
initial begin
    reset_case(0,0);
    repeat(50) @(negedge clk);
    if (card_reads || load_count || image_count || display_valid) $fatal(1,"SD not ready started work");
    request_next();
    sd_init_done=1;
    wait(dut.scan_done); repeat(20) @(negedge clk);
    if (image_count!=0 || load_count!=0 || ready_toggle!=0) $fatal(1,"Zero image scan");
    request_next(); repeat(30) @(negedge clk);
    if (load_count) $fatal(1,"Zero images loaded");

    reset_case(1,0); sd_init_done=1;
    wait_ready(1);
    if (image_count!=1 || loaded_images[0]!=0 || loaded_banks[0]!=0 || display_valid)
        $fatal(1,"First image/count/bank/commit wrong");
    hold_ready(700);
    request_next(); request_next(); request_next();
    if (!dut.next_req_pending || load_count!=1) $fatal(1,"Busy next requests not held once");
    commit_ready(1);
    wait_ready(2);
    if (loaded_images[1]!=0 || loaded_banks[1]!=1) $fatal(1,"One-image wrap/bank wrong");
    commit_ready(0);
    before_load=load_count; repeat(800) @(negedge clk);
    if (load_count!=before_load || dut.next_req_pending) $fatal(1,"Busy requests accumulated multiple loads");
    request_next(); wait_ready(3);
    if (loaded_banks[2]!=0 || loaded_images[2]!=0) $fatal(1,"One-image banks failed to alternate");
    commit_ready(0);

    reset_case(4,1); sd_init_done=1;
    wait(dut.bmp_ready && load_count==1 && pixel_count==8);
    repeat(8) @(negedge clk);
    if (ready_toggle!=0 || display_valid || dut.mem_write_done_seen)
        $fatal(1,"Parser finishing early published without memory");
    wait_ready(1);
    if (image_count!=4) $fatal(1,"Four-image count wrong");
    hold_ready(40);
    request_next(); request_next(); request_next();
    commit_ready(1); wait_ready(2);
    if (loaded_images[1]!=1 || loaded_banks[1]!=1) $fatal(1,"ACK+next bank/index wrong");
    commit_ready(0); repeat(700) @(negedge clk);
    if (load_count!=2) $fatal(1,"Four-image busy queue exceeded one");
    memory_late=0;
    for(i=2;i<5;i=i+1) begin
        request_next(); wait_ready(i+1);
        if (loaded_images[i]!=(i%4) || loaded_banks[i]!=(i%2))
            $fatal(1,"Four-image order/bank wrap at %0d",i);
        commit_ready(0);
    end

    // Abort a real parser transfer, then re-enter scan with reset toggle baselines.
    request_next(); wait(load_count==6 && pixel_count>=2);
    reset_case(4,0); repeat(30) @(negedge clk);
    if (load_count || image_count || ready_toggle || display_valid) $fatal(1,"Reset retained work");
    sd_init_done=1; wait_ready(1);
    if (loaded_images[0]!=0 || loaded_banks[0]!=0) $fatal(1,"Reset re-entry skipped first image");
    commit_ready(0);
    @(negedge clk); sd_init_done=0;
    repeat(20) @(negedge clk);
    if (image_count || display_valid || dut.load_busy) $fatal(1,"SD loss retained unsafe state");
    // Preserve external toggle levels while the manager restarts its first scan.
    @(negedge clk); sd_init_done=1;
    wait(load_count==2 && dut.ready_pending);
    if (loaded_images[1]!=0 || loaded_banks[1]!=0) $fatal(1,"SD re-init did not reload first bank0");
    commit_ready(0);

    before_load=presses;
    @(negedge clk); button_in=0;
    wait(!button_level); repeat(5) @(negedge clk);
    if (presses!=before_load+1) $fatal(1,"Debounced press behavior changed");
    @(negedge clk); button_in=1;
    wait(button_level); repeat(4) @(negedge clk);
    if (presses!=before_load+1) $fatal(1,"Release generated press");
    if (!early_completions || !late_completions || simultaneous_commits!=2) $fatal(1,"Completion/ACK+next coverage missing");
    $display("PASS BMP preload: actual BMP parser, scan0/1/4, header/pixels/SD padding, early%0d late%0d memory completion, held ready/no ACK overwrite, one busy request, simultaneous ACK+next, cyclic banks, reset/SD re-entry and button_level",early_completions,late_completions);
    $finish;
end
initial begin repeat(150000) @(posedge clk); $fatal(1,"BMP preload timeout"); end
endmodule
