`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/21/2026 04:01:00 PM
// Design Name: 
// Module Name: register_file
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


module register_file(
        input logic clk,
        input logic we,
        input logic[4:0] waddr,
        input logic[31:0] wdata,
        input logic[4:0] raddr1,
        output logic[31:0] rdata1,
        input logic[4:0] raddr2,
        output  logic[31:0] rdata2  
    );
    logic [31:0] mem [32];
    always_ff @(posedge clk) begin
        if (we == 1) begin
            mem[waddr] <= wdata; 
        end
    end
    always_comb begin
        
        rdata1 = raddr1?mem[raddr1]:32'h0;
        rdata2 = raddr2?mem[raddr2]:32'h0;
    end
    
endmodule
