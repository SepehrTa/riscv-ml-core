`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/03/2026 05:09:42 PM
// Design Name: 
// Module Name: ml_unit
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

module ml_unit (
    input  logic        clk,
    input  logic        rst,
    input  logic        valid,      // a custom-0 instruction is in MEM (0 for bubbles)
    input  logic [2:0]  funct3,     // which operation
    input  logic [31:0] a,          // rs1: four packed int8 values
    input  logic [31:0] b,          // rs2: four packed int8 values
    output logic [31:0] out         // result for dot4 and acc.rd
);

    logic signed [15:0] p0, p1, p2, p3;   // the four products (int8 x int8 fits 16 bits)
    logic signed [17:0] dot;              // their sum: |dot| <= 4 * 128 * 128 = 65536, fits 18 bits
    logic        [31:0] dot32;            // dot sign-extended to 32 bits
    logic        [31:0] acc;              // the accumulator

    // ---------- four signed 8x8 multiplies ----------
    assign p0 = $signed(a[7:0])   * $signed(b[7:0]);
    assign p1 = $signed(a[15:8])  * $signed(b[15:8]);
    assign p2 = $signed(a[23:16]) * $signed(b[23:16]);
    assign p3 = $signed(a[31:24]) * $signed(b[31:24]);

    // ---------- adder tree ----------
    assign dot   = (p0 + p1) + (p2 + p3);          // all signed: operands are sign-extended to 18 bits
    assign dot32 = {{14{dot[17]}}, dot};

    // ---------- result ----------
    always_comb begin
        case (funct3)
            3'b000:  out = dot32;          // dot4
            3'b011:  out = acc;            // acc.rd
            default: out = 32'd0;          // dot4.acc and acc.set write no register
        endcase
    end

    // ---------- accumulator ----------
    always_ff @(posedge clk) begin
        if (rst)
            acc <= 32'd0;
        else if (valid) begin
            case (funct3)
                3'b001:  acc <= acc + dot32;   // dot4.acc
                3'b010:  acc <= a;             // acc.set
                default: ;                     // dot4, acc.rd: acc unchanged
            endcase
        end
    end

endmodule