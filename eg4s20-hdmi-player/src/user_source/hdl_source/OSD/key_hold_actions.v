`timescale 1ns/1ps
module key_hold_actions #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer DEBOUNCE_MS = 20,
    parameter integer HOLD_MS = 1500
)(
    input wire clk,
    input wire rst,
    input wire cancel,
    input wire button_n,
    output reg short_pulse,
    output reg long_pulse
);
localparam integer HOLD_CYCLES = (CLK_FREQ_HZ / 1000) * HOLD_MS;
localparam integer RELEASE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
wire button_level, button_sample;
reg was_pressed, long_sent, blocked;
reg [31:0] hold_count;
key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) u_key (
    .clk(clk), .rst(rst), .button_in(button_n), .press_pulse(),
    .button_level(button_level), .button_sample(button_sample));

always @(posedge clk or posedge rst) begin
    if (rst) begin
        short_pulse <= 0; long_pulse <= 0;
        was_pressed <= 0; long_sent <= 0; blocked <= 0;
        hold_count <= 0;
    end else begin
        short_pulse <= 0; long_pulse <= 0;
        if (cancel) begin
            blocked <= 1;
            was_pressed <= 0; long_sent <= 0; hold_count <= 0;
        end else if (blocked) begin
            // A mode change can precede debounce; require a fresh stable release.
            if (button_sample && button_level) begin
                if (hold_count >= RELEASE_CYCLES - 1) begin
                    blocked <= 0;
                    hold_count <= 0;
                end else hold_count <= hold_count + 1;
            end else hold_count <= 0;
        end else if (!button_level) begin
            was_pressed <= 1;
            if (!long_sent) begin
                if (hold_count >= HOLD_CYCLES - 1) begin
                    long_pulse <= 1;
                    long_sent <= 1;
                end else hold_count <= hold_count + 1;
            end
        end else begin
            if (was_pressed && !long_sent) short_pulse <= 1;
            was_pressed <= 0; long_sent <= 0; hold_count <= 0;
        end
    end
end
endmodule
