`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/03/2026 03:00:09 PM
// Design Name: 
// Module Name: divider
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



module divider (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,      // begin a division (1-cycle pulse)
    input  logic [31:0] a,          // dividend
    input  logic [31:0] b,          // divisor
    input  logic [2:0]  funct3,     // 100 div, 101 divu, 110 rem, 111 remu
    output logic        busy,       // division in progress
    output logic        done,       // out is valid (1 cycle)
    output logic [31:0] out
);

    typedef enum logic [1:0] {IDLE, BUSY, DONE} state_t;
    state_t state;

    logic [32:0] rem;               // partial remainder (bit 32 = sign of the trial subtraction)
    logic [31:0] quo;               // dividend bits shift out at the top, quotient bits shift in at the bottom
    logic [31:0] divisor;
    logic [4:0]  count;             // iteration 0..31
    logic        neg_q, neg_r;      // negate the quotient / remainder at the end?
    logic        want_rem;          // rem / remu: output the remainder

    // ---------- operand preparation (used at start) ----------
    logic        is_signed, a_neg, b_neg;
    logic [31:0] a_abs, b_abs;

    assign is_signed = ~funct3[0];              // div, rem are signed; divu, remu unsigned
    assign a_neg     = is_signed & a[31];
    assign b_neg     = is_signed & b[31];
    assign a_abs     = a_neg ? -a : a;
    assign b_abs     = b_neg ? -b : b;

    // ---------- one iteration (combinational) ----------
    logic [32:0] rem_shift, diff, rem_next;
    logic [31:0] quo_next;

    assign rem_shift = {rem[31:0], quo[31]};             // shift {rem, quo} left by 1
    assign diff      = rem_shift - {1'b0, divisor};      // try to subtract the divisor
    assign rem_next  = diff[32] ? rem_shift : diff;      // negative: did not fit, keep the old value
    assign quo_next  = {quo[30:0], ~diff[32]};           // new quotient bit: 1 if it fit

    // ---------- state machine ----------
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
        end else begin
            case (state)
                IDLE: begin
                    if (start) begin
                        want_rem <= funct3[1];
                        if (b == 32'd0) begin                                   // division by zero
                            out   <= funct3[1] ? a : 32'hFFFF_FFFF;
                            state <= DONE;
                        end else if (is_signed && a == 32'h8000_0000 && b == 32'hFFFF_FFFF) begin  // overflow
                            out   <= funct3[1] ? 32'd0 : 32'h8000_0000;
                            state <= DONE;
                        end else begin                                          // normal case
                            rem     <= 33'd0;
                            quo     <= a_abs;
                            divisor <= b_abs;
                            neg_q   <= a_neg ^ b_neg;   // quotient negative if exactly one operand is
                            neg_r   <= a_neg;           // remainder takes the sign of the dividend
                            count   <= 5'd0;
                            state   <= BUSY;
                        end
                    end
                end

                BUSY: begin
                    rem   <= rem_next;
                    quo   <= quo_next;
                    count <= count + 5'd1;
                    if (count == 5'd31) begin                                   // last iteration
                        if (want_rem) out <= neg_r ? -rem_next[31:0] : rem_next[31:0];
                        else          out <= neg_q ? -quo_next      : quo_next;
                        state <= DONE;
                    end
                end

                DONE:    state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end

    assign busy = (state == BUSY);
    assign done = (state == DONE);

endmodule