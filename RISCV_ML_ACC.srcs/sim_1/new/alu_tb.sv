`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/15/2026 04:55:44 PM
// Design Name: 
// Module Name: alu_tb
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

module alu_tb;
    import riscv_pkg::*;

    // 1) Signals that drive the DUT and receive its output
    alu_op_t     alu_op;
    logic [31:0] inp1;
    logic [31:0] inp2;
    logic [31:0] out;

    int errors = 0;
    int tests  = 0;

    alu_op_t     r_op;                                  // ADDED: variables for the random loop
    logic [31:0] r_a;                                   // ADDED
    logic [31:0] r_b;                                   // ADDED

    // 2) The design under test (DUT), ports connected by name
    alu dut (
        .alu_op (alu_op),
        .inp1   (inp1),
        .inp2   (inp2),
        .out (out)
    );

    // 3) One reusable check: apply inputs, wait, compare, report
    task automatic check(input alu_op_t opp, input logic [31:0] a, input logic [31:0] b);
        logic [31:0] expected;
        case (opp)
        ALU_ADD     :   expected = a + b;        
        ALU_SUB     :   expected = a + ~b + 32'd1;      // CHANGED: two's complement instead of '-'
        ALU_SLL     :   begin                           // CHANGED: shift one bit at a time
                            expected = a;
                            for (int i = 0; i < b[4:0]; i++) expected = {expected[30:0], 1'b0};
                        end
        ALU_SRL     :   begin                           // CHANGED: fill with 0, one bit at a time
                            expected = a;
                            for (int i = 0; i < b[4:0]; i++) expected = {1'b0, expected[31:1]};
                        end
        ALU_SRA     :   begin                           // CHANGED: fill with sign bit, one bit at a time
                            expected = a;
                            for (int i = 0; i < b[4:0]; i++) expected = {expected[31], expected[31:1]};
                        end
        ALU_SLT     :   expected = (a[31] != b[31]) ? {31'd0, a[31]}      // CHANGED: signs differ -> negative is smaller
                                                    : {31'd0, (a < b)};   //          same sign -> plain compare
        ALU_SLTU    :   expected = a < b ? 32'd1: 32'd0 ;     
        ALU_XOR     :   expected = a ^ b;
        ALU_OR      :   expected = a | b;  
        ALU_AND     :   expected = a & b;
        default: expected = '0;
        endcase
        
        alu_op = opp;
        inp1 = a;
        inp2 = b;
        #1;                                    // let the combinational logic settle
        

        
        tests++;
        if (out !== expected) begin
            errors++;
            $display("FAIL  alu_op=%s inp1=%h inp2=%h  out=%h  expected=%h", opp.name(), a, b, out, expected);   // CHANGED
        end                                                                                                      // CHANGED: PASS line removed
    endtask
    initial begin
    
    for (int i = 0; i < 1000; i++) begin
        r_op = alu_op_t'($urandom_range(9, 0));   // random operation
        r_a  = $urandom;                          // random inputs
        r_b  = $urandom;
        check(r_op, r_a, r_b);
    end
    

        $display("\n%0d tests, %0d errors", tests, errors);
        if (errors == 0) $display("*** ALL TESTS PASSED ***");
        else             $display("*** SOME TESTS FAILED ***");
        $finish;
    end

endmodule