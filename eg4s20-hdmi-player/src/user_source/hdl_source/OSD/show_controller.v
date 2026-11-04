`timescale 1ns/1ps
module show_controller #(
    // About five seconds at the current 59.52 Hz VGA refresh.
    parameter integer HOLD_FRAMES = 300
)(
    input wire video_clk,
    input wire rst,
    input wire enable,
    input wire short_toggle,
    input wire auto_toggle,
    input wire ready_toggle,
    input wire ready_bank,
    input wire [2:0] image_count,
    input wire read_req,
    input wire read_req_ack,
    output reg next_toggle,
    output reg ack_toggle,
    output reg display_bank,
    output reg display_valid,
    output reg auto_play,
    output reg [4:0] fade_level
);
localparam [2:0] FIRST = 0, SHOW = 1, FADE_OUT = 2, COMMIT = 3, FADE_IN = 4;
reg [2:0] state;
reg [1:0] short_sync, auto_sync, ready_sync;
reg short_seen, auto_seen, ready_seen;
reg read_req_last;
reg [2:0] count_meta, count_sync, count_latched;
reg pending_ready, pending_bank, pending_token;
reg manual_pending;
reg waiting_ack, ack_low_seen, commit_token;
reg [8:0] hold_frames;
wire short_event = short_sync[1] != short_seen;
wire auto_event = auto_sync[1] != auto_seen;
wire frame_tick = read_req && !read_req_last;

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        short_sync <= 0; auto_sync <= 0; ready_sync <= 0;
        count_meta <= 0; count_sync <= 0;
        read_req_last <= 0;
    end else begin
        short_sync <= {short_sync[0], short_toggle};
        auto_sync <= {auto_sync[0], auto_toggle};
        ready_sync <= {ready_sync[0], ready_toggle};
        count_meta <= image_count; count_sync <= count_meta;
        read_req_last <= read_req;
    end
end

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        state <= FIRST;
        short_seen <= 0; auto_seen <= 0; ready_seen <= 0;
        pending_ready <= 0; pending_bank <= 0; pending_token <= 0;
        manual_pending <= 0; waiting_ack <= 0; ack_low_seen <= 0; commit_token <= 0;
        next_toggle <= 0; ack_toggle <= 0;
        display_bank <= 0; display_valid <= 0;
        auto_play <= 1; fade_level <= 16;
        hold_frames <= 0; count_latched <= 0;
    end else if (!enable) begin
        state <= FIRST;
        short_seen <= short_sync[1]; auto_seen <= auto_sync[1]; ready_seen <= ready_sync[1];
        pending_ready <= 0; pending_bank <= 0; pending_token <= 0;
        manual_pending <= 0; waiting_ack <= 0; ack_low_seen <= 0; commit_token <= 0;
        next_toggle <= 0; ack_toggle <= 0;
        display_bank <= 0; display_valid <= 0;
        auto_play <= 1; fade_level <= 16;
        hold_frames <= 0; count_latched <= 0;
    end else begin
        short_seen <= short_sync[1];
        auto_seen <= auto_sync[1];
        if (short_event && count_latched > 1) manual_pending <= 1;
        if (auto_event) begin
            auto_play <= !auto_play;
            hold_frames <= 0;
        end
        if (ready_sync[1] != ready_seen) begin
            ready_seen <= ready_sync[1];
            pending_ready <= 1;
            pending_bank <= ready_bank;
            pending_token <= ready_sync[1];
            count_latched <= count_sync;
        end

        // Release the old bank only after the read engine has latched the new one.
        if (waiting_ack) begin
            if (!read_req_ack) ack_low_seen <= 1;
            if (ack_low_seen && read_req_ack) begin
                ack_toggle <= commit_token;
                waiting_ack <= 0;
                ack_low_seen <= 0;
                if (count_latched > 1) next_toggle <= !next_toggle;
            end
        end

        case (state)
            FIRST: if (pending_ready && frame_tick) begin
                display_bank <= pending_bank;
                display_valid <= 1;
                pending_ready <= 0;
                commit_token <= pending_token;
                waiting_ack <= 1;
                ack_low_seen <= !read_req_ack;
                state <= SHOW;
            end
            SHOW: begin
                if (frame_tick && auto_play && !auto_event && !waiting_ack &&
                    count_latched > 1 && hold_frames < HOLD_FRAMES)
                    hold_frames <= hold_frames + 1;
                if (pending_ready && !waiting_ack && count_latched > 1 &&
                    (manual_pending || (auto_play && !auto_event && hold_frames >= HOLD_FRAMES))) begin
                    manual_pending <= 0;
                    hold_frames <= 0;
                    state <= FADE_OUT;
                end
            end
            FADE_OUT: if (frame_tick) begin
                fade_level <= fade_level - 1;
                if (fade_level == 1) state <= COMMIT;
            end
            COMMIT: if (pending_ready && frame_tick && !waiting_ack) begin
                display_bank <= pending_bank;
                pending_ready <= 0;
                commit_token <= pending_token;
                waiting_ack <= 1;
                ack_low_seen <= !read_req_ack;
                state <= FADE_IN;
            end
            FADE_IN: if (frame_tick && !waiting_ack) begin
                fade_level <= fade_level + 1;
                if (fade_level == 15) begin
                    hold_frames <= 0;
                    state <= SHOW;
                end
            end
            default: state <= FIRST;
        endcase
    end
end
endmodule
