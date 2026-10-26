`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/24/2026 03:47:55 PM
// Design Name: 
// Module Name: muldiv
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

module muldiv
    import riscv_pkg::*;     
(
    input  logic [2:0]     funct3,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] out
);

 logic               a_signed, b_signed;
    logic signed [32:0] a_ext, b_ext;
    logic signed [65:0] product;

    assign a_signed = (funct3 == 3'b001) || (funct3 == 3'b010);   // mulh, mulhsu
    assign b_signed = (funct3 == 3'b001);                         // mulh only

    assign a_ext   = {a_signed & a[31], a};
    assign b_ext   = {b_signed & b[31], b};
    assign product = a_ext * b_ext;        

    // ------------------------------------------------------------------
    // DIVIDE: RISC-V defines results for the two special cases (no traps).
    // ------------------------------------------------------------------
    logic div_by_zero, overflow;
    assign div_by_zero = (b == 32'd0);
    assign overflow    = (a == 32'h8000_0000) && (b == 32'hFFFF_FFFF);   // -2^31 / -1

    always_comb begin
        out = '0;
        case (funct3)
            3'b000: out = product[31:0];                  // mul:   low 32 bits
            3'b001,
            3'b010,
            3'b011: out = product[63:32];                 // mulh, mulhsu, mulhu: high 32 bits

            3'b100: begin                                    // div
                if (div_by_zero)   out = 32'hFFFF_FFFF;
                else if (overflow) out = 32'h8000_0000;
                else               out = $signed(a) / $signed(b);
            end
            3'b101: begin                                    // divu
                if (div_by_zero)   out = 32'hFFFF_FFFF;
                else               out = a / b;
            end
            3'b110: begin                                    // rem
                if (div_by_zero)   out = a;
                else if (overflow) out = 32'd0;
                else               out = $signed(a) % $signed(b);
            end
            3'b111: begin                                    // remu
                if (div_by_zero)   out = a;
                else               out = a % b;
            end
        endcase
    end

endmodule