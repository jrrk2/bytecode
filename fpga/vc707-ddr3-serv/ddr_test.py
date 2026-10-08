"""ddr_test.py: write a pattern over the whole DDR3, read it back, count the differences.

A bus master of its own on two LiteDRAM native ports (one write, one read), beside the SERV's: it moves a 64-byte
line (the controller's data width, 512 bits for a 64-bit 4:1 PHY) per cycle at best, so a gigabyte is a couple of
seconds rather than the hours a CPU memtest through the BIOS takes.  The pattern is a function of the line's
address alone (a multiplicative hash, rotated a different amount in each of the 16 words), so aliasing
(an address bit stuck or shorted), a data bit stuck, and lines landing in the wrong place all show up.

Registers (CSRs, base from csr.csv):
  start      write 1: begin (the write pass, then the read pass)
  limit      lines to test from 0; reads 0 -> the whole memory (written 0 for all)
  status     bit0 done, bit1 running, bit2 write pass, bit3 read pass
  errors     lines read back wrong
  first_err  address of the first of them (line number, 64 bytes each)
  lines      lines in the memory (a constant)
  cycles_w, cycles_r   system-clock cycles spent in each pass, for the throughput
"""
from migen import *
from litex.gen import *
from litex.soc.interconnect.csr import *
from litex.soc.interconnect import stream
from litedram.frontend.dma import LiteDRAMDMAWriter, LiteDRAMDMAReader




class DDRTest(LiteXModule):
    def __init__(self, wport, rport):
        aw = wport.address_width
        dw = wport.data_width
        assert dw % 32 == 0
        nwords = dw // 32
        self.lines = lines = 1 << aw

        self.start     = CSR()
        self.limit     = CSRStorage(aw + 1, description="lines to test (0: all)")
        self.status    = CSRStatus(4)
        self.errors    = CSRStatus(32)
        self.first_err = CSRStatus(aw)
        self.nlines    = CSRStatus(aw + 1, reset=lines)
        self.cycles_w  = CSRStatus(32)
        self.cycles_r  = CSRStatus(32)

        writer = LiteDRAMDMAWriter(wport, fifo_depth=32)
        reader = LiteDRAMDMAReader(rport, fifo_depth=32)
        self.submodules += writer, reader

        wr_addr  = Signal(aw + 1)
        rd_addr  = Signal(aw + 1)
        chk_addr = Signal(aw + 1)
        total    = Signal(aw + 1)
        errors   = Signal(32)
        first    = Signal(aw)
        seen     = Signal()
        cyc_w    = Signal(32)
        cyc_r    = Signal(32)
        wait     = Signal(10)

        def line_for(a):
            """the data of line a"""
            base = Signal(32)
            self.comb += base.eq((a[:aw] * 0x9E3779B1)[:32] ^ 0x5EED1234)
            words = []
            for k in range(nwords):
                r = (2 * k) % 32
                rot = Cat(base[32 - r:], base[:32 - r]) if r else base
                words.append(rot ^ ((k * 0x045D9F3B) & 0xFFFFFFFF))
            return Cat(*words)

        wdata = Signal(dw)
        rdata = Signal(dw)
        self.comb += [wdata.eq(line_for(wr_addr)), rdata.eq(line_for(chk_addr))]

        self.comb += [
            self.errors.status.eq(errors),
            self.first_err.status.eq(first),
            self.cycles_w.status.eq(cyc_w),
            self.cycles_r.status.eq(cyc_r),
        ]

        done = Signal()
        self.fsm = fsm = FSM(reset_state="IDLE")
        fsm.act("IDLE",
            self.status.status.eq(Cat(done, 0, 0, 0)),
            If(self.start.re,
                NextValue(wr_addr, 0), NextValue(rd_addr, 0), NextValue(chk_addr, 0),
                NextValue(errors, 0), NextValue(seen, 0), NextValue(first, 0),
                NextValue(cyc_w, 0), NextValue(cyc_r, 0), NextValue(done, 0),
                NextValue(total, Mux(self.limit.storage == 0, lines, self.limit.storage)),
                NextState("WRITE")))
        fsm.act("WRITE",
            self.status.status.eq(0b0110),
            writer.sink.valid.eq(1),
            writer.sink.address.eq(wr_addr[:aw]),
            writer.sink.data.eq(wdata),
            NextValue(cyc_w, cyc_w + 1),
            If(writer.sink.ready,
                NextValue(wr_addr, wr_addr + 1),
                If(wr_addr + 1 == total, NextValue(wait, 0), NextState("DRAIN"))))
        fsm.act("DRAIN",                       # the writer's FIFO and the controller's queues empty before the first read
            self.status.status.eq(0b0110),
            NextValue(cyc_w, cyc_w + 1),
            NextValue(wait, wait + 1),
            If(wait == 1023, NextState("READ")))
        fsm.act("READ",
            self.status.status.eq(0b1010),
            NextValue(cyc_r, cyc_r + 1),
            reader.sink.valid.eq(rd_addr != total),
            reader.sink.address.eq(rd_addr[:aw]),
            If(reader.sink.valid & reader.sink.ready, NextValue(rd_addr, rd_addr + 1)),
            reader.source.ready.eq(1),
            If(reader.source.valid,
                NextValue(chk_addr, chk_addr + 1),
                If(reader.source.data != rdata,
                    NextValue(errors, errors + 1),
                    If(~seen, NextValue(seen, 1), NextValue(first, chk_addr[:aw]))),
                If(chk_addr + 1 == total, NextValue(done, 1), NextState("IDLE"))))
