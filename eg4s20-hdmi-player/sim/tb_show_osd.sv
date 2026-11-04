`timescale 1ns/1ps
module tb_show_osd;
    reg video_clk = 0;
    always #20 video_clk = ~video_clk;
    reg rst = 1, enable = 0;
    reg [1:0] brightness_gray = 2'b10;
    reg [4:0] fade_level = 16;
    reg mode_video = 0, video_paused = 0, video_ended = 0, auto_play = 0;
    reg in_hs = 1, in_vs = 1, in_de = 0;
    reg [23:0] in_rgb = 0;
    wire out_hs, out_vs, out_de;
    wire [23:0] out_rgb;
    brightness_osd dut (.*);

    integer gold_level = 3, gold_fade = 16, gold_status = 0;
    reg [23:0] reference_rgb = 0;
    reg [26:0] expected0, expected1, expected2;
    integer capture = 0, capture0 = 0, capture1 = 0, capture2 = 0;
    integer images [0:6];
    integer pixels [0:6];
    integer checked = 0;
    always @(posedge video_clk) begin
        if (rst) begin
            expected0 = {3'b110, 24'd0}; expected1 = expected0; expected2 = expected0;
            capture0 = 0; capture1 = 0; capture2 = 0;
        end else begin
            expected2 = expected1; expected1 = expected0;
            expected0 = {in_hs, in_vs, in_de, reference_rgb};
            capture2 = capture1; capture1 = capture0; capture0 = capture;
            #1;
            if ({out_hs, out_vs, out_de, out_rgb} !== expected2)
                $fatal(1, "show OSD pixel/timing mismatch at %0d: got %h expected %h",
                       checked, {out_hs, out_vs, out_de, out_rgb}, expected2);
            checked = checked + 1;
            if (capture2 > 0) begin
                $fwrite(images[capture2-1], "%0d %0d %0d\n", out_rgb[23:16], out_rgb[15:8], out_rgb[7:0]);
                pixels[capture2-1] = pixels[capture2-1] + 1;
            end
        end
    end

    function automatic [1:0] gray(input integer level);
        gray = level ^ (level >> 1);
    endfunction

    function automatic [23:0] dim(input [23:0] rgb, input integer level, input integer fade);
        integer red, green, blue;
        begin
            // Separate integer divisions check brightness rounding before the fade multiplication.
            red = (rgb[23:16] * (level+1) / 4) * fade / 16;
            green = (rgb[15:8] * (level+1) / 4) * fade / 16;
            blue = (rgb[7:0] * (level+1) / 4) * fade / 16;
            dim = {red[7:0], green[7:0], blue[7:0]};
        end
    endfunction

    // Expected artwork stores columns independently of the RTL row ROM.
    function automatic bit ink(input byte character, input integer row, input integer col);
        reg [34:0] columns;
        begin
            case (character)
                "B": columns = 35'h7f93264b6;
                "R": columns = 35'h7f9132531;
                "I": columns = 35'h4183fe0c1;
                "G": columns = 35'h3e83264ae;
                "H": columns = 35'h7f102047f;
                "T": columns = 35'h4081fe040;
                "E": columns = 35'h7f93264c1;
                "Y": columns = 35'h60203c860;
                "A": columns = 35'h3f912243f;
                "U": columns = 35'h7e02040fe;
                "O": columns = 35'h3e83060be;
                "N": columns = 35'h7f404047f;
                "F": columns = 35'h7f9122440;
                "P": columns = 35'h7f9122430;
                "L": columns = 35'h7f0204081;
                "S": columns = 35'h3193264c6;
                "D": columns = 35'h7f83060be;
                "0": columns = 35'h3e8b268be;
                "1": columns = 35'h0043fc080;
                "2": columns = 35'h2187164b1;
                "5": columns = 35'h7993264c6;
                "7": columns = 35'h408f22860;
                "%": columns = 35'h64d059340;
                default: columns = 0;
            endcase
            ink = columns[34-col*7-row];
        end
    endfunction

    function automatic [23:0] pixel(input integer xx, input integer yy, input [23:0] rgb);
        integer row, col, index;
        reg [87:0] text;
        bit hint, text_hit;
        begin
            pixel = dim(rgb, gold_level, gold_fade);
            if (enable && xx >= 16 && xx < 208 && yy >= 16 && yy < 66) begin
                pixel = 0;
                hint = yy >= 44 && yy < 58;
                text_hit = xx >= 24 && ((yy >= 24 && yy < 38 && xx < 200) ||
                                       (hint && xx < 152));
                if (text_hit) begin
                    index = (xx-24)/16;
                    col = ((xx-24)%16)/2;
                    row = (yy-(hint ? 44 : 24))/2;
                    if (hint) case (gold_status)
                        0: text = "AUTO OFF   ";
                        1: text = "AUTO ON    ";
                        2: text = "PLAY       ";
                        3: text = "PAUSE      ";
                        4: text = "END        ";
                    endcase
                    else case (gold_level)
                        0: text = "BRIGHT  25%";
                        1: text = "BRIGHT  50%";
                        2: text = "BRIGHT  75%";
                        3: text = "BRIGHT 100%";
                    endcase
                    if (col < 5 && ink(text[87-index*8 -: 8], row, col))
                        pixel = hint ? 24'h40dfff : 24'hffffff;
                end
            end
        end
    endfunction

    task automatic cycle(input bit hs, input bit vs, input bit de,
                         input [23:0] rgb, input [23:0] expected_rgb, input integer save);
        @(negedge video_clk);
        in_hs = hs; in_vs = vs; in_de = de;
        in_rgb = rgb; reference_rgb = expected_rgb; capture = save;
    endtask

    task automatic idle(input integer count);
        repeat (count) cycle(1, 1, 0, 24'hc39a57, dim(24'hc39a57, gold_level, gold_fade), 0);
    endtask

    task automatic request(input integer level, input integer fade, input integer status);
        brightness_gray = gray(level); fade_level = fade;
        mode_video = status >= 2;
        auto_play = status == 1;
        video_paused = status == 3 || status == 4;
        video_ended = status == 4;
    endtask

    task automatic commit(input integer level, input integer fade, input integer status);
        @(negedge video_clk); request(level, fade, status);
        idle(8);
        cycle(1, 0, 0, 0, 0, 0);
        repeat (4) cycle(0, 0, 0, 0, 0, 0);
        gold_level = level; gold_fade = status >= 2 ? 16 : fade; gold_status = status;
        idle(8);
    endtask

    // Runtime bounds/direct drive avoid XSIM unrolling a full raster through nested event tasks.
    integer image_width = 640, image_height = 480;
    task automatic frame(input integer save, input integer change);
        integer xx, yy;
        reg [23:0] rgb;
        begin
            cycle(1, 0, 0, 0, 0, 0);
            cycle(0, 0, 0, 0, 0, 0);
            cycle(1, 1, 0, 0, 0, 0);
            for (yy = 0; yy < image_height; yy = yy+1) begin
                for (xx = 0; xx < image_width; xx = xx+1) begin
                    @(negedge video_clk);
                    if (yy == 8 && xx == 320) begin
                        if (change == 1) request(0, 0, 4);
                        if (change == 2) request(0, 0, 0);
                    end
                    rgb = {xx[7:0], yy[7:0], (xx[7:0]^yy[7:0])};
                    if (yy >= 444 && yy < 460 && xx >= 160 && xx < 480) rgb = 24'hffffff;
                    in_hs = 1; in_vs = 1; in_de = 1; in_rgb = rgb;
                    reference_rgb = pixel(xx, yy, rgb); capture = save;
                end
                cycle(0, 1, 0, 24'h2468ac, dim(24'h2468ac, gold_level, gold_fade), 0);
                cycle(1, 1, 0, 24'h13579b, dim(24'h13579b, gold_level, gold_fade), 0);
            end
            idle(8);
        end
    endtask

    integer level, fade, value, mode, ii;
    reg [23:0] rgb;
    initial begin
        images[0] = $fopen("show_auto_on.ppm", "w");
        images[1] = $fopen("show_auto_off.ppm", "w");
        images[2] = $fopen("show_play.ppm", "w");
        images[3] = $fopen("show_pause.ppm", "w");
        images[4] = $fopen("show_end.ppm", "w");
        images[5] = $fopen("show_fade_half.ppm", "w");
        images[6] = $fopen("show_fade_black.ppm", "w");
        for (ii = 0; ii < 7; ii = ii+1) begin
            if (!images[ii]) $fatal(1, "Cannot create show OSD preview %0d", ii);
            pixels[ii] = 0;
            $fwrite(images[ii], "P3\n640 480\n255\n");
        end
        repeat (4) @(negedge video_clk);
        rst = 0;
        idle(8);
        for (value = 0; value < 256; value = value+1) begin
            rgb = {value[7:0], (8'd255-value[7:0]), (value[7:0]^8'ha5)};
            cycle(value[0], 1, 1, rgb, rgb, 0);
        end
        idle(8);
        // Every RGB channel exercises all 256 values at 4 brightness x 17 fade levels in both modes.
        for (mode = 0; mode < 2; mode = mode+1)
            for (level = 0; level < 4; level = level+1)
                for (fade = 0; fade <= 16; fade = fade+1) begin
                    commit(level, fade, mode == 0 ? 0 : 2);
                    for (value = 0; value < 256; value = value+1) begin
                        rgb = {value[7:0], (8'd255-value[7:0]), (value[7:0]^8'ha5)};
                        cycle(value[0], 1, 1, rgb, dim(rgb, gold_level, gold_fade), 0);
                    end
                    idle(8);
                end
        @(negedge video_clk); enable = 1;
        commit(3, 16, 1); frame(1, 0);
        commit(3, 16, 0); frame(2, 0);
        commit(0, 0, 2); frame(3, 1);
        // END arrives only in the next VS, with ended taking priority over simultaneously paused.
        gold_status = 4; frame(0, 0);
        commit(1, 7, 3); frame(4, 0);
        commit(2, 0, 4); frame(5, 0);
        commit(3, 8, 1); frame(6, 2);
        // This preceding half-faded frame cannot show the new fade/brightness/AUTO status early.
        gold_level = 0; gold_fade = 0; gold_status = 0; frame(7, 0);
        @(negedge video_clk); enable = 0;
        frame(0, 0);
        @(negedge video_clk); rst = 1;
        in_de = 0; in_rgb = 0; reference_rgb = 0; capture = 0;
        repeat (4) @(negedge video_clk);
        rst = 0; gold_level = 3; gold_fade = 16; gold_status = 0;
        idle(8);
        for (value = 0; value < 256; value = value+1) begin
            rgb = {value[7:0], (8'd255-value[7:0]), (value[7:0]^8'ha5)};
            cycle(value[0], 1, 1, rgb, rgb, 0);
        end
        idle(8);
        for (ii = 0; ii < 7; ii = ii+1) begin
            if (pixels[ii] != 640*480) $fatal(1, "Preview %0d has %0d pixels", ii, pixels[ii]);
            $fclose(images[ii]);
        end
        $display("PASS: show OSD checked %0d pixel/timing cycles; 4 brightness x 17 fade x 256 channels in PIC/VIDEO, nine full frames, AUTO ON/OFF PLAY/PAUSE/END glyphs, frame-atomic fade/status/brightness, full-intensity OSD at black, reset/enable and three-clock timing", checked);
        $finish;
    end
    initial begin
        #150000000;
        $fatal(1, "show OSD simulation timeout");
    end
endmodule
