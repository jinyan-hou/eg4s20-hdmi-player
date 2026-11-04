if {[catch {
    if {[info exists ::env(ANLOGIC_LICENSE)] && $::env(ANLOGIC_LICENSE) ne ""} {
        val_license -f $::env(ANLOGIC_LICENSE)
    }
    import_device eagle_s20.db -package EG4S20BG256
    set project_root [file normalize [file dirname [info script]]]
    foreach relative_file {
        src/user_source/hdl_source/audio_arc_calculate.v
        src/user_source/hdl_source/hdmi_phy_warpper.v
        src/user_source/hdl_source/lane_lvds_10_1.v
        src/user_source/hdl_source/startup_pulse.v
        src/user_source/hdl_source/SD/color_bar.v
        src/user_source/hdl_source/SD/seg_decoder.v
        src/user_source/hdl_source/SD/seg_scan.v
        src/user_source/hdl_source/SD/video_delay.v
        src/user_source/hdl_source/SD/video_timing_data.v
        src/user_source/hdl_source/SD/video_define.v
        src/user_source/hdl_source/SD/sdram.v
        src/user_source/hdl_source/hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v
        src/user_source/hdl_source/include/sdr_as_ram.enc.v
        src/user_source/hdl_source/include/sdr_init_ref.enc.v
        src/user_source/hdl_source/include/sdr_wrrd.enc.v
        src/user_source/hdl_source/include/global_def.v
        src/td_project/al_ip/PLL_HDMI_AUDIO.v
        src/td_project/al_ip/PLL_HDMI_AUDIO.vhd
        src/user_source/hdl_source/IP/afifo_16_32_256.v
        src/user_source/hdl_source/IP/afifo_16_32_256.tcl
        src/user_source/hdl_source/IP/afifo_32_16_256.v
        src/user_source/hdl_source/IP/afifo_32_16_256.tcl
        src/user_source/hdl_source/IP/sys_pll.v
        src/user_source/hdl_source/IP/sys_pll.vhd
        src/user_source/hdl_source/IP/video_pll.v
        src/user_source/hdl_source/IP/video_pll.vhd
    } {
        if {![file isfile [file join $project_root $relative_file]]} {
            error "Missing vendor dependency: $relative_file. See docs/DEPENDENCIES.md before building."
        }
    }
    set project_directory [file join $project_root src/td_project]
    cd $project_directory
    open_project HDMI1.4b_Transmitter_v1.0.al -single_run
    load_run_param -run syn_1
    elaborate -top top
    read_adc ../user_source/constraints_source/pin.adc
    read_sdc ../user_source/constraints_source/timing.sdc
    read_sdc -ip rfifo_32_32_512 ../user_source/hdl_source/IP/afifo_32_16_256.tcl
    read_sdc -ip wfifo_32_32_512 ../user_source/hdl_source/IP/afifo_16_32_256.tcl
    optimize_rtl
    optimize_gate -packarea video_show_gate.area
    legalize_phy_inst
    read_sdc ../user_source/constraints_source/timing.sdc
    read_sdc -ip rfifo_32_32_512 ../user_source/hdl_source/IP/afifo_32_16_256.tcl
    read_sdc -ip wfifo_32_32_512 ../user_source/hdl_source/IP/afifo_16_32_256.tcl
    load_run_param -run phy_1
    place
    route
    report_area -io_info -file video_show_phy.area
    update_timing -mode final
    report_timing_summary -file video_show_pr.timing
    report_timing_status -file video_show_phy.ts
    report_timing_exception -ep_num 20 -file video_show_sd_io.timing
    report_timing_ignored -ep_num 20 -file video_show_ignored.timing
    set timing_file [open video_show_phy.ts r]
    set timing_text [read $timing_file]
    close $timing_file
    foreach metric {STNS HTNS} {
        if {![regexp [format {%s:\s*(-?[0-9.]+)ns} $metric] $timing_text -> value] || $value < 0} {
            error "Timing failed: $metric; bit generation stopped."
        }
    }
    bitgen -bit video_show_640x480_10fps_normal_audio.bit
    close_project
} message]} {
    puts stderr $message
    exit 1
}
exit

