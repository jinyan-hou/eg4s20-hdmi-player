
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // KEY2: next image / restart video
    input                       key2,           // KEY4: image / video mode
    input                       key_brightness, // KEY3: brightness level

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // Native SD clock, bidirectional command and four data lines.
    output                      sd_dclk,
    inout                       sd_cmd,
    inout [3:0]                 sd_dat
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;
// Native 640x480 package; bind its verified CRC/count/LBA before board use.
parameter VIDEO_FPS = 10;
parameter VIDEO_WIDTH = 640;
parameter VIDEO_HEIGHT = 480;
parameter VIDEO_FRAME_COUNT = 2270;
parameter [31:0] VIDEO_FILE_LBA = 32'h0029d960;
parameter [31:0] VIDEO_HEADER_CRC32 = 32'hec836e38;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire [23:0] selected_rgb;
wire [23:0] subtitle_rgb;
wire subtitle_hs, subtitle_vs, subtitle_de;
wire [23:0] brightness_rgb;
wire brightness_hs, brightness_vs, brightness_de;
wire overlay_hs, overlay_vs, overlay_de;
wire [1:0] brightness_gray;
wire        display_valid;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;
wire        sd_write_ready;
wire        video_read_empty;
wire [11:0] frame_load_ms_bcd;
reg [7:0]   display_underflows;
reg         pixel_read_valid, display_corrupt, hdmi_input_stall;
wire [6:0]  seg_load_h, seg_load_t, seg_load_u, seg_empty_h, seg_empty_l;
reg [1:0]   write_ack_sd, read_ack_video;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;

