`timescale 1ns/1ps
module avp_subtitles #(
    parameter integer CUE_COUNT = 57,
    parameter integer GLYPH_COUNT = 203
)(
    input wire video_clk,
    input wire rst,
    input wire sd_clk,
    input wire meta_we,
    input wire [12:0] meta_addr,
    input wire [7:0] meta_data,
    input wire enable,
    input wire [31:0] sample_count,
    input wire in_hs,
    input wire in_vs,
    input wire in_de,
    input wire [23:0] in_rgb,
    output wire out_hs,
    output wire out_vs,
    output wire out_de,
    output reg [23:0] out_rgb
);

// ponytail: fixed AVP metadata layout, <=40 characters and 203 glyphs;
// change these bounds when supporting another package format.
reg [7:0] cue_mem [0:511];
reg [7:0] text_mem [0:1023];
reg [7:0] glyph_hi [0:GLYPH_COUNT*16-1];
reg [7:0] glyph_lo [0:GLYPH_COUNT*16-1];
wire [12:0] glyph_byte_addr = meta_addr - 13'd1536;

// Metadata is loaded completely before enable. RAM has no reset.
always @(posedge sd_clk) begin
    if (meta_we) begin
        if (meta_addr < 13'd512)
            cue_mem[meta_addr[8:0]] <= meta_data;
        else if (meta_addr < 13'd1536)
            text_mem[meta_addr - 13'd512] <= meta_data;
        else if (glyph_byte_addr < GLYPH_COUNT*32) begin
            if (!glyph_byte_addr[0])
                glyph_hi[glyph_byte_addr[12:1]] <= meta_data;
            else
                glyph_lo[glyph_byte_addr[12:1]] <= meta_data;
        end
    end
end

reg [8:0] cue_addr;
reg [7:0] cue_q;
reg [6:0] cue_index;
reg [3:0] fetch_count;
reg next_ready;
reg [31:0] next_tick;
reg [15:0] next_offset;
reg [15:0] next_length;
reg [9:0] current_offset;
reg [5:0] current_length;
reg [9:0] display_offset;
reg [5:0] display_length;
wire [16:0] next_text_end = {1'b0, next_offset} + {1'b0, next_length};

always @(posedge video_clk)
    cue_q <= cue_mem[cue_addr];

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        cue_addr <= 9'd0;
        cue_index <= 7'd0;
        fetch_count <= 4'd0;
        next_ready <= 1'b0;
        next_tick <= 32'd0;
        next_offset <= 16'd0;
        next_length <= 16'd0;
        current_offset <= 10'd0;
        current_length <= 6'd0;
    end else if (!enable) begin
        cue_addr <= 9'd0;
        cue_index <= 7'd0;
        fetch_count <= 4'd0;
        next_ready <= 1'b0;
        current_offset <= 10'd0;
        current_length <= 6'd0;
    end else if (fetch_count < 4'd10 && cue_index < CUE_COUNT) begin
        if (fetch_count < 4'd8)
            cue_addr <= {cue_index[5:0], 3'b000} + fetch_count;
        // Address register + synchronous RAM: byte zero arrives at count 2.
        case (fetch_count)
            4'd2: next_tick[7:0] <= cue_q;
            4'd3: next_tick[15:8] <= cue_q;
            4'd4: next_tick[23:16] <= cue_q;
            4'd5: next_tick[31:24] <= cue_q;
            4'd6: next_offset[7:0] <= cue_q;
            4'd7: next_offset[15:8] <= cue_q;
            4'd8: next_length[7:0] <= cue_q;
            4'd9: begin
                next_length[15:8] <= cue_q;
                next_ready <= 1'b1;
            end
        endcase
        fetch_count <= fetch_count + 4'd1;
    end else if (next_ready && sample_count >= next_tick) begin
        if (next_length <= 16'd40 && next_text_end <= 17'd1024) begin
            current_offset <= next_offset[9:0];
            current_length <= next_length[5:0];
        end else begin
            current_offset <= 10'd0;
            current_length <= 6'd0;
        end
        next_ready <= 1'b0;
        cue_index <= cue_index + 7'd1;
        if (cue_index + 7'd1 < CUE_COUNT)
            fetch_count <= 4'd0;
    end
end

// Cue timing follows consumed PCM; pixel state changes only in vertical blank.
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        display_offset <= 10'd0;
        display_length <= 6'd0;
    end else if (!enable) begin
        display_offset <= 10'd0;
        display_length <= 6'd0;
    end else if (!in_vs) begin
        display_offset <= current_offset;
        display_length <= current_length;
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

wire [9:0] text_left = 10'd320 - {display_length, 3'b000};
wire [9:0] text_x = x - text_left;
wire [9:0] text_addr = display_offset + {4'd0, text_x[9:4]};
wire bar_hit = enable && in_de && y >= 10'd440 && y < 10'd464;
wire font_hit = bar_hit && y >= 10'd444 && y < 10'd460 &&
                x >= text_left && x < 10'd640 - text_left;
reg [7:0] text_q;
reg [3:0] row_s1;
reg [3:0] col_s1;
reg [3:0] col_s2;
wire [11:0] glyph_addr = text_q < GLYPH_COUNT ? {text_q, row_s1} : 12'd0;
reg [7:0] glyph_hi_q;
reg [7:0] glyph_lo_q;
wire [15:0] glyph_word = {glyph_hi_q, glyph_lo_q};

always @(posedge video_clk) begin
    text_q <= text_mem[font_hit ? text_addr : 10'd0];
    glyph_hi_q <= glyph_hi[glyph_addr];
    glyph_lo_q <= glyph_lo[glyph_addr];
end

reg [2:0] hs_pipe;
reg [2:0] vs_pipe;
reg [2:0] de_pipe;
reg [23:0] rgb_s1;
reg [23:0] rgb_s2;
reg bar_s1;
reg bar_s2;
reg font_s1;
reg font_s2;
assign out_hs = hs_pipe[2];
assign out_vs = vs_pipe[2];
assign out_de = de_pipe[2];

// Text RAM, glyph RAM, then output: all pixel paths have three registers.
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        hs_pipe <= 3'b111;
        vs_pipe <= 3'b111;
        de_pipe <= 3'b000;
        rgb_s1 <= 24'd0;
        rgb_s2 <= 24'd0;
        bar_s1 <= 1'b0;
        bar_s2 <= 1'b0;
        font_s1 <= 1'b0;
        font_s2 <= 1'b0;
        row_s1 <= 4'd0;
        col_s1 <= 4'd0;
        col_s2 <= 4'd0;
        out_rgb <= 24'd0;
    end else begin
        hs_pipe <= {hs_pipe[1:0], in_hs};
        vs_pipe <= {vs_pipe[1:0], in_vs};
        de_pipe <= {de_pipe[1:0], in_de};
        rgb_s1 <= in_rgb;
        rgb_s2 <= rgb_s1;
        bar_s1 <= bar_hit;
        bar_s2 <= bar_s1;
        font_s1 <= font_hit;
        font_s2 <= font_s1 && text_q < GLYPH_COUNT;
        row_s1 <= y - 10'd444;
        col_s1 <= text_x[3:0];
        col_s2 <= col_s1;
        out_rgb <= font_s2 && glyph_word[15 - col_s2] ? 24'hffffff :
                   bar_s2 ? 24'd0 : rgb_s2;
    end
end

endmodule
