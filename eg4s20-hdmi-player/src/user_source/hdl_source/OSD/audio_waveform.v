`timescale 1ns/1ps
module audio_waveform (
    input wire video_clk,
    input wire rst,
    input wire enable,
    input wire audio_valid,
    input wire [23:0] audio_data,
    input wire in_hs,
    input wire in_vs,
    input wire in_de,
    input wire [23:0] in_rgb,
    output wire out_hs,
    output wire out_vs,
    output wire out_de,
    output reg [23:0] out_rgb
);

// Keep the existing trace height when full-volume 24-bit PCM replaces the 1/64 output.
wire signed [23:0] amplitude = $signed(audio_data) >>> 18;
wire [7:0] sample_y = amplitude > 24'sd20 ? 8'd20 :
                     amplitude < -24'sd20 ? 8'd60 : 8'd40 - amplitude;
reg capture_bank;
reg display_bank;
reg display_valid;
reg pending;
reg [8:0] write_index;
reg sample_phase;
wire sample_we = !rst && enable && !pending && audio_valid && sample_phase;
wire [9:0] sample_write_addr = {capture_bank, write_index};

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        capture_bank <= 1'b0;
        display_bank <= 1'b1;
        display_valid <= 1'b0;
        pending <= 1'b0;
        write_index <= 9'd0;
        sample_phase <= 1'b0;
    end else if (!enable) begin
        capture_bank <= 1'b0;
        display_bank <= 1'b1;
        display_valid <= 1'b0;
        pending <= 1'b0;
        write_index <= 9'd0;
        sample_phase <= 1'b0;
    end else begin
        if (pending) begin
            // A completed capture owns its bank until vertical blank releases the old display.
            if (!in_vs) begin
                display_bank <= capture_bank;
                capture_bank <= display_bank;
                display_valid <= 1'b1;
                pending <= 1'b0;
                write_index <= 9'd0;
                sample_phase <= 1'b0;
            end
        end else if (audio_valid) begin
            sample_phase <= !sample_phase;
            if (sample_phase) begin
                if (write_index == 9'd383)
                    pending <= 1'b1;
                else
                    write_index <= write_index + 9'd1;
            end
        end
    end
end

reg [9:0] x;
reg [9:0] y;
reg de_last;
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        x <= 10'd0;
        y <= 10'd0;
        de_last <= 1'b0;
    end else begin
        de_last <= in_de;
        if (!in_vs) begin
            x <= 10'd0;
            y <= 10'd0;
        end else if (in_de)
            x <= x + 10'd1;
        else if (de_last) begin
            x <= 10'd0;
            y <= y + 10'd1;
        end
    end
end

wire panel_hit = enable && in_de && x >= 10'd240 && x < 10'd624 &&
                 y >= 10'd16 && y < 10'd64;
wire [9:0] panel_x = x - 10'd240;
wire [9:0] sample_read_addr = {display_bank, panel_x[8:0]};
reg [7:0] samples [0:1023]; /* fehdl force_ram=1, ram_style="bram" */
reg [7:0] sample_q;
// One synchronous write port and one synchronous read port; RAM contents need no reset.
always @(posedge video_clk) begin
    if (sample_we)
        samples[sample_write_addr] <= sample_y;
    sample_q <= samples[sample_read_addr];
end

reg [1:0] hs_pipe, vs_pipe, de_pipe;
reg [23:0] rgb_s1;
reg panel_s1, border_s1, first_s1, valid_s1;
reg [5:0] y_s1;
reg [7:0] previous_y;
reg previous_valid;
wire wave_hit = panel_s1 && valid_s1 &&
                (first_s1 ? y_s1 == sample_q : previous_valid &&
                 ((y_s1 >= sample_q && y_s1 <= previous_y) ||
                  (y_s1 <= sample_q && y_s1 >= previous_y)));
assign out_hs = hs_pipe[1];
assign out_vs = vs_pipe[1];
assign out_de = de_pipe[1];

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        hs_pipe <= 2'b11;
        vs_pipe <= 2'b11;
        de_pipe <= 2'b00;
        rgb_s1 <= 24'd0;
        panel_s1 <= 1'b0;
        border_s1 <= 1'b0;
        first_s1 <= 1'b0;
        valid_s1 <= 1'b0;
        y_s1 <= 6'd0;
        previous_y <= 8'd40;
        previous_valid <= 1'b0;
        out_rgb <= 24'd0;
    end else begin
        hs_pipe <= {hs_pipe[0], in_hs};
        vs_pipe <= {vs_pipe[0], in_vs};
        de_pipe <= {de_pipe[0], in_de};
        rgb_s1 <= in_rgb;
        panel_s1 <= panel_hit;
        border_s1 <= x == 10'd240 || x == 10'd623 || y == 10'd16 || y == 10'd63;
        first_s1 <= x == 10'd240;
        valid_s1 <= display_valid;
        y_s1 <= y[5:0];
        previous_valid <= panel_s1;
        if (panel_s1)
            previous_y <= sample_q;
        out_rgb <= wave_hit ? 24'h40ff80 :
                   panel_s1 ? (border_s1 ? 24'h234536 :
                               y_s1 == 6'd40 ? 24'h163323 : 24'd0) : rgb_s1;
    end
end

endmodule