wire bmp_valid, bmp_write_req, bmp_write_en;
wire [7:0] sd_error, sd_byte;
wire sd_init_done, sd_byte_valid, sd_block_end;
wire bmp_read_req, bmp_read_stop, av_read_req, av_read_stop;
wire [31:0] bmp_read_lba, av_read_lba;
wire [31:0] bmp_write_data;
wire [1:0] bmp_write_buf, bmp_disp_buf;
wire [3:0] bmp_state;
wire av_write_req, av_write_en;
wire [31:0] av_write_data;
wire [1:0] av_write_buf, av_disp_buf;
wire [3:0] av_state, av_play_state;
wire frame_ready_toggle, frame_ready_bank, frame_ready_last, frame_ack_toggle;
wire [31:0] frame_ready_number, file_sample_count;
wire pcm_we, pcm_bank, meta_we, av_valid;
wire [12:0] pcm_addr, meta_addr;
wire [15:0] pcm_data;
wire [7:0] meta_data;
wire short_press, long_press, mode_press;
reg mode_video;
reg [18:0] mode_reset_count;
reg video_paused_board, pic_short_toggle, pic_auto_toggle;
reg [1:0] paused_video_sync;
wire video_paused = paused_video_sync[1];
wire pic_next_toggle, pic_ack_toggle, pic_ready_toggle, pic_ready_bank, pic_display_bank;
wire [2:0] pic_image_count;
wire pic_auto_play;
wire [4:0] pic_fade_level;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 音频链路
wire rst_all;
wire base_rst = ~rst_n | ~audio_pll_lock;
assign rst_all = base_rst | (mode_reset_count != 0);
(* syn_preserve = 1 *) reg [1:0] reset_sd_pipe, reset_mem_pipe, reset_video_pipe, reset_serial_pipe;
reg [1:0] mode_sd_pipe;
wire mode_sd = mode_sd_pipe[1];
wire rst_sd = reset_sd_pipe[1];
wire rst_mem = reset_mem_pipe[1];
wire rst_video = reset_video_pipe[1];
wire rst_serial = reset_serial_pipe[1];
// Assert immediately; release each domain's reset on its own clock.
always @(posedge sd_card_clk or posedge rst_all)
    if (rst_all) reset_sd_pipe <= 2'b11;
    else reset_sd_pipe <= {reset_sd_pipe[0], 1'b0};
always @(posedge ext_mem_clk or posedge rst_all)
    if (rst_all) reset_mem_pipe <= 2'b11;
    else reset_mem_pipe <= {reset_mem_pipe[0], 1'b0};
always @(posedge video_clk or posedge rst_all)
    if (rst_all) reset_video_pipe <= 2'b11;
    else reset_video_pipe <= {reset_video_pipe[0], 1'b0};
always @(posedge hdmi_5x_clk or posedge rst_all)
    if (rst_all) reset_serial_pipe <= 2'b11;
    else reset_serial_pipe <= {reset_serial_pipe[0], 1'b0};
always @(posedge sd_card_clk or posedge rst_sd)
    if (rst_sd) mode_sd_pipe <= 2'b11;
    else mode_sd_pipe <= {mode_sd_pipe[0], mode_video};

key_press_debounce #(.CLK_FREQ_HZ(50_000_000)) u_mode_key (
    .clk(clk), .rst(base_rst), .button_in(key2), .press_pulse(mode_press));
key_hold_actions u_action_key (
    .clk(clk), .rst(base_rst), .cancel(mode_press), .button_n(key1),
    .short_pulse(short_press), .long_pulse(long_press));
brightness_control u_brightness_control (
    .clk(clk), .rst(base_rst), .key_brightness(key_brightness),
    .brightness_gray(brightness_gray));
always @(posedge clk or posedge base_rst) begin
    if (base_rst) begin
        mode_video <= 1'b1;
        mode_reset_count <= 19'd250000;
        video_paused_board <= 0;
        pic_short_toggle <= 0;
        pic_auto_toggle <= 0;
    end else begin
        if (mode_press) begin
            mode_video <= ~mode_video;
            mode_reset_count <= 19'd250000;
            video_paused_board <= 0;
            pic_short_toggle <= 0;
            pic_auto_toggle <= 0;
        end else if (mode_video && short_press) begin
            mode_reset_count <= 19'd250000;
            video_paused_board <= 0;
        end else if (mode_reset_count != 0)
            mode_reset_count <= mode_reset_count - 1'b1;
        else if (long_press) begin
            if (mode_video) video_paused_board <= ~video_paused_board;
            else pic_auto_toggle <= ~pic_auto_toggle;
        end else if (short_press && !mode_video)
            pic_short_toggle <= ~pic_short_toggle;
    end
end
always @(posedge video_clk or posedge rst_video)
    if (rst_video) paused_video_sync <= 0;
    else paused_video_sync <= {paused_video_sync[0], video_paused_board};

show_controller u_show_controller (
    .video_clk(video_clk), .rst(rst_video), .enable(!mode_video),
    .short_toggle(pic_short_toggle), .auto_toggle(pic_auto_toggle),
    .ready_toggle(pic_ready_toggle), .ready_bank(pic_ready_bank), .image_count(pic_image_count),
    .read_req(video_read_req), .read_req_ack(read_ack_video[1]),
    .next_toggle(pic_next_toggle), .ack_toggle(pic_ack_toggle),
    .display_bank(pic_display_bank), .display_valid(bmp_valid),
    .auto_play(pic_auto_play), .fade_level(pic_fade_level));
assign bmp_disp_buf = {1'b0, pic_display_bank};

// One native card controller serves the selected parser in the SD clock domain.
assign sd_card_write_req = mode_video ? av_write_req : bmp_write_req;
assign sd_card_write_en = mode_video ? av_write_en : bmp_write_en;
assign sd_card_write_data = mode_video ? av_write_data : bmp_write_data;
assign write_buf_idx = mode_video ? av_write_buf : bmp_write_buf;
assign disp_buf_idx = mode_video ? av_disp_buf : bmp_disp_buf;
assign display_valid = mode_video ? av_valid : bmp_valid;
assign state_code = mode_video ? ((av_state == 4'hE) ? 4'hE :
                                  (av_valid ? av_play_state : av_state)) :
                                  ((sd_error!=0) ? 4'hE : bmp_state);
always @(posedge sd_card_clk or posedge rst_sd)
    if (rst_sd) write_ack_sd <= 0;
    else write_ack_sd <= {write_ack_sd[0], sd_card_write_req_ack};
always @(posedge video_clk or posedge rst_video)
    if (rst_video) read_ack_video <= 0;
    else read_ack_video <= {read_ack_video[0], video_read_req_ack};

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (1'b0)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (1'b0)
);

// Preserve the existing startup lock signal; actual PCM uses video_clk.
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   ()
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd32800), // Verified FAT32 data-area LBA on this card.
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_sd | mode_sd),
    .next_toggle       (pic_next_toggle),
    .commit_ack_toggle (pic_ack_toggle),
    .ready_toggle      (pic_ready_toggle),
    .ready_bank        (pic_ready_bank),
    .image_count       (pic_image_count),
    .state_code        (bmp_state),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (bmp_write_buf),
    .disp_buf_idx      (),

    .write_req         (bmp_write_req),
    .write_req_ack     (write_ack_sd[1]),
    .write_en          (bmp_write_en),
    .write_data        (bmp_write_data),
    .sd_init_done      (sd_init_done),
    .sd_sec_read       (bmp_read_req),
    .sd_sec_read_addr  (bmp_read_lba),
    .sd_read_stop      (bmp_read_stop),
    .sd_sec_read_data  (sd_byte),
    .sd_sec_read_data_valid(sd_byte_valid && !mode_sd),
    .sd_sec_read_end   (sd_block_end && !mode_sd)
);

// ponytail: use the copied package's verified contiguous LBA; re-query after copying media.
avp_reader #(.FILE_LBA(VIDEO_FILE_LBA), .FRAME_COUNT(VIDEO_FRAME_COUNT),
             .VIDEO_FPS(VIDEO_FPS),
             .VIDEO_WIDTH(VIDEO_WIDTH), .VIDEO_HEIGHT(VIDEO_HEIGHT),
             .EXPECTED_HEADER_CRC32(VIDEO_HEADER_CRC32)) u_avp_reader (
    .clk(sd_card_clk), .rst(rst_sd | ~mode_sd),
    .sd_init_done(sd_init_done), .sd_valid(sd_byte_valid && mode_sd),
    .sd_end(sd_block_end && mode_sd), .sd_byte(sd_byte), .card_error(sd_error),
    .sd_read_req(av_read_req), .sd_read_lba(av_read_lba), .sd_read_stop(av_read_stop),
    .write_req(av_write_req), .write_req_ack(write_ack_sd[1]), .write_ready(sd_write_ready),
    .write_en(av_write_en), .write_data(av_write_data), .write_buf_idx(av_write_buf),
    .write_finish_toggle(frame_write_toggle_mem),
    .frame_ready_toggle(frame_ready_toggle), .frame_ready_bank(frame_ready_bank),
    .frame_ready_last(frame_ready_last), .frame_ready_number(frame_ready_number),
    .frame_ack_toggle(frame_ack_toggle),
    .pcm_we(pcm_we), .pcm_bank(pcm_bank), .pcm_addr(pcm_addr), .pcm_data(pcm_data),
    .meta_we(meta_we), .meta_addr(meta_addr), .meta_data(meta_data), .state_code(av_state),
    .frame_load_ms_bcd(frame_load_ms_bcd));

sd_native_4bit #(.MULTI_BLOCK_READ(1)) u_sd_native (
    .clk(sd_card_clk), .rst(rst_sd), .sd_clk(sd_dclk), .sd_cmd(sd_cmd), .sd_dat(sd_dat),
    .init_done(sd_init_done), .error(sd_error), .debug_state(),
    .read_req(mode_sd ? av_read_req : bmp_read_req),
    .read_lba(mode_sd ? av_read_lba : bmp_read_lba),
    .read_stop(mode_sd ? av_read_stop : bmp_read_stop),
    .data(sd_byte), .data_valid(sd_byte_valid), .block_end(sd_block_end));

