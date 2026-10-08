#!/usr/bin/env python3
"""A Migen simulation of ddr_disk.DDRDisk against a model of a LiteDRAM native port: random word and byte-lane
reads and writes over a range several times the cache, checked against a dictionary, then a flush, and the DRAM
model's contents checked against the dictionary."""
import random, sys
sys.path.insert(0, ".")
from migen import *
from migen.sim import run_simulation
from litedram.common import LiteDRAMNativePort
from ddr_disk import DDRDisk

AW, DW, IDX = 6, 512, 2      # 64 lines of 64 bytes, a cache of 4 lines: conflicts everywhere
LAT = 6
DEBUG = len(sys.argv) > 1

class Top(Module):
    def __init__(self):
        self.port = LiteDRAMNativePort("both", AW, DW)
        self.submodules.dut = DDRDisk(self.port, index_bits=IDX)
        self.dut.port = self.port

dram = {}                                   # line -> int (512 bits)

def dram_model(port):
    pending = []                            # [countdown, data]
    yield port.cmd.ready.eq(1)
    yield port.wdata.ready.eq(1)
    while True:
        yield
        if (yield port.cmd.valid) and (yield port.cmd.ready):
            a = (yield port.cmd.addr)
            if (yield port.cmd.we):
                assert (yield port.wdata.valid), "write command without data"
                d = (yield port.wdata.data); m = (yield port.wdata.we)
                old = dram.get(a, 0)
                for b in range(DW // 8):
                    if (m >> b) & 1:
                        old = (old & ~(0xFF << 8 * b)) | (d & (0xFF << 8 * b))
                dram[a] = old
            else:
                pending.append([LAT, dram.get(a, 0)])
                if DEBUG: print('model: read line', a)
        if pending:
            pending[0][0] -= 1
            if pending[0][0] <= 0:
                if DEBUG: print('model: valid up')
                yield port.rdata.valid.eq(1)
                yield port.rdata.data.eq(pending[0][1])
                yield
                while not (yield port.rdata.ready):
                    if DEBUG: print('model: waiting for ready')
                    yield
                if DEBUG: print('model: ready seen')
                pending.pop(0)
                yield port.rdata.valid.eq(0)
        else:
            yield port.rdata.valid.eq(0)

def access(dut, addr, we, wdata=0, be=0xF):
    yield dut.addr.eq(addr); yield dut.we.eq(we); yield dut.wdata.eq(wdata); yield dut.be.eq(be)
    yield dut.req.eq(1)
    n = 0
    while True:
        yield
        if (yield dut.ack):
            r = (yield dut.rdata)
            break
        n += 1
        if n >= 500:
            print("stuck: state", (yield dut.fsm.state), "cmd.valid", (yield dut.port.cmd.valid) if hasattr(dut,"port") else "", "addr", hex(addr), "we", we)
        assert n < 500, "no ack"
    yield dut.req.eq(0)
    yield
    yield
    return r

def test(dut):
    random.seed(1)
    ref = {}
    nwords = (1 << AW) * (DW // 32)
    errors = 0
    for i in range(3000):
        a = random.randrange(nwords) if random.random() < 0.5 else random.randrange(64)
        if random.random() < 0.5:
            w = random.getrandbits(32); be = random.choice([0xF, 0xF, 0x1, 0x2, 0x4, 0x8, 0x3, 0xC])
            yield from access(dut, a, 1, w, be)
            old = ref.get(a, 0)
            for b in range(4):
                if (be >> b) & 1:
                    old = (old & ~(0xFF << 8 * b)) | (w & (0xFF << 8 * b))
            ref[a] = old
        else:
            r = yield from access(dut, a, 0)
            if r != ref.get(a, 0):
                errors += 1
                print("read %x: got %08x want %08x" % (a, r, ref.get(a, 0)))
    # flush, then the DRAM holds everything
    yield dut.flush.eq(1)
    n = 0
    while not (yield dut.flushed):
        yield; n += 1
        assert n < 5000, "flush never finished"
    yield dut.flush.eq(0)
    yield
    yield
    for a, v in ref.items():
        line, w = a >> 4, a & 15
        got = (dram.get(line, 0) >> (32 * w)) & 0xFFFFFFFF
        if got != v:
            errors += 1
            print("dram %x: got %08x want %08x" % (a, got, v))
    print("hits %d misses %d writebacks %d, %d errors" % ((yield dut.hits), (yield dut.misses), (yield dut.writebacks), errors))
    assert errors == 0
    print("PASS")

top = Top()
run_simulation(top, [test(top.dut), dram_model(top.port)])
