// Extracted from Rocket's generated Verilog by tools/extract_modules.py.
// These are Berkeley HardFloat cores (BSD), as Chisel emitted them.

module MulAddRecFNToRaw_preMul_1(
  input  [1:0]   io_op,
  input  [64:0]  io_a,
  input  [64:0]  io_b,
  input  [64:0]  io_c,
  output [52:0]  io_mulAddA,
  output [52:0]  io_mulAddB,
  output [105:0] io_mulAddC,
  output         io_toPostMul_isSigNaNAny,
  output         io_toPostMul_isNaNAOrB,
  output         io_toPostMul_isInfA,
  output         io_toPostMul_isZeroA,
  output         io_toPostMul_isInfB,
  output         io_toPostMul_isZeroB,
  output         io_toPostMul_signProd,
  output         io_toPostMul_isNaNC,
  output         io_toPostMul_isInfC,
  output         io_toPostMul_isZeroC,
  output [12:0]  io_toPostMul_sExpSum,
  output         io_toPostMul_doSubMags,
  output         io_toPostMul_CIsDominant,
  output [5:0]   io_toPostMul_CDom_CAlignDist,
  output [54:0]  io_toPostMul_highAlignedSigC,
  output         io_toPostMul_bit0AlignedSigC
);
  wire [11:0] rawA_exp = io_a[63:52]; // @[rawFloatFromRecFN.scala 51:21]
  wire  rawA_isZero = rawA_exp[11:9] == 3'h0; // @[rawFloatFromRecFN.scala 52:53]
  wire  rawA_isSpecial = rawA_exp[11:10] == 2'h3; // @[rawFloatFromRecFN.scala 53:53]
  wire  rawA__isNaN = rawA_isSpecial & rawA_exp[9]; // @[rawFloatFromRecFN.scala 56:33]
  wire  rawA__sign = io_a[64]; // @[rawFloatFromRecFN.scala 59:25]
  wire [12:0] rawA__sExp = {1'b0,$signed(rawA_exp)}; // @[rawFloatFromRecFN.scala 60:27]
  wire  _rawA_out_sig_T = ~rawA_isZero; // @[rawFloatFromRecFN.scala 61:35]
  wire [53:0] rawA__sig = {1'h0,_rawA_out_sig_T,io_a[51:0]}; // @[rawFloatFromRecFN.scala 61:44]
  wire [11:0] rawB_exp = io_b[63:52]; // @[rawFloatFromRecFN.scala 51:21]
  wire  rawB_isZero = rawB_exp[11:9] == 3'h0; // @[rawFloatFromRecFN.scala 52:53]
  wire  rawB_isSpecial = rawB_exp[11:10] == 2'h3; // @[rawFloatFromRecFN.scala 53:53]
  wire  rawB__isNaN = rawB_isSpecial & rawB_exp[9]; // @[rawFloatFromRecFN.scala 56:33]
  wire  rawB__sign = io_b[64]; // @[rawFloatFromRecFN.scala 59:25]
  wire [12:0] rawB__sExp = {1'b0,$signed(rawB_exp)}; // @[rawFloatFromRecFN.scala 60:27]
  wire  _rawB_out_sig_T = ~rawB_isZero; // @[rawFloatFromRecFN.scala 61:35]
  wire [53:0] rawB__sig = {1'h0,_rawB_out_sig_T,io_b[51:0]}; // @[rawFloatFromRecFN.scala 61:44]
  wire [11:0] rawC_exp = io_c[63:52]; // @[rawFloatFromRecFN.scala 51:21]
  wire  rawC_isZero = rawC_exp[11:9] == 3'h0; // @[rawFloatFromRecFN.scala 52:53]
  wire  rawC_isSpecial = rawC_exp[11:10] == 2'h3; // @[rawFloatFromRecFN.scala 53:53]
  wire  rawC__isNaN = rawC_isSpecial & rawC_exp[9]; // @[rawFloatFromRecFN.scala 56:33]
  wire  rawC__sign = io_c[64]; // @[rawFloatFromRecFN.scala 59:25]
  wire [12:0] rawC__sExp = {1'b0,$signed(rawC_exp)}; // @[rawFloatFromRecFN.scala 60:27]
  wire  _rawC_out_sig_T = ~rawC_isZero; // @[rawFloatFromRecFN.scala 61:35]
  wire [53:0] rawC__sig = {1'h0,_rawC_out_sig_T,io_c[51:0]}; // @[rawFloatFromRecFN.scala 61:44]
  wire  signProd = rawA__sign ^ rawB__sign ^ io_op[1]; // @[MulAddRecFN.scala 96:42]
  wire [13:0] _sExpAlignedProd_T = $signed(rawA__sExp) + $signed(rawB__sExp); // @[MulAddRecFN.scala 99:19]
  wire [13:0] sExpAlignedProd = $signed(_sExpAlignedProd_T) - 14'sh7c8; // @[MulAddRecFN.scala 99:32]
  wire  doSubMags = signProd ^ rawC__sign ^ io_op[0]; // @[MulAddRecFN.scala 101:42]
  wire [13:0] _GEN_0 = {{1{rawC__sExp[12]}},rawC__sExp}; // @[MulAddRecFN.scala 105:42]
  wire [13:0] sNatCAlignDist = $signed(sExpAlignedProd) - $signed(_GEN_0); // @[MulAddRecFN.scala 105:42]
  wire [12:0] posNatCAlignDist = sNatCAlignDist[12:0]; // @[MulAddRecFN.scala 106:42]
  wire  isMinCAlign = rawA_isZero | rawB_isZero | $signed(sNatCAlignDist) < 14'sh0; // @[MulAddRecFN.scala 107:50]
  wire  CIsDominant = _rawC_out_sig_T & (isMinCAlign | posNatCAlignDist <= 13'h35); // @[MulAddRecFN.scala 109:23]
  wire [7:0] _CAlignDist_T_2 = posNatCAlignDist < 13'ha1 ? posNatCAlignDist[7:0] : 8'ha1; // @[MulAddRecFN.scala 113:16]
  wire [7:0] CAlignDist = isMinCAlign ? 8'h0 : _CAlignDist_T_2; // @[MulAddRecFN.scala 111:12]
  wire [53:0] _mainAlignedSigC_T = ~rawC__sig; // @[MulAddRecFN.scala 119:25]
  wire [53:0] _mainAlignedSigC_T_1 = doSubMags ? _mainAlignedSigC_T : rawC__sig; // @[MulAddRecFN.scala 119:13]
  wire [110:0] _mainAlignedSigC_T_3 = doSubMags ? 111'h7fffffffffffffffffffffffffff : 111'h0; // @[Bitwise.scala 77:12]
  wire [164:0] _mainAlignedSigC_T_5 = {_mainAlignedSigC_T_1,_mainAlignedSigC_T_3}; // @[MulAddRecFN.scala 119:94]
  wire [164:0] mainAlignedSigC = $signed(_mainAlignedSigC_T_5) >>> CAlignDist; // @[MulAddRecFN.scala 119:100]
  wire  reduced4CExtra_reducedVec_0 = |rawC__sig[3:0]; // @[primitives.scala 120:54]
  wire  reduced4CExtra_reducedVec_1 = |rawC__sig[7:4]; // @[primitives.scala 120:54]
  wire  reduced4CExtra_reducedVec_2 = |rawC__sig[11:8]; // @[primitives.scala 120:54]
  wire  reduced4CExtra_reducedVec_3 = |rawC__sig[15:12]; // @[primitives.scala 120:54]
  wire  reduced4CExtra_reducedVec_4 = |rawC__sig[19:16]; // @[primitives.scala 120:54]
  wire  reduced4CExtra_reducedVec_5 = |rawC__sig[23:20]; // @[primitives.scala 120:54]
  wire  reduced4CExtra_reducedVec_6 = |rawC__sig[27:24]; // @[primitives.scala 120:54]
  wire  reduced4CExtra_reducedVec_7 = |rawC__sig[31:28]; // @[primitives.scala 120:54]
  wire  reduced4CExtra_reducedVec_8 = |rawC__sig[35:32]; // @[primitives.scala 120:54]
  wire  reduced4CExtra_reducedVec_9 = |rawC__sig[39:36]; // @[primitives.scala 120:54]
  wire  reduced4CExtra_reducedVec_10 = |rawC__sig[43:40]; // @[primitives.scala 120:54]
  wire  reduced4CExtra_reducedVec_11 = |rawC__sig[47:44]; // @[primitives.scala 120:54]
  wire  reduced4CExtra_reducedVec_12 = |rawC__sig[51:48]; // @[primitives.scala 120:54]
  wire  reduced4CExtra_reducedVec_13 = |rawC__sig[53:52]; // @[primitives.scala 123:57]
  wire [6:0] reduced4CExtra_lo = {reduced4CExtra_reducedVec_6,reduced4CExtra_reducedVec_5,reduced4CExtra_reducedVec_4,
    reduced4CExtra_reducedVec_3,reduced4CExtra_reducedVec_2,reduced4CExtra_reducedVec_1,reduced4CExtra_reducedVec_0}; // @[primitives.scala 124:20]
  wire [13:0] _reduced4CExtra_T_1 = {reduced4CExtra_reducedVec_13,reduced4CExtra_reducedVec_12,
    reduced4CExtra_reducedVec_11,reduced4CExtra_reducedVec_10,reduced4CExtra_reducedVec_9,reduced4CExtra_reducedVec_8,
    reduced4CExtra_reducedVec_7,reduced4CExtra_lo}; // @[primitives.scala 124:20]
  wire [64:0] reduced4CExtra_shift = 65'sh10000000000000000 >>> CAlignDist[7:2]; // @[primitives.scala 76:56]
  wire [7:0] _GEN_1 = {{4'd0}, reduced4CExtra_shift[31:28]}; // @[Bitwise.scala 108:31]
  wire [7:0] _reduced4CExtra_T_8 = _GEN_1 & 8'hf; // @[Bitwise.scala 108:31]
  wire [7:0] _reduced4CExtra_T_10 = {reduced4CExtra_shift[27:24], 4'h0}; // @[Bitwise.scala 108:70]
  wire [7:0] _reduced4CExtra_T_12 = _reduced4CExtra_T_10 & 8'hf0; // @[Bitwise.scala 108:80]
  wire [7:0] _reduced4CExtra_T_13 = _reduced4CExtra_T_8 | _reduced4CExtra_T_12; // @[Bitwise.scala 108:39]
  wire [7:0] _GEN_2 = {{2'd0}, _reduced4CExtra_T_13[7:2]}; // @[Bitwise.scala 108:31]
  wire [7:0] _reduced4CExtra_T_18 = _GEN_2 & 8'h33; // @[Bitwise.scala 108:31]
  wire [7:0] _reduced4CExtra_T_20 = {_reduced4CExtra_T_13[5:0], 2'h0}; // @[Bitwise.scala 108:70]
  wire [7:0] _reduced4CExtra_T_22 = _reduced4CExtra_T_20 & 8'hcc; // @[Bitwise.scala 108:80]
  wire [7:0] _reduced4CExtra_T_23 = _reduced4CExtra_T_18 | _reduced4CExtra_T_22; // @[Bitwise.scala 108:39]
  wire [7:0] _GEN_3 = {{1'd0}, _reduced4CExtra_T_23[7:1]}; // @[Bitwise.scala 108:31]
  wire [7:0] _reduced4CExtra_T_28 = _GEN_3 & 8'h55; // @[Bitwise.scala 108:31]
  wire [7:0] _reduced4CExtra_T_30 = {_reduced4CExtra_T_23[6:0], 1'h0}; // @[Bitwise.scala 108:70]
  wire [7:0] _reduced4CExtra_T_32 = _reduced4CExtra_T_30 & 8'haa; // @[Bitwise.scala 108:80]
  wire [7:0] _reduced4CExtra_T_33 = _reduced4CExtra_T_28 | _reduced4CExtra_T_32; // @[Bitwise.scala 108:39]
  wire [12:0] _reduced4CExtra_T_47 = {_reduced4CExtra_T_33,reduced4CExtra_shift[32],reduced4CExtra_shift[33],
    reduced4CExtra_shift[34],reduced4CExtra_shift[35],reduced4CExtra_shift[36]}; // @[Cat.scala 33:92]
  wire [13:0] _GEN_4 = {{1'd0}, _reduced4CExtra_T_47}; // @[MulAddRecFN.scala 121:68]
  wire [13:0] _reduced4CExtra_T_48 = _reduced4CExtra_T_1 & _GEN_4; // @[MulAddRecFN.scala 121:68]
  wire  reduced4CExtra = |_reduced4CExtra_T_48; // @[MulAddRecFN.scala 129:11]
  wire  _alignedSigC_T_4 = &mainAlignedSigC[2:0] & ~reduced4CExtra; // @[MulAddRecFN.scala 133:44]
  wire  _alignedSigC_T_7 = |mainAlignedSigC[2:0] | reduced4CExtra; // @[MulAddRecFN.scala 134:44]
  wire  _alignedSigC_T_8 = doSubMags ? _alignedSigC_T_4 : _alignedSigC_T_7; // @[MulAddRecFN.scala 132:16]
  wire [161:0] alignedSigC_hi = mainAlignedSigC[164:3]; // @[Cat.scala 33:92]
  wire [162:0] alignedSigC = {alignedSigC_hi,_alignedSigC_T_8}; // @[Cat.scala 33:92]
  wire  _io_toPostMul_isSigNaNAny_T_2 = rawA__isNaN & ~rawA__sig[51]; // @[common.scala 82:46]
  wire  _io_toPostMul_isSigNaNAny_T_5 = rawB__isNaN & ~rawB__sig[51]; // @[common.scala 82:46]
  wire  _io_toPostMul_isSigNaNAny_T_9 = rawC__isNaN & ~rawC__sig[51]; // @[common.scala 82:46]
  wire [13:0] _io_toPostMul_sExpSum_T_2 = $signed(sExpAlignedProd) - 14'sh35; // @[MulAddRecFN.scala 157:53]
  wire [13:0] _io_toPostMul_sExpSum_T_3 = CIsDominant ? $signed({{1{rawC__sExp[12]}},rawC__sExp}) : $signed(
    _io_toPostMul_sExpSum_T_2); // @[MulAddRecFN.scala 157:12]
  assign io_mulAddA = rawA__sig[52:0]; // @[MulAddRecFN.scala 140:16]
  assign io_mulAddB = rawB__sig[52:0]; // @[MulAddRecFN.scala 141:16]
  assign io_mulAddC = alignedSigC[106:1]; // @[MulAddRecFN.scala 142:30]
  assign io_toPostMul_isSigNaNAny = _io_toPostMul_isSigNaNAny_T_2 | _io_toPostMul_isSigNaNAny_T_5 |
    _io_toPostMul_isSigNaNAny_T_9; // @[MulAddRecFN.scala 145:58]
  assign io_toPostMul_isNaNAOrB = rawA__isNaN | rawB__isNaN; // @[MulAddRecFN.scala 147:42]
  assign io_toPostMul_isInfA = rawA_isSpecial & ~rawA_exp[9]; // @[rawFloatFromRecFN.scala 57:33]
  assign io_toPostMul_isZeroA = rawA_exp[11:9] == 3'h0; // @[rawFloatFromRecFN.scala 52:53]
  assign io_toPostMul_isInfB = rawB_isSpecial & ~rawB_exp[9]; // @[rawFloatFromRecFN.scala 57:33]
  assign io_toPostMul_isZeroB = rawB_exp[11:9] == 3'h0; // @[rawFloatFromRecFN.scala 52:53]
  assign io_toPostMul_signProd = rawA__sign ^ rawB__sign ^ io_op[1]; // @[MulAddRecFN.scala 96:42]
  assign io_toPostMul_isNaNC = rawC_isSpecial & rawC_exp[9]; // @[rawFloatFromRecFN.scala 56:33]
  assign io_toPostMul_isInfC = rawC_isSpecial & ~rawC_exp[9]; // @[rawFloatFromRecFN.scala 57:33]
  assign io_toPostMul_isZeroC = rawC_exp[11:9] == 3'h0; // @[rawFloatFromRecFN.scala 52:53]
  assign io_toPostMul_sExpSum = _io_toPostMul_sExpSum_T_3[12:0]; // @[MulAddRecFN.scala 156:28]
  assign io_toPostMul_doSubMags = signProd ^ rawC__sign ^ io_op[0]; // @[MulAddRecFN.scala 101:42]
  assign io_toPostMul_CIsDominant = _rawC_out_sig_T & (isMinCAlign | posNatCAlignDist <= 13'h35); // @[MulAddRecFN.scala 109:23]
  assign io_toPostMul_CDom_CAlignDist = CAlignDist[5:0]; // @[MulAddRecFN.scala 160:47]
  assign io_toPostMul_highAlignedSigC = alignedSigC[161:107]; // @[MulAddRecFN.scala 162:20]
  assign io_toPostMul_bit0AlignedSigC = alignedSigC[0]; // @[MulAddRecFN.scala 163:48]
endmodule

module MulAddRecFNToRaw_postMul_1(
  input          io_fromPreMul_isSigNaNAny,
  input          io_fromPreMul_isNaNAOrB,
  input          io_fromPreMul_isInfA,
  input          io_fromPreMul_isZeroA,
  input          io_fromPreMul_isInfB,
  input          io_fromPreMul_isZeroB,
  input          io_fromPreMul_signProd,
  input          io_fromPreMul_isNaNC,
  input          io_fromPreMul_isInfC,
  input          io_fromPreMul_isZeroC,
  input  [12:0]  io_fromPreMul_sExpSum,
  input          io_fromPreMul_doSubMags,
  input          io_fromPreMul_CIsDominant,
  input  [5:0]   io_fromPreMul_CDom_CAlignDist,
  input  [54:0]  io_fromPreMul_highAlignedSigC,
  input          io_fromPreMul_bit0AlignedSigC,
  input  [106:0] io_mulAddResult,
  input  [2:0]   io_roundingMode,
  output         io_invalidExc,
  output         io_rawOut_isNaN,
  output         io_rawOut_isInf,
  output         io_rawOut_isZero,
  output         io_rawOut_sign,
  output [12:0]  io_rawOut_sExp,
  output [55:0]  io_rawOut_sig
);
  wire  roundingMode_min = io_roundingMode == 3'h2; // @[MulAddRecFN.scala 184:45]
  wire  CDom_sign = io_fromPreMul_signProd ^ io_fromPreMul_doSubMags; // @[MulAddRecFN.scala 188:42]
  wire [54:0] _sigSum_T_2 = io_fromPreMul_highAlignedSigC + 55'h1; // @[MulAddRecFN.scala 191:47]
  wire [54:0] _sigSum_T_3 = io_mulAddResult[106] ? _sigSum_T_2 : io_fromPreMul_highAlignedSigC; // @[MulAddRecFN.scala 190:16]
  wire [161:0] sigSum = {_sigSum_T_3,io_mulAddResult[105:0],io_fromPreMul_bit0AlignedSigC}; // @[Cat.scala 33:92]
  wire [1:0] _CDom_sExp_T = {1'b0,$signed(io_fromPreMul_doSubMags)}; // @[MulAddRecFN.scala 201:69]
  wire [12:0] _GEN_0 = {{11{_CDom_sExp_T[1]}},_CDom_sExp_T}; // @[MulAddRecFN.scala 201:43]
  wire [12:0] CDom_sExp = $signed(io_fromPreMul_sExpSum) - $signed(_GEN_0); // @[MulAddRecFN.scala 201:43]
  wire [107:0] _CDom_absSigSum_T_1 = ~sigSum[161:54]; // @[MulAddRecFN.scala 204:13]
  wire [107:0] _CDom_absSigSum_T_5 = {1'h0,io_fromPreMul_highAlignedSigC[54:53],sigSum[159:55]}; // @[MulAddRecFN.scala 207:71]
  wire [107:0] CDom_absSigSum = io_fromPreMul_doSubMags ? _CDom_absSigSum_T_1 : _CDom_absSigSum_T_5; // @[MulAddRecFN.scala 203:12]
  wire [52:0] _CDom_absSigSumExtra_T_1 = ~sigSum[53:1]; // @[MulAddRecFN.scala 213:14]
  wire  _CDom_absSigSumExtra_T_2 = |_CDom_absSigSumExtra_T_1; // @[MulAddRecFN.scala 213:36]
  wire  _CDom_absSigSumExtra_T_4 = |sigSum[54:1]; // @[MulAddRecFN.scala 214:37]
  wire  CDom_absSigSumExtra = io_fromPreMul_doSubMags ? _CDom_absSigSumExtra_T_2 : _CDom_absSigSumExtra_T_4; // @[MulAddRecFN.scala 212:12]
  wire [170:0] _GEN_11 = {{63'd0}, CDom_absSigSum}; // @[MulAddRecFN.scala 217:24]
  wire [170:0] _CDom_mainSig_T = _GEN_11 << io_fromPreMul_CDom_CAlignDist; // @[MulAddRecFN.scala 217:24]
  wire [57:0] CDom_mainSig = _CDom_mainSig_T[107:50]; // @[MulAddRecFN.scala 217:56]
  wire [54:0] _CDom_reduced4SigExtra_T_1 = {CDom_absSigSum[52:0], 2'h0}; // @[MulAddRecFN.scala 220:53]
  wire  CDom_reduced4SigExtra_reducedVec_0 = |_CDom_reduced4SigExtra_T_1[3:0]; // @[primitives.scala 120:54]
  wire  CDom_reduced4SigExtra_reducedVec_1 = |_CDom_reduced4SigExtra_T_1[7:4]; // @[primitives.scala 120:54]
  wire  CDom_reduced4SigExtra_reducedVec_2 = |_CDom_reduced4SigExtra_T_1[11:8]; // @[primitives.scala 120:54]
  wire  CDom_reduced4SigExtra_reducedVec_3 = |_CDom_reduced4SigExtra_T_1[15:12]; // @[primitives.scala 120:54]
  wire  CDom_reduced4SigExtra_reducedVec_4 = |_CDom_reduced4SigExtra_T_1[19:16]; // @[primitives.scala 120:54]
  wire  CDom_reduced4SigExtra_reducedVec_5 = |_CDom_reduced4SigExtra_T_1[23:20]; // @[primitives.scala 120:54]
  wire  CDom_reduced4SigExtra_reducedVec_6 = |_CDom_reduced4SigExtra_T_1[27:24]; // @[primitives.scala 120:54]
  wire  CDom_reduced4SigExtra_reducedVec_7 = |_CDom_reduced4SigExtra_T_1[31:28]; // @[primitives.scala 120:54]
  wire  CDom_reduced4SigExtra_reducedVec_8 = |_CDom_reduced4SigExtra_T_1[35:32]; // @[primitives.scala 120:54]
  wire  CDom_reduced4SigExtra_reducedVec_9 = |_CDom_reduced4SigExtra_T_1[39:36]; // @[primitives.scala 120:54]
  wire  CDom_reduced4SigExtra_reducedVec_10 = |_CDom_reduced4SigExtra_T_1[43:40]; // @[primitives.scala 120:54]
  wire  CDom_reduced4SigExtra_reducedVec_11 = |_CDom_reduced4SigExtra_T_1[47:44]; // @[primitives.scala 120:54]
  wire  CDom_reduced4SigExtra_reducedVec_12 = |_CDom_reduced4SigExtra_T_1[51:48]; // @[primitives.scala 120:54]
  wire  CDom_reduced4SigExtra_reducedVec_13 = |_CDom_reduced4SigExtra_T_1[54:52]; // @[primitives.scala 123:57]
  wire [6:0] CDom_reduced4SigExtra_lo = {CDom_reduced4SigExtra_reducedVec_6,CDom_reduced4SigExtra_reducedVec_5,
    CDom_reduced4SigExtra_reducedVec_4,CDom_reduced4SigExtra_reducedVec_3,CDom_reduced4SigExtra_reducedVec_2,
    CDom_reduced4SigExtra_reducedVec_1,CDom_reduced4SigExtra_reducedVec_0}; // @[primitives.scala 124:20]
  wire [13:0] _CDom_reduced4SigExtra_T_2 = {CDom_reduced4SigExtra_reducedVec_13,CDom_reduced4SigExtra_reducedVec_12,
    CDom_reduced4SigExtra_reducedVec_11,CDom_reduced4SigExtra_reducedVec_10,CDom_reduced4SigExtra_reducedVec_9,
    CDom_reduced4SigExtra_reducedVec_8,CDom_reduced4SigExtra_reducedVec_7,CDom_reduced4SigExtra_lo}; // @[primitives.scala 124:20]
  wire [3:0] _CDom_reduced4SigExtra_T_4 = ~io_fromPreMul_CDom_CAlignDist[5:2]; // @[primitives.scala 52:21]
  wire [16:0] CDom_reduced4SigExtra_shift = 17'sh10000 >>> _CDom_reduced4SigExtra_T_4; // @[primitives.scala 76:56]
  wire [7:0] _GEN_1 = {{4'd0}, CDom_reduced4SigExtra_shift[8:5]}; // @[Bitwise.scala 108:31]
  wire [7:0] _CDom_reduced4SigExtra_T_10 = _GEN_1 & 8'hf; // @[Bitwise.scala 108:31]
  wire [7:0] _CDom_reduced4SigExtra_T_12 = {CDom_reduced4SigExtra_shift[4:1], 4'h0}; // @[Bitwise.scala 108:70]
  wire [7:0] _CDom_reduced4SigExtra_T_14 = _CDom_reduced4SigExtra_T_12 & 8'hf0; // @[Bitwise.scala 108:80]
  wire [7:0] _CDom_reduced4SigExtra_T_15 = _CDom_reduced4SigExtra_T_10 | _CDom_reduced4SigExtra_T_14; // @[Bitwise.scala 108:39]
  wire [7:0] _GEN_2 = {{2'd0}, _CDom_reduced4SigExtra_T_15[7:2]}; // @[Bitwise.scala 108:31]
  wire [7:0] _CDom_reduced4SigExtra_T_20 = _GEN_2 & 8'h33; // @[Bitwise.scala 108:31]
  wire [7:0] _CDom_reduced4SigExtra_T_22 = {_CDom_reduced4SigExtra_T_15[5:0], 2'h0}; // @[Bitwise.scala 108:70]
  wire [7:0] _CDom_reduced4SigExtra_T_24 = _CDom_reduced4SigExtra_T_22 & 8'hcc; // @[Bitwise.scala 108:80]
  wire [7:0] _CDom_reduced4SigExtra_T_25 = _CDom_reduced4SigExtra_T_20 | _CDom_reduced4SigExtra_T_24; // @[Bitwise.scala 108:39]
  wire [7:0] _GEN_3 = {{1'd0}, _CDom_reduced4SigExtra_T_25[7:1]}; // @[Bitwise.scala 108:31]
  wire [7:0] _CDom_reduced4SigExtra_T_30 = _GEN_3 & 8'h55; // @[Bitwise.scala 108:31]
  wire [7:0] _CDom_reduced4SigExtra_T_32 = {_CDom_reduced4SigExtra_T_25[6:0], 1'h0}; // @[Bitwise.scala 108:70]
  wire [7:0] _CDom_reduced4SigExtra_T_34 = _CDom_reduced4SigExtra_T_32 & 8'haa; // @[Bitwise.scala 108:80]
  wire [7:0] _CDom_reduced4SigExtra_T_35 = _CDom_reduced4SigExtra_T_30 | _CDom_reduced4SigExtra_T_34; // @[Bitwise.scala 108:39]
  wire [12:0] _CDom_reduced4SigExtra_T_49 = {_CDom_reduced4SigExtra_T_35,CDom_reduced4SigExtra_shift[9],
    CDom_reduced4SigExtra_shift[10],CDom_reduced4SigExtra_shift[11],CDom_reduced4SigExtra_shift[12],
    CDom_reduced4SigExtra_shift[13]}; // @[Cat.scala 33:92]
  wire [13:0] _GEN_4 = {{1'd0}, _CDom_reduced4SigExtra_T_49}; // @[MulAddRecFN.scala 220:72]
  wire [13:0] _CDom_reduced4SigExtra_T_50 = _CDom_reduced4SigExtra_T_2 & _GEN_4; // @[MulAddRecFN.scala 220:72]
  wire  CDom_reduced4SigExtra = |_CDom_reduced4SigExtra_T_50; // @[MulAddRecFN.scala 221:73]
  wire  _CDom_sig_T_4 = |CDom_mainSig[2:0] | CDom_reduced4SigExtra | CDom_absSigSumExtra; // @[MulAddRecFN.scala 224:61]
  wire [55:0] CDom_sig = {CDom_mainSig[57:3],_CDom_sig_T_4}; // @[Cat.scala 33:92]
  wire  notCDom_signSigSum = sigSum[109]; // @[MulAddRecFN.scala 230:36]
  wire [108:0] _notCDom_absSigSum_T_1 = ~sigSum[108:0]; // @[MulAddRecFN.scala 233:13]
  wire [108:0] _GEN_5 = {{108'd0}, io_fromPreMul_doSubMags}; // @[MulAddRecFN.scala 234:41]
  wire [108:0] _notCDom_absSigSum_T_4 = sigSum[108:0] + _GEN_5; // @[MulAddRecFN.scala 234:41]
  wire [108:0] notCDom_absSigSum = notCDom_signSigSum ? _notCDom_absSigSum_T_1 : _notCDom_absSigSum_T_4; // @[MulAddRecFN.scala 232:12]
  wire  notCDom_reduced2AbsSigSum_reducedVec_0 = |notCDom_absSigSum[1:0]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_1 = |notCDom_absSigSum[3:2]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_2 = |notCDom_absSigSum[5:4]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_3 = |notCDom_absSigSum[7:6]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_4 = |notCDom_absSigSum[9:8]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_5 = |notCDom_absSigSum[11:10]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_6 = |notCDom_absSigSum[13:12]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_7 = |notCDom_absSigSum[15:14]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_8 = |notCDom_absSigSum[17:16]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_9 = |notCDom_absSigSum[19:18]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_10 = |notCDom_absSigSum[21:20]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_11 = |notCDom_absSigSum[23:22]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_12 = |notCDom_absSigSum[25:24]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_13 = |notCDom_absSigSum[27:26]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_14 = |notCDom_absSigSum[29:28]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_15 = |notCDom_absSigSum[31:30]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_16 = |notCDom_absSigSum[33:32]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_17 = |notCDom_absSigSum[35:34]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_18 = |notCDom_absSigSum[37:36]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_19 = |notCDom_absSigSum[39:38]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_20 = |notCDom_absSigSum[41:40]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_21 = |notCDom_absSigSum[43:42]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_22 = |notCDom_absSigSum[45:44]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_23 = |notCDom_absSigSum[47:46]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_24 = |notCDom_absSigSum[49:48]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_25 = |notCDom_absSigSum[51:50]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_26 = |notCDom_absSigSum[53:52]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_27 = |notCDom_absSigSum[55:54]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_28 = |notCDom_absSigSum[57:56]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_29 = |notCDom_absSigSum[59:58]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_30 = |notCDom_absSigSum[61:60]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_31 = |notCDom_absSigSum[63:62]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_32 = |notCDom_absSigSum[65:64]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_33 = |notCDom_absSigSum[67:66]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_34 = |notCDom_absSigSum[69:68]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_35 = |notCDom_absSigSum[71:70]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_36 = |notCDom_absSigSum[73:72]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_37 = |notCDom_absSigSum[75:74]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_38 = |notCDom_absSigSum[77:76]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_39 = |notCDom_absSigSum[79:78]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_40 = |notCDom_absSigSum[81:80]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_41 = |notCDom_absSigSum[83:82]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_42 = |notCDom_absSigSum[85:84]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_43 = |notCDom_absSigSum[87:86]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_44 = |notCDom_absSigSum[89:88]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_45 = |notCDom_absSigSum[91:90]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_46 = |notCDom_absSigSum[93:92]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_47 = |notCDom_absSigSum[95:94]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_48 = |notCDom_absSigSum[97:96]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_49 = |notCDom_absSigSum[99:98]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_50 = |notCDom_absSigSum[101:100]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_51 = |notCDom_absSigSum[103:102]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_52 = |notCDom_absSigSum[105:104]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_53 = |notCDom_absSigSum[107:106]; // @[primitives.scala 103:54]
  wire  notCDom_reduced2AbsSigSum_reducedVec_54 = |notCDom_absSigSum[108]; // @[primitives.scala 106:57]
  wire [5:0] notCDom_reduced2AbsSigSum_lo_lo_lo = {notCDom_reduced2AbsSigSum_reducedVec_5,
    notCDom_reduced2AbsSigSum_reducedVec_4,notCDom_reduced2AbsSigSum_reducedVec_3,notCDom_reduced2AbsSigSum_reducedVec_2
    ,notCDom_reduced2AbsSigSum_reducedVec_1,notCDom_reduced2AbsSigSum_reducedVec_0}; // @[primitives.scala 107:20]
  wire [12:0] notCDom_reduced2AbsSigSum_lo_lo = {notCDom_reduced2AbsSigSum_reducedVec_12,
    notCDom_reduced2AbsSigSum_reducedVec_11,notCDom_reduced2AbsSigSum_reducedVec_10,
    notCDom_reduced2AbsSigSum_reducedVec_9,notCDom_reduced2AbsSigSum_reducedVec_8,notCDom_reduced2AbsSigSum_reducedVec_7
    ,notCDom_reduced2AbsSigSum_reducedVec_6,notCDom_reduced2AbsSigSum_lo_lo_lo}; // @[primitives.scala 107:20]
  wire [6:0] notCDom_reduced2AbsSigSum_lo_hi_lo = {notCDom_reduced2AbsSigSum_reducedVec_19,
    notCDom_reduced2AbsSigSum_reducedVec_18,notCDom_reduced2AbsSigSum_reducedVec_17,
    notCDom_reduced2AbsSigSum_reducedVec_16,notCDom_reduced2AbsSigSum_reducedVec_15,
    notCDom_reduced2AbsSigSum_reducedVec_14,notCDom_reduced2AbsSigSum_reducedVec_13}; // @[primitives.scala 107:20]
  wire [26:0] notCDom_reduced2AbsSigSum_lo = {notCDom_reduced2AbsSigSum_reducedVec_26,
    notCDom_reduced2AbsSigSum_reducedVec_25,notCDom_reduced2AbsSigSum_reducedVec_24,
    notCDom_reduced2AbsSigSum_reducedVec_23,notCDom_reduced2AbsSigSum_reducedVec_22,
    notCDom_reduced2AbsSigSum_reducedVec_21,notCDom_reduced2AbsSigSum_reducedVec_20,notCDom_reduced2AbsSigSum_lo_hi_lo,
    notCDom_reduced2AbsSigSum_lo_lo}; // @[primitives.scala 107:20]
  wire [6:0] notCDom_reduced2AbsSigSum_hi_lo_lo = {notCDom_reduced2AbsSigSum_reducedVec_33,
    notCDom_reduced2AbsSigSum_reducedVec_32,notCDom_reduced2AbsSigSum_reducedVec_31,
    notCDom_reduced2AbsSigSum_reducedVec_30,notCDom_reduced2AbsSigSum_reducedVec_29,
    notCDom_reduced2AbsSigSum_reducedVec_28,notCDom_reduced2AbsSigSum_reducedVec_27}; // @[primitives.scala 107:20]
  wire [13:0] notCDom_reduced2AbsSigSum_hi_lo = {notCDom_reduced2AbsSigSum_reducedVec_40,
    notCDom_reduced2AbsSigSum_reducedVec_39,notCDom_reduced2AbsSigSum_reducedVec_38,
    notCDom_reduced2AbsSigSum_reducedVec_37,notCDom_reduced2AbsSigSum_reducedVec_36,
    notCDom_reduced2AbsSigSum_reducedVec_35,notCDom_reduced2AbsSigSum_reducedVec_34,notCDom_reduced2AbsSigSum_hi_lo_lo}; // @[primitives.scala 107:20]
  wire [6:0] notCDom_reduced2AbsSigSum_hi_hi_lo = {notCDom_reduced2AbsSigSum_reducedVec_47,
    notCDom_reduced2AbsSigSum_reducedVec_46,notCDom_reduced2AbsSigSum_reducedVec_45,
    notCDom_reduced2AbsSigSum_reducedVec_44,notCDom_reduced2AbsSigSum_reducedVec_43,
    notCDom_reduced2AbsSigSum_reducedVec_42,notCDom_reduced2AbsSigSum_reducedVec_41}; // @[primitives.scala 107:20]
  wire [54:0] notCDom_reduced2AbsSigSum = {notCDom_reduced2AbsSigSum_reducedVec_54,
    notCDom_reduced2AbsSigSum_reducedVec_53,notCDom_reduced2AbsSigSum_reducedVec_52,
    notCDom_reduced2AbsSigSum_reducedVec_51,notCDom_reduced2AbsSigSum_reducedVec_50,
    notCDom_reduced2AbsSigSum_reducedVec_49,notCDom_reduced2AbsSigSum_reducedVec_48,notCDom_reduced2AbsSigSum_hi_hi_lo,
    notCDom_reduced2AbsSigSum_hi_lo,notCDom_reduced2AbsSigSum_lo}; // @[primitives.scala 107:20]
  wire [5:0] _notCDom_normDistReduced2_T_55 = notCDom_reduced2AbsSigSum[1] ? 6'h35 : 6'h36; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_56 = notCDom_reduced2AbsSigSum[2] ? 6'h34 : _notCDom_normDistReduced2_T_55; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_57 = notCDom_reduced2AbsSigSum[3] ? 6'h33 : _notCDom_normDistReduced2_T_56; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_58 = notCDom_reduced2AbsSigSum[4] ? 6'h32 : _notCDom_normDistReduced2_T_57; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_59 = notCDom_reduced2AbsSigSum[5] ? 6'h31 : _notCDom_normDistReduced2_T_58; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_60 = notCDom_reduced2AbsSigSum[6] ? 6'h30 : _notCDom_normDistReduced2_T_59; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_61 = notCDom_reduced2AbsSigSum[7] ? 6'h2f : _notCDom_normDistReduced2_T_60; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_62 = notCDom_reduced2AbsSigSum[8] ? 6'h2e : _notCDom_normDistReduced2_T_61; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_63 = notCDom_reduced2AbsSigSum[9] ? 6'h2d : _notCDom_normDistReduced2_T_62; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_64 = notCDom_reduced2AbsSigSum[10] ? 6'h2c : _notCDom_normDistReduced2_T_63; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_65 = notCDom_reduced2AbsSigSum[11] ? 6'h2b : _notCDom_normDistReduced2_T_64; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_66 = notCDom_reduced2AbsSigSum[12] ? 6'h2a : _notCDom_normDistReduced2_T_65; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_67 = notCDom_reduced2AbsSigSum[13] ? 6'h29 : _notCDom_normDistReduced2_T_66; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_68 = notCDom_reduced2AbsSigSum[14] ? 6'h28 : _notCDom_normDistReduced2_T_67; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_69 = notCDom_reduced2AbsSigSum[15] ? 6'h27 : _notCDom_normDistReduced2_T_68; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_70 = notCDom_reduced2AbsSigSum[16] ? 6'h26 : _notCDom_normDistReduced2_T_69; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_71 = notCDom_reduced2AbsSigSum[17] ? 6'h25 : _notCDom_normDistReduced2_T_70; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_72 = notCDom_reduced2AbsSigSum[18] ? 6'h24 : _notCDom_normDistReduced2_T_71; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_73 = notCDom_reduced2AbsSigSum[19] ? 6'h23 : _notCDom_normDistReduced2_T_72; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_74 = notCDom_reduced2AbsSigSum[20] ? 6'h22 : _notCDom_normDistReduced2_T_73; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_75 = notCDom_reduced2AbsSigSum[21] ? 6'h21 : _notCDom_normDistReduced2_T_74; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_76 = notCDom_reduced2AbsSigSum[22] ? 6'h20 : _notCDom_normDistReduced2_T_75; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_77 = notCDom_reduced2AbsSigSum[23] ? 6'h1f : _notCDom_normDistReduced2_T_76; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_78 = notCDom_reduced2AbsSigSum[24] ? 6'h1e : _notCDom_normDistReduced2_T_77; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_79 = notCDom_reduced2AbsSigSum[25] ? 6'h1d : _notCDom_normDistReduced2_T_78; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_80 = notCDom_reduced2AbsSigSum[26] ? 6'h1c : _notCDom_normDistReduced2_T_79; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_81 = notCDom_reduced2AbsSigSum[27] ? 6'h1b : _notCDom_normDistReduced2_T_80; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_82 = notCDom_reduced2AbsSigSum[28] ? 6'h1a : _notCDom_normDistReduced2_T_81; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_83 = notCDom_reduced2AbsSigSum[29] ? 6'h19 : _notCDom_normDistReduced2_T_82; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_84 = notCDom_reduced2AbsSigSum[30] ? 6'h18 : _notCDom_normDistReduced2_T_83; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_85 = notCDom_reduced2AbsSigSum[31] ? 6'h17 : _notCDom_normDistReduced2_T_84; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_86 = notCDom_reduced2AbsSigSum[32] ? 6'h16 : _notCDom_normDistReduced2_T_85; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_87 = notCDom_reduced2AbsSigSum[33] ? 6'h15 : _notCDom_normDistReduced2_T_86; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_88 = notCDom_reduced2AbsSigSum[34] ? 6'h14 : _notCDom_normDistReduced2_T_87; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_89 = notCDom_reduced2AbsSigSum[35] ? 6'h13 : _notCDom_normDistReduced2_T_88; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_90 = notCDom_reduced2AbsSigSum[36] ? 6'h12 : _notCDom_normDistReduced2_T_89; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_91 = notCDom_reduced2AbsSigSum[37] ? 6'h11 : _notCDom_normDistReduced2_T_90; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_92 = notCDom_reduced2AbsSigSum[38] ? 6'h10 : _notCDom_normDistReduced2_T_91; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_93 = notCDom_reduced2AbsSigSum[39] ? 6'hf : _notCDom_normDistReduced2_T_92; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_94 = notCDom_reduced2AbsSigSum[40] ? 6'he : _notCDom_normDistReduced2_T_93; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_95 = notCDom_reduced2AbsSigSum[41] ? 6'hd : _notCDom_normDistReduced2_T_94; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_96 = notCDom_reduced2AbsSigSum[42] ? 6'hc : _notCDom_normDistReduced2_T_95; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_97 = notCDom_reduced2AbsSigSum[43] ? 6'hb : _notCDom_normDistReduced2_T_96; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_98 = notCDom_reduced2AbsSigSum[44] ? 6'ha : _notCDom_normDistReduced2_T_97; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_99 = notCDom_reduced2AbsSigSum[45] ? 6'h9 : _notCDom_normDistReduced2_T_98; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_100 = notCDom_reduced2AbsSigSum[46] ? 6'h8 : _notCDom_normDistReduced2_T_99; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_101 = notCDom_reduced2AbsSigSum[47] ? 6'h7 : _notCDom_normDistReduced2_T_100; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_102 = notCDom_reduced2AbsSigSum[48] ? 6'h6 : _notCDom_normDistReduced2_T_101; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_103 = notCDom_reduced2AbsSigSum[49] ? 6'h5 : _notCDom_normDistReduced2_T_102; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_104 = notCDom_reduced2AbsSigSum[50] ? 6'h4 : _notCDom_normDistReduced2_T_103; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_105 = notCDom_reduced2AbsSigSum[51] ? 6'h3 : _notCDom_normDistReduced2_T_104; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_106 = notCDom_reduced2AbsSigSum[52] ? 6'h2 : _notCDom_normDistReduced2_T_105; // @[Mux.scala 47:70]
  wire [5:0] _notCDom_normDistReduced2_T_107 = notCDom_reduced2AbsSigSum[53] ? 6'h1 : _notCDom_normDistReduced2_T_106; // @[Mux.scala 47:70]
  wire [5:0] notCDom_normDistReduced2 = notCDom_reduced2AbsSigSum[54] ? 6'h0 : _notCDom_normDistReduced2_T_107; // @[Mux.scala 47:70]
  wire [6:0] notCDom_nearNormDist = {notCDom_normDistReduced2, 1'h0}; // @[MulAddRecFN.scala 238:56]
  wire [7:0] _notCDom_sExp_T = {1'b0,$signed(notCDom_nearNormDist)}; // @[MulAddRecFN.scala 239:76]
  wire [12:0] _GEN_6 = {{5{_notCDom_sExp_T[7]}},_notCDom_sExp_T}; // @[MulAddRecFN.scala 239:46]
  wire [12:0] notCDom_sExp = $signed(io_fromPreMul_sExpSum) - $signed(_GEN_6); // @[MulAddRecFN.scala 239:46]
  wire [235:0] _GEN_12 = {{127'd0}, notCDom_absSigSum}; // @[MulAddRecFN.scala 241:27]
  wire [235:0] _notCDom_mainSig_T = _GEN_12 << notCDom_nearNormDist; // @[MulAddRecFN.scala 241:27]
  wire [57:0] notCDom_mainSig = _notCDom_mainSig_T[109:52]; // @[MulAddRecFN.scala 241:50]
  wire  notCDom_reduced4SigExtra_reducedVec_0 = |notCDom_reduced2AbsSigSum[1:0]; // @[primitives.scala 103:54]
  wire  notCDom_reduced4SigExtra_reducedVec_1 = |notCDom_reduced2AbsSigSum[3:2]; // @[primitives.scala 103:54]
  wire  notCDom_reduced4SigExtra_reducedVec_2 = |notCDom_reduced2AbsSigSum[5:4]; // @[primitives.scala 103:54]
  wire  notCDom_reduced4SigExtra_reducedVec_3 = |notCDom_reduced2AbsSigSum[7:6]; // @[primitives.scala 103:54]
  wire  notCDom_reduced4SigExtra_reducedVec_4 = |notCDom_reduced2AbsSigSum[9:8]; // @[primitives.scala 103:54]
  wire  notCDom_reduced4SigExtra_reducedVec_5 = |notCDom_reduced2AbsSigSum[11:10]; // @[primitives.scala 103:54]
  wire  notCDom_reduced4SigExtra_reducedVec_6 = |notCDom_reduced2AbsSigSum[13:12]; // @[primitives.scala 103:54]
  wire  notCDom_reduced4SigExtra_reducedVec_7 = |notCDom_reduced2AbsSigSum[15:14]; // @[primitives.scala 103:54]
  wire  notCDom_reduced4SigExtra_reducedVec_8 = |notCDom_reduced2AbsSigSum[17:16]; // @[primitives.scala 103:54]
  wire  notCDom_reduced4SigExtra_reducedVec_9 = |notCDom_reduced2AbsSigSum[19:18]; // @[primitives.scala 103:54]
  wire  notCDom_reduced4SigExtra_reducedVec_10 = |notCDom_reduced2AbsSigSum[21:20]; // @[primitives.scala 103:54]
  wire  notCDom_reduced4SigExtra_reducedVec_11 = |notCDom_reduced2AbsSigSum[23:22]; // @[primitives.scala 103:54]
  wire  notCDom_reduced4SigExtra_reducedVec_12 = |notCDom_reduced2AbsSigSum[25:24]; // @[primitives.scala 103:54]
  wire  notCDom_reduced4SigExtra_reducedVec_13 = |notCDom_reduced2AbsSigSum[26]; // @[primitives.scala 106:57]
  wire [6:0] notCDom_reduced4SigExtra_lo = {notCDom_reduced4SigExtra_reducedVec_6,notCDom_reduced4SigExtra_reducedVec_5,
    notCDom_reduced4SigExtra_reducedVec_4,notCDom_reduced4SigExtra_reducedVec_3,notCDom_reduced4SigExtra_reducedVec_2,
    notCDom_reduced4SigExtra_reducedVec_1,notCDom_reduced4SigExtra_reducedVec_0}; // @[primitives.scala 107:20]
  wire [13:0] _notCDom_reduced4SigExtra_T_2 = {notCDom_reduced4SigExtra_reducedVec_13,
    notCDom_reduced4SigExtra_reducedVec_12,notCDom_reduced4SigExtra_reducedVec_11,notCDom_reduced4SigExtra_reducedVec_10
    ,notCDom_reduced4SigExtra_reducedVec_9,notCDom_reduced4SigExtra_reducedVec_8,notCDom_reduced4SigExtra_reducedVec_7,
    notCDom_reduced4SigExtra_lo}; // @[primitives.scala 107:20]
  wire [4:0] _notCDom_reduced4SigExtra_T_4 = ~notCDom_normDistReduced2[5:1]; // @[primitives.scala 52:21]
  wire [32:0] notCDom_reduced4SigExtra_shift = 33'sh100000000 >>> _notCDom_reduced4SigExtra_T_4; // @[primitives.scala 76:56]
  wire [7:0] _GEN_7 = {{4'd0}, notCDom_reduced4SigExtra_shift[8:5]}; // @[Bitwise.scala 108:31]
  wire [7:0] _notCDom_reduced4SigExtra_T_10 = _GEN_7 & 8'hf; // @[Bitwise.scala 108:31]
  wire [7:0] _notCDom_reduced4SigExtra_T_12 = {notCDom_reduced4SigExtra_shift[4:1], 4'h0}; // @[Bitwise.scala 108:70]
  wire [7:0] _notCDom_reduced4SigExtra_T_14 = _notCDom_reduced4SigExtra_T_12 & 8'hf0; // @[Bitwise.scala 108:80]
  wire [7:0] _notCDom_reduced4SigExtra_T_15 = _notCDom_reduced4SigExtra_T_10 | _notCDom_reduced4SigExtra_T_14; // @[Bitwise.scala 108:39]
  wire [7:0] _GEN_8 = {{2'd0}, _notCDom_reduced4SigExtra_T_15[7:2]}; // @[Bitwise.scala 108:31]
  wire [7:0] _notCDom_reduced4SigExtra_T_20 = _GEN_8 & 8'h33; // @[Bitwise.scala 108:31]
  wire [7:0] _notCDom_reduced4SigExtra_T_22 = {_notCDom_reduced4SigExtra_T_15[5:0], 2'h0}; // @[Bitwise.scala 108:70]
  wire [7:0] _notCDom_reduced4SigExtra_T_24 = _notCDom_reduced4SigExtra_T_22 & 8'hcc; // @[Bitwise.scala 108:80]
  wire [7:0] _notCDom_reduced4SigExtra_T_25 = _notCDom_reduced4SigExtra_T_20 | _notCDom_reduced4SigExtra_T_24; // @[Bitwise.scala 108:39]
  wire [7:0] _GEN_9 = {{1'd0}, _notCDom_reduced4SigExtra_T_25[7:1]}; // @[Bitwise.scala 108:31]
  wire [7:0] _notCDom_reduced4SigExtra_T_30 = _GEN_9 & 8'h55; // @[Bitwise.scala 108:31]
  wire [7:0] _notCDom_reduced4SigExtra_T_32 = {_notCDom_reduced4SigExtra_T_25[6:0], 1'h0}; // @[Bitwise.scala 108:70]
  wire [7:0] _notCDom_reduced4SigExtra_T_34 = _notCDom_reduced4SigExtra_T_32 & 8'haa; // @[Bitwise.scala 108:80]
  wire [7:0] _notCDom_reduced4SigExtra_T_35 = _notCDom_reduced4SigExtra_T_30 | _notCDom_reduced4SigExtra_T_34; // @[Bitwise.scala 108:39]
  wire [12:0] _notCDom_reduced4SigExtra_T_49 = {_notCDom_reduced4SigExtra_T_35,notCDom_reduced4SigExtra_shift[9],
    notCDom_reduced4SigExtra_shift[10],notCDom_reduced4SigExtra_shift[11],notCDom_reduced4SigExtra_shift[12],
    notCDom_reduced4SigExtra_shift[13]}; // @[Cat.scala 33:92]
  wire [13:0] _GEN_10 = {{1'd0}, _notCDom_reduced4SigExtra_T_49}; // @[MulAddRecFN.scala 245:78]
  wire [13:0] _notCDom_reduced4SigExtra_T_50 = _notCDom_reduced4SigExtra_T_2 & _GEN_10; // @[MulAddRecFN.scala 245:78]
  wire  notCDom_reduced4SigExtra = |_notCDom_reduced4SigExtra_T_50; // @[MulAddRecFN.scala 247:11]
  wire  _notCDom_sig_T_3 = |notCDom_mainSig[2:0] | notCDom_reduced4SigExtra; // @[MulAddRecFN.scala 250:39]
  wire [55:0] notCDom_sig = {notCDom_mainSig[57:3],_notCDom_sig_T_3}; // @[Cat.scala 33:92]
  wire  notCDom_completeCancellation = notCDom_sig[55:54] == 2'h0; // @[MulAddRecFN.scala 253:50]
  wire  _notCDom_sign_T = io_fromPreMul_signProd ^ notCDom_signSigSum; // @[MulAddRecFN.scala 257:36]
  wire  notCDom_sign = notCDom_completeCancellation ? roundingMode_min : _notCDom_sign_T; // @[MulAddRecFN.scala 255:12]
  wire  notNaN_isInfProd = io_fromPreMul_isInfA | io_fromPreMul_isInfB; // @[MulAddRecFN.scala 262:49]
  wire  notNaN_isInfOut = notNaN_isInfProd | io_fromPreMul_isInfC; // @[MulAddRecFN.scala 263:44]
  wire  notNaN_addZeros = (io_fromPreMul_isZeroA | io_fromPreMul_isZeroB) & io_fromPreMul_isZeroC; // @[MulAddRecFN.scala 265:58]
  wire  _io_invalidExc_T = io_fromPreMul_isInfA & io_fromPreMul_isZeroB; // @[MulAddRecFN.scala 270:31]
  wire  _io_invalidExc_T_1 = io_fromPreMul_isSigNaNAny | _io_invalidExc_T; // @[MulAddRecFN.scala 269:35]
  wire  _io_invalidExc_T_2 = io_fromPreMul_isZeroA & io_fromPreMul_isInfB; // @[MulAddRecFN.scala 271:32]
  wire  _io_invalidExc_T_3 = _io_invalidExc_T_1 | _io_invalidExc_T_2; // @[MulAddRecFN.scala 270:57]
  wire  _io_invalidExc_T_6 = ~io_fromPreMul_isNaNAOrB & notNaN_isInfProd; // @[MulAddRecFN.scala 272:36]
  wire  _io_invalidExc_T_7 = _io_invalidExc_T_6 & io_fromPreMul_isInfC; // @[MulAddRecFN.scala 273:61]
  wire  _io_invalidExc_T_8 = _io_invalidExc_T_7 & io_fromPreMul_doSubMags; // @[MulAddRecFN.scala 274:35]
  wire  _io_rawOut_isZero_T_1 = ~io_fromPreMul_CIsDominant & notCDom_completeCancellation; // @[MulAddRecFN.scala 281:42]
  wire  _io_rawOut_sign_T_1 = io_fromPreMul_isInfC & CDom_sign; // @[MulAddRecFN.scala 284:31]
  wire  _io_rawOut_sign_T_2 = notNaN_isInfProd & io_fromPreMul_signProd | _io_rawOut_sign_T_1; // @[MulAddRecFN.scala 283:54]
  wire  _io_rawOut_sign_T_5 = notNaN_addZeros & ~roundingMode_min & io_fromPreMul_signProd; // @[MulAddRecFN.scala 285:48]
  wire  _io_rawOut_sign_T_6 = _io_rawOut_sign_T_5 & CDom_sign; // @[MulAddRecFN.scala 286:36]
  wire  _io_rawOut_sign_T_7 = _io_rawOut_sign_T_2 | _io_rawOut_sign_T_6; // @[MulAddRecFN.scala 284:43]
  wire  _io_rawOut_sign_T_9 = io_fromPreMul_signProd | CDom_sign; // @[MulAddRecFN.scala 288:37]
  wire  _io_rawOut_sign_T_10 = notNaN_addZeros & roundingMode_min & _io_rawOut_sign_T_9; // @[MulAddRecFN.scala 287:46]
  wire  _io_rawOut_sign_T_11 = _io_rawOut_sign_T_7 | _io_rawOut_sign_T_10; // @[MulAddRecFN.scala 286:48]
  wire  _io_rawOut_sign_T_15 = io_fromPreMul_CIsDominant ? CDom_sign : notCDom_sign; // @[MulAddRecFN.scala 290:17]
  wire  _io_rawOut_sign_T_16 = ~notNaN_isInfOut & ~notNaN_addZeros & _io_rawOut_sign_T_15; // @[MulAddRecFN.scala 289:49]
  assign io_invalidExc = _io_invalidExc_T_3 | _io_invalidExc_T_8; // @[MulAddRecFN.scala 271:57]
  assign io_rawOut_isNaN = io_fromPreMul_isNaNAOrB | io_fromPreMul_isNaNC; // @[MulAddRecFN.scala 276:48]
  assign io_rawOut_isInf = notNaN_isInfProd | io_fromPreMul_isInfC; // @[MulAddRecFN.scala 263:44]
  assign io_rawOut_isZero = notNaN_addZeros | _io_rawOut_isZero_T_1; // @[MulAddRecFN.scala 280:25]
  assign io_rawOut_sign = _io_rawOut_sign_T_11 | _io_rawOut_sign_T_16; // @[MulAddRecFN.scala 288:50]
  assign io_rawOut_sExp = io_fromPreMul_CIsDominant ? $signed(CDom_sExp) : $signed(notCDom_sExp); // @[MulAddRecFN.scala 291:26]
  assign io_rawOut_sig = io_fromPreMul_CIsDominant ? CDom_sig : notCDom_sig; // @[MulAddRecFN.scala 292:25]
endmodule

module RoundAnyRawFNToRecFN_4(
  input         io_invalidExc,
  input         io_infiniteExc,
  input         io_in_isNaN,
  input         io_in_isInf,
  input         io_in_isZero,
  input         io_in_sign,
  input  [12:0] io_in_sExp,
  input  [55:0] io_in_sig,
  input  [2:0]  io_roundingMode,
  output [64:0] io_out,
  output [4:0]  io_exceptionFlags
);
  wire  roundingMode_near_even = io_roundingMode == 3'h0; // @[RoundAnyRawFNToRecFN.scala 89:53]
  wire  roundingMode_min = io_roundingMode == 3'h2; // @[RoundAnyRawFNToRecFN.scala 91:53]
  wire  roundingMode_max = io_roundingMode == 3'h3; // @[RoundAnyRawFNToRecFN.scala 92:53]
  wire  roundingMode_near_maxMag = io_roundingMode == 3'h4; // @[RoundAnyRawFNToRecFN.scala 93:53]
  wire  roundingMode_odd = io_roundingMode == 3'h6; // @[RoundAnyRawFNToRecFN.scala 94:53]
  wire  roundMagUp = roundingMode_min & io_in_sign | roundingMode_max & ~io_in_sign; // @[RoundAnyRawFNToRecFN.scala 97:42]
  wire  doShiftSigDown1 = io_in_sig[55]; // @[RoundAnyRawFNToRecFN.scala 119:57]
  wire [11:0] _roundMask_T_1 = ~io_in_sExp[11:0]; // @[primitives.scala 52:21]
  wire  roundMask_msb = _roundMask_T_1[11]; // @[primitives.scala 58:25]
  wire [10:0] roundMask_lsbs = _roundMask_T_1[10:0]; // @[primitives.scala 59:26]
  wire  roundMask_msb_1 = roundMask_lsbs[10]; // @[primitives.scala 58:25]
  wire [9:0] roundMask_lsbs_1 = roundMask_lsbs[9:0]; // @[primitives.scala 59:26]
  wire  roundMask_msb_2 = roundMask_lsbs_1[9]; // @[primitives.scala 58:25]
  wire [8:0] roundMask_lsbs_2 = roundMask_lsbs_1[8:0]; // @[primitives.scala 59:26]
  wire  roundMask_msb_3 = roundMask_lsbs_2[8]; // @[primitives.scala 58:25]
  wire [7:0] roundMask_lsbs_3 = roundMask_lsbs_2[7:0]; // @[primitives.scala 59:26]
  wire  roundMask_msb_4 = roundMask_lsbs_3[7]; // @[primitives.scala 58:25]
  wire [6:0] roundMask_lsbs_4 = roundMask_lsbs_3[6:0]; // @[primitives.scala 59:26]
  wire  roundMask_msb_5 = roundMask_lsbs_4[6]; // @[primitives.scala 58:25]
  wire [5:0] roundMask_lsbs_5 = roundMask_lsbs_4[5:0]; // @[primitives.scala 59:26]
  wire [64:0] roundMask_shift = 65'sh10000000000000000 >>> roundMask_lsbs_5; // @[primitives.scala 76:56]
  wire [31:0] _GEN_0 = {{16'd0}, roundMask_shift[44:29]}; // @[Bitwise.scala 108:31]
  wire [31:0] _roundMask_T_7 = _GEN_0 & 32'hffff; // @[Bitwise.scala 108:31]
  wire [31:0] _roundMask_T_9 = {roundMask_shift[28:13], 16'h0}; // @[Bitwise.scala 108:70]
  wire [31:0] _roundMask_T_11 = _roundMask_T_9 & 32'hffff0000; // @[Bitwise.scala 108:80]
  wire [31:0] _roundMask_T_12 = _roundMask_T_7 | _roundMask_T_11; // @[Bitwise.scala 108:39]
  wire [31:0] _GEN_1 = {{8'd0}, _roundMask_T_12[31:8]}; // @[Bitwise.scala 108:31]
  wire [31:0] _roundMask_T_17 = _GEN_1 & 32'hff00ff; // @[Bitwise.scala 108:31]
  wire [31:0] _roundMask_T_19 = {_roundMask_T_12[23:0], 8'h0}; // @[Bitwise.scala 108:70]
  wire [31:0] _roundMask_T_21 = _roundMask_T_19 & 32'hff00ff00; // @[Bitwise.scala 108:80]
  wire [31:0] _roundMask_T_22 = _roundMask_T_17 | _roundMask_T_21; // @[Bitwise.scala 108:39]
  wire [31:0] _GEN_2 = {{4'd0}, _roundMask_T_22[31:4]}; // @[Bitwise.scala 108:31]
  wire [31:0] _roundMask_T_27 = _GEN_2 & 32'hf0f0f0f; // @[Bitwise.scala 108:31]
  wire [31:0] _roundMask_T_29 = {_roundMask_T_22[27:0], 4'h0}; // @[Bitwise.scala 108:70]
  wire [31:0] _roundMask_T_31 = _roundMask_T_29 & 32'hf0f0f0f0; // @[Bitwise.scala 108:80]
  wire [31:0] _roundMask_T_32 = _roundMask_T_27 | _roundMask_T_31; // @[Bitwise.scala 108:39]
  wire [31:0] _GEN_3 = {{2'd0}, _roundMask_T_32[31:2]}; // @[Bitwise.scala 108:31]
  wire [31:0] _roundMask_T_37 = _GEN_3 & 32'h33333333; // @[Bitwise.scala 108:31]
  wire [31:0] _roundMask_T_39 = {_roundMask_T_32[29:0], 2'h0}; // @[Bitwise.scala 108:70]
  wire [31:0] _roundMask_T_41 = _roundMask_T_39 & 32'hcccccccc; // @[Bitwise.scala 108:80]
  wire [31:0] _roundMask_T_42 = _roundMask_T_37 | _roundMask_T_41; // @[Bitwise.scala 108:39]
  wire [31:0] _GEN_4 = {{1'd0}, _roundMask_T_42[31:1]}; // @[Bitwise.scala 108:31]
  wire [31:0] _roundMask_T_47 = _GEN_4 & 32'h55555555; // @[Bitwise.scala 108:31]
  wire [31:0] _roundMask_T_49 = {_roundMask_T_42[30:0], 1'h0}; // @[Bitwise.scala 108:70]
  wire [31:0] _roundMask_T_51 = _roundMask_T_49 & 32'haaaaaaaa; // @[Bitwise.scala 108:80]
  wire [31:0] _roundMask_T_52 = _roundMask_T_47 | _roundMask_T_51; // @[Bitwise.scala 108:39]
  wire [15:0] _GEN_5 = {{8'd0}, roundMask_shift[60:53]}; // @[Bitwise.scala 108:31]
  wire [15:0] _roundMask_T_58 = _GEN_5 & 16'hff; // @[Bitwise.scala 108:31]
  wire [15:0] _roundMask_T_60 = {roundMask_shift[52:45], 8'h0}; // @[Bitwise.scala 108:70]
  wire [15:0] _roundMask_T_62 = _roundMask_T_60 & 16'hff00; // @[Bitwise.scala 108:80]
  wire [15:0] _roundMask_T_63 = _roundMask_T_58 | _roundMask_T_62; // @[Bitwise.scala 108:39]
  wire [15:0] _GEN_6 = {{4'd0}, _roundMask_T_63[15:4]}; // @[Bitwise.scala 108:31]
  wire [15:0] _roundMask_T_68 = _GEN_6 & 16'hf0f; // @[Bitwise.scala 108:31]
  wire [15:0] _roundMask_T_70 = {_roundMask_T_63[11:0], 4'h0}; // @[Bitwise.scala 108:70]
  wire [15:0] _roundMask_T_72 = _roundMask_T_70 & 16'hf0f0; // @[Bitwise.scala 108:80]
  wire [15:0] _roundMask_T_73 = _roundMask_T_68 | _roundMask_T_72; // @[Bitwise.scala 108:39]
  wire [15:0] _GEN_7 = {{2'd0}, _roundMask_T_73[15:2]}; // @[Bitwise.scala 108:31]
  wire [15:0] _roundMask_T_78 = _GEN_7 & 16'h3333; // @[Bitwise.scala 108:31]
  wire [15:0] _roundMask_T_80 = {_roundMask_T_73[13:0], 2'h0}; // @[Bitwise.scala 108:70]
  wire [15:0] _roundMask_T_82 = _roundMask_T_80 & 16'hcccc; // @[Bitwise.scala 108:80]
  wire [15:0] _roundMask_T_83 = _roundMask_T_78 | _roundMask_T_82; // @[Bitwise.scala 108:39]
  wire [15:0] _GEN_8 = {{1'd0}, _roundMask_T_83[15:1]}; // @[Bitwise.scala 108:31]
  wire [15:0] _roundMask_T_88 = _GEN_8 & 16'h5555; // @[Bitwise.scala 108:31]
  wire [15:0] _roundMask_T_90 = {_roundMask_T_83[14:0], 1'h0}; // @[Bitwise.scala 108:70]
  wire [15:0] _roundMask_T_92 = _roundMask_T_90 & 16'haaaa; // @[Bitwise.scala 108:80]
  wire [15:0] _roundMask_T_93 = _roundMask_T_88 | _roundMask_T_92; // @[Bitwise.scala 108:39]
  wire [50:0] _roundMask_T_102 = {_roundMask_T_52,_roundMask_T_93,roundMask_shift[61],roundMask_shift[62],
    roundMask_shift[63]}; // @[Cat.scala 33:92]
  wire [50:0] _roundMask_T_103 = ~_roundMask_T_102; // @[primitives.scala 73:32]
  wire [50:0] _roundMask_T_104 = roundMask_msb_5 ? 51'h0 : _roundMask_T_103; // @[primitives.scala 73:21]
  wire [50:0] _roundMask_T_105 = ~_roundMask_T_104; // @[primitives.scala 73:17]
  wire [50:0] _roundMask_T_106 = ~_roundMask_T_105; // @[primitives.scala 73:32]
  wire [50:0] _roundMask_T_107 = roundMask_msb_4 ? 51'h0 : _roundMask_T_106; // @[primitives.scala 73:21]
  wire [50:0] _roundMask_T_108 = ~_roundMask_T_107; // @[primitives.scala 73:17]
  wire [50:0] _roundMask_T_109 = ~_roundMask_T_108; // @[primitives.scala 73:32]
  wire [50:0] _roundMask_T_110 = roundMask_msb_3 ? 51'h0 : _roundMask_T_109; // @[primitives.scala 73:21]
  wire [50:0] _roundMask_T_111 = ~_roundMask_T_110; // @[primitives.scala 73:17]
  wire [50:0] _roundMask_T_112 = ~_roundMask_T_111; // @[primitives.scala 73:32]
  wire [50:0] _roundMask_T_113 = roundMask_msb_2 ? 51'h0 : _roundMask_T_112; // @[primitives.scala 73:21]
  wire [50:0] _roundMask_T_114 = ~_roundMask_T_113; // @[primitives.scala 73:17]
  wire [53:0] _roundMask_T_115 = {_roundMask_T_114,3'h7}; // @[primitives.scala 68:58]
  wire [2:0] _roundMask_T_122 = {roundMask_shift[0],roundMask_shift[1],roundMask_shift[2]}; // @[Cat.scala 33:92]
  wire [2:0] _roundMask_T_123 = roundMask_msb_5 ? _roundMask_T_122 : 3'h0; // @[primitives.scala 62:24]
  wire [2:0] _roundMask_T_124 = roundMask_msb_4 ? _roundMask_T_123 : 3'h0; // @[primitives.scala 62:24]
  wire [2:0] _roundMask_T_125 = roundMask_msb_3 ? _roundMask_T_124 : 3'h0; // @[primitives.scala 62:24]
  wire [2:0] _roundMask_T_126 = roundMask_msb_2 ? _roundMask_T_125 : 3'h0; // @[primitives.scala 62:24]
  wire [53:0] _roundMask_T_127 = roundMask_msb_1 ? _roundMask_T_115 : {{51'd0}, _roundMask_T_126}; // @[primitives.scala 67:24]
  wire [53:0] _roundMask_T_128 = roundMask_msb ? _roundMask_T_127 : 54'h0; // @[primitives.scala 62:24]
  wire [53:0] _GEN_9 = {{53'd0}, doShiftSigDown1}; // @[RoundAnyRawFNToRecFN.scala 158:23]
  wire [53:0] _roundMask_T_129 = _roundMask_T_128 | _GEN_9; // @[RoundAnyRawFNToRecFN.scala 158:23]
  wire [55:0] roundMask = {_roundMask_T_129,2'h3}; // @[RoundAnyRawFNToRecFN.scala 158:42]
  wire [56:0] _shiftedRoundMask_T = {1'h0,_roundMask_T_129,2'h3}; // @[RoundAnyRawFNToRecFN.scala 161:41]
  wire [55:0] shiftedRoundMask = _shiftedRoundMask_T[56:1]; // @[RoundAnyRawFNToRecFN.scala 161:53]
  wire [55:0] _roundPosMask_T = ~shiftedRoundMask; // @[RoundAnyRawFNToRecFN.scala 162:28]
  wire [55:0] roundPosMask = _roundPosMask_T & roundMask; // @[RoundAnyRawFNToRecFN.scala 162:46]
  wire [55:0] _roundPosBit_T = io_in_sig & roundPosMask; // @[RoundAnyRawFNToRecFN.scala 163:40]
  wire  roundPosBit = |_roundPosBit_T; // @[RoundAnyRawFNToRecFN.scala 163:56]
  wire [55:0] _anyRoundExtra_T = io_in_sig & shiftedRoundMask; // @[RoundAnyRawFNToRecFN.scala 164:42]
  wire  anyRoundExtra = |_anyRoundExtra_T; // @[RoundAnyRawFNToRecFN.scala 164:62]
  wire  anyRound = roundPosBit | anyRoundExtra; // @[RoundAnyRawFNToRecFN.scala 165:36]
  wire  _roundIncr_T = roundingMode_near_even | roundingMode_near_maxMag; // @[RoundAnyRawFNToRecFN.scala 168:38]
  wire  _roundIncr_T_1 = (roundingMode_near_even | roundingMode_near_maxMag) & roundPosBit; // @[RoundAnyRawFNToRecFN.scala 168:67]
  wire  _roundIncr_T_2 = roundMagUp & anyRound; // @[RoundAnyRawFNToRecFN.scala 170:29]
  wire  roundIncr = _roundIncr_T_1 | _roundIncr_T_2; // @[RoundAnyRawFNToRecFN.scala 169:31]
  wire [55:0] _roundedSig_T = io_in_sig | roundMask; // @[RoundAnyRawFNToRecFN.scala 173:32]
  wire [54:0] _roundedSig_T_2 = _roundedSig_T[55:2] + 54'h1; // @[RoundAnyRawFNToRecFN.scala 173:49]
  wire  _roundedSig_T_4 = ~anyRoundExtra; // @[RoundAnyRawFNToRecFN.scala 175:30]
  wire [54:0] _roundedSig_T_7 = roundingMode_near_even & roundPosBit & _roundedSig_T_4 ? roundMask[55:1] : 55'h0; // @[RoundAnyRawFNToRecFN.scala 174:25]
  wire [54:0] _roundedSig_T_8 = ~_roundedSig_T_7; // @[RoundAnyRawFNToRecFN.scala 174:21]
  wire [54:0] _roundedSig_T_9 = _roundedSig_T_2 & _roundedSig_T_8; // @[RoundAnyRawFNToRecFN.scala 173:57]
  wire [55:0] _roundedSig_T_10 = ~roundMask; // @[RoundAnyRawFNToRecFN.scala 179:32]
  wire [55:0] _roundedSig_T_11 = io_in_sig & _roundedSig_T_10; // @[RoundAnyRawFNToRecFN.scala 179:30]
  wire [54:0] _roundedSig_T_15 = roundingMode_odd & anyRound ? roundPosMask[55:1] : 55'h0; // @[RoundAnyRawFNToRecFN.scala 180:24]
  wire [54:0] _GEN_10 = {{1'd0}, _roundedSig_T_11[55:2]}; // @[RoundAnyRawFNToRecFN.scala 179:47]
  wire [54:0] _roundedSig_T_16 = _GEN_10 | _roundedSig_T_15; // @[RoundAnyRawFNToRecFN.scala 179:47]
  wire [54:0] roundedSig = roundIncr ? _roundedSig_T_9 : _roundedSig_T_16; // @[RoundAnyRawFNToRecFN.scala 172:16]
  wire [2:0] _sRoundedExp_T_1 = {1'b0,$signed(roundedSig[54:53])}; // @[RoundAnyRawFNToRecFN.scala 184:76]
  wire [12:0] _GEN_11 = {{10{_sRoundedExp_T_1[2]}},_sRoundedExp_T_1}; // @[RoundAnyRawFNToRecFN.scala 184:40]
  wire [13:0] sRoundedExp = $signed(io_in_sExp) + $signed(_GEN_11); // @[RoundAnyRawFNToRecFN.scala 184:40]
  wire [11:0] common_expOut = sRoundedExp[11:0]; // @[RoundAnyRawFNToRecFN.scala 186:37]
  wire [51:0] common_fractOut = doShiftSigDown1 ? roundedSig[52:1] : roundedSig[51:0]; // @[RoundAnyRawFNToRecFN.scala 188:16]
  wire [3:0] _common_overflow_T = sRoundedExp[13:10]; // @[RoundAnyRawFNToRecFN.scala 195:30]
  wire  common_overflow = $signed(_common_overflow_T) >= 4'sh3; // @[RoundAnyRawFNToRecFN.scala 195:50]
  wire  common_totalUnderflow = $signed(sRoundedExp) < 14'sh3ce; // @[RoundAnyRawFNToRecFN.scala 199:31]
  wire  unboundedRange_roundPosBit = doShiftSigDown1 ? io_in_sig[2] : io_in_sig[1]; // @[RoundAnyRawFNToRecFN.scala 202:16]
  wire  unboundedRange_anyRound = doShiftSigDown1 & io_in_sig[2] | |io_in_sig[1:0]; // @[RoundAnyRawFNToRecFN.scala 204:49]
  wire  _unboundedRange_roundIncr_T_1 = _roundIncr_T & unboundedRange_roundPosBit; // @[RoundAnyRawFNToRecFN.scala 206:67]
  wire  _unboundedRange_roundIncr_T_2 = roundMagUp & unboundedRange_anyRound; // @[RoundAnyRawFNToRecFN.scala 208:29]
  wire  unboundedRange_roundIncr = _unboundedRange_roundIncr_T_1 | _unboundedRange_roundIncr_T_2; // @[RoundAnyRawFNToRecFN.scala 207:46]
  wire  roundCarry = doShiftSigDown1 ? roundedSig[54] : roundedSig[53]; // @[RoundAnyRawFNToRecFN.scala 210:16]
  wire [1:0] _common_underflow_T = io_in_sExp[12:11]; // @[RoundAnyRawFNToRecFN.scala 219:49]
  wire  _common_underflow_T_5 = doShiftSigDown1 ? roundMask[3] : roundMask[2]; // @[RoundAnyRawFNToRecFN.scala 220:30]
  wire  _common_underflow_T_6 = anyRound & $signed(_common_underflow_T) <= 2'sh0 & _common_underflow_T_5; // @[RoundAnyRawFNToRecFN.scala 219:72]
  wire  _common_underflow_T_10 = doShiftSigDown1 ? roundMask[4] : roundMask[3]; // @[RoundAnyRawFNToRecFN.scala 222:39]
  wire  _common_underflow_T_11 = ~_common_underflow_T_10; // @[RoundAnyRawFNToRecFN.scala 222:34]
  wire  _common_underflow_T_13 = _common_underflow_T_11 & roundCarry; // @[RoundAnyRawFNToRecFN.scala 225:38]
  wire  _common_underflow_T_15 = _common_underflow_T_13 & roundPosBit & unboundedRange_roundIncr; // @[RoundAnyRawFNToRecFN.scala 226:60]
  wire  _common_underflow_T_16 = ~_common_underflow_T_15; // @[RoundAnyRawFNToRecFN.scala 221:27]
  wire  _common_underflow_T_17 = _common_underflow_T_6 & _common_underflow_T_16; // @[RoundAnyRawFNToRecFN.scala 220:76]
  wire  common_underflow = common_totalUnderflow | _common_underflow_T_17; // @[RoundAnyRawFNToRecFN.scala 216:40]
  wire  common_inexact = common_totalUnderflow | anyRound; // @[RoundAnyRawFNToRecFN.scala 229:49]
  wire  isNaNOut = io_invalidExc | io_in_isNaN; // @[RoundAnyRawFNToRecFN.scala 234:34]
  wire  notNaN_isSpecialInfOut = io_infiniteExc | io_in_isInf; // @[RoundAnyRawFNToRecFN.scala 235:49]
  wire  commonCase = ~isNaNOut & ~notNaN_isSpecialInfOut & ~io_in_isZero; // @[RoundAnyRawFNToRecFN.scala 236:61]
  wire  overflow = commonCase & common_overflow; // @[RoundAnyRawFNToRecFN.scala 237:32]
  wire  underflow = commonCase & common_underflow; // @[RoundAnyRawFNToRecFN.scala 238:32]
  wire  inexact = overflow | commonCase & common_inexact; // @[RoundAnyRawFNToRecFN.scala 239:28]
  wire  overflow_roundMagUp = _roundIncr_T | roundMagUp; // @[RoundAnyRawFNToRecFN.scala 242:60]
  wire  pegMinNonzeroMagOut = commonCase & common_totalUnderflow & (roundMagUp | roundingMode_odd); // @[RoundAnyRawFNToRecFN.scala 244:45]
  wire  pegMaxFiniteMagOut = overflow & ~overflow_roundMagUp; // @[RoundAnyRawFNToRecFN.scala 245:39]
  wire  notNaN_isInfOut = notNaN_isSpecialInfOut | overflow & overflow_roundMagUp; // @[RoundAnyRawFNToRecFN.scala 247:32]
  wire  signOut = isNaNOut ? 1'h0 : io_in_sign; // @[RoundAnyRawFNToRecFN.scala 249:22]
  wire [11:0] _expOut_T_1 = io_in_isZero | common_totalUnderflow ? 12'he00 : 12'h0; // @[RoundAnyRawFNToRecFN.scala 252:18]
  wire [11:0] _expOut_T_2 = ~_expOut_T_1; // @[RoundAnyRawFNToRecFN.scala 252:14]
  wire [11:0] _expOut_T_3 = common_expOut & _expOut_T_2; // @[RoundAnyRawFNToRecFN.scala 251:24]
  wire [11:0] _expOut_T_5 = pegMinNonzeroMagOut ? 12'hc31 : 12'h0; // @[RoundAnyRawFNToRecFN.scala 256:18]
  wire [11:0] _expOut_T_6 = ~_expOut_T_5; // @[RoundAnyRawFNToRecFN.scala 256:14]
  wire [11:0] _expOut_T_7 = _expOut_T_3 & _expOut_T_6; // @[RoundAnyRawFNToRecFN.scala 255:17]
  wire [11:0] _expOut_T_8 = pegMaxFiniteMagOut ? 12'h400 : 12'h0; // @[RoundAnyRawFNToRecFN.scala 260:18]
  wire [11:0] _expOut_T_9 = ~_expOut_T_8; // @[RoundAnyRawFNToRecFN.scala 260:14]
  wire [11:0] _expOut_T_10 = _expOut_T_7 & _expOut_T_9; // @[RoundAnyRawFNToRecFN.scala 259:17]
  wire [11:0] _expOut_T_11 = notNaN_isInfOut ? 12'h200 : 12'h0; // @[RoundAnyRawFNToRecFN.scala 264:18]
  wire [11:0] _expOut_T_12 = ~_expOut_T_11; // @[RoundAnyRawFNToRecFN.scala 264:14]
  wire [11:0] _expOut_T_13 = _expOut_T_10 & _expOut_T_12; // @[RoundAnyRawFNToRecFN.scala 263:17]
  wire [11:0] _expOut_T_14 = pegMinNonzeroMagOut ? 12'h3ce : 12'h0; // @[RoundAnyRawFNToRecFN.scala 268:16]
  wire [11:0] _expOut_T_15 = _expOut_T_13 | _expOut_T_14; // @[RoundAnyRawFNToRecFN.scala 267:18]
  wire [11:0] _expOut_T_16 = pegMaxFiniteMagOut ? 12'hbff : 12'h0; // @[RoundAnyRawFNToRecFN.scala 272:16]
  wire [11:0] _expOut_T_17 = _expOut_T_15 | _expOut_T_16; // @[RoundAnyRawFNToRecFN.scala 271:15]
  wire [11:0] _expOut_T_18 = notNaN_isInfOut ? 12'hc00 : 12'h0; // @[RoundAnyRawFNToRecFN.scala 276:16]
  wire [11:0] _expOut_T_19 = _expOut_T_17 | _expOut_T_18; // @[RoundAnyRawFNToRecFN.scala 275:15]
  wire [11:0] _expOut_T_20 = isNaNOut ? 12'he00 : 12'h0; // @[RoundAnyRawFNToRecFN.scala 277:16]
  wire [11:0] expOut = _expOut_T_19 | _expOut_T_20; // @[RoundAnyRawFNToRecFN.scala 276:73]
  wire [51:0] _fractOut_T_2 = isNaNOut ? 52'h8000000000000 : 52'h0; // @[RoundAnyRawFNToRecFN.scala 280:16]
  wire [51:0] _fractOut_T_3 = isNaNOut | io_in_isZero | common_totalUnderflow ? _fractOut_T_2 : common_fractOut; // @[RoundAnyRawFNToRecFN.scala 279:12]
  wire [51:0] _fractOut_T_5 = pegMaxFiniteMagOut ? 52'hfffffffffffff : 52'h0; // @[Bitwise.scala 77:12]
  wire [51:0] fractOut = _fractOut_T_3 | _fractOut_T_5; // @[RoundAnyRawFNToRecFN.scala 282:11]
  wire [12:0] _io_out_T = {signOut,expOut}; // @[RoundAnyRawFNToRecFN.scala 285:23]
  wire [3:0] _io_exceptionFlags_T_2 = {io_invalidExc,io_infiniteExc,overflow,underflow}; // @[RoundAnyRawFNToRecFN.scala 287:53]
  assign io_out = {_io_out_T,fractOut}; // @[RoundAnyRawFNToRecFN.scala 285:33]
  assign io_exceptionFlags = {_io_exceptionFlags_T_2,inexact}; // @[RoundAnyRawFNToRecFN.scala 287:66]
endmodule

module RoundRawFNToRecFN_1(
  input         io_invalidExc,
  input         io_in_isNaN,
  input         io_in_isInf,
  input         io_in_isZero,
  input         io_in_sign,
  input  [12:0] io_in_sExp,
  input  [55:0] io_in_sig,
  input  [2:0]  io_roundingMode,
  output [64:0] io_out,
  output [4:0]  io_exceptionFlags
);
  wire  roundAnyRawFNToRecFN_io_invalidExc; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire  roundAnyRawFNToRecFN_io_infiniteExc; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire  roundAnyRawFNToRecFN_io_in_isNaN; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire  roundAnyRawFNToRecFN_io_in_isInf; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire  roundAnyRawFNToRecFN_io_in_isZero; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire  roundAnyRawFNToRecFN_io_in_sign; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire [12:0] roundAnyRawFNToRecFN_io_in_sExp; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire [55:0] roundAnyRawFNToRecFN_io_in_sig; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire [2:0] roundAnyRawFNToRecFN_io_roundingMode; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire [64:0] roundAnyRawFNToRecFN_io_out; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire [4:0] roundAnyRawFNToRecFN_io_exceptionFlags; // @[RoundAnyRawFNToRecFN.scala 308:15]
  RoundAnyRawFNToRecFN_4 roundAnyRawFNToRecFN ( // @[RoundAnyRawFNToRecFN.scala 308:15]
    .io_invalidExc(roundAnyRawFNToRecFN_io_invalidExc),
    .io_infiniteExc(roundAnyRawFNToRecFN_io_infiniteExc),
    .io_in_isNaN(roundAnyRawFNToRecFN_io_in_isNaN),
    .io_in_isInf(roundAnyRawFNToRecFN_io_in_isInf),
    .io_in_isZero(roundAnyRawFNToRecFN_io_in_isZero),
    .io_in_sign(roundAnyRawFNToRecFN_io_in_sign),
    .io_in_sExp(roundAnyRawFNToRecFN_io_in_sExp),
    .io_in_sig(roundAnyRawFNToRecFN_io_in_sig),
    .io_roundingMode(roundAnyRawFNToRecFN_io_roundingMode),
    .io_out(roundAnyRawFNToRecFN_io_out),
    .io_exceptionFlags(roundAnyRawFNToRecFN_io_exceptionFlags)
  );
  assign io_out = roundAnyRawFNToRecFN_io_out; // @[RoundAnyRawFNToRecFN.scala 316:23]
  assign io_exceptionFlags = roundAnyRawFNToRecFN_io_exceptionFlags; // @[RoundAnyRawFNToRecFN.scala 317:23]
  assign roundAnyRawFNToRecFN_io_invalidExc = io_invalidExc; // @[RoundAnyRawFNToRecFN.scala 311:44]
  assign roundAnyRawFNToRecFN_io_infiniteExc = 1'h0; // @[RoundAnyRawFNToRecFN.scala 312:44]
  assign roundAnyRawFNToRecFN_io_in_isNaN = io_in_isNaN; // @[RoundAnyRawFNToRecFN.scala 313:44]
  assign roundAnyRawFNToRecFN_io_in_isInf = io_in_isInf; // @[RoundAnyRawFNToRecFN.scala 313:44]
  assign roundAnyRawFNToRecFN_io_in_isZero = io_in_isZero; // @[RoundAnyRawFNToRecFN.scala 313:44]
  assign roundAnyRawFNToRecFN_io_in_sign = io_in_sign; // @[RoundAnyRawFNToRecFN.scala 313:44]
  assign roundAnyRawFNToRecFN_io_in_sExp = io_in_sExp; // @[RoundAnyRawFNToRecFN.scala 313:44]
  assign roundAnyRawFNToRecFN_io_in_sig = io_in_sig; // @[RoundAnyRawFNToRecFN.scala 313:44]
  assign roundAnyRawFNToRecFN_io_roundingMode = io_roundingMode; // @[RoundAnyRawFNToRecFN.scala 314:44]
endmodule

module MulAddRecFNPipe_1(
  input         clock,
  input         reset,
  input         io_validin,
  input  [1:0]  io_op,
  input  [64:0] io_a,
  input  [64:0] io_b,
  input  [64:0] io_c,
  input  [2:0]  io_roundingMode,
  output [64:0] io_out,
  output [4:0]  io_exceptionFlags,
  output        io_validout
);
`ifdef RANDOMIZE_REG_INIT
  reg [31:0] _RAND_0;
  reg [31:0] _RAND_1;
  reg [31:0] _RAND_2;
  reg [31:0] _RAND_3;
  reg [31:0] _RAND_4;
  reg [31:0] _RAND_5;
  reg [31:0] _RAND_6;
  reg [31:0] _RAND_7;
  reg [31:0] _RAND_8;
  reg [31:0] _RAND_9;
  reg [31:0] _RAND_10;
  reg [31:0] _RAND_11;
  reg [31:0] _RAND_12;
  reg [31:0] _RAND_13;
  reg [63:0] _RAND_14;
  reg [31:0] _RAND_15;
  reg [127:0] _RAND_16;
  reg [31:0] _RAND_17;
  reg [31:0] _RAND_18;
  reg [31:0] _RAND_19;
  reg [31:0] _RAND_20;
  reg [31:0] _RAND_21;
  reg [31:0] _RAND_22;
  reg [31:0] _RAND_23;
  reg [31:0] _RAND_24;
  reg [31:0] _RAND_25;
  reg [63:0] _RAND_26;
  reg [31:0] _RAND_27;
  reg [31:0] _RAND_28;
`endif // RANDOMIZE_REG_INIT
  wire [1:0] mulAddRecFNToRaw_preMul_io_op; // @[FPU.scala 646:41]
  wire [64:0] mulAddRecFNToRaw_preMul_io_a; // @[FPU.scala 646:41]
  wire [64:0] mulAddRecFNToRaw_preMul_io_b; // @[FPU.scala 646:41]
  wire [64:0] mulAddRecFNToRaw_preMul_io_c; // @[FPU.scala 646:41]
  wire [52:0] mulAddRecFNToRaw_preMul_io_mulAddA; // @[FPU.scala 646:41]
  wire [52:0] mulAddRecFNToRaw_preMul_io_mulAddB; // @[FPU.scala 646:41]
  wire [105:0] mulAddRecFNToRaw_preMul_io_mulAddC; // @[FPU.scala 646:41]
  wire  mulAddRecFNToRaw_preMul_io_toPostMul_isSigNaNAny; // @[FPU.scala 646:41]
  wire  mulAddRecFNToRaw_preMul_io_toPostMul_isNaNAOrB; // @[FPU.scala 646:41]
  wire  mulAddRecFNToRaw_preMul_io_toPostMul_isInfA; // @[FPU.scala 646:41]
  wire  mulAddRecFNToRaw_preMul_io_toPostMul_isZeroA; // @[FPU.scala 646:41]
  wire  mulAddRecFNToRaw_preMul_io_toPostMul_isInfB; // @[FPU.scala 646:41]
  wire  mulAddRecFNToRaw_preMul_io_toPostMul_isZeroB; // @[FPU.scala 646:41]
  wire  mulAddRecFNToRaw_preMul_io_toPostMul_signProd; // @[FPU.scala 646:41]
  wire  mulAddRecFNToRaw_preMul_io_toPostMul_isNaNC; // @[FPU.scala 646:41]
  wire  mulAddRecFNToRaw_preMul_io_toPostMul_isInfC; // @[FPU.scala 646:41]
  wire  mulAddRecFNToRaw_preMul_io_toPostMul_isZeroC; // @[FPU.scala 646:41]
  wire [12:0] mulAddRecFNToRaw_preMul_io_toPostMul_sExpSum; // @[FPU.scala 646:41]
  wire  mulAddRecFNToRaw_preMul_io_toPostMul_doSubMags; // @[FPU.scala 646:41]
  wire  mulAddRecFNToRaw_preMul_io_toPostMul_CIsDominant; // @[FPU.scala 646:41]
  wire [5:0] mulAddRecFNToRaw_preMul_io_toPostMul_CDom_CAlignDist; // @[FPU.scala 646:41]
  wire [54:0] mulAddRecFNToRaw_preMul_io_toPostMul_highAlignedSigC; // @[FPU.scala 646:41]
  wire  mulAddRecFNToRaw_preMul_io_toPostMul_bit0AlignedSigC; // @[FPU.scala 646:41]
  wire  mulAddRecFNToRaw_postMul_io_fromPreMul_isSigNaNAny; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_fromPreMul_isNaNAOrB; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_fromPreMul_isInfA; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_fromPreMul_isZeroA; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_fromPreMul_isInfB; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_fromPreMul_isZeroB; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_fromPreMul_signProd; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_fromPreMul_isNaNC; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_fromPreMul_isInfC; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_fromPreMul_isZeroC; // @[FPU.scala 647:42]
  wire [12:0] mulAddRecFNToRaw_postMul_io_fromPreMul_sExpSum; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_fromPreMul_doSubMags; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_fromPreMul_CIsDominant; // @[FPU.scala 647:42]
  wire [5:0] mulAddRecFNToRaw_postMul_io_fromPreMul_CDom_CAlignDist; // @[FPU.scala 647:42]
  wire [54:0] mulAddRecFNToRaw_postMul_io_fromPreMul_highAlignedSigC; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_fromPreMul_bit0AlignedSigC; // @[FPU.scala 647:42]
  wire [106:0] mulAddRecFNToRaw_postMul_io_mulAddResult; // @[FPU.scala 647:42]
  wire [2:0] mulAddRecFNToRaw_postMul_io_roundingMode; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_invalidExc; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_rawOut_isNaN; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_rawOut_isInf; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_rawOut_isZero; // @[FPU.scala 647:42]
  wire  mulAddRecFNToRaw_postMul_io_rawOut_sign; // @[FPU.scala 647:42]
  wire [12:0] mulAddRecFNToRaw_postMul_io_rawOut_sExp; // @[FPU.scala 647:42]
  wire [55:0] mulAddRecFNToRaw_postMul_io_rawOut_sig; // @[FPU.scala 647:42]
  wire  roundRawFNToRecFN_io_invalidExc; // @[FPU.scala 674:35]
  wire  roundRawFNToRecFN_io_in_isNaN; // @[FPU.scala 674:35]
  wire  roundRawFNToRecFN_io_in_isInf; // @[FPU.scala 674:35]
  wire  roundRawFNToRecFN_io_in_isZero; // @[FPU.scala 674:35]
  wire  roundRawFNToRecFN_io_in_sign; // @[FPU.scala 674:35]
  wire [12:0] roundRawFNToRecFN_io_in_sExp; // @[FPU.scala 674:35]
  wire [55:0] roundRawFNToRecFN_io_in_sig; // @[FPU.scala 674:35]
  wire [2:0] roundRawFNToRecFN_io_roundingMode; // @[FPU.scala 674:35]
  wire [64:0] roundRawFNToRecFN_io_out; // @[FPU.scala 674:35]
  wire [4:0] roundRawFNToRecFN_io_exceptionFlags; // @[FPU.scala 674:35]
  wire [105:0] _mulAddResult_T = mulAddRecFNToRaw_preMul_io_mulAddA * mulAddRecFNToRaw_preMul_io_mulAddB; // @[FPU.scala 655:45]
  wire [106:0] mulAddResult = _mulAddResult_T + mulAddRecFNToRaw_preMul_io_mulAddC; // @[FPU.scala 656:50]
  reg  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isSigNaNAny; // @[Reg.scala 19:16]
  reg  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isNaNAOrB; // @[Reg.scala 19:16]
  reg  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isInfA; // @[Reg.scala 19:16]
  reg  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isZeroA; // @[Reg.scala 19:16]
  reg  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isInfB; // @[Reg.scala 19:16]
  reg  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isZeroB; // @[Reg.scala 19:16]
  reg  mulAddRecFNToRaw_postMul_io_fromPreMul_b_signProd; // @[Reg.scala 19:16]
  reg  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isNaNC; // @[Reg.scala 19:16]
  reg  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isInfC; // @[Reg.scala 19:16]
  reg  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isZeroC; // @[Reg.scala 19:16]
  reg [12:0] mulAddRecFNToRaw_postMul_io_fromPreMul_b_sExpSum; // @[Reg.scala 19:16]
  reg  mulAddRecFNToRaw_postMul_io_fromPreMul_b_doSubMags; // @[Reg.scala 19:16]
  reg  mulAddRecFNToRaw_postMul_io_fromPreMul_b_CIsDominant; // @[Reg.scala 19:16]
  reg [5:0] mulAddRecFNToRaw_postMul_io_fromPreMul_b_CDom_CAlignDist; // @[Reg.scala 19:16]
  reg [54:0] mulAddRecFNToRaw_postMul_io_fromPreMul_b_highAlignedSigC; // @[Reg.scala 19:16]
  reg  mulAddRecFNToRaw_postMul_io_fromPreMul_b_bit0AlignedSigC; // @[Reg.scala 19:16]
  reg [106:0] mulAddRecFNToRaw_postMul_io_mulAddResult_b; // @[Reg.scala 19:16]
  reg [2:0] mulAddRecFNToRaw_postMul_io_roundingMode_b; // @[Reg.scala 19:16]
  reg [2:0] roundingMode_stage0_b; // @[Reg.scala 19:16]
  reg  valid_stage0_v; // @[Valid.scala 130:22]
  reg  roundRawFNToRecFN_io_invalidExc_b; // @[Reg.scala 19:16]
  reg  roundRawFNToRecFN_io_in_b_isNaN; // @[Reg.scala 19:16]
  reg  roundRawFNToRecFN_io_in_b_isInf; // @[Reg.scala 19:16]
  reg  roundRawFNToRecFN_io_in_b_isZero; // @[Reg.scala 19:16]
  reg  roundRawFNToRecFN_io_in_b_sign; // @[Reg.scala 19:16]
  reg [12:0] roundRawFNToRecFN_io_in_b_sExp; // @[Reg.scala 19:16]
  reg [55:0] roundRawFNToRecFN_io_in_b_sig; // @[Reg.scala 19:16]
  reg [2:0] roundRawFNToRecFN_io_roundingMode_b; // @[Reg.scala 19:16]
  reg  io_validout_v; // @[Valid.scala 130:22]
  MulAddRecFNToRaw_preMul_1 mulAddRecFNToRaw_preMul ( // @[FPU.scala 646:41]
    .io_op(mulAddRecFNToRaw_preMul_io_op),
    .io_a(mulAddRecFNToRaw_preMul_io_a),
    .io_b(mulAddRecFNToRaw_preMul_io_b),
    .io_c(mulAddRecFNToRaw_preMul_io_c),
    .io_mulAddA(mulAddRecFNToRaw_preMul_io_mulAddA),
    .io_mulAddB(mulAddRecFNToRaw_preMul_io_mulAddB),
    .io_mulAddC(mulAddRecFNToRaw_preMul_io_mulAddC),
    .io_toPostMul_isSigNaNAny(mulAddRecFNToRaw_preMul_io_toPostMul_isSigNaNAny),
    .io_toPostMul_isNaNAOrB(mulAddRecFNToRaw_preMul_io_toPostMul_isNaNAOrB),
    .io_toPostMul_isInfA(mulAddRecFNToRaw_preMul_io_toPostMul_isInfA),
    .io_toPostMul_isZeroA(mulAddRecFNToRaw_preMul_io_toPostMul_isZeroA),
    .io_toPostMul_isInfB(mulAddRecFNToRaw_preMul_io_toPostMul_isInfB),
    .io_toPostMul_isZeroB(mulAddRecFNToRaw_preMul_io_toPostMul_isZeroB),
    .io_toPostMul_signProd(mulAddRecFNToRaw_preMul_io_toPostMul_signProd),
    .io_toPostMul_isNaNC(mulAddRecFNToRaw_preMul_io_toPostMul_isNaNC),
    .io_toPostMul_isInfC(mulAddRecFNToRaw_preMul_io_toPostMul_isInfC),
    .io_toPostMul_isZeroC(mulAddRecFNToRaw_preMul_io_toPostMul_isZeroC),
    .io_toPostMul_sExpSum(mulAddRecFNToRaw_preMul_io_toPostMul_sExpSum),
    .io_toPostMul_doSubMags(mulAddRecFNToRaw_preMul_io_toPostMul_doSubMags),
    .io_toPostMul_CIsDominant(mulAddRecFNToRaw_preMul_io_toPostMul_CIsDominant),
    .io_toPostMul_CDom_CAlignDist(mulAddRecFNToRaw_preMul_io_toPostMul_CDom_CAlignDist),
    .io_toPostMul_highAlignedSigC(mulAddRecFNToRaw_preMul_io_toPostMul_highAlignedSigC),
    .io_toPostMul_bit0AlignedSigC(mulAddRecFNToRaw_preMul_io_toPostMul_bit0AlignedSigC)
  );
  MulAddRecFNToRaw_postMul_1 mulAddRecFNToRaw_postMul ( // @[FPU.scala 647:42]
    .io_fromPreMul_isSigNaNAny(mulAddRecFNToRaw_postMul_io_fromPreMul_isSigNaNAny),
    .io_fromPreMul_isNaNAOrB(mulAddRecFNToRaw_postMul_io_fromPreMul_isNaNAOrB),
    .io_fromPreMul_isInfA(mulAddRecFNToRaw_postMul_io_fromPreMul_isInfA),
    .io_fromPreMul_isZeroA(mulAddRecFNToRaw_postMul_io_fromPreMul_isZeroA),
    .io_fromPreMul_isInfB(mulAddRecFNToRaw_postMul_io_fromPreMul_isInfB),
    .io_fromPreMul_isZeroB(mulAddRecFNToRaw_postMul_io_fromPreMul_isZeroB),
    .io_fromPreMul_signProd(mulAddRecFNToRaw_postMul_io_fromPreMul_signProd),
    .io_fromPreMul_isNaNC(mulAddRecFNToRaw_postMul_io_fromPreMul_isNaNC),
    .io_fromPreMul_isInfC(mulAddRecFNToRaw_postMul_io_fromPreMul_isInfC),
    .io_fromPreMul_isZeroC(mulAddRecFNToRaw_postMul_io_fromPreMul_isZeroC),
    .io_fromPreMul_sExpSum(mulAddRecFNToRaw_postMul_io_fromPreMul_sExpSum),
    .io_fromPreMul_doSubMags(mulAddRecFNToRaw_postMul_io_fromPreMul_doSubMags),
    .io_fromPreMul_CIsDominant(mulAddRecFNToRaw_postMul_io_fromPreMul_CIsDominant),
    .io_fromPreMul_CDom_CAlignDist(mulAddRecFNToRaw_postMul_io_fromPreMul_CDom_CAlignDist),
    .io_fromPreMul_highAlignedSigC(mulAddRecFNToRaw_postMul_io_fromPreMul_highAlignedSigC),
    .io_fromPreMul_bit0AlignedSigC(mulAddRecFNToRaw_postMul_io_fromPreMul_bit0AlignedSigC),
    .io_mulAddResult(mulAddRecFNToRaw_postMul_io_mulAddResult),
    .io_roundingMode(mulAddRecFNToRaw_postMul_io_roundingMode),
    .io_invalidExc(mulAddRecFNToRaw_postMul_io_invalidExc),
    .io_rawOut_isNaN(mulAddRecFNToRaw_postMul_io_rawOut_isNaN),
    .io_rawOut_isInf(mulAddRecFNToRaw_postMul_io_rawOut_isInf),
    .io_rawOut_isZero(mulAddRecFNToRaw_postMul_io_rawOut_isZero),
    .io_rawOut_sign(mulAddRecFNToRaw_postMul_io_rawOut_sign),
    .io_rawOut_sExp(mulAddRecFNToRaw_postMul_io_rawOut_sExp),
    .io_rawOut_sig(mulAddRecFNToRaw_postMul_io_rawOut_sig)
  );
  RoundRawFNToRecFN_1 roundRawFNToRecFN ( // @[FPU.scala 674:35]
    .io_invalidExc(roundRawFNToRecFN_io_invalidExc),
    .io_in_isNaN(roundRawFNToRecFN_io_in_isNaN),
    .io_in_isInf(roundRawFNToRecFN_io_in_isInf),
    .io_in_isZero(roundRawFNToRecFN_io_in_isZero),
    .io_in_sign(roundRawFNToRecFN_io_in_sign),
    .io_in_sExp(roundRawFNToRecFN_io_in_sExp),
    .io_in_sig(roundRawFNToRecFN_io_in_sig),
    .io_roundingMode(roundRawFNToRecFN_io_roundingMode),
    .io_out(roundRawFNToRecFN_io_out),
    .io_exceptionFlags(roundRawFNToRecFN_io_exceptionFlags)
  );
  assign io_out = roundRawFNToRecFN_io_out; // @[FPU.scala 685:23]
  assign io_exceptionFlags = roundRawFNToRecFN_io_exceptionFlags; // @[FPU.scala 686:23]
  assign io_validout = io_validout_v; // @[Valid.scala 125:21 126:17]
  assign mulAddRecFNToRaw_preMul_io_op = io_op; // @[FPU.scala 649:35]
  assign mulAddRecFNToRaw_preMul_io_a = io_a; // @[FPU.scala 650:35]
  assign mulAddRecFNToRaw_preMul_io_b = io_b; // @[FPU.scala 651:35]
  assign mulAddRecFNToRaw_preMul_io_c = io_c; // @[FPU.scala 652:35]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_isSigNaNAny = mulAddRecFNToRaw_postMul_io_fromPreMul_b_isSigNaNAny; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_isNaNAOrB = mulAddRecFNToRaw_postMul_io_fromPreMul_b_isNaNAOrB; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_isInfA = mulAddRecFNToRaw_postMul_io_fromPreMul_b_isInfA; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_isZeroA = mulAddRecFNToRaw_postMul_io_fromPreMul_b_isZeroA; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_isInfB = mulAddRecFNToRaw_postMul_io_fromPreMul_b_isInfB; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_isZeroB = mulAddRecFNToRaw_postMul_io_fromPreMul_b_isZeroB; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_signProd = mulAddRecFNToRaw_postMul_io_fromPreMul_b_signProd; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_isNaNC = mulAddRecFNToRaw_postMul_io_fromPreMul_b_isNaNC; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_isInfC = mulAddRecFNToRaw_postMul_io_fromPreMul_b_isInfC; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_isZeroC = mulAddRecFNToRaw_postMul_io_fromPreMul_b_isZeroC; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_sExpSum = mulAddRecFNToRaw_postMul_io_fromPreMul_b_sExpSum; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_doSubMags = mulAddRecFNToRaw_postMul_io_fromPreMul_b_doSubMags; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_CIsDominant = mulAddRecFNToRaw_postMul_io_fromPreMul_b_CIsDominant; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_CDom_CAlignDist =
    mulAddRecFNToRaw_postMul_io_fromPreMul_b_CDom_CAlignDist; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_highAlignedSigC =
    mulAddRecFNToRaw_postMul_io_fromPreMul_b_highAlignedSigC; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_fromPreMul_bit0AlignedSigC =
    mulAddRecFNToRaw_postMul_io_fromPreMul_b_bit0AlignedSigC; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_mulAddResult = mulAddRecFNToRaw_postMul_io_mulAddResult_b; // @[Valid.scala 125:21 127:16]
  assign mulAddRecFNToRaw_postMul_io_roundingMode = mulAddRecFNToRaw_postMul_io_roundingMode_b; // @[Valid.scala 125:21 127:16]
  assign roundRawFNToRecFN_io_invalidExc = roundRawFNToRecFN_io_invalidExc_b; // @[Valid.scala 125:21 127:16]
  assign roundRawFNToRecFN_io_in_isNaN = roundRawFNToRecFN_io_in_b_isNaN; // @[Valid.scala 125:21 127:16]
  assign roundRawFNToRecFN_io_in_isInf = roundRawFNToRecFN_io_in_b_isInf; // @[Valid.scala 125:21 127:16]
  assign roundRawFNToRecFN_io_in_isZero = roundRawFNToRecFN_io_in_b_isZero; // @[Valid.scala 125:21 127:16]
  assign roundRawFNToRecFN_io_in_sign = roundRawFNToRecFN_io_in_b_sign; // @[Valid.scala 125:21 127:16]
  assign roundRawFNToRecFN_io_in_sExp = roundRawFNToRecFN_io_in_b_sExp; // @[Valid.scala 125:21 127:16]
  assign roundRawFNToRecFN_io_in_sig = roundRawFNToRecFN_io_in_b_sig; // @[Valid.scala 125:21 127:16]
  assign roundRawFNToRecFN_io_roundingMode = roundRawFNToRecFN_io_roundingMode_b; // @[Valid.scala 125:21 127:16]
  always @(posedge clock) begin
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_isSigNaNAny <= mulAddRecFNToRaw_preMul_io_toPostMul_isSigNaNAny; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_isNaNAOrB <= mulAddRecFNToRaw_preMul_io_toPostMul_isNaNAOrB; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_isInfA <= mulAddRecFNToRaw_preMul_io_toPostMul_isInfA; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_isZeroA <= mulAddRecFNToRaw_preMul_io_toPostMul_isZeroA; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_isInfB <= mulAddRecFNToRaw_preMul_io_toPostMul_isInfB; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_isZeroB <= mulAddRecFNToRaw_preMul_io_toPostMul_isZeroB; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_signProd <= mulAddRecFNToRaw_preMul_io_toPostMul_signProd; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_isNaNC <= mulAddRecFNToRaw_preMul_io_toPostMul_isNaNC; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_isInfC <= mulAddRecFNToRaw_preMul_io_toPostMul_isInfC; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_isZeroC <= mulAddRecFNToRaw_preMul_io_toPostMul_isZeroC; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_sExpSum <= mulAddRecFNToRaw_preMul_io_toPostMul_sExpSum; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_doSubMags <= mulAddRecFNToRaw_preMul_io_toPostMul_doSubMags; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_CIsDominant <= mulAddRecFNToRaw_preMul_io_toPostMul_CIsDominant; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_CDom_CAlignDist <= mulAddRecFNToRaw_preMul_io_toPostMul_CDom_CAlignDist; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_highAlignedSigC <= mulAddRecFNToRaw_preMul_io_toPostMul_highAlignedSigC; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_fromPreMul_b_bit0AlignedSigC <= mulAddRecFNToRaw_preMul_io_toPostMul_bit0AlignedSigC; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_mulAddResult_b <= mulAddResult; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      mulAddRecFNToRaw_postMul_io_roundingMode_b <= io_roundingMode; // @[Reg.scala 20:22]
    end
    if (io_validin) begin // @[Reg.scala 20:18]
      roundingMode_stage0_b <= io_roundingMode; // @[Reg.scala 20:22]
    end
    if (reset) begin // @[Valid.scala 130:22]
      valid_stage0_v <= 1'h0; // @[Valid.scala 130:22]
    end else begin
      valid_stage0_v <= io_validin; // @[Valid.scala 130:22]
    end
    if (valid_stage0_v) begin // @[Reg.scala 20:18]
      roundRawFNToRecFN_io_invalidExc_b <= mulAddRecFNToRaw_postMul_io_invalidExc; // @[Reg.scala 20:22]
    end
    if (valid_stage0_v) begin // @[Reg.scala 20:18]
      roundRawFNToRecFN_io_in_b_isNaN <= mulAddRecFNToRaw_postMul_io_rawOut_isNaN; // @[Reg.scala 20:22]
    end
    if (valid_stage0_v) begin // @[Reg.scala 20:18]
      roundRawFNToRecFN_io_in_b_isInf <= mulAddRecFNToRaw_postMul_io_rawOut_isInf; // @[Reg.scala 20:22]
    end
    if (valid_stage0_v) begin // @[Reg.scala 20:18]
      roundRawFNToRecFN_io_in_b_isZero <= mulAddRecFNToRaw_postMul_io_rawOut_isZero; // @[Reg.scala 20:22]
    end
    if (valid_stage0_v) begin // @[Reg.scala 20:18]
      roundRawFNToRecFN_io_in_b_sign <= mulAddRecFNToRaw_postMul_io_rawOut_sign; // @[Reg.scala 20:22]
    end
    if (valid_stage0_v) begin // @[Reg.scala 20:18]
      roundRawFNToRecFN_io_in_b_sExp <= mulAddRecFNToRaw_postMul_io_rawOut_sExp; // @[Reg.scala 20:22]
    end
    if (valid_stage0_v) begin // @[Reg.scala 20:18]
      roundRawFNToRecFN_io_in_b_sig <= mulAddRecFNToRaw_postMul_io_rawOut_sig; // @[Reg.scala 20:22]
    end
    if (valid_stage0_v) begin // @[Reg.scala 20:18]
      roundRawFNToRecFN_io_roundingMode_b <= roundingMode_stage0_b; // @[Reg.scala 20:22]
    end
    if (reset) begin // @[Valid.scala 130:22]
      io_validout_v <= 1'h0; // @[Valid.scala 130:22]
    end else begin
      io_validout_v <= valid_stage0_v; // @[Valid.scala 130:22]
    end
  end
// Register and memory initialization
`ifdef RANDOMIZE_GARBAGE_ASSIGN
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_INVALID_ASSIGN
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_REG_INIT
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_MEM_INIT
`define RANDOMIZE
`endif
`ifndef RANDOM
`define RANDOM $random
`endif
`ifdef RANDOMIZE_MEM_INIT
  integer initvar;
`endif
`ifndef SYNTHESIS
`ifdef FIRRTL_BEFORE_INITIAL
`FIRRTL_BEFORE_INITIAL
`endif
initial begin
  `ifdef RANDOMIZE
    `ifdef INIT_RANDOM
      `INIT_RANDOM
    `endif
    `ifndef VERILATOR
      `ifdef RANDOMIZE_DELAY
        #`RANDOMIZE_DELAY begin end
      `else
        #0.002 begin end
      `endif
    `endif
`ifdef RANDOMIZE_REG_INIT
  _RAND_0 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isSigNaNAny = _RAND_0[0:0];
  _RAND_1 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isNaNAOrB = _RAND_1[0:0];
  _RAND_2 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isInfA = _RAND_2[0:0];
  _RAND_3 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isZeroA = _RAND_3[0:0];
  _RAND_4 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isInfB = _RAND_4[0:0];
  _RAND_5 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isZeroB = _RAND_5[0:0];
  _RAND_6 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_signProd = _RAND_6[0:0];
  _RAND_7 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isNaNC = _RAND_7[0:0];
  _RAND_8 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isInfC = _RAND_8[0:0];
  _RAND_9 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_isZeroC = _RAND_9[0:0];
  _RAND_10 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_sExpSum = _RAND_10[12:0];
  _RAND_11 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_doSubMags = _RAND_11[0:0];
  _RAND_12 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_CIsDominant = _RAND_12[0:0];
  _RAND_13 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_CDom_CAlignDist = _RAND_13[5:0];
  _RAND_14 = {2{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_highAlignedSigC = _RAND_14[54:0];
  _RAND_15 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_fromPreMul_b_bit0AlignedSigC = _RAND_15[0:0];
  _RAND_16 = {4{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_mulAddResult_b = _RAND_16[106:0];
  _RAND_17 = {1{`RANDOM}};
  mulAddRecFNToRaw_postMul_io_roundingMode_b = _RAND_17[2:0];
  _RAND_18 = {1{`RANDOM}};
  roundingMode_stage0_b = _RAND_18[2:0];
  _RAND_19 = {1{`RANDOM}};
  valid_stage0_v = _RAND_19[0:0];
  _RAND_20 = {1{`RANDOM}};
  roundRawFNToRecFN_io_invalidExc_b = _RAND_20[0:0];
  _RAND_21 = {1{`RANDOM}};
  roundRawFNToRecFN_io_in_b_isNaN = _RAND_21[0:0];
  _RAND_22 = {1{`RANDOM}};
  roundRawFNToRecFN_io_in_b_isInf = _RAND_22[0:0];
  _RAND_23 = {1{`RANDOM}};
  roundRawFNToRecFN_io_in_b_isZero = _RAND_23[0:0];
  _RAND_24 = {1{`RANDOM}};
  roundRawFNToRecFN_io_in_b_sign = _RAND_24[0:0];
  _RAND_25 = {1{`RANDOM}};
  roundRawFNToRecFN_io_in_b_sExp = _RAND_25[12:0];
  _RAND_26 = {2{`RANDOM}};
  roundRawFNToRecFN_io_in_b_sig = _RAND_26[55:0];
  _RAND_27 = {1{`RANDOM}};
  roundRawFNToRecFN_io_roundingMode_b = _RAND_27[2:0];
  _RAND_28 = {1{`RANDOM}};
  io_validout_v = _RAND_28[0:0];
`endif // RANDOMIZE_REG_INIT
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule

module DivSqrtRawFN_small_1(
  input         clock,
  input         reset,
  output        io_inReady,
  input         io_inValid,
  input         io_sqrtOp,
  input         io_a_isNaN,
  input         io_a_isInf,
  input         io_a_isZero,
  input         io_a_sign,
  input  [12:0] io_a_sExp,
  input  [53:0] io_a_sig,
  input         io_b_isNaN,
  input         io_b_isInf,
  input         io_b_isZero,
  input         io_b_sign,
  input  [12:0] io_b_sExp,
  input  [53:0] io_b_sig,
  input  [2:0]  io_roundingMode,
  output        io_rawOutValid_div,
  output        io_rawOutValid_sqrt,
  output [2:0]  io_roundingModeOut,
  output        io_invalidExc,
  output        io_infiniteExc,
  output        io_rawOut_isNaN,
  output        io_rawOut_isInf,
  output        io_rawOut_isZero,
  output        io_rawOut_sign,
  output [12:0] io_rawOut_sExp,
  output [55:0] io_rawOut_sig
);
`ifdef RANDOMIZE_REG_INIT
  reg [31:0] _RAND_0;
  reg [31:0] _RAND_1;
  reg [31:0] _RAND_2;
  reg [31:0] _RAND_3;
  reg [31:0] _RAND_4;
  reg [31:0] _RAND_5;
  reg [31:0] _RAND_6;
  reg [31:0] _RAND_7;
  reg [31:0] _RAND_8;
  reg [31:0] _RAND_9;
  reg [63:0] _RAND_10;
  reg [31:0] _RAND_11;
  reg [63:0] _RAND_12;
  reg [31:0] _RAND_13;
  reg [63:0] _RAND_14;
`endif // RANDOMIZE_REG_INIT
  reg [5:0] cycleNum; // @[DivSqrtRecFN_small.scala 223:33]
  reg  inReady; // @[DivSqrtRecFN_small.scala 224:33]
  reg  rawOutValid; // @[DivSqrtRecFN_small.scala 225:33]
  reg  sqrtOp_Z; // @[DivSqrtRecFN_small.scala 227:29]
  reg  majorExc_Z; // @[DivSqrtRecFN_small.scala 228:29]
  reg  isNaN_Z; // @[DivSqrtRecFN_small.scala 230:29]
  reg  isInf_Z; // @[DivSqrtRecFN_small.scala 231:29]
  reg  isZero_Z; // @[DivSqrtRecFN_small.scala 232:29]
  reg  sign_Z; // @[DivSqrtRecFN_small.scala 233:29]
  reg [12:0] sExp_Z; // @[DivSqrtRecFN_small.scala 234:29]
  reg [52:0] fractB_Z; // @[DivSqrtRecFN_small.scala 235:29]
  reg [2:0] roundingMode_Z; // @[DivSqrtRecFN_small.scala 236:29]
  reg [54:0] rem_Z; // @[DivSqrtRecFN_small.scala 242:29]
  reg  notZeroRem_Z; // @[DivSqrtRecFN_small.scala 243:29]
  reg [54:0] sigX_Z; // @[DivSqrtRecFN_small.scala 244:29]
  wire  notSigNaNIn_invalidExc_S_div = io_a_isZero & io_b_isZero | io_a_isInf & io_b_isInf; // @[DivSqrtRecFN_small.scala 253:42]
  wire  _notSigNaNIn_invalidExc_S_sqrt_T = ~io_a_isNaN; // @[DivSqrtRecFN_small.scala 255:9]
  wire  notSigNaNIn_invalidExc_S_sqrt = ~io_a_isNaN & ~io_a_isZero & io_a_sign; // @[DivSqrtRecFN_small.scala 255:43]
  wire  _majorExc_S_T_2 = io_a_isNaN & ~io_a_sig[51]; // @[common.scala 82:46]
  wire  _majorExc_S_T_3 = _majorExc_S_T_2 | notSigNaNIn_invalidExc_S_sqrt; // @[DivSqrtRecFN_small.scala 258:38]
  wire  _majorExc_S_T_9 = io_b_isNaN & ~io_b_sig[51]; // @[common.scala 82:46]
  wire  _majorExc_S_T_11 = _majorExc_S_T_2 | _majorExc_S_T_9 | notSigNaNIn_invalidExc_S_div; // @[DivSqrtRecFN_small.scala 259:66]
  wire  _majorExc_S_T_15 = _notSigNaNIn_invalidExc_S_sqrt_T & ~io_a_isInf & io_b_isZero; // @[DivSqrtRecFN_small.scala 261:51]
  wire  _majorExc_S_T_16 = _majorExc_S_T_11 | _majorExc_S_T_15; // @[DivSqrtRecFN_small.scala 260:46]
  wire  _isNaN_S_T = io_a_isNaN | notSigNaNIn_invalidExc_S_sqrt; // @[DivSqrtRecFN_small.scala 265:26]
  wire  _isNaN_S_T_2 = io_a_isNaN | io_b_isNaN | notSigNaNIn_invalidExc_S_div; // @[DivSqrtRecFN_small.scala 266:42]
  wire  _sign_S_T = ~io_sqrtOp; // @[DivSqrtRecFN_small.scala 270:33]
  wire  sign_S = io_a_sign ^ ~io_sqrtOp & io_b_sign; // @[DivSqrtRecFN_small.scala 270:30]
  wire  specialCaseA_S = io_a_isNaN | io_a_isInf | io_a_isZero; // @[DivSqrtRecFN_small.scala 272:55]
  wire  specialCaseB_S = io_b_isNaN | io_b_isInf | io_b_isZero; // @[DivSqrtRecFN_small.scala 273:55]
  wire  _normalCase_S_div_T = ~specialCaseA_S; // @[DivSqrtRecFN_small.scala 274:28]
  wire  normalCase_S_div = ~specialCaseA_S & ~specialCaseB_S; // @[DivSqrtRecFN_small.scala 274:45]
  wire  normalCase_S_sqrt = _normalCase_S_div_T & ~io_a_sign; // @[DivSqrtRecFN_small.scala 275:46]
  wire  normalCase_S = io_sqrtOp ? normalCase_S_sqrt : normalCase_S_div; // @[DivSqrtRecFN_small.scala 276:27]
  wire [10:0] _sExpQuot_S_div_T_2 = ~io_b_sExp[10:0]; // @[DivSqrtRecFN_small.scala 280:40]
  wire [11:0] _sExpQuot_S_div_T_4 = {io_b_sExp[11],_sExpQuot_S_div_T_2}; // @[DivSqrtRecFN_small.scala 280:71]
  wire [12:0] _GEN_15 = {{1{_sExpQuot_S_div_T_4[11]}},_sExpQuot_S_div_T_4}; // @[DivSqrtRecFN_small.scala 279:21]
  wire [13:0] sExpQuot_S_div = $signed(io_a_sExp) + $signed(_GEN_15); // @[DivSqrtRecFN_small.scala 279:21]
  wire [3:0] _sSatExpQuot_S_div_T_2 = 14'she00 <= $signed(sExpQuot_S_div) ? 4'h6 : sExpQuot_S_div[12:9]; // @[DivSqrtRecFN_small.scala 283:16]
  wire [12:0] sSatExpQuot_S_div = {_sSatExpQuot_S_div_T_2,sExpQuot_S_div[8:0]}; // @[DivSqrtRecFN_small.scala 288:11]
  wire  _evenSqrt_S_T_1 = ~io_a_sExp[0]; // @[DivSqrtRecFN_small.scala 290:35]
  wire  evenSqrt_S = io_sqrtOp & ~io_a_sExp[0]; // @[DivSqrtRecFN_small.scala 290:32]
  wire  oddSqrt_S = io_sqrtOp & io_a_sExp[0]; // @[DivSqrtRecFN_small.scala 291:32]
  wire  idle = cycleNum == 6'h0; // @[DivSqrtRecFN_small.scala 295:25]
  wire  entering = inReady & io_inValid; // @[DivSqrtRecFN_small.scala 296:28]
  wire  entering_normalCase = entering & normalCase_S; // @[DivSqrtRecFN_small.scala 297:40]
  wire  skipCycle2 = cycleNum == 6'h3 & sigX_Z[54]; // @[DivSqrtRecFN_small.scala 300:39]
  wire  _inReady_T_1 = entering & ~normalCase_S; // @[DivSqrtRecFN_small.scala 304:26]
  wire [5:0] _inReady_T_17 = cycleNum - 6'h1; // @[DivSqrtRecFN_small.scala 312:56]
  wire  _inReady_T_18 = _inReady_T_17 <= 6'h1; // @[DivSqrtRecFN_small.scala 316:38]
  wire  _inReady_T_19 = ~entering & ~skipCycle2 & _inReady_T_18; // @[DivSqrtRecFN_small.scala 312:16]
  wire  _inReady_T_20 = _inReady_T_1 | _inReady_T_19; // @[DivSqrtRecFN_small.scala 311:15]
  wire  _inReady_T_23 = _inReady_T_20 | skipCycle2; // @[DivSqrtRecFN_small.scala 312:95]
  wire  _rawOutValid_T_18 = _inReady_T_17 == 6'h1; // @[DivSqrtRecFN_small.scala 317:42]
  wire  _rawOutValid_T_19 = ~entering & ~skipCycle2 & _rawOutValid_T_18; // @[DivSqrtRecFN_small.scala 312:16]
  wire  _rawOutValid_T_20 = _inReady_T_1 | _rawOutValid_T_19; // @[DivSqrtRecFN_small.scala 311:15]
  wire  _rawOutValid_T_23 = _rawOutValid_T_20 | skipCycle2; // @[DivSqrtRecFN_small.scala 312:95]
  wire [5:0] _cycleNum_T_4 = io_a_sExp[0] ? 6'h35 : 6'h36; // @[DivSqrtRecFN_small.scala 307:24]
  wire [5:0] _cycleNum_T_5 = io_sqrtOp ? _cycleNum_T_4 : 6'h37; // @[DivSqrtRecFN_small.scala 306:20]
  wire [5:0] _cycleNum_T_6 = entering_normalCase ? _cycleNum_T_5 : 6'h0; // @[DivSqrtRecFN_small.scala 305:16]
  wire [5:0] _GEN_16 = {{5'd0}, _inReady_T_1}; // @[DivSqrtRecFN_small.scala 304:57]
  wire [5:0] _cycleNum_T_7 = _GEN_16 | _cycleNum_T_6; // @[DivSqrtRecFN_small.scala 304:57]
  wire [5:0] _cycleNum_T_14 = ~entering & ~skipCycle2 ? _inReady_T_17 : 6'h0; // @[DivSqrtRecFN_small.scala 312:16]
  wire [5:0] _cycleNum_T_15 = _cycleNum_T_7 | _cycleNum_T_14; // @[DivSqrtRecFN_small.scala 311:15]
  wire [5:0] _GEN_17 = {{5'd0}, skipCycle2}; // @[DivSqrtRecFN_small.scala 312:95]
  wire [5:0] _cycleNum_T_17 = _cycleNum_T_15 | _GEN_17; // @[DivSqrtRecFN_small.scala 312:95]
  wire  _GEN_0 = ~idle | entering ? _inReady_T_23 : inReady; // @[DivSqrtRecFN_small.scala 302:31 316:17 224:33]
  wire [11:0] _sExp_Z_T = io_a_sExp[12:1]; // @[DivSqrtRecFN_small.scala 334:29]
  wire [12:0] _sExp_Z_T_1 = $signed(_sExp_Z_T) + 12'sh400; // @[DivSqrtRecFN_small.scala 334:34]
  wire  _T_2 = ~inReady; // @[DivSqrtRecFN_small.scala 339:23]
  wire  _T_3 = ~inReady & sqrtOp_Z; // @[DivSqrtRecFN_small.scala 339:33]
  wire  _fractB_Z_T_1 = inReady & _sign_S_T; // @[DivSqrtRecFN_small.scala 341:25]
  wire [52:0] _fractB_Z_T_3 = {io_b_sig[51:0], 1'h0}; // @[DivSqrtRecFN_small.scala 341:90]
  wire [52:0] _fractB_Z_T_4 = inReady & _sign_S_T ? _fractB_Z_T_3 : 53'h0; // @[DivSqrtRecFN_small.scala 341:16]
  wire  _fractB_Z_T_5 = inReady & io_sqrtOp; // @[DivSqrtRecFN_small.scala 342:25]
  wire [51:0] _fractB_Z_T_8 = inReady & io_sqrtOp & io_a_sExp[0] ? 52'h8000000000000 : 52'h0; // @[DivSqrtRecFN_small.scala 342:16]
  wire [52:0] _GEN_18 = {{1'd0}, _fractB_Z_T_8}; // @[DivSqrtRecFN_small.scala 341:100]
  wire [52:0] _fractB_Z_T_9 = _fractB_Z_T_4 | _GEN_18; // @[DivSqrtRecFN_small.scala 341:100]
  wire [52:0] _fractB_Z_T_14 = _fractB_Z_T_5 & _evenSqrt_S_T_1 ? 53'h10000000000000 : 53'h0; // @[DivSqrtRecFN_small.scala 343:16]
  wire [52:0] _fractB_Z_T_15 = _fractB_Z_T_9 | _fractB_Z_T_14; // @[DivSqrtRecFN_small.scala 342:100]
  wire [51:0] _fractB_Z_T_25 = _T_2 ? fractB_Z[52:1] : 52'h0; // @[DivSqrtRecFN_small.scala 345:16]
  wire [52:0] _GEN_19 = {{1'd0}, _fractB_Z_T_25}; // @[DivSqrtRecFN_small.scala 344:100]
  wire [52:0] _fractB_Z_T_26 = _fractB_Z_T_15 | _GEN_19; // @[DivSqrtRecFN_small.scala 344:100]
  wire [54:0] _rem_T_2 = {io_a_sig, 1'h0}; // @[DivSqrtRecFN_small.scala 351:47]
  wire [54:0] _rem_T_3 = inReady & ~oddSqrt_S ? _rem_T_2 : 55'h0; // @[DivSqrtRecFN_small.scala 351:12]
  wire  _rem_T_4 = inReady & oddSqrt_S; // @[DivSqrtRecFN_small.scala 352:21]
  wire [1:0] _rem_T_7 = io_a_sig[52:51] - 2'h1; // @[DivSqrtRecFN_small.scala 353:56]
  wire [53:0] _rem_T_9 = {io_a_sig[50:0], 3'h0}; // @[DivSqrtRecFN_small.scala 354:44]
  wire [55:0] _rem_T_10 = {_rem_T_7,_rem_T_9}; // @[Cat.scala 33:92]
  wire [55:0] _rem_T_11 = inReady & oddSqrt_S ? _rem_T_10 : 56'h0; // @[DivSqrtRecFN_small.scala 352:12]
  wire [55:0] _GEN_20 = {{1'd0}, _rem_T_3}; // @[DivSqrtRecFN_small.scala 351:57]
  wire [55:0] _rem_T_12 = _GEN_20 | _rem_T_11; // @[DivSqrtRecFN_small.scala 351:57]
  wire [55:0] _rem_T_14 = {rem_Z, 1'h0}; // @[DivSqrtRecFN_small.scala 358:29]
  wire [55:0] _rem_T_15 = _T_2 ? _rem_T_14 : 56'h0; // @[DivSqrtRecFN_small.scala 358:12]
  wire [55:0] rem = _rem_T_12 | _rem_T_15; // @[DivSqrtRecFN_small.scala 357:11]
  wire [63:0] _bitMask_T = 64'h1 << cycleNum; // @[DivSqrtRecFN_small.scala 359:23]
  wire [61:0] bitMask = _bitMask_T[63:2]; // @[DivSqrtRecFN_small.scala 359:34]
  wire [54:0] _trialTerm_T_2 = {io_b_sig, 1'h0}; // @[DivSqrtRecFN_small.scala 361:48]
  wire [54:0] _trialTerm_T_3 = _fractB_Z_T_1 ? _trialTerm_T_2 : 55'h0; // @[DivSqrtRecFN_small.scala 361:12]
  wire [53:0] _trialTerm_T_5 = inReady & evenSqrt_S ? 54'h20000000000000 : 54'h0; // @[DivSqrtRecFN_small.scala 362:12]
  wire [54:0] _GEN_21 = {{1'd0}, _trialTerm_T_5}; // @[DivSqrtRecFN_small.scala 361:74]
  wire [54:0] _trialTerm_T_6 = _trialTerm_T_3 | _GEN_21; // @[DivSqrtRecFN_small.scala 361:74]
  wire [54:0] _trialTerm_T_8 = _rem_T_4 ? 55'h50000000000000 : 55'h0; // @[DivSqrtRecFN_small.scala 363:12]
  wire [54:0] _trialTerm_T_9 = _trialTerm_T_6 | _trialTerm_T_8; // @[DivSqrtRecFN_small.scala 362:74]
  wire [52:0] _trialTerm_T_11 = _T_2 ? fractB_Z : 53'h0; // @[DivSqrtRecFN_small.scala 364:12]
  wire [54:0] _GEN_22 = {{2'd0}, _trialTerm_T_11}; // @[DivSqrtRecFN_small.scala 363:74]
  wire [54:0] _trialTerm_T_12 = _trialTerm_T_9 | _GEN_22; // @[DivSqrtRecFN_small.scala 363:74]
  wire  _trialTerm_T_14 = ~sqrtOp_Z; // @[DivSqrtRecFN_small.scala 365:26]
  wire [53:0] _trialTerm_T_17 = _T_2 & ~sqrtOp_Z ? 54'h20000000000000 : 54'h0; // @[DivSqrtRecFN_small.scala 365:12]
  wire [54:0] _GEN_23 = {{1'd0}, _trialTerm_T_17}; // @[DivSqrtRecFN_small.scala 364:74]
  wire [54:0] _trialTerm_T_18 = _trialTerm_T_12 | _GEN_23; // @[DivSqrtRecFN_small.scala 364:74]
  wire [55:0] _trialTerm_T_21 = {sigX_Z, 1'h0}; // @[DivSqrtRecFN_small.scala 366:44]
  wire [55:0] _trialTerm_T_22 = _T_3 ? _trialTerm_T_21 : 56'h0; // @[DivSqrtRecFN_small.scala 366:12]
  wire [55:0] _GEN_24 = {{1'd0}, _trialTerm_T_18}; // @[DivSqrtRecFN_small.scala 365:74]
  wire [55:0] trialTerm = _GEN_24 | _trialTerm_T_22; // @[DivSqrtRecFN_small.scala 365:74]
  wire [56:0] _trialRem_T = {1'b0,$signed(rem)}; // @[DivSqrtRecFN_small.scala 367:24]
  wire [56:0] _trialRem_T_1 = {1'b0,$signed(trialTerm)}; // @[DivSqrtRecFN_small.scala 367:42]
  wire [57:0] trialRem = $signed(_trialRem_T) - $signed(_trialRem_T_1); // @[DivSqrtRecFN_small.scala 367:29]
  wire  newBit = 58'sh0 <= $signed(trialRem); // @[DivSqrtRecFN_small.scala 368:23]
  wire [57:0] _nextRem_Z_T = $signed(_trialRem_T) - $signed(_trialRem_T_1); // @[DivSqrtRecFN_small.scala 370:42]
  wire [57:0] _nextRem_Z_T_1 = newBit ? _nextRem_Z_T : {{2'd0}, rem}; // @[DivSqrtRecFN_small.scala 370:24]
  wire [54:0] nextRem_Z = _nextRem_Z_T_1[54:0]; // @[DivSqrtRecFN_small.scala 370:54]
  wire [54:0] _sigX_Z_T_2 = {newBit, 54'h0}; // @[DivSqrtRecFN_small.scala 393:50]
  wire [54:0] _sigX_Z_T_3 = _fractB_Z_T_1 ? _sigX_Z_T_2 : 55'h0; // @[DivSqrtRecFN_small.scala 393:16]
  wire [53:0] _sigX_Z_T_5 = _fractB_Z_T_5 ? 54'h20000000000000 : 54'h0; // @[DivSqrtRecFN_small.scala 394:16]
  wire [54:0] _GEN_30 = {{1'd0}, _sigX_Z_T_5}; // @[DivSqrtRecFN_small.scala 393:74]
  wire [54:0] _sigX_Z_T_6 = _sigX_Z_T_3 | _GEN_30; // @[DivSqrtRecFN_small.scala 393:74]
  wire [52:0] _sigX_Z_T_8 = {newBit, 52'h0}; // @[DivSqrtRecFN_small.scala 395:50]
  wire [52:0] _sigX_Z_T_9 = _rem_T_4 ? _sigX_Z_T_8 : 53'h0; // @[DivSqrtRecFN_small.scala 395:16]
  wire [54:0] _GEN_31 = {{2'd0}, _sigX_Z_T_9}; // @[DivSqrtRecFN_small.scala 394:74]
  wire [54:0] _sigX_Z_T_10 = _sigX_Z_T_6 | _GEN_31; // @[DivSqrtRecFN_small.scala 394:74]
  wire [54:0] _sigX_Z_T_12 = _T_2 ? sigX_Z : 55'h0; // @[DivSqrtRecFN_small.scala 396:16]
  wire [54:0] _sigX_Z_T_13 = _sigX_Z_T_10 | _sigX_Z_T_12; // @[DivSqrtRecFN_small.scala 395:74]
  wire [61:0] _sigX_Z_T_16 = _T_2 & newBit ? bitMask : 62'h0; // @[DivSqrtRecFN_small.scala 397:16]
  wire [61:0] _GEN_32 = {{7'd0}, _sigX_Z_T_13}; // @[DivSqrtRecFN_small.scala 396:74]
  wire [61:0] _sigX_Z_T_17 = _GEN_32 | _sigX_Z_T_16; // @[DivSqrtRecFN_small.scala 396:74]
  wire [61:0] _GEN_14 = entering | _T_2 ? _sigX_Z_T_17 : {{7'd0}, sigX_Z}; // @[DivSqrtRecFN_small.scala 389:34 392:16 244:29]
  wire [55:0] _GEN_33 = {{55'd0}, notZeroRem_Z}; // @[DivSqrtRecFN_small.scala 413:35]
  assign io_inReady = inReady; // @[DivSqrtRecFN_small.scala 321:16]
  assign io_rawOutValid_div = rawOutValid & _trialTerm_T_14; // @[DivSqrtRecFN_small.scala 403:40]
  assign io_rawOutValid_sqrt = rawOutValid & sqrtOp_Z; // @[DivSqrtRecFN_small.scala 404:40]
  assign io_roundingModeOut = roundingMode_Z; // @[DivSqrtRecFN_small.scala 405:25]
  assign io_invalidExc = majorExc_Z & isNaN_Z; // @[DivSqrtRecFN_small.scala 406:36]
  assign io_infiniteExc = majorExc_Z & ~isNaN_Z; // @[DivSqrtRecFN_small.scala 407:36]
  assign io_rawOut_isNaN = isNaN_Z; // @[DivSqrtRecFN_small.scala 408:22]
  assign io_rawOut_isInf = isInf_Z; // @[DivSqrtRecFN_small.scala 409:22]
  assign io_rawOut_isZero = isZero_Z; // @[DivSqrtRecFN_small.scala 410:22]
  assign io_rawOut_sign = sign_Z; // @[DivSqrtRecFN_small.scala 411:22]
  assign io_rawOut_sExp = sExp_Z; // @[DivSqrtRecFN_small.scala 412:22]
  assign io_rawOut_sig = _trialTerm_T_21 | _GEN_33; // @[DivSqrtRecFN_small.scala 413:35]
  always @(posedge clock) begin
    if (reset) begin // @[DivSqrtRecFN_small.scala 223:33]
      cycleNum <= 6'h0; // @[DivSqrtRecFN_small.scala 223:33]
    end else if (~idle | entering) begin // @[DivSqrtRecFN_small.scala 302:31]
      cycleNum <= _cycleNum_T_17; // @[DivSqrtRecFN_small.scala 318:18]
    end
    inReady <= reset | _GEN_0; // @[DivSqrtRecFN_small.scala 224:{33,33}]
    if (reset) begin // @[DivSqrtRecFN_small.scala 225:33]
      rawOutValid <= 1'h0; // @[DivSqrtRecFN_small.scala 225:33]
    end else if (~idle | entering) begin // @[DivSqrtRecFN_small.scala 302:31]
      rawOutValid <= _rawOutValid_T_23; // @[DivSqrtRecFN_small.scala 317:21]
    end
    if (entering) begin // @[DivSqrtRecFN_small.scala 325:21]
      sqrtOp_Z <= io_sqrtOp; // @[DivSqrtRecFN_small.scala 326:20]
    end
    if (entering) begin // @[DivSqrtRecFN_small.scala 325:21]
      if (io_sqrtOp) begin // @[DivSqrtRecFN_small.scala 257:12]
        majorExc_Z <= _majorExc_S_T_3;
      end else begin
        majorExc_Z <= _majorExc_S_T_16;
      end
    end
    if (entering) begin // @[DivSqrtRecFN_small.scala 325:21]
      if (io_sqrtOp) begin // @[DivSqrtRecFN_small.scala 264:12]
        isNaN_Z <= _isNaN_S_T;
      end else begin
        isNaN_Z <= _isNaN_S_T_2;
      end
    end
    if (entering) begin // @[DivSqrtRecFN_small.scala 325:21]
      if (io_sqrtOp) begin // @[DivSqrtRecFN_small.scala 268:23]
        isInf_Z <= io_a_isInf;
      end else begin
        isInf_Z <= io_a_isInf | io_b_isZero;
      end
    end
    if (entering) begin // @[DivSqrtRecFN_small.scala 325:21]
      if (io_sqrtOp) begin // @[DivSqrtRecFN_small.scala 269:23]
        isZero_Z <= io_a_isZero;
      end else begin
        isZero_Z <= io_a_isZero | io_b_isInf;
      end
    end
    if (entering) begin // @[DivSqrtRecFN_small.scala 325:21]
      sign_Z <= sign_S; // @[DivSqrtRecFN_small.scala 331:20]
    end
    if (entering) begin // @[DivSqrtRecFN_small.scala 325:21]
      if (io_sqrtOp) begin // @[DivSqrtRecFN_small.scala 333:16]
        sExp_Z <= _sExp_Z_T_1;
      end else begin
        sExp_Z <= sSatExpQuot_S_div;
      end
    end
    if (entering | ~inReady & sqrtOp_Z) begin // @[DivSqrtRecFN_small.scala 339:46]
      fractB_Z <= _fractB_Z_T_26; // @[DivSqrtRecFN_small.scala 340:18]
    end
    if (entering) begin // @[DivSqrtRecFN_small.scala 325:21]
      roundingMode_Z <= io_roundingMode; // @[DivSqrtRecFN_small.scala 337:24]
    end
    if (entering | _T_2) begin // @[DivSqrtRecFN_small.scala 389:34]
      rem_Z <= nextRem_Z; // @[DivSqrtRecFN_small.scala 391:15]
    end
    if (entering | _T_2) begin // @[DivSqrtRecFN_small.scala 389:34]
      if (inReady | newBit) begin // @[DivSqrtRecFN_small.scala 379:31]
        notZeroRem_Z <= $signed(trialRem) != 58'sh0;
      end
    end
    sigX_Z <= _GEN_14[54:0];
  end
// Register and memory initialization
`ifdef RANDOMIZE_GARBAGE_ASSIGN
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_INVALID_ASSIGN
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_REG_INIT
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_MEM_INIT
`define RANDOMIZE
`endif
`ifndef RANDOM
`define RANDOM $random
`endif
`ifdef RANDOMIZE_MEM_INIT
  integer initvar;
`endif
`ifndef SYNTHESIS
`ifdef FIRRTL_BEFORE_INITIAL
`FIRRTL_BEFORE_INITIAL
`endif
initial begin
  `ifdef RANDOMIZE
    `ifdef INIT_RANDOM
      `INIT_RANDOM
    `endif
    `ifndef VERILATOR
      `ifdef RANDOMIZE_DELAY
        #`RANDOMIZE_DELAY begin end
      `else
        #0.002 begin end
      `endif
    `endif
`ifdef RANDOMIZE_REG_INIT
  _RAND_0 = {1{`RANDOM}};
  cycleNum = _RAND_0[5:0];
  _RAND_1 = {1{`RANDOM}};
  inReady = _RAND_1[0:0];
  _RAND_2 = {1{`RANDOM}};
  rawOutValid = _RAND_2[0:0];
  _RAND_3 = {1{`RANDOM}};
  sqrtOp_Z = _RAND_3[0:0];
  _RAND_4 = {1{`RANDOM}};
  majorExc_Z = _RAND_4[0:0];
  _RAND_5 = {1{`RANDOM}};
  isNaN_Z = _RAND_5[0:0];
  _RAND_6 = {1{`RANDOM}};
  isInf_Z = _RAND_6[0:0];
  _RAND_7 = {1{`RANDOM}};
  isZero_Z = _RAND_7[0:0];
  _RAND_8 = {1{`RANDOM}};
  sign_Z = _RAND_8[0:0];
  _RAND_9 = {1{`RANDOM}};
  sExp_Z = _RAND_9[12:0];
  _RAND_10 = {2{`RANDOM}};
  fractB_Z = _RAND_10[52:0];
  _RAND_11 = {1{`RANDOM}};
  roundingMode_Z = _RAND_11[2:0];
  _RAND_12 = {2{`RANDOM}};
  rem_Z = _RAND_12[54:0];
  _RAND_13 = {1{`RANDOM}};
  notZeroRem_Z = _RAND_13[0:0];
  _RAND_14 = {2{`RANDOM}};
  sigX_Z = _RAND_14[54:0];
`endif // RANDOMIZE_REG_INIT
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule

module DivSqrtRecFNToRaw_small_1(
  input         clock,
  input         reset,
  output        io_inReady,
  input         io_inValid,
  input         io_sqrtOp,
  input  [64:0] io_a,
  input  [64:0] io_b,
  input  [2:0]  io_roundingMode,
  output        io_rawOutValid_div,
  output        io_rawOutValid_sqrt,
  output [2:0]  io_roundingModeOut,
  output        io_invalidExc,
  output        io_infiniteExc,
  output        io_rawOut_isNaN,
  output        io_rawOut_isInf,
  output        io_rawOut_isZero,
  output        io_rawOut_sign,
  output [12:0] io_rawOut_sExp,
  output [55:0] io_rawOut_sig
);
  wire  divSqrtRawFN__clock; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__reset; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_inReady; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_inValid; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_sqrtOp; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_a_isNaN; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_a_isInf; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_a_isZero; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_a_sign; // @[DivSqrtRecFN_small.scala 444:15]
  wire [12:0] divSqrtRawFN__io_a_sExp; // @[DivSqrtRecFN_small.scala 444:15]
  wire [53:0] divSqrtRawFN__io_a_sig; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_b_isNaN; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_b_isInf; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_b_isZero; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_b_sign; // @[DivSqrtRecFN_small.scala 444:15]
  wire [12:0] divSqrtRawFN__io_b_sExp; // @[DivSqrtRecFN_small.scala 444:15]
  wire [53:0] divSqrtRawFN__io_b_sig; // @[DivSqrtRecFN_small.scala 444:15]
  wire [2:0] divSqrtRawFN__io_roundingMode; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_rawOutValid_div; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_rawOutValid_sqrt; // @[DivSqrtRecFN_small.scala 444:15]
  wire [2:0] divSqrtRawFN__io_roundingModeOut; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_invalidExc; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_infiniteExc; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_rawOut_isNaN; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_rawOut_isInf; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_rawOut_isZero; // @[DivSqrtRecFN_small.scala 444:15]
  wire  divSqrtRawFN__io_rawOut_sign; // @[DivSqrtRecFN_small.scala 444:15]
  wire [12:0] divSqrtRawFN__io_rawOut_sExp; // @[DivSqrtRecFN_small.scala 444:15]
  wire [55:0] divSqrtRawFN__io_rawOut_sig; // @[DivSqrtRecFN_small.scala 444:15]
  wire [11:0] divSqrtRawFN_io_a_exp = io_a[63:52]; // @[rawFloatFromRecFN.scala 51:21]
  wire  divSqrtRawFN_io_a_isZero = divSqrtRawFN_io_a_exp[11:9] == 3'h0; // @[rawFloatFromRecFN.scala 52:53]
  wire  divSqrtRawFN_io_a_isSpecial = divSqrtRawFN_io_a_exp[11:10] == 2'h3; // @[rawFloatFromRecFN.scala 53:53]
  wire  _divSqrtRawFN_io_a_out_sig_T = ~divSqrtRawFN_io_a_isZero; // @[rawFloatFromRecFN.scala 61:35]
  wire [1:0] _divSqrtRawFN_io_a_out_sig_T_1 = {1'h0,_divSqrtRawFN_io_a_out_sig_T}; // @[rawFloatFromRecFN.scala 61:32]
  wire [11:0] divSqrtRawFN_io_b_exp = io_b[63:52]; // @[rawFloatFromRecFN.scala 51:21]
  wire  divSqrtRawFN_io_b_isZero = divSqrtRawFN_io_b_exp[11:9] == 3'h0; // @[rawFloatFromRecFN.scala 52:53]
  wire  divSqrtRawFN_io_b_isSpecial = divSqrtRawFN_io_b_exp[11:10] == 2'h3; // @[rawFloatFromRecFN.scala 53:53]
  wire  _divSqrtRawFN_io_b_out_sig_T = ~divSqrtRawFN_io_b_isZero; // @[rawFloatFromRecFN.scala 61:35]
  wire [1:0] _divSqrtRawFN_io_b_out_sig_T_1 = {1'h0,_divSqrtRawFN_io_b_out_sig_T}; // @[rawFloatFromRecFN.scala 61:32]
  DivSqrtRawFN_small_1 divSqrtRawFN_ ( // @[DivSqrtRecFN_small.scala 444:15]
    .clock(divSqrtRawFN__clock),
    .reset(divSqrtRawFN__reset),
    .io_inReady(divSqrtRawFN__io_inReady),
    .io_inValid(divSqrtRawFN__io_inValid),
    .io_sqrtOp(divSqrtRawFN__io_sqrtOp),
    .io_a_isNaN(divSqrtRawFN__io_a_isNaN),
    .io_a_isInf(divSqrtRawFN__io_a_isInf),
    .io_a_isZero(divSqrtRawFN__io_a_isZero),
    .io_a_sign(divSqrtRawFN__io_a_sign),
    .io_a_sExp(divSqrtRawFN__io_a_sExp),
    .io_a_sig(divSqrtRawFN__io_a_sig),
    .io_b_isNaN(divSqrtRawFN__io_b_isNaN),
    .io_b_isInf(divSqrtRawFN__io_b_isInf),
    .io_b_isZero(divSqrtRawFN__io_b_isZero),
    .io_b_sign(divSqrtRawFN__io_b_sign),
    .io_b_sExp(divSqrtRawFN__io_b_sExp),
    .io_b_sig(divSqrtRawFN__io_b_sig),
    .io_roundingMode(divSqrtRawFN__io_roundingMode),
    .io_rawOutValid_div(divSqrtRawFN__io_rawOutValid_div),
    .io_rawOutValid_sqrt(divSqrtRawFN__io_rawOutValid_sqrt),
    .io_roundingModeOut(divSqrtRawFN__io_roundingModeOut),
    .io_invalidExc(divSqrtRawFN__io_invalidExc),
    .io_infiniteExc(divSqrtRawFN__io_infiniteExc),
    .io_rawOut_isNaN(divSqrtRawFN__io_rawOut_isNaN),
    .io_rawOut_isInf(divSqrtRawFN__io_rawOut_isInf),
    .io_rawOut_isZero(divSqrtRawFN__io_rawOut_isZero),
    .io_rawOut_sign(divSqrtRawFN__io_rawOut_sign),
    .io_rawOut_sExp(divSqrtRawFN__io_rawOut_sExp),
    .io_rawOut_sig(divSqrtRawFN__io_rawOut_sig)
  );
  assign io_inReady = divSqrtRawFN__io_inReady; // @[DivSqrtRecFN_small.scala 446:16]
  assign io_rawOutValid_div = divSqrtRawFN__io_rawOutValid_div; // @[DivSqrtRecFN_small.scala 453:25]
  assign io_rawOutValid_sqrt = divSqrtRawFN__io_rawOutValid_sqrt; // @[DivSqrtRecFN_small.scala 454:25]
  assign io_roundingModeOut = divSqrtRawFN__io_roundingModeOut; // @[DivSqrtRecFN_small.scala 455:25]
  assign io_invalidExc = divSqrtRawFN__io_invalidExc; // @[DivSqrtRecFN_small.scala 456:25]
  assign io_infiniteExc = divSqrtRawFN__io_infiniteExc; // @[DivSqrtRecFN_small.scala 457:25]
  assign io_rawOut_isNaN = divSqrtRawFN__io_rawOut_isNaN; // @[DivSqrtRecFN_small.scala 458:25]
  assign io_rawOut_isInf = divSqrtRawFN__io_rawOut_isInf; // @[DivSqrtRecFN_small.scala 458:25]
  assign io_rawOut_isZero = divSqrtRawFN__io_rawOut_isZero; // @[DivSqrtRecFN_small.scala 458:25]
  assign io_rawOut_sign = divSqrtRawFN__io_rawOut_sign; // @[DivSqrtRecFN_small.scala 458:25]
  assign io_rawOut_sExp = divSqrtRawFN__io_rawOut_sExp; // @[DivSqrtRecFN_small.scala 458:25]
  assign io_rawOut_sig = divSqrtRawFN__io_rawOut_sig; // @[DivSqrtRecFN_small.scala 458:25]
  assign divSqrtRawFN__clock = clock;
  assign divSqrtRawFN__reset = reset;
  assign divSqrtRawFN__io_inValid = io_inValid; // @[DivSqrtRecFN_small.scala 447:34]
  assign divSqrtRawFN__io_sqrtOp = io_sqrtOp; // @[DivSqrtRecFN_small.scala 448:34]
  assign divSqrtRawFN__io_a_isNaN = divSqrtRawFN_io_a_isSpecial & divSqrtRawFN_io_a_exp[9]; // @[rawFloatFromRecFN.scala 56:33]
  assign divSqrtRawFN__io_a_isInf = divSqrtRawFN_io_a_isSpecial & ~divSqrtRawFN_io_a_exp[9]; // @[rawFloatFromRecFN.scala 57:33]
  assign divSqrtRawFN__io_a_isZero = divSqrtRawFN_io_a_exp[11:9] == 3'h0; // @[rawFloatFromRecFN.scala 52:53]
  assign divSqrtRawFN__io_a_sign = io_a[64]; // @[rawFloatFromRecFN.scala 59:25]
  assign divSqrtRawFN__io_a_sExp = {1'b0,$signed(divSqrtRawFN_io_a_exp)}; // @[rawFloatFromRecFN.scala 60:27]
  assign divSqrtRawFN__io_a_sig = {_divSqrtRawFN_io_a_out_sig_T_1,io_a[51:0]}; // @[rawFloatFromRecFN.scala 61:44]
  assign divSqrtRawFN__io_b_isNaN = divSqrtRawFN_io_b_isSpecial & divSqrtRawFN_io_b_exp[9]; // @[rawFloatFromRecFN.scala 56:33]
  assign divSqrtRawFN__io_b_isInf = divSqrtRawFN_io_b_isSpecial & ~divSqrtRawFN_io_b_exp[9]; // @[rawFloatFromRecFN.scala 57:33]
  assign divSqrtRawFN__io_b_isZero = divSqrtRawFN_io_b_exp[11:9] == 3'h0; // @[rawFloatFromRecFN.scala 52:53]
  assign divSqrtRawFN__io_b_sign = io_b[64]; // @[rawFloatFromRecFN.scala 59:25]
  assign divSqrtRawFN__io_b_sExp = {1'b0,$signed(divSqrtRawFN_io_b_exp)}; // @[rawFloatFromRecFN.scala 60:27]
  assign divSqrtRawFN__io_b_sig = {_divSqrtRawFN_io_b_out_sig_T_1,io_b[51:0]}; // @[rawFloatFromRecFN.scala 61:44]
  assign divSqrtRawFN__io_roundingMode = io_roundingMode; // @[DivSqrtRecFN_small.scala 451:34]
endmodule

module RoundRawFNToRecFN_3(
  input         io_invalidExc,
  input         io_infiniteExc,
  input         io_in_isNaN,
  input         io_in_isInf,
  input         io_in_isZero,
  input         io_in_sign,
  input  [12:0] io_in_sExp,
  input  [55:0] io_in_sig,
  input  [2:0]  io_roundingMode,
  output [64:0] io_out,
  output [4:0]  io_exceptionFlags
);
  wire  roundAnyRawFNToRecFN_io_invalidExc; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire  roundAnyRawFNToRecFN_io_infiniteExc; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire  roundAnyRawFNToRecFN_io_in_isNaN; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire  roundAnyRawFNToRecFN_io_in_isInf; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire  roundAnyRawFNToRecFN_io_in_isZero; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire  roundAnyRawFNToRecFN_io_in_sign; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire [12:0] roundAnyRawFNToRecFN_io_in_sExp; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire [55:0] roundAnyRawFNToRecFN_io_in_sig; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire [2:0] roundAnyRawFNToRecFN_io_roundingMode; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire [64:0] roundAnyRawFNToRecFN_io_out; // @[RoundAnyRawFNToRecFN.scala 308:15]
  wire [4:0] roundAnyRawFNToRecFN_io_exceptionFlags; // @[RoundAnyRawFNToRecFN.scala 308:15]
  RoundAnyRawFNToRecFN_4 roundAnyRawFNToRecFN ( // @[RoundAnyRawFNToRecFN.scala 308:15]
    .io_invalidExc(roundAnyRawFNToRecFN_io_invalidExc),
    .io_infiniteExc(roundAnyRawFNToRecFN_io_infiniteExc),
    .io_in_isNaN(roundAnyRawFNToRecFN_io_in_isNaN),
    .io_in_isInf(roundAnyRawFNToRecFN_io_in_isInf),
    .io_in_isZero(roundAnyRawFNToRecFN_io_in_isZero),
    .io_in_sign(roundAnyRawFNToRecFN_io_in_sign),
    .io_in_sExp(roundAnyRawFNToRecFN_io_in_sExp),
    .io_in_sig(roundAnyRawFNToRecFN_io_in_sig),
    .io_roundingMode(roundAnyRawFNToRecFN_io_roundingMode),
    .io_out(roundAnyRawFNToRecFN_io_out),
    .io_exceptionFlags(roundAnyRawFNToRecFN_io_exceptionFlags)
  );
  assign io_out = roundAnyRawFNToRecFN_io_out; // @[RoundAnyRawFNToRecFN.scala 316:23]
  assign io_exceptionFlags = roundAnyRawFNToRecFN_io_exceptionFlags; // @[RoundAnyRawFNToRecFN.scala 317:23]
  assign roundAnyRawFNToRecFN_io_invalidExc = io_invalidExc; // @[RoundAnyRawFNToRecFN.scala 311:44]
  assign roundAnyRawFNToRecFN_io_infiniteExc = io_infiniteExc; // @[RoundAnyRawFNToRecFN.scala 312:44]
  assign roundAnyRawFNToRecFN_io_in_isNaN = io_in_isNaN; // @[RoundAnyRawFNToRecFN.scala 313:44]
  assign roundAnyRawFNToRecFN_io_in_isInf = io_in_isInf; // @[RoundAnyRawFNToRecFN.scala 313:44]
  assign roundAnyRawFNToRecFN_io_in_isZero = io_in_isZero; // @[RoundAnyRawFNToRecFN.scala 313:44]
  assign roundAnyRawFNToRecFN_io_in_sign = io_in_sign; // @[RoundAnyRawFNToRecFN.scala 313:44]
  assign roundAnyRawFNToRecFN_io_in_sExp = io_in_sExp; // @[RoundAnyRawFNToRecFN.scala 313:44]
  assign roundAnyRawFNToRecFN_io_in_sig = io_in_sig; // @[RoundAnyRawFNToRecFN.scala 313:44]
  assign roundAnyRawFNToRecFN_io_roundingMode = io_roundingMode; // @[RoundAnyRawFNToRecFN.scala 314:44]
endmodule

module DivSqrtRecFN_small_1(
  input         clock,
  input         reset,
  output        io_inReady,
  input         io_inValid,
  input         io_sqrtOp,
  input  [64:0] io_a,
  input  [64:0] io_b,
  input  [2:0]  io_roundingMode,
  output        io_outValid_div,
  output        io_outValid_sqrt,
  output [64:0] io_out,
  output [4:0]  io_exceptionFlags
);
  wire  divSqrtRecFNToRaw_clock; // @[DivSqrtRecFN_small.scala 490:15]
  wire  divSqrtRecFNToRaw_reset; // @[DivSqrtRecFN_small.scala 490:15]
  wire  divSqrtRecFNToRaw_io_inReady; // @[DivSqrtRecFN_small.scala 490:15]
  wire  divSqrtRecFNToRaw_io_inValid; // @[DivSqrtRecFN_small.scala 490:15]
  wire  divSqrtRecFNToRaw_io_sqrtOp; // @[DivSqrtRecFN_small.scala 490:15]
  wire [64:0] divSqrtRecFNToRaw_io_a; // @[DivSqrtRecFN_small.scala 490:15]
  wire [64:0] divSqrtRecFNToRaw_io_b; // @[DivSqrtRecFN_small.scala 490:15]
  wire [2:0] divSqrtRecFNToRaw_io_roundingMode; // @[DivSqrtRecFN_small.scala 490:15]
  wire  divSqrtRecFNToRaw_io_rawOutValid_div; // @[DivSqrtRecFN_small.scala 490:15]
  wire  divSqrtRecFNToRaw_io_rawOutValid_sqrt; // @[DivSqrtRecFN_small.scala 490:15]
  wire [2:0] divSqrtRecFNToRaw_io_roundingModeOut; // @[DivSqrtRecFN_small.scala 490:15]
  wire  divSqrtRecFNToRaw_io_invalidExc; // @[DivSqrtRecFN_small.scala 490:15]
  wire  divSqrtRecFNToRaw_io_infiniteExc; // @[DivSqrtRecFN_small.scala 490:15]
  wire  divSqrtRecFNToRaw_io_rawOut_isNaN; // @[DivSqrtRecFN_small.scala 490:15]
  wire  divSqrtRecFNToRaw_io_rawOut_isInf; // @[DivSqrtRecFN_small.scala 490:15]
  wire  divSqrtRecFNToRaw_io_rawOut_isZero; // @[DivSqrtRecFN_small.scala 490:15]
  wire  divSqrtRecFNToRaw_io_rawOut_sign; // @[DivSqrtRecFN_small.scala 490:15]
  wire [12:0] divSqrtRecFNToRaw_io_rawOut_sExp; // @[DivSqrtRecFN_small.scala 490:15]
  wire [55:0] divSqrtRecFNToRaw_io_rawOut_sig; // @[DivSqrtRecFN_small.scala 490:15]
  wire  roundRawFNToRecFN_io_invalidExc; // @[DivSqrtRecFN_small.scala 505:15]
  wire  roundRawFNToRecFN_io_infiniteExc; // @[DivSqrtRecFN_small.scala 505:15]
  wire  roundRawFNToRecFN_io_in_isNaN; // @[DivSqrtRecFN_small.scala 505:15]
  wire  roundRawFNToRecFN_io_in_isInf; // @[DivSqrtRecFN_small.scala 505:15]
  wire  roundRawFNToRecFN_io_in_isZero; // @[DivSqrtRecFN_small.scala 505:15]
  wire  roundRawFNToRecFN_io_in_sign; // @[DivSqrtRecFN_small.scala 505:15]
  wire [12:0] roundRawFNToRecFN_io_in_sExp; // @[DivSqrtRecFN_small.scala 505:15]
  wire [55:0] roundRawFNToRecFN_io_in_sig; // @[DivSqrtRecFN_small.scala 505:15]
  wire [2:0] roundRawFNToRecFN_io_roundingMode; // @[DivSqrtRecFN_small.scala 505:15]
  wire [64:0] roundRawFNToRecFN_io_out; // @[DivSqrtRecFN_small.scala 505:15]
  wire [4:0] roundRawFNToRecFN_io_exceptionFlags; // @[DivSqrtRecFN_small.scala 505:15]
  DivSqrtRecFNToRaw_small_1 divSqrtRecFNToRaw ( // @[DivSqrtRecFN_small.scala 490:15]
    .clock(divSqrtRecFNToRaw_clock),
    .reset(divSqrtRecFNToRaw_reset),
    .io_inReady(divSqrtRecFNToRaw_io_inReady),
    .io_inValid(divSqrtRecFNToRaw_io_inValid),
    .io_sqrtOp(divSqrtRecFNToRaw_io_sqrtOp),
    .io_a(divSqrtRecFNToRaw_io_a),
    .io_b(divSqrtRecFNToRaw_io_b),
    .io_roundingMode(divSqrtRecFNToRaw_io_roundingMode),
    .io_rawOutValid_div(divSqrtRecFNToRaw_io_rawOutValid_div),
    .io_rawOutValid_sqrt(divSqrtRecFNToRaw_io_rawOutValid_sqrt),
    .io_roundingModeOut(divSqrtRecFNToRaw_io_roundingModeOut),
    .io_invalidExc(divSqrtRecFNToRaw_io_invalidExc),
    .io_infiniteExc(divSqrtRecFNToRaw_io_infiniteExc),
    .io_rawOut_isNaN(divSqrtRecFNToRaw_io_rawOut_isNaN),
    .io_rawOut_isInf(divSqrtRecFNToRaw_io_rawOut_isInf),
    .io_rawOut_isZero(divSqrtRecFNToRaw_io_rawOut_isZero),
    .io_rawOut_sign(divSqrtRecFNToRaw_io_rawOut_sign),
    .io_rawOut_sExp(divSqrtRecFNToRaw_io_rawOut_sExp),
    .io_rawOut_sig(divSqrtRecFNToRaw_io_rawOut_sig)
  );
  RoundRawFNToRecFN_3 roundRawFNToRecFN ( // @[DivSqrtRecFN_small.scala 505:15]
    .io_invalidExc(roundRawFNToRecFN_io_invalidExc),
    .io_infiniteExc(roundRawFNToRecFN_io_infiniteExc),
    .io_in_isNaN(roundRawFNToRecFN_io_in_isNaN),
    .io_in_isInf(roundRawFNToRecFN_io_in_isInf),
    .io_in_isZero(roundRawFNToRecFN_io_in_isZero),
    .io_in_sign(roundRawFNToRecFN_io_in_sign),
    .io_in_sExp(roundRawFNToRecFN_io_in_sExp),
    .io_in_sig(roundRawFNToRecFN_io_in_sig),
    .io_roundingMode(roundRawFNToRecFN_io_roundingMode),
    .io_out(roundRawFNToRecFN_io_out),
    .io_exceptionFlags(roundRawFNToRecFN_io_exceptionFlags)
  );
  assign io_inReady = divSqrtRecFNToRaw_io_inReady; // @[DivSqrtRecFN_small.scala 492:16]
  assign io_outValid_div = divSqrtRecFNToRaw_io_rawOutValid_div; // @[DivSqrtRecFN_small.scala 501:22]
  assign io_outValid_sqrt = divSqrtRecFNToRaw_io_rawOutValid_sqrt; // @[DivSqrtRecFN_small.scala 502:22]
  assign io_out = roundRawFNToRecFN_io_out; // @[DivSqrtRecFN_small.scala 511:23]
  assign io_exceptionFlags = roundRawFNToRecFN_io_exceptionFlags; // @[DivSqrtRecFN_small.scala 512:23]
  assign divSqrtRecFNToRaw_clock = clock;
  assign divSqrtRecFNToRaw_reset = reset;
  assign divSqrtRecFNToRaw_io_inValid = io_inValid; // @[DivSqrtRecFN_small.scala 493:39]
  assign divSqrtRecFNToRaw_io_sqrtOp = io_sqrtOp; // @[DivSqrtRecFN_small.scala 494:39]
  assign divSqrtRecFNToRaw_io_a = io_a; // @[DivSqrtRecFN_small.scala 495:39]
  assign divSqrtRecFNToRaw_io_b = io_b; // @[DivSqrtRecFN_small.scala 496:39]
  assign divSqrtRecFNToRaw_io_roundingMode = io_roundingMode; // @[DivSqrtRecFN_small.scala 497:39]
  assign roundRawFNToRecFN_io_invalidExc = divSqrtRecFNToRaw_io_invalidExc; // @[DivSqrtRecFN_small.scala 506:39]
  assign roundRawFNToRecFN_io_infiniteExc = divSqrtRecFNToRaw_io_infiniteExc; // @[DivSqrtRecFN_small.scala 507:39]
  assign roundRawFNToRecFN_io_in_isNaN = divSqrtRecFNToRaw_io_rawOut_isNaN; // @[DivSqrtRecFN_small.scala 508:39]
  assign roundRawFNToRecFN_io_in_isInf = divSqrtRecFNToRaw_io_rawOut_isInf; // @[DivSqrtRecFN_small.scala 508:39]
  assign roundRawFNToRecFN_io_in_isZero = divSqrtRecFNToRaw_io_rawOut_isZero; // @[DivSqrtRecFN_small.scala 508:39]
  assign roundRawFNToRecFN_io_in_sign = divSqrtRecFNToRaw_io_rawOut_sign; // @[DivSqrtRecFN_small.scala 508:39]
  assign roundRawFNToRecFN_io_in_sExp = divSqrtRecFNToRaw_io_rawOut_sExp; // @[DivSqrtRecFN_small.scala 508:39]
  assign roundRawFNToRecFN_io_in_sig = divSqrtRecFNToRaw_io_rawOut_sig; // @[DivSqrtRecFN_small.scala 508:39]
  assign roundRawFNToRecFN_io_roundingMode = divSqrtRecFNToRaw_io_roundingModeOut; // @[DivSqrtRecFN_small.scala 509:39]
endmodule

module CompareRecFN(
  input  [64:0] io_a,
  input  [64:0] io_b,
  input         io_signaling,
  output        io_lt,
  output        io_eq,
  output [4:0]  io_exceptionFlags
);
  wire [11:0] rawA_exp = io_a[63:52]; // @[rawFloatFromRecFN.scala 51:21]
  wire  rawA_isZero = rawA_exp[11:9] == 3'h0; // @[rawFloatFromRecFN.scala 52:53]
  wire  rawA_isSpecial = rawA_exp[11:10] == 2'h3; // @[rawFloatFromRecFN.scala 53:53]
  wire  rawA__isNaN = rawA_isSpecial & rawA_exp[9]; // @[rawFloatFromRecFN.scala 56:33]
  wire  rawA__isInf = rawA_isSpecial & ~rawA_exp[9]; // @[rawFloatFromRecFN.scala 57:33]
  wire  rawA__sign = io_a[64]; // @[rawFloatFromRecFN.scala 59:25]
  wire [12:0] rawA__sExp = {1'b0,$signed(rawA_exp)}; // @[rawFloatFromRecFN.scala 60:27]
  wire  _rawA_out_sig_T = ~rawA_isZero; // @[rawFloatFromRecFN.scala 61:35]
  wire [53:0] rawA__sig = {1'h0,_rawA_out_sig_T,io_a[51:0]}; // @[rawFloatFromRecFN.scala 61:44]
  wire [11:0] rawB_exp = io_b[63:52]; // @[rawFloatFromRecFN.scala 51:21]
  wire  rawB_isZero = rawB_exp[11:9] == 3'h0; // @[rawFloatFromRecFN.scala 52:53]
  wire  rawB_isSpecial = rawB_exp[11:10] == 2'h3; // @[rawFloatFromRecFN.scala 53:53]
  wire  rawB__isNaN = rawB_isSpecial & rawB_exp[9]; // @[rawFloatFromRecFN.scala 56:33]
  wire  rawB__isInf = rawB_isSpecial & ~rawB_exp[9]; // @[rawFloatFromRecFN.scala 57:33]
  wire  rawB__sign = io_b[64]; // @[rawFloatFromRecFN.scala 59:25]
  wire [12:0] rawB__sExp = {1'b0,$signed(rawB_exp)}; // @[rawFloatFromRecFN.scala 60:27]
  wire  _rawB_out_sig_T = ~rawB_isZero; // @[rawFloatFromRecFN.scala 61:35]
  wire [53:0] rawB__sig = {1'h0,_rawB_out_sig_T,io_b[51:0]}; // @[rawFloatFromRecFN.scala 61:44]
  wire  ordered = ~rawA__isNaN & ~rawB__isNaN; // @[CompareRecFN.scala 57:32]
  wire  bothInfs = rawA__isInf & rawB__isInf; // @[CompareRecFN.scala 58:33]
  wire  bothZeros = rawA_isZero & rawB_isZero; // @[CompareRecFN.scala 59:33]
  wire  eqExps = $signed(rawA__sExp) == $signed(rawB__sExp); // @[CompareRecFN.scala 60:29]
  wire  common_ltMags = $signed(rawA__sExp) < $signed(rawB__sExp) | eqExps & rawA__sig < rawB__sig; // @[CompareRecFN.scala 62:33]
  wire  common_eqMags = eqExps & rawA__sig == rawB__sig; // @[CompareRecFN.scala 63:32]
  wire  _ordered_lt_T_1 = ~rawB__sign; // @[CompareRecFN.scala 67:28]
  wire  _ordered_lt_T_9 = _ordered_lt_T_1 & common_ltMags; // @[CompareRecFN.scala 70:41]
  wire  _ordered_lt_T_10 = rawA__sign & ~common_ltMags & ~common_eqMags | _ordered_lt_T_9; // @[CompareRecFN.scala 69:74]
  wire  _ordered_lt_T_11 = ~bothInfs & _ordered_lt_T_10; // @[CompareRecFN.scala 68:30]
  wire  _ordered_lt_T_12 = rawA__sign & ~rawB__sign | _ordered_lt_T_11; // @[CompareRecFN.scala 67:41]
  wire  ordered_lt = ~bothZeros & _ordered_lt_T_12; // @[CompareRecFN.scala 66:21]
  wire  ordered_eq = bothZeros | rawA__sign == rawB__sign & (bothInfs | common_eqMags); // @[CompareRecFN.scala 72:19]
  wire  _invalid_T_2 = rawA__isNaN & ~rawA__sig[51]; // @[common.scala 82:46]
  wire  _invalid_T_5 = rawB__isNaN & ~rawB__sig[51]; // @[common.scala 82:46]
  wire  _invalid_T_8 = io_signaling & ~ordered; // @[CompareRecFN.scala 76:27]
  wire  invalid = _invalid_T_2 | _invalid_T_5 | _invalid_T_8; // @[CompareRecFN.scala 75:58]
  assign io_lt = ordered & ordered_lt; // @[CompareRecFN.scala 78:22]
  assign io_eq = ordered & ordered_eq; // @[CompareRecFN.scala 79:22]
  assign io_exceptionFlags = {invalid,4'h0}; // @[CompareRecFN.scala 81:34]
endmodule

