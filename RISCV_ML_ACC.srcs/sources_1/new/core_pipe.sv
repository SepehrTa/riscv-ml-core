`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/02/2026 03:00:25 PM
// Design Name: 
// Module Name: core_pipe
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



module core_pipe
    import riscv_pkg::*;
    #(    
        parameter IMEM_FILE = "test1.mem",
        parameter DMEM_FILE = "",
        parameter int IMEM_DEPTH = 1024,
        parameter int DMEM_DEPTH = 16384
    )
    (
        input  logic        clk,
        input  logic        rst,
        input  logic [3:0]  btn,
        output logic [31:0] pc_out,
        output logic [3:0]  led
    );

    localparam logic [31:0] NOP = 32'h0000_0013;      // addi x0, x0, 0

    // ---------------- signals used across stages (declared up front) ----------------
    logic        load_use;              // load-use hazard: hold IF and ID for 1 cycle
    logic        div_stall;             // ADDED: a divide in EX is not finished yet
    logic        stall;                 // CHANGED: hold IF and ID (load-use or divide)
    logic        redirect;              // taken branch or jump in EX: change the PC, flush IF/ID
    logic [31:0] redirect_target;       // where to go when redirect = 1

    logic [4:0]  rd_m, rd_w;            // destination registers in MEM and WB (for forwarding)
    logic        reg_write_m, reg_write_w;
    result_src_t result_src_m;
    logic [31:0] alu_result_m, md_result_m, pc_plus4_m;
    logic [31:0] wb_value;              // value written back in WB

    
    // ADDED: cycle counter, readable with lw from 0x8000_0008
    logic [31:0] cycle_cnt;
    always_ff @(posedge clk) begin
        if (rst) cycle_cnt <= 32'd0;
        else     cycle_cnt <= cycle_cnt + 32'd1;
    end


    //=========================================================================
    // IF: fetch
    //=========================================================================
    logic [31:0] pc, pc_next, instr;    // instr = instruction at pc (block RAM output)

    // CHANGED: the next PC is computed first, because the block RAM must be
    // given its address one cycle early. At the clock edge, pc becomes pc_next
    // and the RAM output becomes mem[pc_next], so instr always matches pc.
    always_comb begin
        if (rst)            pc_next = 32'd0;
        else if (redirect)  pc_next = redirect_target;  // branch/jump wins
        else if (stall)     pc_next = pc;               // stall: fetch the same instruction again
        else                pc_next = pc + 32'd4;
    end

    always_ff @(posedge clk) begin
        pc <= pc_next;
    end

    instr_mem #(.DEPTH(IMEM_DEPTH), .INIT_FILE(IMEM_FILE), .SYNC_READ(1)) u_instr_mem(   // CHANGED: block RAM
        .clk(clk), //in
        .en(1'b1), //in
        .addr(pc_next), //in                            // CHANGED: was pc
        .instr(instr) //out
    );

    // ----------------------------- IF/ID register -----------------------------
    logic [31:0] instr_d, pc_d;

    always_ff @(posedge clk) begin
        if (rst || redirect) begin      // flush: the wrong-path instruction becomes a NOP
            instr_d <= NOP;
            pc_d    <= 32'd0;
        end else if (!stall) begin      // stall: hold the instruction in ID
            instr_d <= instr;
            pc_d    <= pc;
        end
    end


    //=========================================================================
    // ID: decode and read registers
    //=========================================================================
    imm_sel_t    imm_sel_d;
    alu_op_t     alu_op_d;
    alu_a_sel_t  alu_a_sel_d;
    alu_b_sel_t  alu_b_sel_d;
    result_src_t result_src_d;
    logic        reg_write_d, mem_write_d, branch_d, jal_d, jalr_d;
    logic [31:0] imm_d, rf_rdata1, rf_rdata2, rs1_val_d, rs2_val_d;
    logic [4:0]  rs1_d, rs2_d, rd_d;
    logic ml_op_d;

    assign rs1_d = instr_d[19:15];
    assign rs2_d = instr_d[24:20];
    assign rd_d  = instr_d[11:7];

    decoder u_decoder(
            .instr_inp(instr_d),   //in
            .imm_sel(imm_sel_d), //out
            .alu_op(alu_op_d), //out
            .alu_a_sel(alu_a_sel_d), //out
            .alu_b_sel(alu_b_sel_d), //out
            .reg_write(reg_write_d), //out
            .mem_write(mem_write_d), //out
            .result_src(result_src_d),  //out
            .branch(branch_d), //out
            .jal(jal_d), //out
            .jalr(jalr_d), //out
            .ml_op(ml_op_d)
    );

    imm_gen u_imm_gen(
        .instr(instr_d), //in
        .imm_sel(imm_sel_d), //in
        .imm(imm_d) //out
    );

    register_file u_register_file(      // written from WB, read in ID
        .clk(clk),//in
        .we(reg_write_w),//in
        .waddr(rd_w),//in
        .wdata(wb_value),//in
        .raddr1(rs1_d),//in
        .rdata1(rf_rdata1),//out
        .raddr2(rs2_d),//in
        .rdata2(rf_rdata2)  //out
    );

    // WB writes a register at the same clock edge that ID reads it, so ID would
    // still see the old value. Bypass: take the value being written instead.
    assign rs1_val_d = (reg_write_w && rd_w != 0 && rd_w == rs1_d) ? wb_value : rf_rdata1;
    assign rs2_val_d = (reg_write_w && rd_w != 0 && rd_w == rs2_d) ? wb_value : rf_rdata2;

    // ----------------------------- ID/EX register -----------------------------
    logic [31:0] pc_e, rs1_val_e, rs2_val_e, imm_e;
    logic [4:0]  rs1_e, rs2_e, rd_e;
    logic [2:0]  funct3_e;
    alu_op_t     alu_op_e;
    alu_a_sel_t  alu_a_sel_e;
    alu_b_sel_t  alu_b_sel_e;
    result_src_t result_src_e;
    logic        reg_write_e, mem_write_e, branch_e, jal_e, jalr_e, ml_op_e;

    always_ff @(posedge clk) begin
      if (rst || !div_stall) begin        // ADDED: a divide waiting in EX holds this register
        // data: always copied forward
        pc_e         <= pc_d;
        rs1_val_e    <= rs1_val_d;
        rs2_val_e    <= rs2_val_d;
        imm_e        <= imm_d;
        rs1_e        <= rs1_d;
        rs2_e        <= rs2_d;
        rd_e         <= rd_d;
        funct3_e     <= instr_d[14:12];
        alu_op_e     <= alu_op_d;
        alu_a_sel_e  <= alu_a_sel_d;
        alu_b_sel_e  <= alu_b_sel_d;
        result_src_e <= result_src_d;
        // controls that change state: cleared to insert a bubble (a do-nothing instruction)
        if (rst || redirect || load_use) begin      // CHANGED: was stall
            reg_write_e <= 0;
            mem_write_e <= 0;
            branch_e    <= 0;
            jal_e       <= 0;
            jalr_e      <= 0;
            ml_op_e     <= 0;
        end else begin
            reg_write_e <= reg_write_d;
            mem_write_e <= mem_write_d;
            branch_e    <= branch_d;
            jal_e       <= jal_d;
            jalr_e      <= jalr_d;
            ml_op_e     <= ml_op_d;
        end
      end
    end


    //=========================================================================
    // EX: execute
    //=========================================================================
    logic [31:0] fwd_m;                 // the value the instruction in MEM will write back
    logic [31:0] src_a, src_b;          // rs1 / rs2 values after forwarding
    logic [31:0] alu_a, alu_b, alu_result_e, md_result_e, pc_target_e;
    logic [31:0] div_result_e;    
    logic        is_div_e, div_start, div_busy, div_done;
    logic        taken_e;

    always_comb begin
        case (result_src_m)
            PC4_res: fwd_m = pc_plus4_m;
//            MD_res:  fwd_m = md_result_m;
            default: fwd_m = alu_result_m;   // (a load in MEM is never forwarded: the stall prevents it)
        endcase
    end

    // Forwarding: use the newest value of rs1 / rs2.
    // MEM holds the newer instruction, so it has priority over WB.
    always_comb begin
        if      (reg_write_m && rd_m != 0 && rd_m == rs1_e) src_a = fwd_m;
        else if (reg_write_w && rd_w != 0 && rd_w == rs1_e) src_a = wb_value;
        else                                                src_a = rs1_val_e;

        if      (reg_write_m && rd_m != 0 && rd_m == rs2_e) src_b = fwd_m;
        else if (reg_write_w && rd_w != 0 && rd_w == rs2_e) src_b = wb_value;
        else                                                src_b = rs2_val_e;
    end

    // mux A: ALU first input
    always_comb begin
        case (alu_a_sel_e)
            RS1:     alu_a = src_a;
            PC:      alu_a = pc_e;
            ZERO:    alu_a = 32'd0;
            default: alu_a = src_a;
        endcase
    end

    // mux B: ALU second input
    always_comb begin
        case (alu_b_sel_e)
            RS2:     alu_b = src_b;
            IMME:    alu_b = imm_e;
            default: alu_b = src_b;
        endcase
    end

    alu u_alu(
        .alu_op(alu_op_e),//in
        .inp1(alu_a),//in
        .inp2 (alu_b),//in
        .out(alu_result_e)//out
    );

//    muldiv u_muldiv(                                  // CHANGED: multiply only
//        .a(src_a), //in
//        .b(src_b), //in
//        .funct3({1'b0, funct3_e[1:0]}), //in          // bit 2 forced to 0: never a divide
//        .out(mul_result_e) //out
//    );

    // ADDED: iterative divider. A div/rem in EX starts it and waits in EX until done.
    // reg_write_e excludes bubbles (a bubble can carry a divide's other fields).
    assign is_div_e  = reg_write_e && (result_src_e == MD_res) && funct3_e[2] && !ml_op_e;
    assign div_start = is_div_e && !div_busy && !div_done;
    assign div_stall = is_div_e && !div_done;

    divider u_divider(
        .clk(clk), //in
        .rst(rst), //in
        .start(div_start), //in
        .a(src_a), //in                               // captured at start
        .b(src_b), //in
        .funct3(funct3_e), //in
        .busy(div_busy), //out
        .done(div_done), //out
        .out(div_result_e) //out
    );

    assign md_result_e = div_result_e;

    branch_comparator u_branch_comparator(
        .a(src_a), //in
        .b(src_b), //in
        .func(funct3_e), //in
        .bout(taken_e) //out
    );

    assign pc_target_e     = pc_e + imm_e;
    assign redirect        = (branch_e & taken_e) | jal_e | jalr_e;
    assign redirect_target = jalr_e ? (alu_result_e & ~32'd1) : pc_target_e;

    // ----------------------------- EX/MEM register -----------------------------
    logic [31:0] store_data_m;
    logic [31:0] mul_a_m, mul_b_m;
    logic [2:0]  funct3_m;
    logic        mem_write_m, ml_op_m;

    always_ff @(posedge clk) begin
        alu_result_m <= alu_result_e;
        md_result_m  <= md_result_e;
        store_data_m <= src_b;                 // forwarded rs2 = data for a store
        mul_a_m <= src_a;
        mul_b_m <= src_b;
        pc_plus4_m   <= pc_e + 32'd4;          // return address for jal / jalr
        rd_m         <= rd_e;
        funct3_m     <= funct3_e;
        result_src_m <= result_src_e;
        if (rst || div_stall) begin                 // CHANGED: bubble into MEM while dividing
            reg_write_m <= 0;
            mem_write_m <= 0;
            ml_op_m <= 0;
        end else begin
            reg_write_m <= reg_write_e;
            mem_write_m <= mem_write_e;
            ml_op_m <= ml_op_e;
        end
    end


    //=========================================================================
    // MEM: data memory and memory-mapped I/O
    //=========================================================================
    logic        io_sel_m;
    logic [31:0] load_data_w;           // CHANGED: block RAM output, valid one cycle later (in WB)
    logic [31:0] mul_result_m, md_value_m, ml_result_m;           
    
        muldiv u_muldiv(                                  // CHANGED: multiply only
        .a(mul_a_m), //in
        .b(mul_b_m), //in
        .funct3({1'b0, funct3_m[1:0]}), //in          // bit 2 forced to 0: never a divide
        .out(mul_result_m) //out
    );
    
    
    ml_unit u_ml_unit(
        .clk(clk), //in
        .rst(rst), //in
        .valid(ml_op_m), //in                         // 0 for bubbles: the accumulator stays put
        .funct3(funct3_m), //in
        .a(mul_a_m), //in
        .b(mul_b_m), //in
        .out(ml_result_m) //out
    );
    
    
    assign md_value_m = ml_op_m ? ml_result_m : funct3_m[2] ? md_result_m : mul_result_m;   // divide result or product

    assign io_sel_m = alu_result_m[31];        // address 0x8000_0000 and above = I/O

    data_mem #(.DEPTH(DMEM_DEPTH),.INIT_FILE(DMEM_FILE) , .SYNC_READ(1)) u_data_mem(                           // CHANGED: block RAM
        .clk(clk), //in
        .en(1'b1), //in
        .we(mem_write_m & ~io_sel_m), //in
        .addr(alu_result_m), //in
        .wdata(store_data_m), //in
        .funct3(funct3_m), //in
        .rdata(load_data_w) //out                     // arrives in WB
    );

    always_ff @(posedge clk) begin             // LED register
        if (rst)
            led <= 4'b0000;
        else if (mem_write_m & io_sel_m)
            led <= store_data_m[3:0];
    end

    // ----------------------------- MEM/WB register -----------------------------
    logic [31:0] alu_result_w, md_result_w, pc_plus4_w, mem_data_w;
    logic        io_sel_w;
    logic [31:0]  io_rdata_w;
    result_src_t result_src_w;

    always_ff @(posedge clk) begin
        alu_result_w <= alu_result_m;
        md_result_w  <= md_value_m;
        pc_plus4_w   <= pc_plus4_m;
        io_sel_w     <= io_sel_m;              // CHANGED: the I/O choice moves to WB,
        io_rdata_w   <= (alu_result_m[3:2] == 2'b10) ? cycle_cnt : {28'b0, btn};   // CHANGED: 0x...8 = counter, 0x...4 = buttons                   //          where the load data now arrives
        rd_w         <= rd_m;
        result_src_w <= result_src_m;
        if (rst) reg_write_w <= 0;
        else     reg_write_w <= reg_write_m;
    end


    //=========================================================================
    // WB: write back (the result mux)
    //=========================================================================
    assign mem_data_w = io_sel_w ? io_rdata_w  : load_data_w;   // CHANGED: was done in MEM

    always_comb begin
        case (result_src_w)
            ALU_res: wb_value = alu_result_w;
            MEM_res: wb_value = mem_data_w;
            PC4_res: wb_value = pc_plus4_w;
            MD_res:  wb_value = md_result_w;
            default: wb_value = alu_result_w;
        endcase
    end



    assign load_use = reg_write_e && (result_src_e == MEM_res || result_src_e == MD_res) &&   // CHANGED
                      (rd_e != 0) && ((rd_e == rs1_d) || (rd_e == rs2_d));

    assign stall = load_use || div_stall;      // ADDED: hold PC and IF/ID for either reason

    assign pc_out = pc;

endmodule
