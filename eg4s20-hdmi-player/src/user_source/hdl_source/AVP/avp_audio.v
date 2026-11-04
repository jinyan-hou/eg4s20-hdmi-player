module avp_audio #(
    parameter integer CLK_FREQ_HZ = 25000000,
    parameter integer SAMPLE_RATE = 48000,
    parameter integer SAMPLES_PER_FRAME = 4800,
    parameter integer AUDIO_SHIFT = 0
)(
    input wire video_clk,
    input wire rst,
    input wire paused,
    input wire sd_clk,
    input wire pcm_we,
    input wire pcm_bank,
    input wire [12:0] pcm_addr,
    input wire [15:0] pcm_data,
    input wire frame_ready_toggle,
    input wire frame_ready_bank,
    input wire frame_ready_last,
    input wire [31:0] frame_ready_number,
    output reg frame_ack_toggle,
    input wire video_read_req,
    input wire video_read_req_ack, // Already synchronized to video_clk by top.
    output reg [1:0] disp_buf_idx,
    output reg display_valid,
    output wire [31:0] sample_count,
    output reg audio_valid,
    output reg [23:0] audio_left_data,
    output wire [23:0] audio_right_data,
    output wire [3:0] play_state
);

// Two simple dual-port banks: SD writes, video_clk performs synchronous reads.
// Do not reset the arrays; the reader fills a bank before publishing its toggle.
reg [15:0] pcm_bank0 [0:SAMPLES_PER_FRAME-1];
reg [15:0] pcm_bank1 [0:SAMPLES_PER_FRAME-1];
reg active_bank;
reg [12:0] read_addr;
reg [15:0] read_pcm0, read_pcm1;
wire [15:0] read_pcm = active_bank ? read_pcm1 : read_pcm0;
always @(posedge sd_clk) begin
    if (pcm_we && pcm_addr < SAMPLES_PER_FRAME) begin
        if (pcm_bank)
            pcm_bank1[pcm_addr] <= pcm_data;
        else
            pcm_bank0[pcm_addr] <= pcm_data;
    end
end
always @(posedge video_clk) begin
    read_pcm0 <= pcm_bank0[read_addr];
    read_pcm1 <= pcm_bank1[read_addr];
end

reg ready_meta, ready_sync, ready_seen;
reg pending_valid, pending_bank, pending_last, pending_token;
reg [31:0] pending_number, active_number;
reg active, started, ended, active_last;
reg [1:0] read_settle;
reg [31:0] consumed_samples;
reg read_req_delayed;
reg display_pending, display_bank, display_token;
reg waiting_display_ack, ack_low_seen, commit_token;
reg [31:0] sample_accumulator;
wire [32:0] sample_sum = {1'b0, sample_accumulator} + SAMPLE_RATE;
wire sample_tick = sample_sum >= CLK_FREQ_HZ;
wire read_req_rise = video_read_req && !read_req_delayed;
wire signed [23:0] output_pcm = $signed({read_pcm, 8'b0}) >>> AUDIO_SHIFT;
assign sample_count = consumed_samples;
assign audio_right_data = audio_left_data;
assign play_state = ended ? 4'd8 : paused ? 4'd9 : active ? 4'd6 : 4'd7;

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        ready_meta <= 0;
        ready_sync <= 0;
        ready_seen <= 0;
        pending_valid <= 0;
        pending_bank <= 0;
        pending_last <= 0;
        pending_token <= 0;
        pending_number <= 0;
        active_number <= 0;
        active <= 0;
        started <= 0;
        ended <= 0;
        active_last <= 0;
        active_bank <= 0;
        read_addr <= 0;
        read_settle <= 0;
        consumed_samples <= 0;
        sample_accumulator <= 0;
        audio_valid <= 0;
        audio_left_data <= 0;
        read_req_delayed <= 0;
        display_pending <= 0;
        display_bank <= 0;
        display_token <= 0;
        waiting_display_ack <= 0;
        ack_low_seen <= 0;
        commit_token <= 0;
        frame_ack_toggle <= 0;
        disp_buf_idx <= 0;
        display_valid <= 0;
    end else begin
        ready_meta <= frame_ready_toggle;
        ready_sync <= ready_meta;
        read_req_delayed <= video_read_req;
        if (ready_sync != ready_seen) begin
            // Bundled bank/number stay unchanged in sd_clk until our ack.
            ready_seen <= ready_sync;
            pending_valid <= 1;
            pending_bank <= frame_ready_bank;
            pending_last <= frame_ready_last;
            pending_number <= frame_ready_number;
            pending_token <= ready_sync;
        end

        // Drain committed-frame ACKs during pause; a stale high still cannot release a bank.
        if (waiting_display_ack) begin
            if (!video_read_req_ack)
                ack_low_seen <= 1;
            if (ack_low_seen && video_read_req_ack) begin
                frame_ack_toggle <= commit_token;
                waiting_display_ack <= 0;
                ack_low_seen <= 0;
            end
        end
        if (!paused && read_req_rise && display_pending && !waiting_display_ack) begin
            disp_buf_idx <= {1'b0, display_bank};
            display_valid <= 1;
            display_pending <= 0;
            commit_token <= display_token;
            waiting_display_ack <= 1;
            ack_low_seen <= !video_read_req_ack;
        end

        if (!paused && !started && pending_valid && read_req_rise) begin
            started <= 1;
            active <= 1;
            active_bank <= pending_bank;
            active_last <= pending_last;
            active_number <= pending_number;
            read_addr <= 0;
            read_settle <= 2;
            pending_valid <= 0;
            disp_buf_idx <= {1'b0, pending_bank};
            display_valid <= 1;
            commit_token <= pending_token;
            waiting_display_ack <= 1;
            ack_low_seen <= !video_read_req_ack;
        end else if (!paused && started && !active && !ended && pending_valid) begin
            // Resume after an underrun; only real PCM advances sample_count.
            active <= 1;
            active_bank <= pending_bank;
            active_last <= pending_last;
            active_number <= pending_number;
            read_addr <= 0;
            read_settle <= 2;
            pending_valid <= 0;
            display_pending <= 1;
            display_bank <= pending_bank;
            display_token <= pending_token;
        end

        if (read_settle != 0)
            read_settle <= read_settle - 1'b1;

        // 48 kHz continues in WAIT/pause/EOF so HDMI ACR sees uninterrupted samples.
        audio_valid <= sample_tick;
        if (sample_tick) begin
            sample_accumulator <= sample_sum - CLK_FREQ_HZ;
            audio_left_data <= 0;
            if (!paused && active && read_settle == 0) begin
                audio_left_data <= output_pcm;
                consumed_samples <= consumed_samples + 1'b1;
                if (read_addr == SAMPLES_PER_FRAME - 1) begin
                    read_addr <= 0;
                    if (active_last) begin
                        active <= 0;
                        ended <= 1;
                    end else if (pending_valid) begin
                        active_bank <= pending_bank;
                        active_last <= pending_last;
                        active_number <= pending_number;
                        read_settle <= 2;
                        pending_valid <= 0;
                        display_pending <= 1;
                        display_bank <= pending_bank;
                        display_token <= pending_token;
                    end else begin
                        active <= 0;
                    end
                end else begin
                    read_addr <= read_addr + 1'b1;
                    read_settle <= 2;
                end
            end
        end else begin
            sample_accumulator <= sample_sum;
        end
    end
end
endmodule
