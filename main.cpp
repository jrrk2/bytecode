#include "Vocaml4142_vm.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
typedef enum
#include "state.h"

#include <fstream>
#include <iostream>

// ------------------------------------------------------------
// Bytecode ROM (owned by C++)
// ------------------------------------------------------------
uint32_t code_rom[1 << 20];

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

extern "C"
{
  void caml_bytecode(char *byte_name);
  char *opname(int ix);
  };

const char *statenam(int state)
{
  switch(state)
    {
    case S_FETCH      : return "S_FETCH      ";
    case S_DECIDE_IMM: return "S_DECIDE_IMM";
    case S_FETCH_IMM : return "S_FETCH_IMM ";
    case S_EXEC      : return "S_EXEC      ";

    // heap write micro-ops
    case S_HEAP_ALLOC_HDR: return "S_HEAP_ALLOC_HDR";
    case S_HEAP_ALLOC_FIELDS: return "S_HEAP_ALLOC_FIELDS";
    case S_CLOSURE_ALLOC_HDR: return "S_CLOSURE_ALLOC_HDR";
    case S_CLOSURE_WRITE_CODE: return "S_CLOSURE_WRITE_CODE";
    case S_CLOSURE_WRITE_CLOSINFO: return "S_CLOSURE_WRITE_CLOSINFO";
    case S_CLOSURE_WRITE_ENV: return "S_CLOSURE_WRITE_ENV";
    case S_CLOSURE_DONE: return "S_CLOSURE_DONE";			   
    case S_CLOSUREREC_CALC: return "S_CLOSUREREC_CALC";
    // trap / ccall
    case S_TRAP_WAIT: return "S_TRAP_WAIT";
    case S_DONE: return "S_DONE";
    default: return "S_UNKNOWN";
    }
}

typedef char linbuf[256];

linbuf trace[30];

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    if (argc < 3) {
        std::cerr << "usage: " << argv[0] << " program.bc trace_file\n";
        return 1;
    }

    caml_bytecode(argv[1]);
    auto* top = new Vocaml4142_vm;
    FILE *tracef = fopen(argv[2], "r");
    fgets(trace[0], sizeof(linbuf), tracef);
    
    // Optional waveform
    VerilatedVcdC* tfp = nullptr;
    Verilated::traceEverOn(true);
    tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("trace.vcd");

    // Reset
    top->reset = 1;
    for (int i = 0; i < 10; i++) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
    }
    top->reset = 0;

    uint64_t cycles = 0;
    const char *op;
    linbuf opcode;
    uint32_t addr, op1, cnt, oldpc, cycle,  oldcycle = 0;
    int matching = 1;
    
    while (matching && !Verilated::gotFinish()) {
        // Provide instruction byte
        top->code_rdata = code_rom[top->pc];
        // Clock tick
        top->clk = 0;
        top->eval();
        tfp->dump(cycles);
	
	switch(top->state_out)
	  {
	  case S_FETCH:
	    oldpc = top->pc;
	    op = opname(top->code_rdata);
	    printf("Fetch PC=%d ROM = 0x%x, instruction = %s\n", top->pc, top->code_rdata, op);
	    break;
	    // Trace like ocamlrun -dinstr
	  case S_EXEC: printf(
            "%08llx %s pc=%06d rom=%4x op=%s imm=%x nvars=%08x offset=%08x acc=%08x sp=%04x\n",
            cycles,
	    statenam(top->state_out), 
            top->pc,
	    top->opcode_out,
            opname(top->opcode_out),
	    top->imm,
	    top->nvars,
	    top->offset,
            top->accu,
            top->sp);
	    break;
	  case S_DONE:
	    printf("%08llx %s pc=%06d\n", cycles, statenam(top->state_out), top->pc);
	    cnt = 0;
	    do {
	      fgets(trace[cnt], sizeof(linbuf), tracef);
	      printf("Trace %s", trace[cnt]);
	    } while (cnt < sizeof(trace)/sizeof(*trace) && strlen(trace[cnt++]) > 1);
	    
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
		if (strcmp(op, opcode))
		  matching = 0;
		if (!matching)
		  printf("Stopped due to instruction mismatch %s vs %s\n", op, opcode);
		if (oldpc != addr)
		  {
		    printf("Stopped due to PC mismatch %d vs %d\n", oldpc, addr);
		    matching = 0;
		  }
		    
	      }
	    break;
	  default:
	    printf("%08llx %s pc=%06d\n", cycles, statenam(top->state_out), top->pc);
	    break;
	  }
	
        top->clk = 1;
        top->eval();

        if (top->halted) {
            std::cout << "HALT\n";
            break;
        }

        if (++cycles > 50'000'000) {
            std::cerr << "Timeout\n";
            break;
        }
    }

    tfp->close();
    delete tfp;
    delete top;
    return 0;
}
