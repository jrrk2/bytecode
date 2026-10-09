// Verilator harness for intcode_core: the INTCODE machine in RTL running a program as bcplkit's icint does.
//   tb_intcode prog.int [max_clocks]        stdin and stdout are the program's, as with icint
// The loader is icint.c's assembler (the .int file is INTCODE assembly), run on the host to fill the store; the core then starts with C, P
// and G as icint leaves them.  The store is a synchronous RAM here (read data the cycle after the request); the stream operations
// (X24..29, 33, 34, 38, 39) are served by the kit's own blib.c, so a program sees exactly what it sees under icint.  It prints the same
// banner and the same "EXECUTION CYCLES" (instructions executed) as icint, so a diff of the two outputs is a check of the RTL, and it
// reports the clocks the RTL took.
#include "Vintcode_core.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>

extern "C" {
int *M; int G, P, A, B, C, D, W;           // blib.c's registers and store
int getbyte(int, int); void putbyte(int, int, int);
void initio(void); int findinput(int); int findoutput(int);
void selectinput(int); void selectoutput(int);
int input(void); int output(void); int rdch(void); void wrch(int); void endread(void); void endwrite(void);
}

#define MGLOB 1
#define MPROG 402
#define FSHIFT 13
#define IBIT 010000
#define PBIT 04000
#define GBIT 02000
#define DBIT 01000
#define ABITS 0777
#define WORDSIZE 32
#define BYTESIZE 8
#define LIG1 0012001
#define K2 0140002
#define X22 0160026
#define STORE 65536

static FILE *fp;
static int Ch, Cp;
static int Labv[501];

static void stw(int w) { M[P++] = w; Cp = 0; }
static void stc(int c) { if (Cp == 0) { stw(0); Cp = WORDSIZE; } Cp -= BYTESIZE; M[P - 1] += c << Cp; }
static void rch(void) { for (;;) { Ch = fgetc(fp); if (Ch != '/') return; do Ch = fgetc(fp); while (Ch != '\n'); } }
static int rdn(void) { int a = 0, b = 0; if (Ch == '-') { b = 1; rch(); } while ('0' <= Ch && Ch <= '9') { a = 10 * a + Ch - '0'; rch(); } return b ? -a : a; }
static void setlab(int n) {
    int k = Labv[n];
    if (k < 0) printf("L%d ALREADY SET TO %d AT P = %d\n", n, -k, P);
    while (k > 0) { int m = M[k]; M[k] = P; k = m; }
    Labv[n] = -P;
}
static void labref(int n, int a) { int k = Labv[n]; if (k < 0) k = -k; else Labv[n] = a; M[a] += k; }

