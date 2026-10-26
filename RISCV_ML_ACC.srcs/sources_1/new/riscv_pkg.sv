//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/15/2026 02:01:43 PM
// Design Name: 
// Module Name: riscv_pkg
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


package riscv_pkg;

    typedef enum logic [3:0] {
        ALU_ADD     = 4'd0,
        ALU_SUB     = 4'd1,
        ALU_SLL     = 4'd2,      
        ALU_SRL     = 4'd3,     
        ALU_SRA     = 4'd4,      
        ALU_SLT     = 4'd5,      
        ALU_SLTU    = 4'd6,      
        ALU_XOR     = 4'd7,      
        ALU_OR      = 4'd8,      
        ALU_AND     = 4'd9      
    } alu_op_t;
    
        // Immediate formats: which instruction layout the immediate comes from.
    // The decoder chooses one of these from the opcode.
    typedef enum logic [2:0] {
        IMM_I = 3'd0,    // addi and other immediate arithmetic, loads, jalr
        IMM_S = 3'd1,    // stores
        IMM_B = 3'd2,    // branches
        IMM_U = 3'd3,    // lui, auipc
        IMM_J = 3'd4     // jal
    } imm_sel_t;

    typedef enum logic [1:0] {
        RS1 = 2'd0,
        PC = 2'd1,
        ZERO = 2'd2
    }alu_a_sel_t;
    
    typedef enum logic {
        RS2 = 1'd0,
        IMME = 1'd1
    }alu_b_sel_t;
    typedef enum logic[1:0] {
        ALU_res = 2'd0,
        MEM_res = 2'd1,
        PC4_res = 2'd2,
		MD_res  = 2'd3
    }result_src_t;
endpackage