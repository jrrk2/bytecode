#include <unistd.h>
#include <sys/stat.h>
#include <string>
#include <vector>
#include "Vocaml4142_vm_rtl.h"
#include <cmath>
#include <cstring>
#include "verilated.h"
#include "verilated_vcd_c.h"
typedef enum
#include "state_rtl_complete.h"
#include "ethmodel.h"

#include <fstream>
#include <iostream>

// ------------------------------------------------------------
// Bytecode ROM (owned by C++)
// ------------------------------------------------------------
uint32_t code_rom[1 << 20];
// A write into the code window invalidates the one-deep prefetch, as
// ethmin_vm_core does with code_q_valid.
static bool code_dirty = false;
// The RAM disk, as ethmin_vm_core decodes it at 0x100000.  Backed by a file
// when +disk= names one, so a filesystem can be written and read here and
// then looked at from outside.
// the RAM disk: the board's 512 KiB unless $OCVM_DISK_KIB says otherwise (to measure an image that would not fit)
static uint8_t disk_ram[16 * 1024 * 1024];
static size_t disk_bytes = 512 * 1024;
static const char *disk_path = nullptr;

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

extern "C"
{
  int caml_bytecode(char *byte_name);
  char *opname(int ix);
  };

const char *statenam(int state)
{
  switch(state)
    {
    case S_FETCH: return "S_FETCH";
    case S_DECIDE_IMM: return "S_DECIDE_IMM";
    case S_FETCH_IMM: return "S_FETCH_IMM";
    case S_EXEC: return "S_EXEC";
    case S_DONE: return "S_DONE";

    // Single memory operation states
    case S_STACK_READ: return "S_STACK_READ";           // Single stack read (2 cycles: req + wait)
    case S_HEAP_READ: return "S_HEAP_READ";            // Single heap read (2 cycles: req + wait)
    case S_GLOBALS_READ: return "S_GLOBALS_READ";         // Single globals read (2 cycles: req + wait)

    // PUSH/ACC combined operations
    case S_PUSHACC_WRITE: return "S_PUSHACC_WRITE";        // Write old accu to stack
    case S_PUSHACC_READ: return "S_PUSHACC_READ";         // Read new accu from stack
    
    // Helper completion states
    case S_ENVACC_DONE: return "S_ENVACC_DONE";          // Complete ENVACC operations
    case S_GETFIELD_DONE: return "S_GETFIELD_DONE";        // Complete GETFIELD operations
    case S_OFFSETCLOSURE_CALC: return "S_OFFSETCLOSURE_CALC";   // Complete OFFSETCLOSURE calculation
    
    // MAKEBLOCK3 states
    case S_MAKEBLOCK_READ_STACK: return "S_MAKEBLOCK_READ_STACK"; // Read values from stack
    case S_MAKEBLOCK_WRITE_HDR: return "S_MAKEBLOCK_WRITE_HDR";       // Write header
    case S_MAKEBLOCK_WRITE_FIELD: return "S_MAKEBLOCK_WRITE_FIELD";    // Write fields (loop)
    
    // MAKEBLOCK1 states
    
    // MAKEBLOCK2 states
    
    // MAKEBLOCK3 states
    
    // APPTERM states
    case S_APPTERM_READ_CODE: return "S_APPTERM_READ_CODE";    // Read arguments
    case S_APPTERM_READ_ARGS: return "S_APPTERM_READ_ARGS";    // Read arguments
    case S_APPTERM_WRITE_ARGS: return "S_APPTERM_WRITE_ARGS";   // Write arguments
    case S_APPTERM_SET_PC: return "S_APPTERM_SET_PC";       // Set PC from closure
    
    // APPTERM1 states
    case S_APPTERM1_ADJUST: return "S_APPTERM1_ADJUST";      // Adjust stack pointer
    case S_APPTERM1_WRITE: return "S_APPTERM1_WRITE";       // Write argument
    case S_APPTERM1_SETPC: return "S_APPTERM1_SETPC";       // Set PC from closure
    
    // APPTERM2 states
    case S_APPTERM2_READ_ARGS: return "S_APPTERM2_READ_ARGS";   // Read arguments
    case S_APPTERM2_WRITE_ARGS: return "S_APPTERM2_WRITE_ARGS";  // Write arguments
    case S_APPTERM2_SETPC: return "S_APPTERM2_SETPC";       // Set PC from closure
    
    // APPTERM3 states
    case S_APPTERM3_READ_ARGS: return "S_APPTERM3_READ_ARGS";   // Read arguments
    case S_APPTERM3_WRITE_ARGS: return "S_APPTERM3_WRITE_ARGS";  // Write arguments
    case S_APPTERM3_SETPC: return "S_APPTERM3_SETPC";       // Set PC from closure
    
    // APPLY states
    case S_APPLY_READ_CODE: return "S_APPLY_READ_CODE";      // Read arguments
    case S_APPLY_WRITE_FRAME: return "S_APPLY_WRITE_FRAME";    // Write return frame
    case S_APPLY_SET_PC: return "S_APPLY_SET_PC";         // Set PC from closure
    
    // APPLY1 states
    case S_APPLY1_WRITE_FRAME: return "S_APPLY1_WRITE_FRAME";   // Write return frame
    case S_APPLY1_SETPC: return "S_APPLY1_SETPC";         // Set PC from closure
    
    // APPLY2 states
    case S_APPLY2_WRITE_FRAME: return "S_APPLY2_WRITE_FRAME";   // Write return frame
    case S_APPLY2_SETPC: return "S_APPLY2_SETPC";         // Set PC from closure
    
    // APPLY3 states
    case S_APPLY3_WRITE_FRAME: return "S_APPLY3_WRITE_FRAME";   // Write return frame
    case S_APPLY3_SETPC: return "S_APPLY3_SETPC";         // Set PC from closure
    
    // RETURN states
    case S_RETURN_READ_FRAME: return "S_RETURN_READ_FRAME";    // Read return frame
    case S_RETURN_RESTORE: return "S_RETURN_RESTORE";       // Restore state
    case S_RETURN_READ_PC: return "S_RETURN_READ_PC";       // Restore state
    case S_RETURN_READ_ENV: return "S_RETURN_READ_ENV";      // Restore state
    case S_RETURN_READ_EXTRA: return "S_RETURN_READ_EXTRA";      // Restore state
    case S_RETURN_SET_STATE: return "S_RETURN_SET_STATE";     // Restore state
    
    // Heap allocation micro-ops (for CLOSURE/MAKEBLOCK via S_EXEC)
    
    // CLOSURE-specific states (kept from original)

    case S_PUSH_RETADDR_WRITE_FRAME: return "S_PUSH_RETADDR_WRITE_FRAME";   // Write return frame

    // Trap / ccall
    case S_TRAP_WAIT: return "S_TRAP_WAIT";
    case S_ALLOC_HDR: return "S_ALLOC_HDR";
    case S_ALLOC_FIELD: return "S_ALLOC_FIELD";
    case S_ALLOC_DONE: return "S_ALLOC_DONE";
    case S_ALLOC_PUSH: return "S_ALLOC_PUSH";
    case S_APPTERM_COPY: return "S_APPTERM_COPY";
    case S_GC_START: return "S_GC_START";
    case S_GC_ROOT: return "S_GC_ROOT";
    case S_GC_ROOT_WB: return "S_GC_ROOT_WB";
    case S_GC_FWD: return "S_GC_FWD";
    case S_GC_COPY: return "S_GC_COPY";
    case S_GC_MARK: return "S_GC_MARK";
    case S_GC_SCAN: return "S_GC_SCAN";
    case S_GC_SCAN_FIELD: return "S_GC_SCAN_FIELD";
    case S_GC_SCAN_WB: return "S_GC_SCAN_WB";
    case S_GC_DONE: return "S_GC_DONE";
    case S_SWITCH_TAG: return "S_SWITCH_TAG";
    case S_SWITCH_JUMP: return "S_SWITCH_JUMP";
    case S_DUP_HDR: return "S_DUP_HDR";
    case S_DUP_FIELD: return "S_DUP_FIELD";
    case S_RESTART_HDR: return "S_RESTART_HDR";
    case S_RESTART_ARG: return "S_RESTART_ARG";
    case S_RESTART_ENV: return "S_RESTART_ENV";
    case S_DIV_ITER: return "S_DIV_ITER";
    case S_BYTESET_RMW: return "S_BYTESET_RMW";
    case S_CREATE_BYTES: return "S_CREATE_BYTES";
    case S_STREQ_HDR: return "S_STREQ_HDR";
    case S_STREQ_WORD: return "S_STREQ_WORD";
    case S_STRLEN_HDR: return "S_STRLEN_HDR";
    case S_STRLEN_LAST: return "S_STRLEN_LAST";
    case S_STRGET_READ: return "S_STRGET_READ";
    case S_IO_WAIT: return "S_IO_WAIT";

    // obsolete states
    case S_OFFSETCLOSURE_READ: return "S_OFFSETCLOSURE_READ";
    case S_OFFSETCLOSURE_ADD: return "S_OFFSETCLOSURE_ADD";
    // Unknown state for debugging
    case S_UNKNOWN: return "S_UNKNOWN";
    default: return "S_NOT_DOCUMENTED";
    }
}

