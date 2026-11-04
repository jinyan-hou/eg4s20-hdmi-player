`timescale 1ns/1ps
// Fixed ALAV0001 stream for a verified, contiguous media package.
// Replacing/recopying the file requires rechecking FILE_LBA and the header CRC.
module avp_reader #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter [31:0] FILE_LBA = 32'd40224,
    parameter integer FRAME_COUNT = 2270,
    parameter integer VIDEO_FPS = 10,
    parameter integer VIDEO_WIDTH = 320,
    parameter integer VIDEO_HEIGHT = 240,
    parameter integer SAMPLES_PER_FRAME = 48000 / VIDEO_FPS,
    parameter [31:0] EXPECTED_HEADER_CRC32 = 32'h1bd8f165,
    parameter integer SECTOR_TIMEOUT_CYCLES = CLK_FREQ_HZ,
    parameter integer INIT_TIMEOUT_CYCLES = CLK_FREQ_HZ * 5
)(
    input clk,
    input rst,
    input sd_init_done,
    input sd_valid,
    input sd_end,
    input [7:0] sd_byte,
    input [7:0] card_error,
    output sd_read_req,
    output [31:0] sd_read_lba,
    output sd_read_stop,
    output write_req,
    input write_req_ack,
    input write_ready,
    output write_en,
    output [31:0] write_data,
    output reg [1:0] write_buf_idx,
    input write_finish_toggle,
    output reg frame_ready_toggle,
    output reg frame_ready_bank,
    output reg frame_ready_last,
    output reg [31:0] frame_ready_number,
    input frame_ack_toggle,
    output reg pcm_we,
    output pcm_bank,
    output reg [12:0] pcm_addr,
    output reg [15:0] pcm_data,
    output reg meta_we,
    output reg [12:0] meta_addr,
    output reg [7:0] meta_data,
    output [3:0] state_code,
    output reg [11:0] frame_load_ms_bcd
);
localparam [3:0] ST_INIT = 4'h0, ST_READ = 4'h1, ST_HEADER = 4'h2,
    ST_META = 4'h3, ST_REQ = 4'h4, ST_ACK_LOW = 4'h5,
    ST_VIDEO = 4'h6, ST_PCM = 4'h7, ST_END = 4'h8,
    ST_REPLAY = 4'h9, ST_MEM = 4'ha, ST_ACK = 4'hb,
    ST_NEXT = 4'hc, ST_ERROR = 4'he;
localparam [1:0] HEADER = 2'd0, META = 2'd1, VIDEO = 2'd2, PCM = 2'd3;
localparam integer AUDIO_BYTES = SAMPLES_PER_FRAME * 2;
localparam integer VIDEO_BYTES = VIDEO_WIDTH * VIDEO_HEIGHT * 2;
localparam integer VIDEO_SECTORS = VIDEO_BYTES / 512;
localparam integer RECORD_SECTORS = VIDEO_SECTORS + (AUDIO_BYTES + 511) / 512;
localparam integer UPSCALE_2X = (VIDEO_WIDTH == 320 && VIDEO_HEIGHT == 240);
localparam [15:0] WIDTH_FIELD = VIDEO_WIDTH, HEIGHT_FIELD = VIDEO_HEIGHT;
localparam [15:0] FPS_FIELD = VIDEO_FPS;

reg [3:0] state, previous_state;
reg [1:0] section;
reg [31:0] sector_lba, frame_number, timer;
reg [9:0] capture_count, parse_index;
reg [10:0] record_sector;
reg [8:0] source_x, replay_x;
reg [4:0] metadata_sector;
reg [12:0] metadata_offset, pcm_count;
reg [2:0] pixel_phase;
reg [1:0] replay_phase;
reg byte_wait;
reg [7:0] low_byte;
reg [15:0] pixel;
reg header_bad, frame_active, source_done_seen, mem_done_seen;
reg [8:0] header_expected_q;
reg [7:0] header_byte_q;
reg header_check_valid;
reg [2:0] finish_sync;
reg [1:0] ack_sync, write_ack_sync;
reg ack_seen;
reg [16:0] load_ms_divider;
reg [11:0] load_ms_bcd;
localparam integer MS_CYCLES = (CLK_FREQ_HZ < 1000) ? 1 : CLK_FREQ_HZ / 1000;

// Both read ports are synchronous, so these small buffers can infer block RAM.
reg [7:0] sector_mem [0:511];
reg [7:0] sector_byte;
reg [15:0] line_mem [0:319];
reg [15:0] replay_pixel;

wire finish_event = finish_sync[2] ^ finish_sync[1];
wire header_byte_bad = header_check_valid && header_expected_q[8] &&
                       (header_byte_q != header_expected_q[7:0]);
wire timed_state = (state == ST_READ) || (state == ST_REQ) ||
                   (state == ST_ACK_LOW) || (state == ST_MEM);
wire timeout = (state == previous_state) &&
    (((state == ST_INIT) && (timer >= INIT_TIMEOUT_CYCLES - 1)) ||
     (timed_state && (timer >= SECTOR_TIMEOUT_CYCLES - 1)));

assign state_code = state;
assign write_req = !rst && (state == ST_REQ);
assign write_en = !rst && write_ready &&
    (((state == ST_VIDEO) && ((pixel_phase == 3'd4) || (UPSCALE_2X && pixel_phase == 3'd5))) ||
     (UPSCALE_2X && (state == ST_REPLAY) && ((replay_phase == 2'd1) || (replay_phase == 2'd2))));
assign write_data = expand565((UPSCALE_2X && state == ST_REPLAY) ? replay_pixel : pixel);
assign pcm_bank = write_buf_idx[0];

function [31:0] expand565;
    input [15:0] value;
    begin
        expand565 = {value[15:11], value[15:13],
                     value[10:5], value[10:9], value[4:0], value[4:2], 8'h00};
    end
endfunction

// Check declared layout and bind this reader to the PC/card-verified header CRC.
// The CRC field is checked here; CRC computation itself was performed on the PC.
function [8:0] header_expected;
    input [8:0] address;
    reg [31:0] word_value;
    reg [7:0] byte_value;
    reg checked;
    begin
        checked = 1'b1;
        case (address[8:2])
            7'd0: word_value = 32'h56414c41; // ALAV
            7'd1: word_value = 32'h31303030; // 0001
            7'd2: word_value = {HEIGHT_FIELD, WIDTH_FIELD};
            7'd3: word_value = {16'd1, FPS_FIELD};
            7'd4: word_value = 32'd48000;
            7'd5: word_value = SAMPLES_PER_FRAME;
            7'd6: word_value = FRAME_COUNT;
            7'd7: word_value = 32'd57;
            7'd8: word_value = 32'd203;
            7'd9: word_value = 32'd516;
            7'd10: word_value = 32'd1;
            7'd11: word_value = 32'd2;
            7'd12: word_value = 32'd4;
            7'd13: word_value = 32'd17;
            7'd14: word_value = RECORD_SECTORS;
            7'd15: word_value = VIDEO_BYTES;
            7'd16: word_value = AUDIO_BYTES;
            7'd17: word_value = 32'd226958;
            7'd18: word_value = FRAME_COUNT * SAMPLES_PER_FRAME;
            7'd19: word_value = 32'd1;
            7'd20: word_value = {16'd16, 16'd16};
            7'd21: word_value = 32'd10893984;
            7'd127: word_value = EXPECTED_HEADER_CRC32;
            default: begin word_value = 32'd0; checked = 1'b0; end
        endcase
        byte_value = word_value >> (address[1:0] * 8);
        header_expected = {checked, byte_value};
    end
endfunction

// Separate header-table selection from byte comparison at the 100 MHz clock.
// Data and its expected value travel together, including a last-byte/end beat.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_expected_q <= 9'd0;
        header_byte_q <= 8'd0;
        header_check_valid <= 1'b0;
    end else begin
        header_check_valid <= (state == ST_READ) && (section == HEADER) &&
                              sd_valid && (capture_count < 10'd512);
        if ((state == ST_READ) && (section == HEADER) && sd_valid &&
            (capture_count < 10'd512)) begin
            header_expected_q <= header_expected(capture_count[8:0]);
            header_byte_q <= sd_byte;
        end
    end
end

assign sd_read_req = !rst && (state == ST_READ);
assign sd_read_lba = sector_lba;
assign sd_read_stop = (state == ST_END) || (state == ST_ERROR);

// Measure actual card, pixel expansion and memory loading; hold the last result.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        load_ms_divider <= 0;
        load_ms_bcd <= 0;
        frame_load_ms_bcd <= 0;
    end else begin
        if ((state == ST_REQ && previous_state != ST_REQ) ||
            !(frame_active || state == ST_REQ || state == ST_ACK_LOW)) begin
            load_ms_divider <= 0;
            load_ms_bcd <= 0;
        end else if (load_ms_divider == MS_CYCLES - 1) begin
            load_ms_divider <= 0;
            if (load_ms_bcd != 12'h999) begin
                if (load_ms_bcd[3:0] != 4'd9)
                    load_ms_bcd[3:0] <= load_ms_bcd[3:0] + 1'b1;
                else begin
                    load_ms_bcd[3:0] <= 0;
                    if (load_ms_bcd[7:4] != 4'd9)
                        load_ms_bcd[7:4] <= load_ms_bcd[7:4] + 1'b1;
                    else begin
                        load_ms_bcd[7:4] <= 0;
                        load_ms_bcd[11:8] <= load_ms_bcd[11:8] + 1'b1;
                    end
                end
            end
        end else load_ms_divider <= load_ms_divider + 1'b1;
        if (state == ST_MEM && source_done_seen && mem_done_seen)
            frame_load_ms_bcd <= load_ms_bcd;
    end
end

always @(posedge clk) begin
    if (!rst && (state == ST_READ) && sd_valid && (capture_count < 10'd512))
        sector_mem[capture_count[8:0]] <= sd_byte;
    if (!rst && UPSCALE_2X && (state == ST_VIDEO) && (pixel_phase == 3'd3))
        line_mem[source_x] <= {sector_byte, low_byte};
    sector_byte <= sector_mem[parse_index[8:0]];
    replay_pixel <= line_mem[replay_x];
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        finish_sync <= 3'd0;
        ack_sync <= 2'd0;
        write_ack_sync <= 2'd0;
    end else begin
        finish_sync <= {finish_sync[1:0], write_finish_toggle};
        ack_sync <= {ack_sync[0], frame_ack_toggle};
        write_ack_sync <= {write_ack_sync[0], write_req_ack};
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= ST_INIT;
        previous_state <= ST_INIT;
        section <= HEADER;
        sector_lba <= FILE_LBA;
        frame_number <= 32'd0;
        timer <= 32'd0;
        capture_count <= 10'd0;
        parse_index <= 10'd0;
        record_sector <= 11'd0;
        source_x <= 9'd0;
        replay_x <= 9'd0;
        metadata_sector <= 5'd1;
        metadata_offset <= 13'd0;
        pcm_count <= 13'd0;
        pixel_phase <= 3'd0;
        replay_phase <= 2'd0;
        byte_wait <= 1'b0;
        low_byte <= 8'd0;
        pixel <= 16'd0;
        header_bad <= 1'b0;
        frame_active <= 1'b0;
        source_done_seen <= 1'b0;
        mem_done_seen <= 1'b0;
        ack_seen <= 1'b0;
        write_buf_idx <= 2'd0;
        frame_ready_toggle <= 1'b0;
        frame_ready_bank <= 1'b0;
        frame_ready_last <= 1'b0;
        frame_ready_number <= 32'd0;
        pcm_we <= 1'b0;
        pcm_addr <= 13'd0;
        pcm_data <= 16'd0;
        meta_we <= 1'b0;
        meta_addr <= 13'd0;
        meta_data <= 8'd0;
    end else begin
        previous_state <= state;
        if ((state != previous_state) || !((state == ST_INIT) || timed_state))
            timer <= 32'd0;
        else
            timer <= timer + 32'd1;
        pcm_we <= 1'b0;
        meta_we <= 1'b0;
        if (header_byte_bad)
            header_bad <= 1'b1;
        if (frame_active && finish_event)
            mem_done_seen <= 1'b1;

        if (timeout) begin
            state <= ST_ERROR;
            frame_active <= 1'b0;
            mem_done_seen <= 1'b0;
            source_done_seen <= 1'b0;
        end else case (state)
            ST_INIT: if (FILE_LBA==32'hffffffff) state<=ST_ERROR;
                     else if (sd_init_done) state <= ST_READ;
            ST_READ: begin
                if (sd_valid) begin
                    if (capture_count < 10'd512) begin
                        capture_count <= capture_count + 10'd1;
                    end else begin
                        state <= ST_ERROR;
                        frame_active <= 1'b0;
                    end
                end
                if (sd_end) begin
                    // Also allow a controller delivering its last byte with end.
                    if ((capture_count == 10'd512 && !sd_valid) ||
                        (capture_count == 10'd511 && sd_valid)) begin
                        parse_index <= 10'd0;
                        byte_wait <= 1'b0;
                        pixel_phase <= 3'd0;
                        case (section)
                            HEADER: state <= ST_HEADER;
                            META: state <= ST_META;
                            VIDEO: state <= ST_VIDEO;
                            PCM: state <= ST_PCM;
                        endcase
                    end else begin
                        state <= ST_ERROR;
                        frame_active <= 1'b0;
                    end
                end
            end
            ST_HEADER: begin
                // Last comparison may be pending if sd_valid and sd_end coincided.
                if (header_bad || header_byte_bad || FRAME_COUNT < 1 ||
                    !(UPSCALE_2X || (VIDEO_WIDTH == 640 && VIDEO_HEIGHT == 480))) state <= ST_ERROR;
                else begin
                    section <= META;
                    sector_lba <= FILE_LBA + 32'd1;
                    capture_count <= 10'd0;
                    state <= ST_READ;
                end
            end
            ST_META: begin
                if (!byte_wait) byte_wait <= 1'b1;
                else begin
                    byte_wait <= 1'b0;
                    meta_we <= 1'b1;
                    meta_addr <= metadata_offset;
                    meta_data <= sector_byte;
                    metadata_offset <= metadata_offset + 13'd1;
                    parse_index <= parse_index + 10'd1;
                    if (parse_index == 10'd511) state <= ST_NEXT;
                end
            end
            ST_REQ: begin
                if (write_ack_sync[1]) begin
                    frame_active <= 1'b1;
                    source_done_seen <= 1'b0;
                    mem_done_seen <= 1'b0;
                    pcm_count <= 13'd0;
                    source_x <= 9'd0;
                    record_sector <= 11'd0;
                    section <= VIDEO;
                    state <= ST_ACK_LOW;
                end
            end
            // ACK is held while frame_fifo_write clears its FIFO. Wait for release.
            ST_ACK_LOW: if (!write_ack_sync[1]) begin
                capture_count <= 10'd0;
                state <= ST_READ;
            end
            ST_VIDEO: begin
                case (pixel_phase)
                    3'd0: pixel_phase <= 3'd1;
                    3'd1: begin
                        low_byte <= sector_byte;
                        parse_index <= parse_index + 10'd1;
                        pixel_phase <= 3'd2;
                    end
                    3'd2: pixel_phase <= 3'd3;
                    3'd3: begin
                        pixel <= {sector_byte, low_byte};
                        parse_index <= parse_index + 10'd1;
                        pixel_phase <= 3'd4;
                    end
                    3'd4: if (write_ready) begin
                        if (UPSCALE_2X) pixel_phase <= 3'd5;
                        else begin
                            pixel_phase <= 3'd0;
                            if (parse_index == 10'd512) state <= ST_NEXT;
                        end
                    end
                    3'd5: if (write_ready) begin
                        pixel_phase <= 3'd0;
                        if (source_x == 9'd319) begin
                            source_x <= 9'd0;
                            replay_x <= 9'd0;
                            replay_phase <= 2'd0;
                            state <= ST_REPLAY;
                        end else begin
                            source_x <= source_x + 9'd1;
                            if (parse_index == 10'd512) state <= ST_NEXT;
                        end
                    end
                    default: state <= ST_ERROR;
                endcase
            end
            ST_REPLAY: begin
                case (replay_phase)
                    2'd0: replay_phase <= 2'd1;
                    2'd1: if (write_ready) replay_phase <= 2'd2;
                    2'd2: if (write_ready) begin
                        replay_phase <= 2'd0;
                        if (replay_x == 9'd319) begin
                            if (parse_index == 10'd512) state <= ST_NEXT;
                            else state <= ST_VIDEO;
                        end else replay_x <= replay_x + 9'd1;
                    end
                    default: state <= ST_ERROR;
                endcase
            end
            ST_PCM: begin
                if (!byte_wait) byte_wait <= 1'b1;
                else begin
                    byte_wait <= 1'b0;
                    parse_index <= parse_index + 10'd1;
                    if (pcm_count < SAMPLES_PER_FRAME) begin
                        if (!parse_index[0]) low_byte <= sector_byte;
                        else begin
                            pcm_we <= 1'b1;
                            pcm_addr <= pcm_count;
                            pcm_data <= {sector_byte, low_byte};
                            pcm_count <= pcm_count + 13'd1;
                        end
                    end
                    if (parse_index == 10'd511) state <= ST_NEXT;
                end
            end
            ST_NEXT: begin
                sector_lba <= sector_lba + 32'd1;
                capture_count <= 10'd0;
                if (section == META) begin
                    if (metadata_sector == 5'd16) begin
                        section <= VIDEO;
                        state <= ST_REQ;
                    end else begin
                        metadata_sector <= metadata_sector + 5'd1;
                        state <= ST_READ;
                    end
                end else if (section == VIDEO) begin
                    record_sector <= record_sector + 11'd1;
                    if (record_sector == VIDEO_SECTORS - 1) section <= PCM;
                    state <= ST_READ;
                end else if (section == PCM) begin
                    if (record_sector == RECORD_SECTORS - 1) begin
                        if (pcm_count != SAMPLES_PER_FRAME) state <= ST_ERROR;
                        else begin
                            source_done_seen <= 1'b1;
                            state <= ST_MEM;
                        end
                    end else begin
                        record_sector <= record_sector + 11'd1;
                        state <= ST_READ;
                    end
                end else state <= ST_ERROR;
            end
            ST_MEM: if (source_done_seen && mem_done_seen) begin
                frame_ready_toggle <= ~frame_ready_toggle;
                frame_ready_bank <= write_buf_idx[0];
                frame_ready_number <= frame_number;
                frame_ready_last <= (frame_number == FRAME_COUNT - 1);
                ack_seen <= ack_sync[1];
                frame_active <= 1'b0;
                mem_done_seen <= 1'b0;
                state <= ST_ACK;
            end
            ST_ACK: if (ack_sync[1] != ack_seen) begin
                ack_seen <= ack_sync[1];
                source_done_seen <= 1'b0;
                if (frame_number == FRAME_COUNT - 1) state <= ST_END;
                else begin
                    frame_number <= frame_number + 32'd1;
                    write_buf_idx <= {1'b0, ~write_buf_idx[0]};
                    state <= ST_REQ;
                end
            end
            ST_END: ;
            ST_ERROR: begin
                frame_active <= 1'b0;
                source_done_seen <= 1'b0;
                mem_done_seen <= 1'b0;
            end
            default: state <= ST_ERROR;
        endcase
        if(card_error!=0) begin state<=ST_ERROR; frame_active<=0; end
    end
end
endmodule
