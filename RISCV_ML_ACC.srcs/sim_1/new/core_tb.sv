`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_core
// Description: Runs test1.mem on the single-cycle core and checks the result.
//   - prints a trace: every instruction executed and every register written
//   - checks every register the program writes, plus registers it must NOT write
//   - checks the stored value in data memory and the final PC
//////////////////////////////////////////////////////////////////////////////////

module tb_core;

    // 1) Clock, reset and the core
    logic        clk = 1'b0;
    logic        rst = 1'b1;
    logic [31:0] pc_out;

    int errors = 0;
    int tests  = 0;

    logic [31:0] last_pc  = 32'hFFFF_FFFF;   // for the trace: skip repeated lines
    bit          trace_on = 1'b1;

    always #5 clk = ~clk;                 // 10 ns clock

    core dut (
        .clk    (clk),
        .rst    (rst),
        .pc_out (pc_out)
    );

    // 2) Trace: once per cycle (at the falling edge, when everything has
    //    settled) print the instruction being executed and, if it writes a
    //    register, which register and what value will be written.
    //    A jump-to-itself (the halt loop) is printed only once.
    always @(negedge clk) begin
        if (!rst && trace_on) begin
            if (dut.pc != last_pc) begin
                if (dut.reg_write && dut.instr[11:7] != 5'd0)
                    $display("pc=%h  instr=%h   x%0d <= %h",
                             dut.pc, dut.instr, dut.instr[11:7], dut.wb_value);
                else
                    $display("pc=%h  instr=%h", dut.pc, dut.instr);
            end
            last_pc = dut.pc;
        end
    end

    // 3) Check one register (read directly from inside the register file)
    task automatic check_reg(input int r, input logic [31:0] expected);
        tests++;
        if (dut.u_register_file.mem[r] !== expected) begin
            errors++;
            $display("FAIL  x%0d = %h, expected %h", r, dut.u_register_file.mem[r], expected);
        end
    endtask

    // 4) The test
    initial begin
        repeat (2) @(posedge clk);        // hold reset for 2 cycles
        #1 rst = 1'b0;                    // release reset just after a rising edge:
                                          // the program starts at PC = 0

        repeat (40) @(posedge clk);       // enough cycles to reach the halt loop
        @(negedge clk);

        trace_on = 1'b0;
        $display("\n---------------- checks ----------------");

        // Registers the program writes
        check_reg(1,  32'h0000_0005);     // addi x1, x0, 5
        check_reg(2,  32'h0000_000A);     // addi x2, x0, 10
        check_reg(3,  32'h0000_000F);     // add  x3, x1, x2
        check_reg(4,  32'h0000_0005);     // sub  x4, x2, x1
        check_reg(5,  32'h0000_000F);     // lw   x5, 0(x0)    (load after store)
        check_reg(7,  32'h0000_0007);     // addi x7 (after the taken branch)
        check_reg(8,  32'h0000_0028);     // jal  x8: return address
        check_reg(10, 32'h1234_5000);     // lui
        check_reg(11, 32'h0000_0030);     // auipc: its own address
        check_reg(13, 32'h0000_0038);     // jal  x13 ("call"): return address
        check_reg(14, 32'h0000_000E);     // addi x14 (inside the "function")

        // Instructions that must have been SKIPPED
        tests++;
        if (dut.u_register_file.mem[6] === 32'h0000_0001) begin
            errors++;
            $display("FAIL  x6 was written: the beq at 0x18 was not taken");
        end
        tests++;
        if (dut.u_register_file.mem[9] === 32'h0000_0009) begin
            errors++;
            $display("FAIL  x9 was written: the jal at 0x24 did not jump");
        end

        // The store went to data memory (word 0)
        tests++;
        if (dut.u_data_mem.mem[0] !== 32'h0000_000F) begin
            errors++;
            $display("FAIL  data memory[0] = %h, expected 0000000f", dut.u_data_mem.mem[0]);
        end

        // The program ends in its halt loop at 0x38
        tests++;
        if (pc_out !== 32'h0000_0038) begin
            errors++;
            $display("FAIL  pc = %h, expected 00000038 (the halt loop)", pc_out);
        end

        // Summary
        $display("\n%0d checks, %0d errors", tests, errors);
        if (errors == 0) $display("*** ALL TESTS PASSED ***");
        else             $display("*** SOME TESTS FAILED ***");
        $finish;
    end

endmodule