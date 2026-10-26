`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/23/2026 09:48:18 AM
// Design Name: 
// Module Name: core
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


module core
    import riscv_pkg::*;  
    (
        input logic clk,
        input logic rst,
        output logic [31:0] pc_out
    );
    
    logic[31:0] pc, pc_next, pc_plus4, pc_target;      // CHANGED: removed "= 0" (the reset sets pc)
    logic[31:0] instr;
    logic[31:0] rs1_val,rs2_val;
    logic [31:0] imm,alu_a, alu_b, alu_result,load_data, wb_value;
    logic [31:0] md_result;
    logic taken, take_branch;
    imm_sel_t imm_sel;
    alu_op_t alu_op;
    alu_a_sel_t alu_a_sel;
    alu_b_sel_t alu_b_sel;
    logic jal, jalr,branch;
    result_src_t result_src;
    
    logic reg_write,mem_write;
    
    decoder u_decoder(
            .instr_inp(instr),   //in
            .imm_sel(imm_sel), //out
            .alu_op(alu_op), //out
            .alu_a_sel(alu_a_sel), //out
            .alu_b_sel(alu_b_sel), //out
            .reg_write(reg_write), //out
            .mem_write(mem_write), //out
            .result_src(result_src),  //out
            .branch(branch), //out
            .jal(jal), //out
            .jalr(jalr) //out
    );
    imm_gen u_imm_gen(
        .instr(instr), //in
        .imm_sel(imm_sel), //in
        .imm(imm) //out
    );
    
    
    register_file u_register_file(
        .clk(clk),//in
        .we(reg_write),//in
        .waddr(instr[11:7]),//in
        .wdata(wb_value),//in
        .raddr1(instr[19:15]),//in
        .rdata1(rs1_val),//out
        .raddr2(instr[24:20]),//in
        .rdata2(rs2_val)  //out
    );
    
    alu u_alu(
        .alu_op(alu_op),//in
        .inp1(alu_a),//in
        .inp2 (alu_b),//in
        .out(alu_result)//out
    );
    
    always_ff @(posedge clk) begin
        if (rst) begin                                  // CHANGED: was (!rst) - reset is active high
            pc <= 0;                                    // CHANGED: was pc_next
        end else if(jalr) begin
            pc <= alu_result & ~32'd1;                  // CHANGED: was pc_next
        end else if (jal || take_branch) begin
            pc <= pc_target;                            // CHANGED: was pc_next
        end else begin
            pc <= pc_plus4;                             // CHANGED: was pc_next
        end
    end
    
    instr_mem #(.DEPTH(1024), .INIT_FILE("test1.mem"), .SYNC_READ(0)) u_instr_mem(
        .clk(clk), //in
        .en(1'b1), //in
        .addr(pc), //in
        .instr(instr) //out
    );

    branch_comparator u_branch_comparator(
        .a(rs1_val), //in
        .b(rs2_val), //in
        .func(instr[14:12]), //in
        .bout(taken) //out
    );

    data_mem #(.DEPTH(1024), .SYNC_READ(0)) u_data_mem(
        .clk(clk), //in
        .en(1'b1), //in
        .we(mem_write), //in
        .addr(alu_result), //in
        .wdata(rs2_val), //in
        .funct3(instr[14:12]), //in
        .rdata(load_data) //out
    );
    
    muldiv u_muldiv(                                  
        .a(rs1_val), //in
        .b(rs2_val), //in
        .funct3(instr[14:12]), //in
        .out(md_result) //out
    );

    // mux A: ALU first input
    always_comb begin
        case (alu_a_sel)
            RS1:     alu_a = rs1_val;
            PC:      alu_a = pc;
            ZERO:    alu_a = 32'd0;
            default: alu_a = rs1_val;
        endcase
    end

    // mux B: ALU second input
    always_comb begin
        case (alu_b_sel)
            RS2:     alu_b = rs2_val;
            IMME:    alu_b = imm;
            default: alu_b = rs2_val;
        endcase
    end

    // result mux: the value written into rd
    always_comb begin
        case (result_src)
            ALU_res: wb_value = alu_result;
            MEM_res: wb_value = load_data;
            PC4_res: wb_value = pc_plus4;
            MD_res:  wb_value = md_result;
            default: wb_value = alu_result;
        endcase
    end

    assign pc_plus4    = pc + 32'd4;          // PC + 4 adder
    assign pc_target   = pc + imm;            // PC + imm adder (branch / jal target)
    assign take_branch = branch & taken;      // a branch AND its condition is true
    assign pc_out      = pc;
    
endmodule