avp_audio #(.AUDIO_SHIFT(0), .SAMPLES_PER_FRAME(48000/VIDEO_FPS)) u_avp_audio (
    .video_clk(video_clk), .rst(rst_video), .sd_clk(sd_card_clk), .paused(video_paused),
    .pcm_we(pcm_we), .pcm_bank(pcm_bank), .pcm_addr(pcm_addr), .pcm_data(pcm_data),
    .frame_ready_toggle(frame_ready_toggle), .frame_ready_bank(frame_ready_bank),
    .frame_ready_last(frame_ready_last), .frame_ready_number(frame_ready_number),
    .frame_ack_toggle(frame_ack_toggle),
    .video_read_req(video_read_req), .video_read_req_ack(read_ack_video[1]),
    .disp_buf_idx(av_disp_buf), .display_valid(av_valid), .sample_count(file_sample_count),
    .audio_valid(audio_valid), .audio_left_data(audio_left_data), .audio_right_data(audio_right_data),
    .play_state(av_play_state));

seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);
always @(posedge video_clk or posedge rst_video)
    if (rst_video) display_underflows <= 0;
    else if (display_valid && video_read_en && video_read_empty && display_underflows != 8'hff)
        display_underflows <= display_underflows + 1'b1;
// The unused pixel byte is always written as zero; nonzero readback proves corruption.
always @(posedge video_clk or posedge rst_video)
    if (rst_video) begin
        pixel_read_valid <= 0;
        display_corrupt <= 0;
        hdmi_input_stall <= 0;
    end else begin
        pixel_read_valid <= display_valid && video_read_en && !video_read_empty;
        if (pixel_read_valid && video_read_data[7:0] != 8'h00)
            display_corrupt <= 1;
        if (display_valid && axis_s_valid && !axis_s_ready)
            hdmi_input_stall <= 1;
    end
seg_decoder u_seg_load_h (.bin_data(frame_load_ms_bcd[11:8]), .seg_data(seg_load_h));
seg_decoder u_seg_load_t (.bin_data(frame_load_ms_bcd[7:4]), .seg_data(seg_load_t));
seg_decoder u_seg_load_u (.bin_data(frame_load_ms_bcd[3:0]), .seg_data(seg_load_u));
seg_decoder u_seg_empty_h (.bin_data(display_underflows[7:4]), .seg_data(seg_empty_h));
seg_decoder u_seg_empty_l (.bin_data(display_underflows[3:0]), .seg_data(seg_empty_l));

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,seg_load_h}),
    .seg_data_1        ({1'b1,seg_load_t}),
    .seg_data_2        ({~hdmi_input_stall,seg_load_u}),
    .seg_data_3        ({1'b1,seg_empty_h}),
    .seg_data_4        ({1'b1,seg_empty_l}),
    .seg_data_5        ({~display_corrupt,seg_data_0})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_req          (video_read_req),
    .read_req_ack      (read_ack_video[1]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
assign selected_rgb = display_valid ? vout_data_raw : 24'd0;
avp_subtitles u_avp_subtitles (
    .video_clk(video_clk), .rst(rst_video), .sd_clk(sd_card_clk),
    .meta_we(meta_we), .meta_addr(meta_addr), .meta_data(meta_data),
    .enable(mode_video & av_valid), .sample_count(file_sample_count),
    .in_hs(hs), .in_vs(vs), .in_de(de), .in_rgb(selected_rgb),
    .out_hs(subtitle_hs), .out_vs(subtitle_vs), .out_de(subtitle_de), .out_rgb(subtitle_rgb));
brightness_osd u_brightness_osd (
    .video_clk(video_clk), .rst(rst_video), .enable(display_valid),
    .brightness_gray(brightness_gray),
    .fade_level(pic_fade_level), .mode_video(mode_video),
    .video_paused(video_paused), .video_ended(av_play_state == 4'd8), .auto_play(pic_auto_play),
    .in_hs(subtitle_hs), .in_vs(subtitle_vs), .in_de(subtitle_de), .in_rgb(subtitle_rgb),
    .out_hs(brightness_hs), .out_vs(brightness_vs), .out_de(brightness_de), .out_rgb(brightness_rgb));
audio_waveform u_audio_waveform (
    .video_clk(video_clk), .rst(rst_video), .enable(mode_video & av_valid),
    .audio_valid(audio_valid), .audio_data(audio_left_data),
    .in_hs(brightness_hs), .in_vs(brightness_vs), .in_de(brightness_de), .in_rgb(brightness_rgb),
    .out_hs(overlay_hs), .out_vs(overlay_vs), .out_de(overlay_de), .out_rgb(vout_data));

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (24'd0),
    .read_addr_3       (24'd0),
    .read_addr_index   (disp_buf_idx),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (24'd0),
    .write_addr_3      (24'd0),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .write_ready       (sd_write_ready),
    .read_empty        (video_read_empty)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// Actual TF PCM, including 48 kHz silence while waiting for a frame.
audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_vs          (overlay_vs),
    .I_de          (overlay_de),
    .I_rgb         (vout_data),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_video),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_video),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_serial),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
