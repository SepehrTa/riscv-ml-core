`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/03/2026 03:01:12 PM
// Design Name: 
// Module Name: tb_divider
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

module tb_divider;

    logic        clk = 0;
    logic        rst = 1;
    logic        start = 0;
    logic [31:0] a, b;
    logic [2:0]  funct3;
    logic        busy, done;
    logic [31:0] out;

    int tests = 0, errors = 0;

    always #5 clk = ~clk;

    divider dut (.clk(clk), .rst(rst), .start(start), .a(a), .b(b),
                 .funct3(funct3), .busy(busy), .done(done), .out(out));

    // Reference model with the RISC-V rules. The special cases are checked
    // BEFORE dividing: dividing by zero would crash the simulator itself.
    function automatic logic [31:0] ref_model(logic [31:0] x, logic [31:0] y, logic [2:0] f);
        case (f)
            3'b100: if (y == 0) return 32'hFFFF_FFFF;                              // div
                    else if (x == 32'h8000_0000 && y == 32'hFFFF_FFFF) return 32'h8000_0000;
                    else return $signed(x) / $signed(y);
            3'b101: if (y == 0) return 32'hFFFF_FFFF; else return x / y;          // divu
            3'b110: if (y == 0) return x;                                          // rem
                    else if (x == 32'h8000_0000 && y == 32'hFFFF_FFFF) return 32'd0;
                    else return $signed(x) % $signed(y);
            default: if (y == 0) return x; else return x % y;                      // remu
        endcase
    endfunction

    task automatic check(logic [31:0] x, logic [31:0] y, logic [2:0] f);
        logic [31:0] expected;
        int cycles;
        expected = ref_model(x, y, f);
        @(negedge clk);
        a = x;  b = y;  funct3 = f;  start = 1;
        @(negedge clk);
        start = 0;
        a = $urandom;  b = $urandom;         // operands must be captured at start: change them now
        cycles = 1;
        while (!done && cycles < 100) begin
            @(negedge clk);
            cycles++;
        end
        tests++;
        if (!done || out !== expected) begin
            errors++;
            if (errors <= 10)
                $display("FAIL f3=%b a=%h b=%h : got %h, expected %h (done=%b)", f, x, y, out, expected, done);
        end
    endtask

    logic [31:0] corner [10];       // interesting operand values

    initial begin
        corner[0] = 32'd0;          corner[1] = 32'd1;          corner[2] = 32'd2;
        corner[3] = 32'd7;          corner[4] = 32'hFFFF_FFFF;  corner[5] = 32'hFFFF_FFFE;
        corner[6] = 32'h8000_0000;  corner[7] = 32'h7FFF_FFFF;  corner[8] = 32'h8000_0001;
        corner[9] = 32'h1234_5678;

        repeat (2) @(negedge clk);
        rst = 0;

        // 1) every pair of corner values, all four operations
        for (int f = 4; f < 8; f++)
            for (int i = 0; i < 10; i++)
                for (int j = 0; j < 10; j++)
                    check(corner[i], corner[j], f[2:0]);

        // 2) random operands (some with a small divisor, to get large quotients)
        for (int k = 0; k < 4000; k++) begin
            logic [31:0] y;
            y = (k % 4 == 0) ? ($urandom % 16) : $urandom;
            check($urandom, y, 3'b100 + (k % 4));
        end

        $display("divider: %0d tests, %0d errors", tests, errors);
        $finish;
    end

endmodule