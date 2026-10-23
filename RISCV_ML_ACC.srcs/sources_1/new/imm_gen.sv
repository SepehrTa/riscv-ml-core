`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: imm_gen
// Description: Immediate generator. Collects the immediate bits from the
//              instruction for the format chosen by imm_sel, puts them in
//              order, and extends the result to 32 bits.
//              Each concatenation lists pieces from bit 31 down to bit 0.
//////////////////////////////////////////////////////////////////////////////////

module imm_gen
    import riscv_pkg::*;
(
    input  logic [31:0] instr,
    input  imm_sel_t    imm_sel,
    output logic [31:0] imm
);

    always_comb begin
        imm = '0;
        case (imm_sel)
            //                 sign bits          immediate pieces                                   widths
            IMM_I:   imm = {{20{instr[31]}}, instr[31:20]};                                       // 20+12
            IMM_S:   imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};                          // 20+7+5
            IMM_B:   imm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};          // 20+1+6+4+1
            IMM_U:   imm = {instr[31:12], 12'b0};                                                 // 20+12
            IMM_J:   imm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};        // 12+8+1+10+1
            default: imm = '0;
        endcase
    end

endmodule