`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/07/2026 02:59:57 PM
// Design Name: 
// Module Name: tb_mnist
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


module tb_mnist;
    parameter string BUILD_DIR = "C:/FPGA/RISCV_ML_ACC/sw/mnist/build";
    parameter int unsigned TIMEOUT_CYCLES = 30_000_000;
    parameter int unsigned PROGRESS_EVERY = 1_000_000;
    parameter logic [31:0] SCALAR_CYCLES_ADDR = 32'h00019ce8;
    parameter logic [31:0] DOT4_CYCLES_ADDR   = 32'h00019ca8;
 
    localparam int N_TEST = 16;
    localparam int N_OUT  = 10;
    localparam logic [31:0] DMEM_BASE = 32'h0001_0000;
    localparam logic [31:0] DMEM_BYTES = 32'd65536;
    localparam logic [31:0] HALT_INSTR = 32'h0000_006f; // jal x0, 0
 
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic [31:0] pc_out;
    logic [3:0] led;
    logic [31:0] gp;
    int unsigned cycles;
    bit halted;
    int first_idx, failed_mode, failed_image, failed_output;
    int word_scalar, word_dot4;
    logic [31:0] c_scalar, c_dot4;
    longint unsigned sum_scalar, sum_dot4;
 
    always #5 clk = ~clk; // 10 ns simulation period; cycle counts do not depend on this
    // ------------------------------------------------------------
// Debug: monitor writes to general-purpose register x3 (gp)
// ------------------------------------------------------------
always @(posedge clk) begin
    if (!rst &&
        dut.reg_write_w === 1'b1 &&
        dut.rd_w === 5'd3) begin
 
        $display(
            "[GP WRITE] time=%0t PC=%08h value=%08h",
            $time,
            dut.pc,
            dut.wb_value
        );
    end
end
    core_pipe #(
        .IMEM_FILE(""),
        .DMEM_FILE(""),
        .IMEM_DEPTH(1024),
        .DMEM_DEPTH(16384) // 64 KiB
    ) dut (
        .clk(clk),
        .rst(rst),
        .btn(4'b0),
        .pc_out(pc_out),
        .led(led),
        // ADDED: memory port B unused here (the ARM side drives it on the board)
        .imem_b_en(1'b0), .imem_b_we(4'b0), .imem_b_addr(32'b0), .imem_b_wdata(32'b0), .imem_b_rdata(),
        .dmem_b_en(1'b0), .dmem_b_we(4'b0), .dmem_b_addr(32'b0), .dmem_b_wdata(32'b0), .dmem_b_rdata()
    );
 
    initial begin
        // Wait until the memory modules' time-zero initial blocks have run.
        #1;
        $display("MNIST: loading images from %s", BUILD_DIR);
        $readmemh({BUILD_DIR, "/mnist_imem.mem"}, dut.u_instr_mem.mem);
        $readmemh({BUILD_DIR, "/mnist_dmem.mem"}, dut.u_data_mem.mem);
 
        // Release reset between clock edges, as in the existing testbenches.
        repeat (5) @(negedge clk);
        rst = 1'b0;
        cycles = 0;
        halted = 0;
 
        // The final loop is 'j .' (machine word 0x0000006f).  It is the
        // convention already used by tb_riscv_tests and tb_bench.
        while (!halted && cycles < TIMEOUT_CYCLES) begin
            @(negedge clk);
            cycles = cycles + 1;
            // Detect an executed self-jump in the EX stage.
// Ignore speculative instructions in the fetch stage.
            if ((dut.jal_e === 1'b1) &&
                (dut.redirect === 1'b1) &&
                (dut.redirect_target === dut.pc_e)) begin
            
                halted = 1;
            
                $display(
                    "MNIST: real halt reached EX at PC=%08h",
                    dut.pc_e
                );
            
            end 
            if (PROGRESS_EVERY != 0 &&
                (cycles % PROGRESS_EVERY) == 0) begin
            
                $display(
                    "[PROGRESS] cycles=%0d PC=%08h SP=%08h GP=%08h",
                    cycles,
                    pc_out,
                    dut.u_register_file.mem[2],
                    dut.u_register_file.mem[3]
                );
            
            end
        end
 
        if (!halted) begin
            $display("MNIST FAIL: timed out at %0d cycles, PC=%08h, instr=%08h",
                     cycles, pc_out, dut.instr);
            $fatal(1, "MNIST did not reach its final j . instruction");
        end
 
        // The halt instruction can enter IF before the preceding mv gp,a0
        // has reached WB.  Allow the pipeline to drain before reading x3.
        repeat (12) @(negedge clk);
        gp = dut.u_register_file.mem[3];
        $display("------------------------------------------------------------");
        $display("MNIST firmware completed after %0d cycles", cycles);
        $display("gp (x3) = %08h; LEDs = %04b", gp, led);
 
        if (gp === 32'd1 && led === 4'h1) begin
            $display("MNIST PASS: all scalar and DOT4 logits match TEST_LOGITS");
        end else begin
            if (gp !== 32'd1 && gp[0] === 1'b1 && gp > 32'd1) begin
                // mnist.c uses: gp = 2*(1 + mode*160 + image*10 + output) + 1
                first_idx     = (gp - 3) / 2;
                failed_mode   = first_idx / (N_TEST * N_OUT);
                failed_image  = (first_idx % (N_TEST * N_OUT)) / N_OUT;
                failed_output = first_idx % N_OUT;
                $display("First mismatch: %s, image=%0d, logit=%0d",
                         failed_mode == 0 ? "scalar" : "DOT4", failed_image,
                         failed_output);
            end else begin
                $display("Invalid or unknown gp; inspect startup, PC and DMEM initialization.");
            end
            $fatal(1, "MNIST FAIL: gp or LED did not indicate success");
        end
 
        // Optional performance reporting.  Addresses come from ELF symbols,
        // not fixed memory locations: set them after each firmware rebuild.
        if (SCALAR_CYCLES_ADDR != 32'h0 && DOT4_CYCLES_ADDR != 32'h0) begin
            if (SCALAR_CYCLES_ADDR < DMEM_BASE ||
                DOT4_CYCLES_ADDR < DMEM_BASE ||
                SCALAR_CYCLES_ADDR + N_TEST*4 > DMEM_BASE + DMEM_BYTES ||
                DOT4_CYCLES_ADDR + N_TEST*4 > DMEM_BASE + DMEM_BYTES ||
                SCALAR_CYCLES_ADDR[1:0] != 2'b00 ||
                DOT4_CYCLES_ADDR[1:0] != 2'b00)
                $fatal(1, "Invalid scalar_cycles or dot4_cycles ELF symbol address");
 
            word_scalar = (SCALAR_CYCLES_ADDR - DMEM_BASE) / 4;
            word_dot4   = (DOT4_CYCLES_ADDR   - DMEM_BASE) / 4;
            sum_scalar = 0;
            sum_dot4 = 0;
            $display("Image   RV32IM cycles   DOT4 cycles   Speedup");
            for (int i = 0; i < N_TEST; i++) begin
                c_scalar = dut.u_data_mem.mem[word_scalar + i];
                c_dot4   = dut.u_data_mem.mem[word_dot4 + i];
                sum_scalar = sum_scalar + c_scalar;
                sum_dot4   = sum_dot4 + c_dot4;
                if (c_dot4 != 0)
                    $display("%5d   %13d   %11d   %6.2fx", i, c_scalar,
                             c_dot4, real'(c_scalar) / real'(c_dot4));
                else
                    $display("%5d   %13d   %11d   n/a", i, c_scalar, c_dot4);
            end
            if (sum_dot4 != 0)
                $display("TOTAL   %13d   %11d   %6.2fx", sum_scalar,
                         sum_dot4, real'(sum_scalar) / real'(sum_dot4));
        end else begin
            $display("To print per-image cycles, set SCALAR_CYCLES_ADDR and");
            $display("DOT4_CYCLES_ADDR to the ELF symbol addresses (nm -n).");
        end
        $finish;
    end
endmodule

