`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/22/2026 05:54:06 PM
// Design Name: 
// Module Name: branch_comparator
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


module branch_comparator(
        input logic [31:0] a,
        input logic [31:0] b,
        input logic [2:0] func,
        output logic bout
        
    );
    
    always_comb begin
        bout = 0;
        case (func)
            3'b000: bout = a == b ? 1 : 0;
            3'b001: bout = !(a == b ? 1 : 0);
            3'b100: bout = $signed (a) < $signed (b) ? 1 : 0;
            3'b101: bout = $signed (a) >= $signed (b) ? 1 : 0;
            3'b110: bout = $unsigned (a) < $unsigned (b) ? 1 : 0;
            3'b111: bout = $unsigned (a) >= $unsigned (b) ? 1 : 0;   
        endcase
    end
endmodule