// BOOT from the RAM disk (0x100e, written with the image's byte offset in the disk).  What the
// hardware does is load the image's code, heap and globals into the machine and restart it, with
// the RAM disk untouched.  Here the machine is this process, so it does the same by starting
// itself again: the disk is saved to its backing file, the image is written out as a bytecode
// file plus heap and globals hex (the form the model runs), and the UART input carries on where
// this program stopped reading.
static int g_argc; static char **g_argv;

static uint16_t crc16_ccitt(const uint8_t *p, size_t n) {
    uint16_t c = 0xFFFF;
    for (size_t i = 0; i < n; i++) {
        c ^= (uint16_t)p[i] << 8;
        for (int b = 0; b < 8; b++) c = (c & 0x8000) ? (uint16_t)((c << 1) ^ 0x1021) : (uint16_t)(c << 1);
    }
    return c;
}

static void put_be32(std::string &s, uint32_t v) { for (int i = 3; i >= 0; i--) s.push_back((char)(v >> (8 * i))); }

static void boot_from_disk(uint32_t off) {
    if ((size_t)off + 32 > disk_bytes) { printf("BOOT: offset %u is off the disk\n", off); return; }
    const uint8_t *h = disk_ram + off;
    auto rd32 = [&](uint32_t o) { return (uint32_t)h[o] | (uint32_t)h[o + 1] << 8 | (uint32_t)h[o + 2] << 16 | (uint32_t)h[o + 3] << 24; };
    if (rd32(0) != 0x4D56434Fu || rd32(4) != 1) { printf("BOOT: no image at %u\n", off); return; }
    uint32_t cw = rd32(8), hw = rd32(12), gw = rd32(16), crc = rd32(24);
    size_t body = 4 * ((size_t)cw + hw + gw);
    if ((size_t)off + 32 + body > disk_bytes) { printf("BOOT: the image runs past the disk\n"); return; }
    if (crc16_ccitt(h + 32, body) != (crc & 0xFFFF)) { printf("BOOT: CRC mismatch\n"); return; }
    if (!Verilated::commandArgsPlusMatch("notrace")[0]) { printf("BOOT from the disk needs +notrace\n"); return; }

    // the running program's PRIM section: the image's C calls number the same primitives
    std::string prim;
    {
        FILE *f = fopen(g_argv[1], "rb");
        if (!f) { printf("BOOT: cannot read %s\n", g_argv[1]); return; }
        std::string d; char buf[65536]; size_t n;
        while ((n = fread(buf, 1, sizeof buf, f)) > 0) d.append(buf, n);
        fclose(f);
        auto be32 = [&](size_t o) { return (uint32_t)(uint8_t)d[o] << 24 | (uint32_t)(uint8_t)d[o + 1] << 16 | (uint32_t)(uint8_t)d[o + 2] << 8 | (uint8_t)d[o + 3]; };
        size_t len = d.size(); uint32_t ns = be32(len - 16);
        size_t table = len - 16 - 8 * (size_t)ns, total = 0;
        for (uint32_t i = 0; i < ns; i++) total += be32(table + 8 * i + 4);
        size_t pos = table - total; bool found = false;
        for (uint32_t i = 0; i < ns; i++) {
            uint32_t sz = be32(table + 8 * i + 4);
            if (d.compare(table + 8 * i, 4, "PRIM") == 0) { prim = d.substr(pos, sz); found = true; }
            pos += sz;
        }
        if (!found) { printf("BOOT: no PRIM section in %s\n", g_argv[1]); return; }
    }
    char dir[64]; snprintf(dir, sizeof dir, "/tmp/ocvm_boot_%d", (int)getpid());
    mkdir(dir, 0700);
    std::string dp = std::string(dir) + "/";
    std::string bc((const char *)(h + 32), 4 * (size_t)cw);
    std::string trailer = bc + prim + std::string(4, '\0');
    std::string table;
    table += "CODE"; put_be32(table, 4 * cw);
    table += "PRIM"; put_be32(table, (uint32_t)prim.size());
    table += "DATA"; put_be32(table, 4);
    std::string file = trailer + table; put_be32(file, 3); file += "Caml1999X031";
    { FILE *f = fopen((dp + "prog.bc").c_str(), "wb"); fwrite(file.data(), 1, file.size(), f); fclose(f); }
    auto hex = [&](const char *name, size_t first, uint32_t n) {
        FILE *f = fopen((dp + name).c_str(), "w");
        for (uint32_t i = 0; i < n; i++) fprintf(f, "%08x\n", rd32((uint32_t)(32 + 4 * (first + i))));
        fclose(f);
    };
    hex("heap.hex", cw, hw); hex("globals.hex", (size_t)cw + hw, gw);
    // the disk outlives the chain load
    std::string diskfile = (disk_path && *disk_path) ? std::string(disk_path) : dp + "disk.bin";
    { FILE *f = fopen(diskfile.c_str(), "wb"); if (f) { fwrite(disk_ram, 1, disk_bytes, f); fclose(f); } }
    setenv("ETHMODEL_UART_SKIP", std::to_string(ethmodel_uart_consumed()).c_str(), 1);

    std::vector<std::string> args = { g_argv[0], dp + "prog.bc", "+notrace", "+heap=" + dp + "heap.hex",
        "+globals=" + dp + "globals.hex", "+heap_words=" + std::to_string(hw), "+disk=" + diskfile };
    for (int i = 2; i < g_argc; i++) {          // whatever else was asked for, but not what is being replaced
        std::string a = g_argv[i];
        if (a.rfind("+heap=", 0) && a.rfind("+globals=", 0) && a.rfind("+heap_words=", 0) && a.rfind("+disk=", 0) && a != "+notrace" && a[0] == '+') args.push_back(a);
    }
    std::vector<char *> av; for (auto &a : args) av.push_back(const_cast<char *>(a.c_str())); av.push_back(nullptr);
    printf("BOOT from the disk: %u code, %u heap, %u globals words\n", cw, hw, gw);
    fflush(stdout);
    execv(g_argv[0], av.data());
    perror("execv");
}

