`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/05/2026 10:39:50 AM
// Design Name: 
// Module Name: tb_ml_unit
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


module tb_ml_unit;

    logic        clk = 0;
    logic        rst = 1;
    logic        valid = 0;
    logic [2:0]  funct3 = 0;
    logic [31:0] a = 0, b = 0;
    logic [31:0] out;

    logic [31:0] model_acc;            // reference accumulator
    int tests = 0, errors = 0;

    always #5 clk = ~clk;

    ml_unit dut (.clk(clk), .rst(rst), .valid(valid), .funct3(funct3),
                 .a(a), .b(b), .out(out));

    // reference dot product, written differently from the RTL (a loop of integers)
    function automatic logic [31:0] ref_dot(logic [31:0] x, logic [31:0] y);
        int sum = 0;
        for (int i = 0; i < 4; i++)
            sum += int'($signed(x[8*i +: 8])) * int'($signed(y[8*i +: 8]));
        return sum;
    endfunction

    // apply one instruction for one cycle and check it
    task automatic do_op(logic v, logic [2:0] f, logic [31:0] x, logic [31:0] y);
        logic [31:0] expected;
        @(negedge clk);
        valid = v;  funct3 = f;  a = x;  b = y;
        #1;
        case (f)
            3'b000:  expected = ref_dot(x, y);
            3'b011:  expected = model_acc;
            default: expected = 32'd0;
        endcase
        tests++;
        if (out !== expected) begin
            errors++;
            if (errors <= 10)
                $display("FAIL valid=%b f3=%b a=%h b=%h: out=%h expected=%h", v, f, x, y, out, expected);
        end
        @(posedge clk);                                   // the accumulator updates here
        if (v && f == 3'b001) model_acc = model_acc + ref_dot(x, y);
        if (v && f == 3'b010) model_acc = x;
    endtask

    initial begin
        model_acc = 0;
        repeat (2) @(negedge clk);
        rst = 0;

        // 1) directed corner cases
        do_op(1, 3'b000, 32'h8080_8080, 32'h8080_8080);   // 4 x (-128 * -128) = 65536 (largest)
        do_op(1, 3'b000, 32'h8080_8080, 32'h7F7F_7F7F);   // 4 x (-128 * 127)  = -65024 (smallest)
        do_op(1, 3'b000, 32'h0102_03FF, 32'h0101_01FF);   // 1 + 2 + 3 + 1 = 7
        do_op(1, 3'b010, 32'd0, 32'd0);                   // acc.set 0
        do_op(1, 3'b001, 32'h0102_0304, 32'h0101_0101);   // acc += 10
        do_op(1, 3'b001, 32'h0102_0304, 32'h0101_0101);   // acc += 10
        do_op(1, 3'b011, 32'd0, 32'd0);                   // acc.rd -> 20
        do_op(0, 3'b001, 32'h7F7F_7F7F, 32'h7F7F_7F7F);   // bubble: acc must not change
        do_op(1, 3'b011, 32'd0, 32'd0);                   // acc.rd -> still 20
        do_op(1, 3'b010, 32'h7FFF_FFFF, 32'd0);           // acc.set to the maximum
        do_op(1, 3'b001, 32'h0000_0001, 32'h0000_0001);   // acc += 1: wraps around like add
        do_op(1, 3'b011, 32'd0, 32'd0);                   // acc.rd -> 0x8000_0000

        // 2) random instruction mix
        for (int k = 0; k < 5000; k++)
            do_op(($urandom % 8) != 0, $urandom % 4, $urandom, $urandom);

        $display("ml_unit: %0d tests, %0d errors", tests, errors);
        $finish;
    end

endmodule