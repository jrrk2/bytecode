"""ddr_disk.py: the DDR3 as the bytecode machine's RAM disk.

The machine reaches its disk a word (or a byte of one) at a time and waits for each; DRAM wants 64-byte lines.
This is a direct-mapped write-back cache between them: 2^index_bits lines of 512 bits in block RAM, in front
of one LiteDRAM native port.  A word access that hits answers in two cycles; a miss writes the old line back if
it is dirty, reads the new one and answers (a few tens of cycles, once per line: a sequential file costs one miss
per 16 words).

The interface to the machine, level-sensitive (hold req until ack, then drop it):

  req    in   an access is wanted
  we     in   write (else read)
  addr   in   word index (byte address >> 2): 28 bits for 1 GiB
  wdata  in   the word to write, be (4 bits) the bytes of it to
  ack    out  done; rdata (valid with ack) is the word read
  flush  in   write every dirty line back to the DRAM; flushed (out) says it is done

With the CSR master (with_csr_master) the same signals are driven from registers, so the BIOS can use the disk and
the cache's counters can be read before the machine is wired to it.
"""
from math import log2
from migen import *
from litex.gen import *
from litex.soc.interconnect.csr import *


class DDRDisk(LiteXModule):
    def __init__(self, port, index_bits=9, with_csr_master=False):
        aw = port.address_width            # lines
        dw = port.data_width               # bits per line
        assert dw % 32 == 0
        wpl = dw // 32
        lw = int(log2(wpl))
        assert 1 << lw == wpl
        self.word_aw = aw + lw
        N = 1 << index_bits
        tag_w = aw - index_bits

        # the machine's side
        self.req     = req     = Signal()
        self.we      = we      = Signal()
        self.addr    = addr    = Signal(aw + lw)
        self.wdata   = wdata   = Signal(32)
        self.be      = be      = Signal(4)
        self.ack     = ack     = Signal()
        self.rdata   = rdata   = Signal(32)
        self.flush   = flush   = Signal()
        self.flushed = flushed = Signal()

        # statistics
        hits, misses, writebacks = Signal(32), Signal(32), Signal(32)

        # the cache: lines in one wide memory with a write enable per byte, {dirty, valid, tag} beside it
        data = Memory(dw, N)
        tags = Memory(tag_w + 2, N)
        dp = data.get_port(write_capable=True, we_granularity=8, mode=READ_FIRST)
        tp = tags.get_port(write_capable=True, mode=READ_FIRST)
        self.specials += data, tags, dp, tp

        req_index = addr[lw:lw + index_bits]
        req_tag   = addr[lw + index_bits:]
        word      = addr[:lw]

        fl_idx   = Signal(index_bits)
        flushing = Signal()
        cur_idx  = Signal(index_bits)
        self.comb += cur_idx.eq(Mux(flushing, fl_idx, req_index))
        self.comb += [dp.adr.eq(cur_idx), tp.adr.eq(cur_idx)]

        line_tag   = tp.dat_r[:tag_w]
        line_valid = tp.dat_r[tag_w]
        line_dirty = tp.dat_r[tag_w + 1]
        hit = Signal()
        self.comb += hit.eq(line_valid & (line_tag == req_tag))

        # the word of the line the access is to, and the write lanes of it
        rword = Signal(32)
        self.comb += Case(word, {i: rword.eq(dp.dat_r[32 * i:32 * i + 32]) for i in range(wpl)})
        wen = Signal(dw // 8)
        self.comb += Case(word, {i: wen.eq(be << (4 * i)) for i in range(wpl)})

        cmd_done  = Signal()
        data_done = Signal()
        wb_tag    = Signal(tag_w)          # the line being written back, as {tag, index}
        self.comb += wb_tag.eq(line_tag)

        self.fsm = fsm = FSM(reset_state="IDLE")
        fsm.act("IDLE",
            If(flush & ~flushing,
                NextValue(flushing, 1), NextValue(fl_idx, 0), NextState("FL_WAIT")
            ).Elif(req, NextState("CHECK")))
        fsm.act("CHECK",
            If(hit,
                NextValue(hits, hits + 1),
                NextValue(rdata, rword),
                If(we,
                    dp.we.eq(wen), dp.dat_w.eq(Replicate(wdata, wpl)),
                    tp.we.eq(1), tp.dat_w.eq(Cat(req_tag, 1, 1))),     # dirty, valid
                NextState("ACK")
            ).Else(
                NextValue(misses, misses + 1),
                NextValue(cmd_done, 0), NextValue(data_done, 0),
                If(line_valid & line_dirty, NextState("WRITEBACK")).Else(NextState("FILL"))))
        fsm.act("WRITEBACK",                # the old line is on dp.dat_r while the index is held
            port.cmd.valid.eq(~cmd_done),
            port.cmd.we.eq(1),
            port.cmd.addr.eq(Cat(cur_idx, wb_tag)),
            port.wdata.valid.eq(~data_done),
            port.wdata.data.eq(dp.dat_r),
            port.wdata.we.eq(2**(dw // 8) - 1),
            If(port.cmd.valid & port.cmd.ready, NextValue(cmd_done, 1)),
            If(port.wdata.valid & port.wdata.ready, NextValue(data_done, 1)),
            If((cmd_done | (port.cmd.valid & port.cmd.ready)) & (data_done | (port.wdata.valid & port.wdata.ready)),
                NextValue(writebacks, writebacks + 1),
                If(flushing,
                    tp.we.eq(1), tp.dat_w.eq(Cat(wb_tag, 1, 0)),       # still valid, clean
                    NextValue(fl_idx, fl_idx + 1),
                    NextState("FL_NEXT")
                ).Else(NextValue(cmd_done, 0), NextState("FILL"))))
        fsm.act("FILL",
            port.cmd.valid.eq(~cmd_done),
            port.cmd.we.eq(0),
            port.cmd.addr.eq(Cat(cur_idx, req_tag)),
            If(port.cmd.valid & port.cmd.ready, NextValue(cmd_done, 1)),
            If(cmd_done | (port.cmd.valid & port.cmd.ready), NextState("FILL_WAIT")))
        fsm.act("FILL_WAIT",
            port.rdata.ready.eq(1),
            If(port.rdata.valid,
                dp.we.eq(2**(dw // 8) - 1), dp.dat_w.eq(port.rdata.data),
                tp.we.eq(1), tp.dat_w.eq(Cat(req_tag, 1, 0)),          # valid, clean
                NextState("REREAD")))
        fsm.act("REREAD", NextState("CHECK"))      # the memories read what was written one cycle on
        fsm.act("ACK",
            ack.eq(1),
            If(~req, NextState("IDLE")))

        # flushing: each index in turn; a dirty line goes to the DRAM
        fsm.act("FL_WAIT", NextState("FL_CHECK"))                       # the read of fl_idx
        fsm.act("FL_CHECK",
            If(line_valid & line_dirty,
                NextValue(cmd_done, 0), NextValue(data_done, 0), NextState("WRITEBACK")
            ).Else(NextValue(fl_idx, fl_idx + 1), NextState("FL_NEXT")))
        fsm.act("FL_NEXT",
            If(fl_idx == 0,                                              # wrapped: all done
                NextValue(flushing, 0), flushed.eq(1), NextState("FL_DONE")
            ).Else(NextState("FL_WAIT")))
        fsm.act("FL_DONE", flushed.eq(1), If(~flush, NextState("IDLE")))

        # counters out
        self.hits, self.misses, self.writebacks = hits, misses, writebacks

        if with_csr_master:
            self.c_addr   = CSRStorage(aw + lw, description="word index")
            self.c_wdata  = CSRStorage(32)
            self.c_be     = CSRStorage(4, reset=0xF)
            self.c_go     = CSRStorage(2, description="write: bit0 = write (else read), bit1 = go (rises to start)")
            self.c_rdata  = CSRStatus(32)
            self.c_status = CSRStatus(4, description="bit0 busy, bit1 flushed")
            self.c_flush  = CSRStorage(1)
            self.c_hits   = CSRStatus(32)
            self.c_misses = CSRStatus(32)
            self.c_wbs    = CSRStatus(32)
            busy = Signal()
            self.sync += [
                If(self.c_go.re & self.c_go.storage[1], busy.eq(1)),
                If(ack & busy, busy.eq(0), self.c_rdata.status.eq(rdata)),
            ]
            self.comb += [
                req.eq(busy), we.eq(self.c_go.storage[0]), addr.eq(self.c_addr.storage),
                wdata.eq(self.c_wdata.storage), be.eq(self.c_be.storage),
                flush.eq(self.c_flush.storage),
                self.c_status.status.eq(Cat(busy, flushed)),
                self.c_hits.status.eq(hits), self.c_misses.status.eq(misses), self.c_wbs.status.eq(writebacks),
            ]