static void assemble(void) {      // icint.c's assembler, unchanged in effect
    int f = 0;
clear:
    for (int i = 0; i <= 500; i++) Labv[i] = 0;
    Cp = 0;
next:
    rch();
sw:
    switch (Ch) {
    default: if (Ch == EOF) return; printf("\nBAD CH %c AT P = %d\n", Ch, P); goto next;
    case '0': case '1': case '2': case '3': case '4': case '5': case '6': case '7': case '8': case '9':
        setlab(rdn()); Cp = 0; goto sw;
    case '$': case ' ': case '\n': goto next;
    case 'L': f = 0; break;  case 'S': f = 1; break;  case 'A': f = 2; break;  case 'J': f = 3; break;
    case 'T': f = 4; break;  case 'F': f = 5; break;  case 'K': f = 6; break;  case 'X': f = 7; break;
    case 'C': rch(); stc(rdn()); goto sw;
    case 'D': rch();
        if (Ch == 'L') { rch(); stw(0); labref(rdn(), P - 1); } else stw(rdn());
        goto sw;
    case 'G': rch(); A = rdn() + G;
        if (Ch == 'L') rch(); else printf("\nBAD CODE AT P = %d\n", P);
        M[A] = 0; labref(rdn(), A); goto sw;
    case 'Z': for (int i = 0; i <= 500; i++) if (Labv[i] > 0) printf("L%d UNSET\n", i);
        goto clear;
    }
    W = f << FSHIFT;
    rch();
    if (Ch == 'I') { W += IBIT; rch(); }
    if (Ch == 'P') { W += PBIT; rch(); }
    if (Ch == 'G') { W += GBIT; rch(); }
    if (Ch == 'L') { rch(); stw(W + DBIT); stw(0); labref(rdn(), P - 1); }
    else { int a = rdn(); if ((a & ABITS) == a) stw(W + a); else { stw(W + DBIT); stw(a); } }
    goto sw;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: tb_intcode file.int [max_clocks]\n"); return 1; }
    uint64_t max_clocks = argc > 2 ? strtoull(argv[2], nullptr, 0) : 4000000000ULL;
    fp = fopen(argv[1], "r");
    if (!fp) { fprintf(stderr, "%s: Can't open\n", argv[1]); return 0; }
    M = (int *)calloc(STORE, sizeof(int));
    G = MGLOB; P = MPROG;
    M[P++] = LIG1; M[P++] = K2; M[P++] = X22;
    initio();
    printf("INTCODE SYSTEM ENTERED\n");
    assemble();
    fclose(fp);
    printf("\nPROGRAM SIZE = %d\n", P - MPROG);
    if (const char *dump = getenv("INTCODE_DUMP")) {          // the loaded store as a $readmemh file, and the registers the loader leaves
        char path[512];
        snprintf(path, sizeof path, "%s/image.hex", dump);
        FILE *f = fopen(path, "w");
        for (int i = 0; i < 32768; i++) fprintf(f, "%08x\n", (unsigned)M[i]);
        fclose(f);
        snprintf(path, sizeof path, "%s/image.vh", dump);
        f = fopen(path, "w");
        fprintf(f, "`define INIT_C %d\n`define INIT_P %d\n`define INIT_G %d\n", MPROG, P, G);
        fclose(f);
        fprintf(stderr, "store image dumped to %s\n", dump);
        return 0;
    }

    Vintcode_core *top = new Vintcode_core;
    top->rst = 1;
    top->init_c = MPROG; top->init_p = P; top->init_g = G;
    top->m_rdata = 0; top->io_ack = 0; top->io_res = 0; top->clk = 0;
    for (int i = 0; i < 4; i++) { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }
    top->rst = 0; top->clk = 0; top->eval();

    uint64_t clocks = 0, instrs = 0;
    uint32_t rdata = 0, ack = 0, res = 0;
    while (!top->halted && clocks < max_clocks) {
        // outputs of the cycle about to end
        int re = top->m_re, we = top->m_we, req = top->io_req;
        uint32_t addr = top->m_addr, wdata = (uint32_t)top->m_wdata, op = top->io_op, ioa = (uint32_t)top->io_a;
        if (top->instr_done) instrs++;
        top->clk = 1; top->eval();
        clocks++;
        // what the outside world does at that edge: the RAM, and the streams
        if (we) M[addr] = (int)wdata;
        if (re) rdata = (uint32_t)M[addr];
        ack = 0;
        if (req) {
            A = (int)ioa;
            switch (op) {
            case 24: selectinput(A); break;
            case 25: selectoutput(A); break;
            case 26: res = (uint32_t)rdch(); break;
            case 27: wrch(A); break;
            case 28: res = (uint32_t)findinput(A); break;
            case 29: res = (uint32_t)findoutput(A); break;
            case 33: endread(); break;
            case 34: endwrite(); break;
            case 38: res = (uint32_t)input(); break;
            case 39: res = (uint32_t)output(); break;
            }
            ack = 1;
        }
        top->m_rdata = rdata; top->io_ack = ack; top->io_res = res;
        top->clk = 0; top->eval();
    }
    if (top->instr_done) instrs++;
    int code = (int)top->result;
    if (!top->halted) { fprintf(stderr, "\nstopped after %llu clocks\n", (unsigned long long)clocks); }
    printf("\nEXECUTION CYCLES = %llu, CODE = %d\n", (unsigned long long)instrs, code);
    fflush(stdout);
    fprintf(stderr, "RTL: %llu clocks, %llu instructions, %.2f clocks per instruction\n",
            (unsigned long long)clocks, (unsigned long long)instrs, instrs ? (double)clocks / instrs : 0.0);
    delete top;
    return code;
}
