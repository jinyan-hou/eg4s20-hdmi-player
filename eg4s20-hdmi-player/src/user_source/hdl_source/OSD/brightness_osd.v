`timescale 1ns/1ps
module brightness_osd (
    input wire video_clk,
    input wire rst,
    input wire enable,
    input wire [1:0] brightness_gray,
    input wire [4:0] fade_level,
    input wire mode_video,
    input wire video_paused,
    input wire video_ended,
    input wire auto_play,
    input wire in_hs,
    input wire in_vs,
    input wire in_de,
    input wire [23:0] in_rgb,
    output wire out_hs,
    output wire out_vs,
    output wire out_de,
    output reg [23:0] out_rgb
);

(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [1:0] brightness_meta;
(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [1:0] brightness_sync;
reg [1:0] display_level;
reg [4:0] display_fade;
reg [2:0] display_status;
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        brightness_meta <= 2'b10;
        brightness_sync <= 2'b10;
        display_level <= 2'd3;
        display_fade <= 5'd16;
        display_status <= 3'd0;
    end else begin
        brightness_meta <= brightness_gray;
        brightness_sync <= brightness_meta;
        // Negative VS is vertical blank; the image and label share one frame value.
        if (!in_vs) begin
            display_level <= {brightness_sync[1], brightness_sync[1] ^ brightness_sync[0]};
            display_fade <= mode_video ? 5'd16 : fade_level;
            display_status <= mode_video ? (video_ended ? 3'd4 : video_paused ? 3'd3 : 3'd2) :
                                          (auto_play ? 3'd1 : 3'd0);
        end
    end
end

function [7:0] attenuate;
    input [7:0] value;
    input [1:0] level;
    input [4:0] fade;
    reg [9:0] triple;
    reg [7:0] dimmed;
    reg [11:0] product;
    begin
        triple = {2'b00, value} + {1'b0, value, 1'b0};
        case (level)
            2'd0: dimmed = {2'b00, value[7:2]};
            2'd1: dimmed = {1'b0, value[7:1]};
            2'd2: dimmed = triple[9:2];
            default: dimmed = value;
        endcase
        product = dimmed * fade;
        attenuate = product[11:4];
    end
endfunction

// ponytail: fixed status glyphs and fade contract 0..16; extend only for new UI/source ranges.
function [4:0] glyph_row;
    input [7:0] character;
    input [2:0] row;
    reg [34:0] bitmap;
    begin
        case (character)
            "B": bitmap = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
            "R": bitmap = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
            "I": bitmap = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111};
            "G": bitmap = {5'b01110,5'b10001,5'b10000,5'b10111,5'b10001,5'b10001,5'b01110};
            "H": bitmap = {5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
            "T": bitmap = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
            "E": bitmap = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
            "Y": bitmap = {5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100};
            "A": bitmap = {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
            "U": bitmap = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
            "O": bitmap = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
            "N": bitmap = {5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001};
            "F": bitmap = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
            "P": bitmap = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
            "L": bitmap = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
            "S": bitmap = {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
            "D": bitmap = {5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
            "0": bitmap = {5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
            "1": bitmap = {5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
            "2": bitmap = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
            "5": bitmap = {5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
            "7": bitmap = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
            "%": bitmap = {5'b11001,5'b11010,5'b00100,5'b01000,5'b10110,5'b00110,5'b00000};
            default: bitmap = 35'd0;
        endcase
        glyph_row = bitmap[34 - row*5 -: 5];
    end
endfunction

function [7:0] label_character;
    input [3:0] index;
    input [1:0] level;
    input hint;
    input [2:0] status;
    reg [63:0] status_text;
    begin
        label_character = " ";
        if (hint) begin
            case (status)
                3'd1: status_text = "AUTO ON ";
                3'd2: status_text = "PLAY    ";
                3'd3: status_text = "PAUSE   ";
                3'd4: status_text = "END     ";
                default: status_text = "AUTO OFF";
            endcase
            label_character = status_text[63-index*8 -: 8];
        end else begin
            case (index)
                0: label_character = "B";
                1: label_character = "R";
                2: label_character = "I";
                3: label_character = "G";
                4: label_character = "H";
                5: label_character = "T";
                7: label_character = level == 3 ? "1" : " ";
                8: case (level)
                    0: label_character = "2";
                    1: label_character = "5";
                    2: label_character = "7";
                    3: label_character = "0";
                endcase
                9: label_character = level == 0 || level == 2 ? "5" : "0";
                10: label_character = "%";
            endcase
        end
    end
endfunction

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

wire panel_hit = enable && in_de && x >= 10'd16 && x < 10'd208 &&
                 y >= 10'd16 && y < 10'd66;
wire hint_hit = y >= 10'd44 && y < 10'd58;
wire [9:0] text_x = x - 10'd24;
wire [9:0] text_y = y - (hint_hit ? 10'd44 : 10'd24);
wire font_hit = panel_hit && x >= 10'd24 && text_x[3:1] < 3'd5 &&
                ((y >= 10'd24 && y < 10'd38 && x < 10'd200) ||
                 (hint_hit && x < 10'd152));

reg [2:0] hs_pipe;
reg [2:0] vs_pipe;
reg [2:0] de_pipe;
reg [23:0] rgb_s1;
reg [23:0] rgb_s2;
reg panel_s1, panel_s2;
reg font_s1, font_s2;
reg hint_s1, hint_s2;
reg [7:0] character_s1;
reg [2:0] row_s1, col_s1, col_s2;
reg [4:0] glyph_s2;
assign out_hs = hs_pipe[2];
assign out_vs = vs_pipe[2];
assign out_de = de_pipe[2];

// Attenuation/coordinates, glyph lookup, then overlay: every path is three clocks.
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        hs_pipe <= 3'b111;
        vs_pipe <= 3'b111;
        de_pipe <= 3'b000;
        rgb_s1 <= 24'd0;
        rgb_s2 <= 24'd0;
        panel_s1 <= 1'b0; panel_s2 <= 1'b0;
        font_s1 <= 1'b0; font_s2 <= 1'b0;
        hint_s1 <= 1'b0; hint_s2 <= 1'b0;
        character_s1 <= " ";
        row_s1 <= 3'd0; col_s1 <= 3'd0; col_s2 <= 3'd0;
        glyph_s2 <= 5'd0;
        out_rgb <= 24'd0;
    end else begin
        hs_pipe <= {hs_pipe[1:0], in_hs};
        vs_pipe <= {vs_pipe[1:0], in_vs};
        de_pipe <= {de_pipe[1:0], in_de};
        rgb_s1 <= {attenuate(in_rgb[23:16], display_level, display_fade),
                   attenuate(in_rgb[15:8], display_level, display_fade),
                   attenuate(in_rgb[7:0], display_level, display_fade)};
        rgb_s2 <= rgb_s1;
        panel_s1 <= panel_hit; panel_s2 <= panel_s1;
        font_s1 <= font_hit; font_s2 <= font_s1;
        hint_s1 <= hint_hit; hint_s2 <= hint_s1;
        character_s1 <= label_character(text_x[7:4], display_level, hint_hit, display_status);
        row_s1 <= text_y[3:1];
        col_s1 <= text_x[3:1]; col_s2 <= col_s1;
        glyph_s2 <= glyph_row(character_s1, row_s1);
        out_rgb <= font_s2 && glyph_s2[4-col_s2] ?
                   (hint_s2 ? 24'h40dfff : 24'hffffff) :
                   panel_s2 ? 24'd0 : rgb_s2;
    end
end

endmodule
