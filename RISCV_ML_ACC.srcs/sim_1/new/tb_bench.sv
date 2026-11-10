`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/07/2026 12:42:09 PM
// Design Name: 
// Module Name: tb_bench
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module tb_bench;
    parameter string BUILD_DIR = "C:/FPGA/RISCV_ML_ACC/sw/rvtest/build";
    logic clk = 1'b0, rst = 1'b1;
    logic [3:0] led;
    int cycles;
    logic [31:0] plain, plain_unr, simple, unrolled;
 
    always #5 clk = ~clk;
 
    core_pipe dut (.clk(clk), .rst(rst), .btn(4'b0), .pc_out(), .led(led),
                    .imem_b_en(1'b0), .imem_b_we(4'b0), .imem_b_addr(32'b0), .imem_b_wdata(32'b0), .imem_b_rdata(),
                    .dmem_b_en(1'b0), .dmem_b_we(4'b0), .dmem_b_addr(32'b0), .dmem_b_wdata(32'b0), .dmem_b_rdata());
 
    initial begin
        $readmemh({BUILD_DIR, "/bench_dot.text.mem"}, dut.u_instr_mem.mem);
        $readmemh({BUILD_DIR, "/bench_dot.data.mem"}, dut.u_data_mem.mem);
        repeat (2) @(posedge clk); #1 rst = 1'b0;
        cycles = 0;
        while (dut.instr !== 32'h0000_006f && cycles < 100000) begin @(posedge clk); #1; cycles++; end
        repeat (5) @(posedge clk);
        plain    = dut.u_register_file.mem[8];    // s0
        plain_unr= dut.u_register_file.mem[23];   // s7
        simple   = dut.u_register_file.mem[9];    // s1
        unrolled = dut.u_register_file.mem[18];   // s2
        $display("check (gp)             : %s", dut.u_register_file.mem[3] == 1 ? "PASS, all four results match" : "FAIL");
        $display("dot product            : %0d", $signed(dut.u_register_file.mem[12]));
        $display("plain RV32IM           : %0d cycles (%.2f per element)", plain, plain / 256.0);
        $display("plain, unrolled x4     : %0d cycles (%.2f per element)", plain_unr, plain_unr / 256.0);
        $display("dot4.acc               : %0d cycles (%.2f per element)  speedup %.2fx over plain", simple, simple / 256.0, real'(plain) / simple);
        $display("dot4.acc, unrolled x4  : %0d cycles (%.2f per element)  speedup %.2fx over plain unrolled", unrolled, unrolled / 256.0, real'(plain_unr) / unrolled);
        $display("LEDs                   : %b", led);
        $finish;
    end
endmodule
