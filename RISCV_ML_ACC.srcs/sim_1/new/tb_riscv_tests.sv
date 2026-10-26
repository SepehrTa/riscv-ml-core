`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_riscv_tests
// Description: Runs the official riscv-tests (rv32ui) on the core, one after
//              another, and prints PASS / FAIL for each instruction.
//
//   For each test:
//     1. hold the core in reset
//     2. load <name>.text.mem into instruction memory and
//        <name>.data.mem into data memory
//     3. release reset and run until the program halts (j . = 0x0000006f)
//     4. read gp (x3):  1 = PASS,  otherwise the failed test case = gp >> 1
//////////////////////////////////////////////////////////////////////////////////

module tb_riscv_tests;

    // Folder with the .mem files from build_tests.py (use forward slashes)
    parameter string BUILD_DIR = "C:/FPGA/RISCV_ML_ACC/sw/rvtest/build";
    parameter int    TIMEOUT   = 20000;         // max cycles per test

    logic        clk = 1'b0;
    logic        rst = 1'b1;
    logic [31:0] pc_out;

    int passed = 0;
    int failed = 0;

    always #5 clk = ~clk;

    core dut (
        .clk    (clk),
        .rst    (rst),
        .pc_out (pc_out)
    );

    task automatic run_test(input string name);
        int          cycles;
        logic [31:0] gp;

        // 1) + 2) reset the core and load this test's program and data
        rst = 1'b1;
        $readmemh({BUILD_DIR, "/", name, ".text.mem"}, dut.u_instr_mem.mem);
        $readmemh({BUILD_DIR, "/", name, ".data.mem"}, dut.u_data_mem.mem);
        repeat (2) @(posedge clk);
        #1 rst = 1'b0;

        // 3) run until the halt instruction (j .) or the timeout
        cycles = 0;
        while (dut.instr !== 32'h0000_006f && cycles < TIMEOUT) begin
            @(posedge clk);
            #1;
            cycles++;
        end

        // 4) check the result register
        gp = dut.u_register_file.mem[3];
        if (cycles >= TIMEOUT) begin
            failed++;
            $display("FAIL  %-8s timeout after %0d cycles (pc = %h)", name, cycles, dut.pc);
        end else if (gp === 32'd1) begin
            passed++;
            $display("PASS  %-8s %0d cycles", name, cycles);
        end else begin
            failed++;
            $display("FAIL  %-8s failed at test case %0d (gp = %h)", name, gp >> 1, gp);
        end
    endtask

    initial begin
        run_test("simple");
        run_test("add");    run_test("addi");   run_test("sub");
        run_test("and");    run_test("andi");   run_test("or");     run_test("ori");
        run_test("xor");    run_test("xori");
        run_test("sll");    run_test("slli");   run_test("srl");    run_test("srli");
        run_test("sra");    run_test("srai");
        run_test("slt");    run_test("slti");   run_test("sltu");   run_test("sltiu");
        run_test("lui");    run_test("auipc");
        run_test("beq");    run_test("bne");    run_test("blt");    run_test("bge");
        run_test("bltu");   run_test("bgeu");
        run_test("jal");    run_test("jalr");
        run_test("lb");     run_test("lbu");    run_test("lh");     run_test("lhu");
        run_test("lw");
        run_test("sb");     run_test("sh");     run_test("sw");
        run_test("ld_st");  run_test("st_ld");
        run_test("mul");    run_test("mulh");   run_test("mulhsu"); run_test("mulhu");
        run_test("div");    run_test("divu");   run_test("rem");    run_test("remu");

        $display("\n%0d passed, %0d failed", passed, failed);
        if (failed == 0) $display("*** ALL riscv-tests PASSED ***");
        $finish;
    end

endmodule