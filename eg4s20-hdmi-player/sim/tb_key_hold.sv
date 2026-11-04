`timescale 1ns/1ps
module tb_key_hold;
reg clk=0;
always #10 clk=~clk;
reg rst=1, cancel=0, button_n=1;
wire short_pulse, long_pulse;
key_hold_actions #(.CLK_FREQ_HZ(1000), .DEBOUNCE_MS(3), .HOLD_MS(1500)) dut (.*);
integer shorts=0, longs=0;
always @(posedge clk) begin
    #1;
    if (!rst) begin
        if (short_pulse && long_pulse) $fatal(1, "Two actions in one cycle");
        if (short_pulse) shorts=shorts+1;
        if (long_pulse) longs=longs+1;
    end
end
task wait_cycles(input integer count);
    repeat(count) @(negedge clk);
endtask
task expect_counts(input integer s, input integer l);
    if(shorts!=s || longs!=l) $fatal(1,"Key actions got short=%0d long=%0d expected %0d/%0d",shorts,longs,s,l);
endtask
initial begin
    wait_cycles(4); rst=0; wait_cycles(10);
    button_n=0; wait_cycles(1); button_n=1; wait_cycles(1);
    button_n=0; wait_cycles(1); button_n=1; wait_cycles(10);
    expect_counts(0,0);
    button_n=0; wait_cycles(30); expect_counts(0,0);
    button_n=1; wait_cycles(10); expect_counts(1,0);
    button_n=0; wait_cycles(1530); expect_counts(1,1);
    wait_cycles(1600); expect_counts(1,1);
    button_n=1; wait_cycles(10); expect_counts(1,1);
    button_n=0; wait_cycles(1450); button_n=1; wait_cycles(10); expect_counts(2,1);
    button_n=0; wait_cycles(20); cancel=1; wait_cycles(1); cancel=0;
    wait_cycles(1600); expect_counts(2,1);
    button_n=1; wait_cycles(10); expect_counts(2,1);
    button_n=0; wait_cycles(20); button_n=1; wait_cycles(10); expect_counts(3,1);
    // Cancel before the pressed level has finished its debounce window.
    button_n=0; wait_cycles(2); cancel=1; wait_cycles(1); cancel=0;
    wait_cycles(1600); expect_counts(3,1);
    button_n=1; wait_cycles(12); expect_counts(3,1);
    button_n=0; wait_cycles(20); button_n=1; wait_cycles(10); expect_counts(4,1);
    button_n=0; wait_cycles(30); rst=1; button_n=1; wait_cycles(4);
    rst=0; wait_cycles(10); expect_counts(4,1);
    $display("PASS key hold: bounce rejection, release-only short, one long/no release short, threshold, mode cancellation and reset");
    $finish;
end
initial begin #1000000; $fatal(1,"Key test timeout"); end
endmodule
