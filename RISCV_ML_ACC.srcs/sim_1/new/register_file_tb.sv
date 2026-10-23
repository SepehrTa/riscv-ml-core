`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: register_file_tb
// Description: Self-checking testbench for register_file.sv
//   A "shadow" array in the testbench remembers what every register SHOULD
//   hold. Every write updates it, and every read is compared against it.
//////////////////////////////////////////////////////////////////////////////////

module register_file_tb;

    // 1) Clock and signals
    logic        clk    = 1'b0;
    logic        we     = 1'b0;
    logic [4:0]  waddr  = '0;
    logic [31:0] wdata  = '0;
    logic [4:0]  raddr1 = '0;
    logic [31:0] rdata1;
    logic [4:0]  raddr2 = '0;
    logic [31:0] rdata2;

    logic [31:0] shadow [32];          // what each register SHOULD contain
    int          errors = 0;
    int          tests  = 0;

    // Variables for the random test
    logic        r_we;
    logic [4:0]  r_waddr, r_a1, r_a2;
    logic [31:0] r_wdata;

    always #5 clk = ~clk;              // 10 ns clock period

    // 2) The design under test
    register_file dut (
        .clk    (clk),
        .we     (we),
        .waddr  (waddr),
        .wdata  (wdata),
        .raddr1 (raddr1),
        .rdata1 (rdata1),
        .raddr2 (raddr2),
        .rdata2 (rdata2)
    );

    // 3) Write one register: set the inputs at a falling edge, let the rising
    //    edge in between do the write, then turn we off at the next falling edge.
    task automatic write_reg(input logic [4:0] addr, input logic [31:0] data);
        @(negedge clk);
        we    = 1'b1;
        waddr = addr;
        wdata = data;
        @(negedge clk);
        we    = 1'b0;
        if (addr != 5'd0) shadow[addr] = data;     // x0 never changes
    endtask

    // 4) Read two registers and compare both ports with the shadow copy.
    //    Reads are combinational, so no clock is needed - just a short wait.
    task automatic check_read(input logic [4:0] a1, input logic [4:0] a2);
        raddr1 = a1;
        raddr2 = a2;
        #1;
        tests++;
        if (rdata1 !== shadow[a1] || rdata2 !== shadow[a2]) begin
            errors++;
            if (errors <= 20)
                $display("FAIL  t=%0t  x%0d=%h (expected %h)   x%0d=%h (expected %h)",
                         $time, a1, rdata1, shadow[a1], a2, rdata2, shadow[a2]);
        end
    endtask

    // 5) The tests
    initial begin
        shadow[0] = 32'h0;                         // x0 always reads 0
        repeat (2) @(negedge clk);

        // Test 1: write a few registers and read them back
        $display("Test 1: write and read back");
        write_reg(5'd1, 32'h1111_1111);
        write_reg(5'd2, 32'h2222_2222);
        write_reg(5'd3, 32'h3333_3333);
        check_read(5'd1, 5'd2);
        check_read(5'd2, 5'd3);
        check_read(5'd3, 5'd1);

        // Test 2: x0 always reads 0, even after a write to it
        $display("Test 2: x0 stays zero");
        write_reg(5'd0, 32'hDEAD_BEEF);
        check_read(5'd0, 5'd0);
        check_read(5'd0, 5'd1);

        // Test 3: with we = 0, nothing is written
        $display("Test 3: write enable off");
        @(negedge clk);
        we    = 1'b0;
        waddr = 5'd3;
        wdata = 32'hBAD0_BAD0;                     // must NOT reach x3
        @(negedge clk);                            // a rising edge has passed
        check_read(5'd3, 5'd3);                    // still 33333333

        // Test 4: two ports at once - different registers, then the same one
        $display("Test 4: two read ports");
        check_read(5'd1, 5'd2);
        check_read(5'd2, 5'd2);
        check_read(5'd0, 5'd3);

        // Test 5: write a different value to every register, read all back
        $display("Test 5: all registers");
        for (int i = 1; i < 32; i++)
            write_reg(i[4:0], 32'h0101_0101 * i);  // x1=01010101, x2=02020202, ...
        for (int i = 0; i < 32; i++)
            check_read(i[4:0], 5'(31 - i));        // port 2 reads in reverse order

        // Test 6: read and write the same register in the same cycle
        $display("Test 6: read during write");
        @(negedge clk);
        we    = 1'b1;
        waddr = 5'd10;
        wdata = 32'hCAFE_F00D;
        check_read(5'd10, 5'd10);                  // BEFORE the rising edge: old value
        @(posedge clk);
        #1;
        shadow[10] = 32'hCAFE_F00D;
        check_read(5'd10, 5'd10);                  // AFTER the rising edge: new value
        @(negedge clk);
        we = 1'b0;

        // Test 7: 500 random cycles of writes and reads
        $display("Test 7: random");
        for (int i = 0; i < 500; i++) begin
            @(negedge clk);
            r_we    = $urandom_range(1, 0);
            r_waddr = $urandom_range(31, 0);
            r_wdata = $urandom;
            r_a1    = $urandom_range(31, 0);
            r_a2    = $urandom_range(31, 0);
            we      = r_we;
            waddr   = r_waddr;
            wdata   = r_wdata;
            @(posedge clk);
            #1;
            if (r_we && r_waddr != 5'd0) shadow[r_waddr] = r_wdata;
            check_read(r_a1, r_a2);
        end
        @(negedge clk);
        we = 1'b0;

        // Summary
        $display("\n%0d tests, %0d errors", tests, errors);
        if (errors == 0) $display("*** ALL TESTS PASSED ***");
        else             $display("*** SOME TESTS FAILED ***");
        $finish;
    end

endmodule