`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/22/2026 03:31:14 PM
// Design Name: 
// Module Name: decoder
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


module decoder
    import riscv_pkg::*;     
        (
            input logic[31:0] instr_inp,   
            output imm_sel_t imm_sel,
            output  alu_op_t alu_op,
            output  alu_a_sel_t alu_a_sel,
            output alu_b_sel_t alu_b_sel,
            output logic reg_write,
            output logic mem_write,
            output result_src_t result_src, 
            output logic branch,
            output logic jal,
            output logic jalr
        );
        
        always_comb begin
        reg_write = 0; mem_write = 0; branch = 0; jal = 0; jalr = 0; alu_op = ALU_ADD; imm_sel = IMM_I;alu_a_sel = RS1; alu_b_sel = RS2; result_src = ALU_res;  // CHANGED: added result_src
        case (instr_inp[6:0])
        7'b0110011: begin 
                imm_sel = IMM_I; 
                alu_a_sel = RS1; 
                alu_b_sel = RS2;
                mem_write = 0;
                reg_write = 1;
                result_src = ALU_res;
                branch = 0;
                jal = 0;
                jalr = 0;
                case (instr_inp[14:12])
                    3'b000: alu_op = instr_inp[30] ? ALU_SUB : ALU_ADD;
                    3'b001: alu_op = ALU_SLL;
                    3'b010: alu_op = ALU_SLT;
                    3'b011: alu_op = ALU_SLTU;
                    3'b100: alu_op = ALU_XOR;
                    3'b101: alu_op = instr_inp[30] ? ALU_SRA : ALU_SRL;
                    3'b110: alu_op = ALU_OR;
                    3'b111: alu_op = ALU_AND;
                    
                    
                endcase 
                if (instr_inp[25]) result_src = MD_res;  
        end
        7'b0010011: begin //i-arith
                imm_sel = IMM_I; 
                alu_a_sel = RS1; 
                alu_b_sel = IMME;
                mem_write = 0;
                reg_write = 1;
                result_src = ALU_res;
                branch = 0;
                jal = 0;
                jalr = 0;
                case (instr_inp[14:12])
                    3'b000: alu_op = ALU_ADD;
                    3'b001: alu_op = ALU_SLL;
                    3'b010: alu_op = ALU_SLT;
                    3'b011: alu_op = ALU_SLTU;
                    3'b100: alu_op = ALU_XOR;
                    3'b101: alu_op = instr_inp[30] ? ALU_SRA : ALU_SRL;
                    3'b110: alu_op = ALU_OR;
                    3'b111: alu_op = ALU_AND;
                endcase
        end
        7'b0000011: begin //load
            alu_op = ALU_ADD;
            imm_sel = IMM_I; 
            alu_a_sel = RS1; 
            alu_b_sel = IMME;
            mem_write = 0;
            reg_write = 1;
            result_src = MEM_res;
            branch = 0;
            jal = 0;
            jalr = 0;
            
        end
        7'b0100011: begin //store
            alu_op = ALU_ADD;
            imm_sel = IMM_S;                    
            alu_a_sel = RS1; 
            alu_b_sel = IMME;
            mem_write = 1;
            reg_write = 0;
            result_src = MEM_res;
            branch = 0;
            jal = 0;
            jalr = 0;
        end
        7'b1100011: begin //branch             
                                               
            alu_op = ALU_ADD;
            imm_sel = IMM_B;                    
            alu_a_sel = RS1; 
            alu_b_sel = IMME;
            mem_write = 0;
            reg_write = 0;                      
            result_src = MEM_res;
            branch = 1;                         //  added (the comparator decides "taken" in core.sv)
            jal = 0;
            jalr = 0;
        end
        7'b1101111: begin //jal                //  (opcode was 7'b0010011)
            alu_op = ALU_ADD;
            imm_sel = IMM_J; 
            alu_a_sel = RS1; 
            alu_b_sel = RS2;
            mem_write = 0;
            reg_write = 1;
            result_src = PC4_res;
            branch = 0;
            jal = 1;
            jalr = 0;
        end
        7'b1100111: begin //jalr               //  (opcode was 7'b0010011)
            alu_op = ALU_ADD;
            imm_sel = IMM_I; 
            alu_a_sel = RS1; 
            alu_b_sel = IMME;
            mem_write = 0;
            reg_write = 1;
            result_src = PC4_res;
            branch = 0;
            jal = 0;
            jalr = 1;
        end
        
        7'b0110111: begin //lui                //  (opcode was 7'b0010011)
            alu_op = ALU_ADD;
            imm_sel = IMM_U; 
            alu_a_sel = ZERO; 
            alu_b_sel = IMME;
            mem_write = 0;
            reg_write = 1;
            result_src = ALU_res;
            branch = 0;
            jal = 0;
            jalr = 0;
        end
        7'b0010111: begin //auipc              // ADDED (opcode was 7'b0010011)
            alu_op = ALU_ADD;
            imm_sel = IMM_U; 
            alu_a_sel = PC; 
            alu_b_sel = IMME;
            mem_write = 0;
            reg_write = 1;
            result_src = ALU_res;
            branch = 0;
            jal = 0;
            jalr = 0;
        end
        
        default: begin
        
        end
        endcase 
        end                                     // CHANGED: added the missing 'end' of always_comb
        
endmodule