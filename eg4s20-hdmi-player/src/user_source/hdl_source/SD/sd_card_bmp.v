module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4
)(
    input                       clk,
    input                       rst,
    input                       next_toggle,
    input                       commit_ack_toggle,
    output reg                  ready_toggle,
    output reg                  ready_bank,
    output [2:0]                image_count,
    output [3:0]                state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    input                       sd_init_done,
    output                      sd_sec_read,
    output [31:0]               sd_sec_read_addr,
    output                      sd_read_stop,
    input [7:0]                 sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end
);

wire bmp_data_wr_en;
wire [23:0] bmp_data;
wire bmp_ready, scan_done, scan_found_valid;
wire [31:0] scan_found_sector;
wire [2:0] scan_found_total;
reg scan_start_pulse, load_start_pulse, scan_kicked;
reg [31:0] load_sector;
reg [2:0] img_found_count;
reg [1:0] img_idx, load_idx, pending_buf_idx;
reg [31:0] img_sector0, img_sector1, img_sector2, img_sector3;
reg next_req_pending, load_busy, ready_pending, mem_write_done_seen;
reg next_meta, next_sync, next_seen;
reg ack_meta, ack_sync, ack_seen;
reg [2:0] wrfin_tgl_sync;
wire next_event = next_sync != next_seen;
wire ack_event = ack_sync != ack_seen;
wire write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
wire [1:0] next_from_current = next_index_limited(img_idx, img_found_count);

assign image_count = img_found_count;
assign write_en = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};

function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0, 3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = cur == 2'd1 ? 2'd0 : cur + 2'd1;
            3'd3: next_index_limited = cur == 2'd2 ? 2'd0 : cur + 2'd1;
            default: next_index_limited = cur == 2'd3 ? 2'd0 : cur + 2'd1;
        endcase
    end
endfunction

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            default: sector_lut = img_sector3;
        endcase
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        next_meta <= 1'b0; next_sync <= 1'b0; next_seen <= 1'b0;
        ack_meta <= 1'b0; ack_sync <= 1'b0; ack_seen <= 1'b0;
        wrfin_tgl_sync <= 3'b000;
        scan_start_pulse <= 1'b0; load_start_pulse <= 1'b0;
        scan_kicked <= 1'b0;
        load_sector <= 32'd0;
        img_found_count <= 3'd0;
        img_idx <= 2'd0; load_idx <= 2'd0; pending_buf_idx <= 2'd0;
        write_buf_idx <= 2'd0; disp_buf_idx <= 2'd0;
        img_sector0 <= 32'd0; img_sector1 <= 32'd0;
        img_sector2 <= 32'd0; img_sector3 <= 32'd0;
        next_req_pending <= 1'b0; load_busy <= 1'b0; ready_pending <= 1'b0;
        mem_write_done_seen <= 1'b0;
        display_valid <= 1'b0;
        ready_toggle <= 1'b0; ready_bank <= 1'b0;
    end else begin
        next_meta <= next_toggle; next_sync <= next_meta; next_seen <= next_sync;
        ack_meta <= commit_ack_toggle; ack_sync <= ack_meta; ack_seen <= ack_sync;
        wrfin_tgl_sync <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;

        if (!sd_init_done) begin
            scan_kicked <= 1'b0;
            img_found_count <= 3'd0;
            img_idx <= 2'd0; load_idx <= 2'd0; pending_buf_idx <= 2'd0;
            write_buf_idx <= 2'd0; disp_buf_idx <= 2'd0;
            img_sector0 <= 32'd0; img_sector1 <= 32'd0;
            img_sector2 <= 32'd0; img_sector3 <= 32'd0;
            next_req_pending <= 1'b0; load_busy <= 1'b0; ready_pending <= 1'b0;
            mem_write_done_seen <= 1'b0;
            display_valid <= 1'b0;
            ready_toggle <= 1'b0; ready_bank <= 1'b0;
        end else begin
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse <= 1'b1;
                scan_kicked <= 1'b1;
            end
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    default: ;
                endcase
                if (img_found_count < 3'd4)
                    img_found_count <= img_found_count + 3'd1;
            end
            if (next_event && scan_done && img_found_count != 0)
                next_req_pending <= 1'b1;
            if (load_busy && write_finish_pulse)
                mem_write_done_seen <= 1'b1;

            // Both the parser and SDRAM must finish before publishing a held bank.
            if (load_busy && !ready_pending && bmp_ready && mem_write_done_seen) begin
                ready_bank <= pending_buf_idx[0];
                ready_toggle <= ~ready_toggle;
                ready_pending <= 1'b1;
            end
            if (ready_pending && ack_event) begin
                disp_buf_idx <= pending_buf_idx;
                img_idx <= load_idx;
                display_valid <= 1'b1;
                ready_pending <= 1'b0;
                load_busy <= 1'b0;
                mem_write_done_seen <= 1'b0;
            end

            // ACK releases ownership first; a queued next request starts on a later clock.
            if (scan_done && bmp_ready && !load_busy && img_found_count != 0) begin
                if (!display_valid) begin
                    load_idx <= 2'd0;
                    load_sector <= img_sector0;
                    pending_buf_idx <= 2'd0;
                    write_buf_idx <= 2'd0;
                    load_start_pulse <= 1'b1;
                    load_busy <= 1'b1;
                    mem_write_done_seen <= 1'b0;
                end else if (next_req_pending) begin
                    load_idx <= next_from_current;
                    load_sector <= sector_lut(next_from_current);
                    pending_buf_idx <= {1'b0, ~disp_buf_idx[0]};
                    write_buf_idx <= {1'b0, ~disp_buf_idx[0]};
                    load_start_pulse <= 1'b1;
                    load_busy <= 1'b1;
                    mem_write_done_seen <= 1'b0;
                    next_req_pending <= next_event;
                end
            end
        end
    end
end

bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);

assign sd_read_stop = bmp_ready;

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse,
    output wire button_level,
    output wire button_sample
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
assign button_level = button_stable;
assign button_sample = button_sync1;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
