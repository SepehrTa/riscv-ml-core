`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/11/2026 02:56:34 PM
// Design Name: 
// Module Name: tb_mv_engine
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


module tb_mv_engine;
    localparam int LANES = 8;
    localparam int BANK_WORDS = 1024;
    localparam int MAX_ROWS = 64;
    localparam int MAX_WORDS = 256;

    localparam logic [17:0] REG_BASE = 18'h0_1000;
    localparam logic [17:0] W_BASE_A = 18'h1_0000;
    localparam logic [17:0] IN_BASE  = 18'h2_0000;
    localparam logic [17:0] RES_BASE = 18'h3_0000;
    localparam int CTRL = 'h00, STATUS = 'h04, WBASE = 'h08, NWORDS = 'h0C, NGROUPS = 'h10, CYCLES = 'h14;

    logic clk = 1'b0, rst = 1'b1;
    logic we = 1'b0, re = 1'b0;
    logic [17:0] addr = '0;
    logic [31:0] wdata = '0, rdata;

    always #5 clk = ~clk;

    mv_engine #(.LANES(LANES), .BANK_WORDS(BANK_WORDS)) dut (
        .clk(clk), .rst(rst), .we(we), .re(re), .addr(addr), .wdata(wdata), .rdata(rdata));

    // reference copies of what was loaded
    logic [31:0] w_ref [MAX_ROWS][MAX_WORDS];
    logic [31:0] x_ref [MAX_WORDS];
    int errors = 0;
    int tests = 0;

    // ---------------------------------------------------------------- bus
    task automatic bus_write(input logic [17:0] a, input logic [31:0] d);
        @(negedge clk);
        we = 1'b1; addr = a; wdata = d;
        @(negedge clk);
        we = 1'b0;
    endtask

    task automatic bus_read(input logic [17:0] a, output logic [31:0] d);
        @(negedge clk);
        re = 1'b1; addr = a;
        @(negedge clk);
        d = rdata;
        re = 1'b0;
    endtask

    // ---------------------------------------------------------------- reference
    function automatic logic signed [31:0] dot4(input logic [31:0] a, input logic [31:0] b);
        dot4 = $signed(a[7:0])   * $signed(b[7:0])
             + $signed(a[15:8])  * $signed(b[15:8])
             + $signed(a[23:16]) * $signed(b[23:16])
             + $signed(a[31:24]) * $signed(b[31:24]);
    endfunction

    // ---------------------------------------------------------------- helpers
    // write the rows of one layer into the banks, in the engine's layout
    task automatic load_weights(input int base, input int n_words, input int n_rows, input int mode);
        logic [31:0] w;
        for (int r = 0; r < n_rows; r++)
            for (int k = 0; k < n_words; k++) begin
                w = (mode == 1) ? 32'h8080_8080 : $urandom;
                w_ref[r][k] = w;
                bus_write(W_BASE_A + 18'(((base + (r / LANES) * n_words + k) * LANES + (r % LANES)) * 4), w);
            end
    endtask

    task automatic load_inputs(input int n_words, input int mode);
        logic [31:0] x;
        for (int k = 0; k < n_words; k++) begin
            x = (mode == 1) ? 32'h8080_8080 : $urandom;
            x_ref[k] = x;
            bus_write(IN_BASE + 18'(k * 4), x);
        end
    endtask

    task automatic start_and_wait(input int base, input int n_words, input int n_groups, output int waited);
        logic [31:0] s;
        bus_write(REG_BASE + WBASE, base);
        bus_write(REG_BASE + NWORDS, n_words);
        bus_write(REG_BASE + NGROUPS, n_groups);
        bus_write(REG_BASE + CTRL, 1);
        waited = 0;
        do begin
            bus_read(REG_BASE + STATUS, s);
            waited++;
        end while (s[0] && waited < 100000);
    endtask

    task automatic check_results(input string name, input int n_words, input int n_rows);
        logic [31:0] got, cyc;
        logic signed [31:0] exp;
        int bad = 0;
        for (int r = 0; r < n_rows; r++) begin
            exp = 0;
            for (int k = 0; k < n_words; k++) exp += dot4(w_ref[r][k], x_ref[k]);
            bus_read(RES_BASE + 18'(r * 4), got);
            if (got !== exp) begin
                if (bad < 5) $display("  %s row %0d: got %0d, expected %0d", name, r, $signed(got), exp);
                bad++;
            end
        end
        bus_read(REG_BASE + CYCLES, cyc);
        tests++;
        errors += bad;
        $display("%-34s %2d rows x %3d words: %s  (%0d cycles)", name, n_rows, n_words,
                 bad == 0 ? "PASS" : "FAIL", cyc);
    endtask

    // ---------------------------------------------------------------- tests
    int waited, nw, ng, base;
    logic [31:0] s;

    initial begin
        repeat (3) @(posedge clk);
        rst = 1'b0;

        // 1) layer-1 shape: 32 rows of 784 inputs, at the start of the banks
        load_weights(0, 196, 32, 0);
        load_inputs(196, 0);
        start_and_wait(0, 196, 4, waited);
        check_results("layer 1 shape, random", 196, 32);

        // 2) layer-2 shape at an offset: 16 rows of 32 inputs at word 784
        load_weights(784, 8, 16, 0);
        load_inputs(8, 0);
        start_and_wait(784, 8, 2, waited);
        check_results("layer 2 shape at W_BASE=784", 8, 16);

        // 3) shortest row: one word
        load_weights(900, 1, 8, 0);
        load_inputs(1, 0);
        start_and_wait(900, 1, 1, waited);
        check_results("one-word rows", 1, 8);

        // 4) worst case: every weight and input is -128
        load_weights(0, 196, 8, 1);
        load_inputs(196, 1);
        start_and_wait(0, 196, 1, waited);
        check_results("all -128 (largest sums)", 196, 8);

        // 5) a second start while busy must be ignored, and the settings frozen
        load_weights(0, 64, 64, 0);
        load_inputs(64, 0);
        bus_write(REG_BASE + WBASE, 0);
        bus_write(REG_BASE + NWORDS, 64);
        bus_write(REG_BASE + NGROUPS, 8);
        bus_write(REG_BASE + CTRL, 1);
        bus_write(REG_BASE + NWORDS, 3);     // must not take effect
        bus_write(REG_BASE + CTRL, 1);       // must be ignored
        do bus_read(REG_BASE + STATUS, s); while (s[0]);
        check_results("start while busy is ignored", 64, 64);

        // 6) back to back, the same data twice: accumulators must restart at 0
        start_and_wait(0, 64, 8, waited);
        check_results("second run, same data", 64, 64);

        // 7) many random shapes
        for (int t = 0; t < 20; t++) begin
            nw   = 1 + $urandom_range(0, 127);
            ng   = 1 + $urandom_range(0, 7);
            base = $urandom_range(0, BANK_WORDS - nw * ng);
            load_weights(base, nw, ng * LANES, 0);
            load_inputs(nw, 0);
            start_and_wait(base, nw, ng, waited);
            check_results($sformatf("random shape %0d", t), nw, ng * LANES);
        end

        $display("");
        if (errors == 0) $display("*** MV ENGINE PASS: %0d tests ***", tests);
        else             $display("*** MV ENGINE FAIL: %0d wrong results ***", errors);
        $finish;
    end
endmodule