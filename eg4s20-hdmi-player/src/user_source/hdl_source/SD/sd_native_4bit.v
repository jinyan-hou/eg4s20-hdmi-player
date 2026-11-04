`timescale 1ns/1ps
// Read-only, 3.3 V default-speed SD bus. SPI cards require a card power cycle.
// ponytail: sampling assumes a 100 MHz core; redesign timing before enabling faster SD.
module sd_native_4bit #(
    parameter CLK_FREQ_HZ=100_000_000,
    parameter INIT_HALF_CYCLES=125,
    parameter FAST_HALF_CYCLES=2,
    parameter POWERUP_CYCLES=100_000,
    parameter MULTI_BLOCK_READ=1,
    parameter TIMEOUT_CYCLES=CLK_FREQ_HZ
)(input clk,rst, inout sd_cmd, inout [3:0] sd_dat, output reg sd_clk,
  output reg init_done, output reg [7:0] error, output [7:0] debug_state,
  input read_req, input [31:0] read_lba, input read_stop,
  output reg data_valid, output reg [7:0] data, output reg block_end);

localparam POWER=0,CLOCKS=1,IGAP=2,ISEND=3,IWAIT=4,IBUSY=5,
           HALT=6,RGAP=7,RSEND=8,RWAIT=9,RDATA=10,RARM=11,
           SGAP=12,SSEND=13,SWAIT=14,SBUSY=15,FAILED=16;
reg [4:0] state;
reg [3:0] init_step;
reg [31:0] power_count,init_timer,wait_timer,current_lba,next_lba,pending_lba;
reg [15:0] rca;
reg block_addressed,fast_mode,stream_active,request_armed,stop_then_read;
reg [7:0] gap_count;
reg [15:0] half_count;
reg packet_done;
reg [7:0] data_error;
localparam D_IDLE=0,D_WAIT=1,D_PAYLOAD=2,D_CRC=3,D_END=4,D_DONE=5;
reg [2:0] dstate;
reg [7:0] sample_pipe;
wire sample_tick=fast_mode ? sample_pipe[3] : sample_pipe[7];
wire clock_run=(state!=POWER && state!=HALT && state!=FAILED && !packet_done && data_error==0 &&
                !(dstate==D_END && sample_tick));
wire [15:0] half_limit=fast_mode ? FAST_HALF_CYCLES-1 : INIT_HALF_CYCLES-1;
wire edge_tick=(clock_run || sd_clk) && half_count>=half_limit;
wire rise_tick=edge_tick && !sd_clk;
wire fall_tick=edge_tick && sd_clk;
reg cmd_sample;
reg [3:0] dat_sample;
always @(posedge clk)begin cmd_sample<=sd_cmd;dat_sample<=sd_dat;end
assign debug_state={3'd0,state};
assign sd_dat=4'bzzzz;

always @(posedge clk or posedge rst) begin
    if(rst) begin sd_clk<=0;half_count<=0;sample_pipe<=0;end
    else begin
        // Capture at +30 ns fast/+70 ns init; parse registered IO one tick later.
        sample_pipe<={sample_pipe[6:0],rise_tick};
        if(clock_run || sd_clk) begin
            if(edge_tick)begin sd_clk<=!sd_clk;half_count<=0;end
            else half_count<=half_count+1'b1;
        end else half_count<=0;
    end
end

function [6:0] crc7_bit;
    input [6:0] value; input bit_value;
    begin crc7_bit={value[5:0],1'b0} ^ ((value[6]^bit_value) ? 7'h09 : 7'h00);end
endfunction
function [15:0] crc16_bit;
    input [15:0] value; input bit_value;
    begin crc16_bit={value[14:0],1'b0} ^ ((value[15]^bit_value) ? 16'h1021 : 16'h0000);end
endfunction

// Independent command engine. CRC7 is computed serially before transmitting.
localparam C_IDLE=0,C_CRC=1,C_TX=2,C_TXEND=3,C_WAIT=4,C_RX=5,C_CHECK=6;
reg [2:0] cstate;
reg cmd_start,cmd_done,cmd_oe,cmd_out;
reg [5:0] cmd_number,latched_cmd;
reg [31:0] cmd_arg;
reg [1:0] cmd_response,latched_response;
reg cmd_check_crc,latched_check_crc;
reg [7:0] cmd_error;
reg [39:0] cmd_payload,crc_payload;
reg [47:0] tx_shift;
reg [7:0] tx_count,rx_count;
reg [5:0] crc_count;
reg [6:0] tx_crc,rx_crc;
reg [135:0] response;
reg [31:0] cmd_timer;
reg r1_bad;
assign sd_cmd=cmd_oe ? cmd_out : 1'bz;
always @(posedge clk or posedge rst) begin
    if(rst)begin
        cstate<=C_IDLE;cmd_done<=0;cmd_error<=0;cmd_oe<=0;cmd_out<=1;
        tx_crc<=0;rx_crc<=0;response<=0;tx_count<=0;rx_count<=0;cmd_timer<=0;
        cmd_payload<=0;crc_payload<=0;tx_shift<=0;crc_count<=0;
        latched_cmd<=0;latched_response<=0;latched_check_crc<=0;r1_bad<=0;
    end else begin
        cmd_done<=0;
        if(cstate==C_WAIT || cstate==C_RX)cmd_timer<=cmd_timer+1'b1;else cmd_timer<=0;
        case(cstate)
            C_IDLE: if(cmd_start)begin
                cmd_payload<={2'b01,cmd_number,cmd_arg};crc_payload<={2'b01,cmd_number,cmd_arg};
                latched_cmd<=cmd_number;latched_response<=cmd_response;latched_check_crc<=cmd_check_crc;
                tx_crc<=0;crc_count<=0;cmd_error<=0;response<=0;rx_crc<=0;cstate<=C_CRC;
            end
            C_CRC:begin
                tx_crc<=crc7_bit(tx_crc,crc_payload[39]);crc_payload<={crc_payload[38:0],1'b0};
                if(crc_count==39)begin
                    tx_shift<={cmd_payload,crc7_bit(tx_crc,crc_payload[39]),1'b1};tx_count<=0;cstate<=C_TX;
                end else crc_count<=crc_count+1'b1;
            end
            C_TX: if(fall_tick)begin
                cmd_oe<=1;cmd_out<=tx_shift[47];tx_shift<={tx_shift[46:0],1'b1};
                if(tx_count==47)cstate<=C_TXEND;else tx_count<=tx_count+1'b1;
            end
            C_TXEND:if(sample_tick)begin
                cmd_oe<=0;
                if(latched_response==0)begin cmd_done<=1;cstate<=C_IDLE;end
                else begin rx_count<=0;rx_crc<=0;cstate<=C_WAIT;end
            end
            C_WAIT:if(sample_tick && cmd_sample==1'b0)begin
                response<=0;rx_count<=1;rx_crc<=0;cstate<=C_RX;
            end
            C_RX:if(sample_tick)begin
                response<={response[134:0],cmd_sample};
                if(latched_response==2)begin
                    if(rx_count>=8 && rx_count<128)rx_crc<=crc7_bit(rx_crc,cmd_sample);
                end else if(rx_count<40)rx_crc<=crc7_bit(rx_crc,cmd_sample);
                if(rx_count==((latched_response==2) ? 135 : 47))cstate<=C_CHECK;
                else rx_count<=rx_count+1'b1;
            end
            C_CHECK:begin
                r1_bad<=((response[39:8] & 32'hfdffe008)!=0);
                if(response[0]!=1'b1 ||
                   (latched_response==2 ? response[134]!=0 : response[46]!=0))cmd_error<=8'h22;
                else if(latched_check_crc && response[7:1]!=rx_crc)cmd_error<=8'h21;
                else if(latched_response==1 && latched_check_crc && response[45:40]!=latched_cmd)cmd_error<=8'h23;
                cmd_done<=1;cstate<=C_IDLE;
            end
            default:cstate<=C_IDLE;
        endcase
        if((cstate==C_WAIT || cstate==C_RX) && cmd_timer>=TIMEOUT_CYCLES-1)begin
            cmd_error<=8'h24;cmd_done<=1;cmd_oe<=0;cstate<=C_IDLE;
        end
        if(state==FAILED)begin cmd_oe<=0;cstate<=C_IDLE;end
    end
end

// Data runs independently of CMD response reception: legal early data is retained.
reg data_arm;
reg [10:0] nibble_count;
reg [4:0] data_crc_count;
reg [3:0] high_nibble;
reg [15:0] lane_crc[0:3],lane_received[0:3];
integer lane;
wire crc_bad=(lane_crc[0]!=lane_received[0] || lane_crc[1]!=lane_received[1] ||
              lane_crc[2]!=lane_received[2] || lane_crc[3]!=lane_received[3]);
always @(posedge clk or posedge rst)begin
    if(rst)begin
        dstate<=D_IDLE;data_valid<=0;data<=0;packet_done<=0;data_error<=0;
        nibble_count<=0;data_crc_count<=0;high_nibble<=0;
        for(lane=0;lane<4;lane=lane+1)begin lane_crc[lane]<=0;lane_received[lane]<=0;end
    end else begin
        data_valid<=0;packet_done<=0;
        if(data_arm)begin
            dstate<=D_WAIT;nibble_count<=0;data_crc_count<=0;data_error<=0;
            for(lane=0;lane<4;lane=lane+1)begin lane_crc[lane]<=0;lane_received[lane]<=0;end
        end else if(sample_tick)case(dstate)
            D_WAIT:if(dat_sample[0]==0)begin
                if(dat_sample!=4'b0000)begin data_error<=8'h31;dstate<=D_DONE;end
                else dstate<=D_PAYLOAD;
            end
            D_PAYLOAD:begin
                for(lane=0;lane<4;lane=lane+1)lane_crc[lane]<=crc16_bit(lane_crc[lane],dat_sample[lane]);
                if(!nibble_count[0])high_nibble<=dat_sample;
                else begin data<={high_nibble,dat_sample};data_valid<=1;end
                if(nibble_count==1023)begin dstate<=D_CRC;data_crc_count<=0;end
                else nibble_count<=nibble_count+1'b1;
            end
            D_CRC:begin
                for(lane=0;lane<4;lane=lane+1)lane_received[lane]<={lane_received[lane][14:0],dat_sample[lane]};
                if(data_crc_count==15)dstate<=D_END;else data_crc_count<=data_crc_count+1'b1;
            end
            D_END:begin
                if(dat_sample!=4'b1111)data_error<=8'h33;
                else if(crc_bad)data_error<=8'h32;
                else packet_done<=1;
                dstate<=D_DONE;
            end
        endcase
    end
end

wire [31:0] status=response[39:8];
always @(posedge clk or posedge rst)begin
    if(rst)begin
        state<=POWER;init_step<=0;power_count<=0;init_timer<=0;wait_timer<=0;
        rca<=0;block_addressed<=0;fast_mode<=0;init_done<=0;error<=0;
        stream_active<=0;request_armed<=1;stop_then_read<=0;gap_count<=0;
        current_lba<=0;next_lba<=0;pending_lba<=0;
        cmd_start<=0;cmd_number<=0;cmd_arg<=0;cmd_response<=0;cmd_check_crc<=1;
        data_arm<=0;block_end<=0;
    end else begin
        cmd_start<=0;data_arm<=0;block_end<=0;
        if(!read_req)request_armed<=1;
        if(!init_done && state!=POWER && state!=FAILED)init_timer<=init_timer+1'b1;
        if(state==RDATA || state==RWAIT || state==IBUSY || state==SBUSY)wait_timer<=wait_timer+1'b1;
        else wait_timer<=0;
        case(state)
            POWER:if(power_count>=POWERUP_CYCLES-1)begin state<=CLOCKS;gap_count<=0;end
                  else power_count<=power_count+1'b1;
            CLOCKS:if(rise_tick)begin
                if(gap_count==79)begin state<=IGAP;gap_count<=0;end else gap_count<=gap_count+1'b1;
            end
            IGAP:if(rise_tick)begin
                if(gap_count==7)begin state<=ISEND;gap_count<=0;end else gap_count<=gap_count+1'b1;
            end
            ISEND:begin
                cmd_start<=1;cmd_check_crc<=1;cmd_response<=1;cmd_arg<=0;state<=IWAIT;
                case(init_step)
                    0:begin cmd_number<=0;cmd_response<=0;end
                    1:begin cmd_number<=8;cmd_arg<=32'h000001aa;end
                    2:cmd_number<=55;
                    3:begin cmd_number<=41;cmd_arg<=32'h40ff8000;cmd_check_crc<=0;end
                    4:begin cmd_number<=2;cmd_response<=2;end
                    5:cmd_number<=3;
                    6:begin cmd_number<=7;cmd_arg<={rca,16'd0};end
                    7:begin cmd_number<=55;cmd_arg<={rca,16'd0};end
                    8:begin cmd_number<=6;cmd_arg<=2;end
                    9:begin cmd_number<=16;cmd_arg<=512;end
                endcase
            end
            IWAIT:if(cmd_done)begin
                if(cmd_error!=0)begin error<=cmd_error;state<=FAILED;end
                else case(init_step)
                    0:begin init_step<=1;state<=IGAP;end
                    1:if(status!=32'h000001aa)begin error<=8'h11;state<=FAILED;end
                      else begin init_step<=2;state<=IGAP;end
                    2,7:if(r1_bad || !status[5])begin error<=8'h13;state<=FAILED;end
                        else begin init_step<=init_step+1'b1;state<=IGAP;end
                    3:if(!status[31])begin init_step<=2;state<=IGAP;end
                      else if((status & 32'h00ff8000)==0)begin error<=8'h14;state<=FAILED;end
                      else begin block_addressed<=status[30];init_step<=4;state<=IGAP;end
                    4:begin init_step<=5;state<=IGAP;end
                    5:if(status[31:16]==0 || (status[15:0]&16'he000)!=0)begin error<=8'h15;state<=FAILED;end
                      else begin rca<=status[31:16];init_step<=6;state<=IGAP;end
                    6:if(r1_bad)begin error<=8'h16;state<=FAILED;end
                      else begin gap_count<=0;state<=IBUSY;end
                    8:if(r1_bad)begin error<=8'h18;state<=FAILED;end
                      else if(!block_addressed)begin init_step<=9;state<=IGAP;end
                      else begin fast_mode<=1;init_done<=1;state<=HALT;end
                    9:if(r1_bad)begin error<=8'h19;state<=FAILED;end
                      else begin fast_mode<=1;init_done<=1;state<=HALT;end
                    default:begin error<=8'h1f;state<=FAILED;end
                endcase
            end
            IBUSY:if(sample_tick)begin
                if(gap_count<8)gap_count<=gap_count+1'b1;
                else if(dat_sample[0]==1)begin init_step<=7;gap_count<=0;state<=IGAP;end
            end
            HALT:begin
                gap_count<=0;
                if(read_stop && stream_active)begin stop_then_read<=0;state<=SGAP;end
                else if(read_req && request_armed && !read_stop)begin
                    request_armed<=0;current_lba<=read_lba;
                    if(stream_active && read_lba==next_lba)state<=RARM;
                    else if(stream_active)begin pending_lba<=read_lba;stop_then_read<=1;state<=SGAP;end
                    else state<=RGAP;
                end
            end
            RGAP:if(rise_tick)begin
                if(gap_count==7)begin state<=RSEND;gap_count<=0;end else gap_count<=gap_count+1'b1;
            end
            RSEND:begin
                cmd_number<=MULTI_BLOCK_READ ? 18 : 17;
                cmd_arg<=block_addressed ? current_lba : (current_lba<<9);
                cmd_response<=1;cmd_check_crc<=1;cmd_start<=1;data_arm<=1;
                stream_active<=MULTI_BLOCK_READ!=0;state<=RWAIT;
            end
            RWAIT:if(cmd_done)begin
                if(cmd_error!=0 || r1_bad)begin error<=(cmd_error!=0) ? cmd_error : 8'h41;state<=FAILED;end
                else state<=RDATA;
            end
            RARM:begin data_arm<=1;state<=RDATA;end
            RDATA:if(packet_done)begin block_end<=1;next_lba<=current_lba+1'b1;state<=HALT;end
            SGAP:if(rise_tick)begin
                if(gap_count==7)begin state<=SSEND;gap_count<=0;end else gap_count<=gap_count+1'b1;
            end
            SSEND:begin
                cmd_number<=12;cmd_arg<=0;cmd_response<=1;cmd_check_crc<=1;cmd_start<=1;state<=SWAIT;
            end
            SWAIT:if(cmd_done)begin
                if(cmd_error!=0 || r1_bad)begin error<=(cmd_error!=0) ? cmd_error : 8'h42;state<=FAILED;end
                else begin state<=SBUSY;gap_count<=0;end
            end
            SBUSY:if(sample_tick)begin
                if(gap_count<8)gap_count<=gap_count+1'b1;
                else if(dat_sample[0]==1)begin
                    stream_active<=0;gap_count<=0;
                    if(stop_then_read)begin current_lba<=pending_lba;state<=RGAP;end
                    else state<=HALT;
                end
            end
            FAILED:begin init_done<=0;end
            default:begin error<=8'hff;state<=FAILED;end
        endcase
        if(data_error!=0)begin error<=data_error;state<=FAILED;init_done<=0;end
        if(wait_timer>=TIMEOUT_CYCLES-1)begin error<=8'h43;state<=FAILED;init_done<=0;end
        if(!init_done && init_timer>=TIMEOUT_CYCLES-1 && state!=FAILED)begin error<=8'h12;state<=FAILED;end
    end
end
endmodule
