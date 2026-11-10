`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/09/2026 05:32:35 PM
// Design Name: 
// Module Name: tb_loader
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



module tb_loader;
    parameter string BUILD_DIR = "C:/FPGA/RISCV_ML_ACC/sw/mnist/build";
    parameter int unsigned TIMEOUT_CYCLES = 30_000_000;
    parameter int unsigned PROGRESS_EVERY = 1_000_000;
    // Optional: per-image cycle arrays (ELF symbols, as in tb_mnist); 0 = skip
    parameter logic [31:0] SCALAR_CYCLES_ADDR = 32'h00019ce8;
    parameter logic [31:0] DOT4_CYCLES_ADDR   = 32'h00019ca8;
 
    localparam int IMEM_DEPTH = 1024;              // words (4 KB)
    localparam int DMEM_DEPTH = 16384;             // words (64 KB)
    localparam int N_TEST = 16;
    localparam logic [31:0] DMEM_BASE = 32'h0001_0000;
    localparam bit IMEM = 1'b0, DMEM = 1'b1;       // which memory a port B access goes to
 
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic [31:0] pc_out;
    logic [3:0]  led;
 
    // port B of both memories, driven by this testbench (the "ARM")
    logic        imem_b_en = 1'b0, dmem_b_en = 1'b0;
    logic [3:0]  imem_b_we = 4'b0, dmem_b_we = 4'b0;
    logic [31:0] imem_b_addr = '0, dmem_b_addr = '0;
    logic [31:0] imem_b_wdata = '0, dmem_b_wdata = '0;
    logic [31:0] imem_b_rdata, dmem_b_rdata;
 
    // the program images, read from the files into the testbench (not into the core)
    logic [31:0] imem_img [IMEM_DEPTH];
    logic [31:0] dmem_img [DMEM_DEPTH];
    int imem_words, dmem_words;
 
    int unsigned cycles;
    bit halted;
    int errors = 0;
    logic [31:0] value, gp, c_scalar, c_dot4;
    longint unsigned sum_scalar, sum_dot4;
 
    always #5 clk = ~clk;
 
    core_pipe #(
        .IMEM_FILE(""),
        .DMEM_FILE(""),
        .IMEM_DEPTH(IMEM_DEPTH),
        .DMEM_DEPTH(DMEM_DEPTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .btn(4'b0),
        .pc_out(pc_out),
        .led(led),
        .imem_b_en(imem_b_en), .imem_b_we(imem_b_we), .imem_b_addr(imem_b_addr),
        .imem_b_wdata(imem_b_wdata), .imem_b_rdata(imem_b_rdata),
        .dmem_b_en(dmem_b_en), .dmem_b_we(dmem_b_we), .dmem_b_addr(dmem_b_addr),
        .dmem_b_wdata(dmem_b_wdata), .dmem_b_rdata(dmem_b_rdata)
    );
 
    // ------------------------------------------------------------------
    // Port B accesses, as the AXI BRAM Controller makes them.
    // byte_addr is the offset inside the memory (0 = first word).
    // Signals change on the falling edge; the RAM acts on the rising edge.
    // ------------------------------------------------------------------
    task automatic port_b_write(input bit mem, input logic [31:0] byte_addr,
                                input logic [31:0] data, input logic [3:0] we);
        @(negedge clk);
        if (mem == DMEM) begin
            dmem_b_en = 1'b1; dmem_b_we = we; dmem_b_addr = byte_addr; dmem_b_wdata = data;
        end else begin
            imem_b_en = 1'b1; imem_b_we = we; imem_b_addr = byte_addr; imem_b_wdata = data;
        end
        @(negedge clk);                            // the rising edge in between wrote it
        dmem_b_en = 1'b0; dmem_b_we = 4'b0;
        imem_b_en = 1'b0; imem_b_we = 4'b0;
    endtask
 
    task automatic port_b_read(input bit mem, input logic [31:0] byte_addr,
                               output logic [31:0] data);
        @(negedge clk);
        if (mem == DMEM) begin
            dmem_b_en = 1'b1; dmem_b_we = 4'b0; dmem_b_addr = byte_addr;
        end else begin
            imem_b_en = 1'b1; imem_b_we = 4'b0; imem_b_addr = byte_addr;
        end
        @(negedge clk);                            // data arrived on the rising edge
        data = (mem == DMEM) ? dmem_b_rdata : imem_b_rdata;
        dmem_b_en = 1'b0;
        imem_b_en = 1'b0;
    endtask
 
    // compare every loaded word with the file, through port B
    task automatic check_readback(input bit mem, input string what);
        int bad = 0;
        int n = (mem == DMEM) ? dmem_words : imem_words;
        for (int i = 0; i < n; i++) begin
            port_b_read(mem, 4 * i, value);
            if (value !== ((mem == DMEM) ? dmem_img[i] : imem_img[i])) begin
                if (bad < 5)
                    $display("  %s word %0d: read %08h, expected %08h", what, i, value,
                             (mem == DMEM) ? dmem_img[i] : imem_img[i]);
                bad++;
            end
        end
        $display("%-32s %0d words, %0d mismatches", what, n, bad);
        errors += bad;
    endtask
 
    initial begin
        // 1) the core stays in reset while the "ARM" loads the memories
        rst = 1'b1;
        for (int i = 0; i < IMEM_DEPTH; i++) imem_img[i] = 'x;
        for (int i = 0; i < DMEM_DEPTH; i++) dmem_img[i] = 'x;
        $readmemh({BUILD_DIR, "/mnist_imem.mem"}, imem_img);
        $readmemh({BUILD_DIR, "/mnist_dmem.mem"}, dmem_img);
        imem_words = 0; while (imem_words < IMEM_DEPTH && !$isunknown(imem_img[imem_words])) imem_words++;
        dmem_words = 0; while (dmem_words < DMEM_DEPTH && !$isunknown(dmem_img[dmem_words])) dmem_words++;
        $display("Loader: %0d instruction words, %0d data words from %s", imem_words, dmem_words, BUILD_DIR);
        if (imem_words == 0 || dmem_words == 0)
            $fatal(1, "Loader: empty .mem files; check BUILD_DIR");
 
        // 2) byte enables: only bytes 0 and 2 may change
        port_b_write(DMEM, 32'h0000_FFFC, 32'hAABB_CCDD, 4'b1111);
        port_b_write(DMEM, 32'h0000_FFFC, 32'h1122_3344, 4'b0101);
        port_b_read (DMEM, 32'h0000_FFFC, value);
        if (value !== 32'hAA22_CC44) begin
            $display("Byte enables: FAIL, read %08h, expected aa22cc44", value);
            errors++;
        end else
            $display("Byte enables: PASS (aabbccdd, then 11223344 with we=0101 -> aa22cc44)");
 
        // 3) load both memories through port B only
        for (int i = 0; i < imem_words; i++) port_b_write(IMEM, 4 * i, imem_img[i], 4'b1111);
        for (int i = 0; i < dmem_words; i++) port_b_write(DMEM, 4 * i, dmem_img[i], 4'b1111);
 
        // 4) read everything back through port B
        check_readback(IMEM, "Instruction memory readback:");
        check_readback(DMEM, "Data memory readback:");
        if (errors != 0)
            $fatal(1, "Loader FAIL: port B write/read errors before the run");
 
        // 5) release reset and run to the final "j ." (same check as tb_mnist)
        @(negedge clk);
        rst = 1'b0;
        cycles = 0;
        halted = 0;
        while (!halted && cycles < TIMEOUT_CYCLES) begin
            @(negedge clk);
            cycles++;
            if ((dut.jal_e === 1'b1) && (dut.redirect === 1'b1) &&
                (dut.redirect_target === dut.pc_e))
                halted = 1;
            if (PROGRESS_EVERY != 0 && (cycles % PROGRESS_EVERY) == 0)
                $display("[PROGRESS] cycles=%0d PC=%08h", cycles, pc_out);
        end
        if (!halted)
            $fatal(1, "Loader FAIL: timed out at %0d cycles, PC=%08h", cycles, pc_out);
        repeat (12) @(negedge clk);                // let mv gp,a0 reach WB
 
        // 6) results
        gp = dut.u_register_file.mem[3];
        $display("Firmware finished after %0d cycles: gp = %08h, LEDs = %04b", cycles, gp, led);
        if (gp !== 32'd1 || led !== 4'h1) begin
            $display("  firmware reported a failure");
            errors++;
        end
        check_readback(DMEM, "Constants after the run:");
 
        if (SCALAR_CYCLES_ADDR != 32'h0 && DOT4_CYCLES_ADDR != 32'h0) begin
            sum_scalar = 0;
            sum_dot4   = 0;
            for (int i = 0; i < N_TEST; i++) begin
                port_b_read(DMEM, SCALAR_CYCLES_ADDR - DMEM_BASE + 4 * i, c_scalar);
                port_b_read(DMEM, DOT4_CYCLES_ADDR   - DMEM_BASE + 4 * i, c_dot4);
                sum_scalar += c_scalar;
                sum_dot4   += c_dot4;
            end
            if (sum_dot4 != 0)
                $display("Cycles read through port B: RV32IM %0d, DOT4 %0d per image (%.2fx)",
                         sum_scalar / N_TEST, sum_dot4 / N_TEST,
                         real'(sum_scalar) / real'(sum_dot4));
        end
 
        if (errors == 0)
            $display("*** LOADER PASS: program loaded and results read through port B ***");
        else
            $display("*** LOADER FAIL: %0d errors ***", errors);
        $finish;
    end
endmodule
