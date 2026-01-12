#include "Vocaml4142_vm.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

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

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    if (argc < 2) {
        std::cerr << "usage: " << argv[0] << " program.bc\n";
        return 1;
    }

    caml_bytecode(argv[1]);

    auto* top = new Vocaml4142_vm;

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
    uint32_t oldpc = 0;
    
    while (!Verilated::gotFinish()) {
        // Provide instruction byte
        top->code_rdata = code_rom[top->code_addr];

        // Clock tick
        top->clk = 0;
        top->eval();

        tfp->dump(cycles);
        if (top->state_out == 0) oldpc = top->code_addr;

        // Trace like ocamlrun -dinstr
        if (top->state_out == 5) printf(
            "%08llx pc=%06d rom=%4x op=%s imm=%x nvars=%08x offset=%08x acc=%08x sp=%04x\n",
            cycles,
            oldpc,
	    code_rom[oldpc],
            opname(code_rom[oldpc] & 0xFF),
	    top->imm,
	    top->nvars,
	    top->offset,
            top->accu,
            top->sp
        );
	else if (0) printf("%08llx state=%x pc=%06d\n", cycles, top->state_out, top->code_addr);

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