typedef char linbuf[256];

linbuf trace[4096];

int main(int argc, char** argv) {
    if (getenv("OCVM_DISK_KIB")) disk_bytes = (size_t)atol(getenv("OCVM_DISK_KIB")) * 1024;
    g_argc = argc; g_argv = argv;
    Verilated::commandArgs(argc, argv);

    // With +notrace there is nothing to diverge from: a program that writes
    // its own code has no reference run to be compared with, because the
    // reference cannot execute what it generates.
    const bool notrace = Verilated::commandArgsPlusMatch("notrace")[0] != 0;

    if (argc < 2 || (!notrace && argc < 3)) {
        std::cerr << "usage: " << argv[0]
                  << " program.bc trace_file | " << argv[0]
                  << " program.bc +notrace\n";
        return 1;
    }

    int prog_length = caml_bytecode(argv[1]);
    auto* top = new Vocaml4142_vm_rtl;
    FILE *tracef = nullptr;
    if (!notrace) {
        tracef = fopen(argv[2], "r");
        if (!tracef) {
            std::cerr << "cannot open trace file " << argv[2] << "\n";
            return 1;
        }
        fgets(trace[0], sizeof(linbuf), tracef);
    }
    
    // Optional waveform (+vcd): every signal every cycle, so gigabytes for
    // the long network tests
    VerilatedVcdC* tfp = nullptr;
    if (Verilated::commandArgsPlusMatch("vcd")[0]) {
        Verilated::traceEverOn(true);
        tfp = new VerilatedVcdC;
        top->trace(tfp, 99);
        tfp->open("trace.vcd");
    }

    // Reset
    top->reset = 1;
    for (int i = 0; i < 10; i++) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
    }
    top->reset = 0;

    uint64_t cycles = 0;
    FILE *trace_out = getenv("OCVM_TRACE_FILE") ? fopen(getenv("OCVM_TRACE_FILE"), "wb") : nullptr;
    uint64_t max_cycles = getenv("OCVM_MAX_CYCLES") ? strtoull(getenv("OCVM_MAX_CYCLES"), nullptr, 0) : 50'000'000;
    const char *op;
    linbuf opcode;
    uint32_t addr, op1, cnt, oldpc, vitems, cycle, accu, spaddr, items, oldcycle = 0;
    int matching = 1;
    // a file to prime the RAM disk from, and to write back at the end
    {
        const char *d = Verilated::commandArgsPlusMatch("disk");
        if (d && *d) {
            // copied: the pointer commandArgsPlusMatch hands back is into
            // a buffer it reuses on the next call, and the next call is two
            // lines below
            const char *eq = strchr(d, '=');
            disk_path = eq ? strdup(eq + 1) : nullptr;
            if (disk_path && *disk_path) {
                FILE *f = fopen(disk_path, "rb");
                if (f) { fread(disk_ram, 1, disk_bytes, f); fclose(f); }
            }
        }
    }
    int windup = 10;
    printf("Program length %d\n", prog_length);

    while (windup && !Verilated::gotFinish()) {
      // A pc outside the program is the VM's to deal with: code_oob raises "index out of bounds".
        // The trap port as an I/O bus (vm_io_read / vm_io_write), answered by
        // the ethmin device model: one ready per request, not again until
        // trap_valid has dropped.
        static bool trap_answered = false;
        // The floating-point peripheral of fpga/fpu-rtl, in the host's own
        // doubles: the hardware is proved against these in
        // fpga/fpu-rtl/test, so the model and the silicon agree by
        // construction rather than by hope.
        static uint64_t fp_a = 0, fp_b = 0, fp_res = 0;
        static bool fp_flag = false;
        top->trap_ready = 0;
        if (top->trap_valid && !trap_answered &&
            (top->trap_prim == 1 || top->trap_prim == 2)) {
            uint32_t a = (uint32_t)top->trap_arg0;
            if (a >= 0x200000 && a < 0x280000) {
                // Code memory while the program runs, a byte per address:
                // fpga/vc707-ethmin/ethmin_vm_core.v decodes 0x200000..0x27FFFF
                // (128K words) this way, and modelling it here is what lets a compiler
                // that writes its own code be simulated at all.
                uint32_t w = (a - 0x200000) >> 2, lane = a & 3;
                if (top->trap_prim == 2) {
                    code_rom[w] = (code_rom[w] & ~(0xFFu << (8 * lane)))
                                | (((uint32_t)top->trap_arg1 & 0xFF) << (8 * lane));
                    code_dirty = true;
                } else {
                    top->trap_result = (code_rom[w] >> (8 * lane)) & 0xFF;
                }
            } else if (a >= 0x100000 && a < 0x100000 + disk_bytes) {
                uint32_t off = a - 0x100000;
                if (top->trap_prim == 2) disk_ram[off] = (uint8_t)top->trap_arg1;
                else top->trap_result = disk_ram[off];
            } else if (a == 0x100e) {
                if (top->trap_prim == 2) boot_from_disk((uint32_t)top->trap_arg1);
                else top->trap_result = 0;
            } else if (a == 0x100d) {
                if (top->trap_prim == 1) top->trap_result = disk_bytes;
            } else if (a == 0x100c) {
                // prog_words.  Read, it says where the program's code ends,
                // which is what lets a compiler find its own end; written,
                // the hardware widens what the fetch unit will reach, and
                // the model fetches from the whole array anyway.
                static uint32_t pw = 0;
                // caml_bytecode returns a byte count; the register is words
                if (top->trap_prim == 1) top->trap_result = pw ? pw : (uint32_t)prog_length / 4;
                else pw = (uint32_t)top->trap_arg1;
            } else if (top->trap_prim == 1) top->trap_result = ethmodel_read((int32_t)a);
            else ethmodel_write((int32_t)a, (int32_t)top->trap_arg1);
            top->trap_ready = 1;
            trap_answered = true;
        } else if (top->trap_valid && !trap_answered &&
                   top->trap_prim >= 0x10 && top->trap_prim <= 0x13) {
            uint64_t pair = ((uint64_t)(uint32_t)top->trap_arg1 << 32) | (uint32_t)top->trap_arg0;
            auto as_double = [](uint64_t u) { double d; memcpy(&d, &u, 8); return d; };
            auto as_bits = [](double d) { uint64_t u; memcpy(&u, &d, 8); return u; };
            switch (top->trap_prim) {
                case 0x10: fp_a = pair; break;
                case 0x11: fp_b = pair; break;
                case 0x13: top->trap_result = (uint32_t)(fp_res >> 32); break;
                default: {                       // 0x12: do it
                    double a = as_double(fp_a), b = as_double(fp_b);
                    switch (top->trap_arg0 & 0xF) {
                        case 0:  fp_res = as_bits(a + b); break;
                        case 1:  fp_res = as_bits(a - b); break;
                        case 2:  fp_res = as_bits(a * b); break;
                        case 3:  fp_res = as_bits(a / b); break;
                        case 4:  fp_res = as_bits(sqrt(a)); break;
                        case 5:  fp_flag = (a < b); break;
                        case 6:  fp_flag = (a <= b); break;
                        case 7:  fp_flag = (a == b); break;
                        case 8:  fp_res = fp_a ^ (1ULL << 63); break;
                        case 9:  fp_res = fp_a & ~(1ULL << 63); break;
                        case 10: fp_res = as_bits((double)(int32_t)(uint32_t)fp_a); break;
                        default: {               // 11: toward zero, as OCaml's own cast
                            double d = as_double(fp_a);
                            fp_res = (d >= -2147483648.0 && d <= 2147483647.0)
                                       ? (uint32_t)(int32_t)d : 0;
                            break;
                        }
                    }
                    int op = top->trap_arg0 & 0xF;
                    top->trap_result = (op >= 5 && op <= 7) ? (uint32_t)fp_flag
                                                            : (uint32_t)(fp_res & 0xffffffffu);
                    break;
                }
            }
            top->trap_ready = 1;
            trap_answered = true;
        } else if (!top->trap_valid) trap_answered = false;
        // The fetch unit, as in fpga/vc707-ethmin/ethmin_vm_core.v: the code
        // memory is read synchronously (block RAM), the word read is kept
        // with the pc it came from, and the next one is prefetched while the
        // VM uses this one, so straight-line code costs no extra cycle.
        static uint32_t code_q = 0xDEADBEEF, code_q_pc = 0xFFFFFFFF;
        if (code_dirty) { code_q_pc = 0xFFFFFFFF; code_dirty = false; }
        bool code_valid = code_q_pc == top->pc;
        top->code_rdata = code_q;
        top->code_valid = code_valid;
        top->code_oob = code_q_pc >= sizeof(code_rom)/sizeof(*code_rom);
        uint32_t fetch_pc = code_valid ? top->pc + 1 : top->pc;
        // Clock tick
        top->clk = 0;
        top->eval();
        vitems = 0xffff - top->sp;
        if (tfp) tfp->dump(cycles);
	
	switch(top->state_out)
	  {
	  case S_FETCH:
	    if (!code_valid) break;   // waiting for the fetch unit
	    oldpc = top->pc;
	    op = opname(top->code_rdata);
	    if (notrace) { printf("Fetch PC=%d %s\n", top->pc, op); break; }
	    printf("Fetch PC=%d ROM = 0x%x, instruction = %s, SP=@%d\n", top->pc, top->code_rdata, op, vitems);
	    cnt = 0;
	    do {
	      fgets(trace[cnt], sizeof(linbuf), tracef);
	      printf("Trace %s", trace[cnt]);
	      
	    } while (cnt < sizeof(trace)/sizeof(*trace) && ((cnt == 0 && trace[cnt][0] != '#') || strlen(trace[cnt++]) > 1));
	    
	    cnt = sscanf(trace[0], "##%d", &cycle);
	    if (!cnt || cycle != oldcycle+1)
	      {
	      printf("Trace mismatch\n");
	      matching = 0;
	      }
	    oldcycle = cycle;
	    cnt = sscanf(trace[1], " %d %s %d", &addr, opcode, &op1);
	    printf("Trace cnt=%d: %s\n", cnt, trace[1]);
	    if (cnt >= 2 && matching)
	      {
		// ocamlrund's tracer names 4.14's last opcode (GETSTRINGCHAR)
		// "???": that name cannot disagree, the pc still has to
		if (strcmp(op, opcode) && strcmp(opcode, "???"))
		  matching = 0;
		if (!matching)
		  printf("Stopped due to instruction mismatch %s vs %s\n", op, opcode);
		if (oldpc != addr)
		  {
		    printf("Stopped due to PC mismatch %d vs %d\n", oldpc, addr);
		    matching = 0;
		  }
		    
	      }
	    cnt = sscanf(trace[3], "accu=%x", &accu);
	    if (cnt > 0)
	      {
		if (accu != top->accu && accu&1)
		  {
		    printf("ACCU mismatch %x vs %x\n", accu, top->accu);
		  }
	      }
	    cnt = sscanf(trace[4], " sp=0x%x @%d", &spaddr, &items);
	    if (cnt >= 2)
	      {
		if (items != vitems)
		  {
		    printf("SP mismatch %x vs %x\n", items, vitems);
		  }
	      }
	    else printf("Failed to parse SP: %s\n", trace[4]);
	    break;
	  case S_EXEC: printf(
            "%08llx %s pc=%06d rom=%4x op=%s imm=%x nvars=%08x offset=%08x acc=%08x SP=@%d\n",
            cycles,
	    statenam(top->state_out), 
            top->pc,
	    top->opcode_out,
            opname(top->opcode_out),
	    top->imm,
	    top->nvars,
	    top->offset,
            top->accu,
            vitems);
	    break;
	  case S_DONE:
	    printf("%08llx %s pc=%06d SP=@%d\n", cycles, statenam(top->state_out), top->pc, vitems);
	    break;
	  default:
	    printf("%08llx %s pc=%06d SP=@%d\n", cycles, statenam(top->state_out), top->pc, vitems);
	    break;
	  }
	
        top->clk = 1;
        top->eval();
        // OCVM_TRACE_FILE: the same history the board's vm_trace keeps, but all of it -- a 12-byte record
        // (24 bytes: state, opcode, pc, sp, accu 36 bits, env 36 bits, hp low 16 bits) whenever the state or pc changes
        const unsigned GCSTART = 0x36;  /* S_GC_START (state_rtl_complete.h) */
        static uint64_t records = 0, max_records = getenv("OCVM_MAX_RECORDS") ? strtoull(getenv("OCVM_MAX_RECORDS"), nullptr, 0) : 0;
        {
            static unsigned cs = ~0u, cp = ~0u;
            if (top->state_out != cs || top->dbg_pc != cp) { cs = top->state_out; cp = top->dbg_pc; records++; if (cs == 0x3F && getenv("OCVM_REPORT_GC")) std::cerr << "GC_DONE record " << records << "\n"; if (cs == GCSTART && getenv("OCVM_REPORT_GC")) std::cerr << "GC_START record " << records << "\n"; }
            if (max_records && records >= max_records) { std::cerr << "Stopped at record " << records << "\n"; break; }
        }
        static uint64_t trace_from = getenv("OCVM_TRACE_FROM") ? strtoull(getenv("OCVM_TRACE_FROM"), nullptr, 0) : 0;
        if (trace_out && records >= trace_from) {
            static unsigned last_state = ~0u, last_pc = ~0u;
            unsigned st = top->state_out, pcv = top->dbg_pc;
            if (st != last_state || pcv != last_pc) {
                uint64_t ac = top->dbg_accu, ev = top->dbg_env;
                unsigned hpv = top->dbg_hp;
                unsigned char r[24] = { (unsigned char)st, (unsigned char)top->opcode_out,
                    (unsigned char)pcv, (unsigned char)(pcv >> 8), (unsigned char)(pcv >> 16), 0,
                    (unsigned char)top->sp, (unsigned char)(top->sp >> 8), 0, 0, 0, 0,
                    (unsigned char)ac, (unsigned char)(ac >> 8), (unsigned char)(ac >> 16), (unsigned char)(ac >> 24), (unsigned char)(ac >> 32),
                    (unsigned char)ev, (unsigned char)(ev >> 8), (unsigned char)(ev >> 16), (unsigned char)(ev >> 24), (unsigned char)(ev >> 32),
                    (unsigned char)hpv, (unsigned char)(hpv >> 8) };
                fwrite(r, 1, 24, trace_out);
                last_state = st; last_pc = pcv;
            }
        }
        code_q = fetch_pc < sizeof(code_rom)/sizeof(*code_rom) ? code_rom[fetch_pc] : 0xDEADBEEF;
        code_q_pc = fetch_pc;

        if (top->halted) {
            std::cout << "HALT\n";
            break;
        }
        if (ethmodel_done()) {  // ethmin polls forever once the frames are used up
            std::cout << "HALT (device model done)\n";
            break;
        }

        if (++cycles > max_cycles) {
            std::cerr << "Timeout\n";
            break;
        }

	windup -= (!matching && !notrace);
    }

    if (disk_path && *disk_path) {
        FILE *f = fopen(disk_path, "wb");
        if (f) { fwrite(disk_ram, 1, disk_bytes, f); fclose(f); }
    }
    if (tfp) { tfp->close(); delete tfp; }
    top->final();
    delete top;
    return 0;
}
