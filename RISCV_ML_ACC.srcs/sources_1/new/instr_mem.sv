`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/22/2026 06:29:05 PM
// Design Name: 
// Module Name: instr_mem
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


module instr_mem #(
    parameter int DEPTH     = 1024,
    parameter     INIT_FILE = "program.mem",
    parameter bit SYNC_READ = 0
) (
    input  logic        clk,     // used only when SYNC_READ = 1
    input  logic        en,      // read enable, used only when SYNC_READ = 1
                                 // (the pipeline will set it to 0 to stall)
    input  logic [31:0] addr,    // byte address: the PC
    output logic [31:0] instr
);

    localparam int AW = $clog2(DEPTH);       // index bits: 1024 words -> 10

    logic [31:0] mem [DEPTH];

    // The PC counts bytes (0, 4, 8, ...) but each entry is a 4-byte word,
    // so the word index is addr / 4: drop the two lowest bits.
    logic [AW-1:0] index;
    assign index = addr[AW+1:2];

    // Fill every word with a NOP (addi x0, x0, 0) first, so any address past
    // the end of the program reads as "do nothing" instead of X. Then load
    // the program over the start of the memory.
    initial begin
        for (int i = 0; i < DEPTH; i++)
            mem[i] = 32'h0000_0013;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // Read port: one of the two versions is built, chosen by SYNC_READ.
    generate
        if (SYNC_READ) begin : g_sync_read
            always_ff @(posedge clk) begin
                if (en)
                    instr <= mem[index];
            end
        end else begin : g_async_read
            assign instr = mem[index];
        end
    endgenerate

endmodule