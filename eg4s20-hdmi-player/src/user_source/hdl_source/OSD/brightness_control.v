`timescale 1ns/1ps
module brightness_control #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input wire clk,
    input wire rst,
    input wire key_brightness,
    output reg [1:0] brightness_gray
);
wire press;
key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) u_key (
    .clk(clk), .rst(rst), .button_in(key_brightness), .press_pulse(press));

// One Gray bit changes per press across the clock-domain boundary.
always @(posedge clk or posedge rst) begin
    if (rst) brightness_gray <= 2'b10;
    else if (press) begin
        case (brightness_gray)
            2'b10: brightness_gray <= 2'b00;
            2'b00: brightness_gray <= 2'b01;
            2'b01: brightness_gray <= 2'b11;
            2'b11: brightness_gray <= 2'b10;
        endcase
    end
end
endmodule
