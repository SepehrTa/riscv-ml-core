`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/10/2026 12:23:23 PM
// Design Name: 
// Module Name: mv_engine
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



module mv_engine #(
    parameter int LANES      = 8,      // rows computed in parallel
    parameter int BANK_WORDS = 1024,   // 32-bit words per weight bank
    parameter int IN_WORDS   = 256,    // input buffer: 1 KB of packed int8
    parameter int RES_WORDS  = 64      // int32 results
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        we,
    input  logic        re,
    input  logic [17:0] addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata
);
 
    localparam int LW = $clog2(LANES);
    localparam int BW = $clog2(BANK_WORDS);
    localparam int IW = $clog2(IN_WORDS);
    localparam int RW = $clog2(RES_WORDS);
 
    // ------------------------------------------------------------------
    // Address decode
    // ------------------------------------------------------------------
    logic [1:0] region;
    assign region = addr[17:16];
 
    logic reg_sel, w_sel, in_sel, res_sel;
    assign reg_sel = (region == 2'd0) && addr[12];
    assign w_sel   = (region == 2'd1);
    assign in_sel  = (region == 2'd2);
    assign res_sel = (region == 2'd3);
 
    logic [LW-1:0] w_bank;                 // which bank a weight write goes to
    logic [BW-1:0] w_word;                 // which word in that bank
    assign w_bank = addr[2 +: LW];
    assign w_word = addr[2 + LW +: BW];
 
    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    logic [BW-1:0] w_base;
    logic [IW:0]   n_words;                // up to IN_WORDS, so one bit wider
    logic [RW-LW:0] n_groups;              // up to RES_WORDS/LANES
    logic [31:0]   cycles;
    logic          busy;
 
    logic start;
    assign start = we && reg_sel && (addr[4:2] == 3'd0) && wdata[0] && !busy
                   && (n_words != 0) && (n_groups != 0);
 
    always_ff @(posedge clk) begin
        if (rst) begin
            w_base   <= '0;
            n_words  <= '0;
            n_groups <= '0;
        end else if (we && reg_sel && !busy) begin   // settings are frozen while busy
            case (addr[4:2])
                3'd2: w_base   <= wdata[BW-1:0];
                3'd3: n_words  <= wdata[IW:0];
                3'd4: n_groups <= wdata[RW-LW:0];
                default: ;
            endcase
        end
    end
 
    // ------------------------------------------------------------------
    // Weight banks and input buffer: one write process (bus) and one read
    // process (engine) per memory, so each maps to a simple dual-port RAM.
    // ------------------------------------------------------------------
    logic [BW-1:0] rd_ptr;                 // S0: weight word, the same in all banks
    logic [IW-1:0] k;                      // S0: word within the row = input word
 
    logic [31:0] w_q [LANES];              // S1: weight words, one per lane
    logic [31:0] x_q;                      // S1: input word
 
    genvar l;
    generate
        for (l = 0; l < LANES; l++) begin : g_bank
            (* ram_style = "block" *) logic [31:0] bank [BANK_WORDS];
 
            always_ff @(posedge clk)
                if (we && w_sel && (w_bank == l))
                    bank[w_word] <= wdata;
 
            always_ff @(posedge clk)
                w_q[l] <= bank[rd_ptr];
        end
    endgenerate
 
    (* ram_style = "block" *) logic [31:0] inbuf [IN_WORDS];
 
    always_ff @(posedge clk)
        if (we && in_sel)
            inbuf[addr[2 +: IW]] <= wdata;
 
    always_ff @(posedge clk)
        x_q <= inbuf[k];
 
    // ------------------------------------------------------------------
    // S0: walk through the words of every group
    // ------------------------------------------------------------------
    logic           issuing;               // S0 has a valid word this cycle
    logic [RW-LW:0] g;                     // current group
    logic           last0;                 // last word of the row
 
    assign last0 = (k == n_words - 1'b1);
 
    always_ff @(posedge clk) begin
        if (rst) begin
            issuing <= 1'b0;
            rd_ptr  <= '0;
            k       <= '0;
            g       <= '0;
        end else if (start) begin
            issuing <= 1'b1;
            rd_ptr  <= w_base;
            k       <= '0;
            g       <= '0;
        end else if (issuing) begin
            rd_ptr <= rd_ptr + 1'b1;
            if (last0) begin
                k <= '0;
                if (g == n_groups - 1'b1)
                    issuing <= 1'b0;
                else
                    g <= g + 1'b1;
            end else begin
                k <= k + 1'b1;
            end
        end
    end
 
    // valid / last / group travel down the pipeline with the data
    logic           v1, v2;
    logic           last1, last2;
    logic [RW-LW:0] grp1, grp2;
 
    always_ff @(posedge clk) begin
        if (rst) begin
            v1 <= 1'b0;
            v2 <= 1'b0;
        end else begin
            v1 <= issuing;
            v2 <= v1;
        end
        last1 <= last0;
        grp1  <= g;
        last2 <= last1;
        grp2  <= grp1;
    end
 
    // ------------------------------------------------------------------
    // S2: four signed int8 products per lane, summed
    // ------------------------------------------------------------------
    function automatic logic signed [31:0] dot4(input logic [31:0] a, input logic [31:0] b);
        dot4 = $signed(a[7:0])   * $signed(b[7:0])
             + $signed(a[15:8])  * $signed(b[15:8])
             + $signed(a[23:16]) * $signed(b[23:16])
             + $signed(a[31:24]) * $signed(b[31:24]);
    endfunction
 
    logic signed [31:0] psum [LANES];
 
    always_ff @(posedge clk)
        for (int i = 0; i < LANES; i++)
            psum[i] <= dot4(w_q[i], x_q);
 
    // ------------------------------------------------------------------
    // S3: accumulate; at the end of a row, store the results
    // ------------------------------------------------------------------
    logic signed [31:0] acc     [LANES];
    logic        [31:0] results [RES_WORDS];
 
    always_ff @(posedge clk) begin
        if (rst || start) begin
            for (int i = 0; i < LANES; i++)
                acc[i] <= '0;
        end else if (v2) begin
            for (int i = 0; i < LANES; i++) begin
                if (last2) begin
                    results[grp2 * LANES + i] <= acc[i] + psum[i];
                    acc[i] <= '0;
                end else begin
                    acc[i] <= acc[i] + psum[i];
                end
            end
        end
    end
 
    // busy from the start until the last group's results are written
    always_ff @(posedge clk) begin
        if (rst) begin
            busy   <= 1'b0;
            cycles <= '0;
        end else if (start) begin
            busy   <= 1'b1;
            cycles <= '0;
        end else if (busy) begin
            cycles <= cycles + 1'b1;
            if (v2 && last2 && (grp2 == n_groups - 1'b1))
                busy <= 1'b0;
        end
    end
 
    // ------------------------------------------------------------------
    // Bus reads (registered, one cycle later)
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (re) begin
            if (reg_sel) begin
                case (addr[4:2])
                    3'd1:    rdata <= {31'b0, busy};
                    3'd2:    rdata <= 32'(w_base);
                    3'd3:    rdata <= 32'(n_words);
                    3'd4:    rdata <= 32'(n_groups);
                    3'd5:    rdata <= cycles;
                    default: rdata <= '0;
                endcase
            end else if (res_sel) begin
                rdata <= results[addr[2 +: RW]];
            end else begin
                rdata <= '0;                     // weights and inputs are write-only
            end
        end
    end
 
endmodule
