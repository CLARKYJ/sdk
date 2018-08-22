// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library vm.bytecode.assembler;

import 'dart:typed_data';

import 'dbc.dart';
import 'exceptions.dart' show ExceptionsTable;

class Label {
  List<int> _jumps = <int>[];
  int offset = -1;

  Label();

  bool get isBound => offset >= 0;

  int jumpOperand(int jumpOffset) {
    if (isBound) {
      // Jump instruction takes an offset in DBC words.
      return (offset - jumpOffset) >> BytecodeAssembler.kLog2BytesPerBytecode;
    }
    _jumps.add(jumpOffset);
    return 0;
  }

  List<int> bind(int offset) {
    assert(!isBound);
    this.offset = offset;
    final jumps = _jumps;
    _jumps = null;
    return jumps;
  }
}

class BytecodeAssembler {
  static const int kBitsPerInt = 64;
  static const int kLog2BytesPerBytecode = 2;

  // TODO(alexmarkov): figure out more efficient storage for generated bytecode.
  final List<int> bytecode = new List<int>();
  final Uint32List _encodeBufferIn;
  final Uint8List _encodeBufferOut;
  final ExceptionsTable exceptionsTable = new ExceptionsTable();

  BytecodeAssembler._(this._encodeBufferIn, this._encodeBufferOut);

  factory BytecodeAssembler() {
    final buf = new Uint32List(1);
    return new BytecodeAssembler._(buf, new Uint8List.view(buf.buffer));
  }

  int get offset => bytecode.length;
  int get offsetInWords => bytecode.length >> kLog2BytesPerBytecode;

  void bind(Label label) {
    final List<int> jumps = label.bind(offset);
    for (int jumpOffset in jumps) {
      patchJump(jumpOffset, label.jumpOperand(jumpOffset));
    }
  }

  void emitWord(int word) {
    _encodeBufferIn[0] = word; // TODO(alexmarkov): Which endianness to use?
    bytecode.addAll(_encodeBufferOut);
  }

  int _getOpcodeAt(int pos) {
    return bytecode[pos]; // TODO(alexmarkov): Take endianness into account.
  }

  void _setWord(int pos, int word) {
    _encodeBufferIn[0] = word; // TODO(alexmarkov): Which endianness to use?
    bytecode.setRange(pos, pos + _encodeBufferOut.length, _encodeBufferOut);
  }

  int _unsigned(int v, int bits) {
    assert(bits < kBitsPerInt);
    final int mask = (1 << bits) - 1;
    if ((v & mask) != v) {
      throw 'Value $v is out of unsigned $bits-bit range';
    }
    return v;
  }

  int _signed(int v, int bits) {
    assert(bits < kBitsPerInt);
    final int shift = kBitsPerInt - bits;
    if (((v << shift) >> shift) != v) {
      throw 'Value $v is out of signed $bits-bit range';
    }
    final int mask = (1 << bits) - 1;
    return v & mask;
  }

  int _uint8(int v) => _unsigned(v, 8);
  int _uint16(int v) => _unsigned(v, 16);

  int _int8(int v) => _signed(v, 8);
  int _int16(int v) => _signed(v, 16);
  int _int24(int v) => _signed(v, 24);

  int _encode0(Opcode opcode) => _uint8(opcode.index);

  int _encodeA(Opcode opcode, int ra) =>
      _uint8(opcode.index) | (_uint8(ra) << 8);

  int _encodeAD(Opcode opcode, int ra, int rd) =>
      _uint8(opcode.index) | (_uint8(ra) << 8) | (_uint16(rd) << 16);

  int _encodeAX(Opcode opcode, int ra, int rx) =>
      _uint8(opcode.index) | (_uint8(ra) << 8) | (_int16(rx) << 16);

  int _encodeD(Opcode opcode, int rd) =>
      _uint8(opcode.index) | (_uint16(rd) << 16);

  int _encodeX(Opcode opcode, int rx) =>
      _uint8(opcode.index) | (_int16(rx) << 16);

  int _encodeABC(Opcode opcode, int ra, int rb, int rc) =>
      _uint8(opcode.index) |
      (_uint8(ra) << 8) |
      (_uint8(rb) << 16) |
      (_uint8(rc) << 24);

  int _encodeABY(Opcode opcode, int ra, int rb, int ry) =>
      _uint8(opcode.index) |
      (_uint8(ra) << 8) |
      (_uint8(rb) << 16) |
      (_int8(ry) << 24);

  int _encodeT(Opcode opcode, int rt) =>
      _uint8(opcode.index) | (_int24(rt) << 8);

  void emitTrap() {
    emitWord(_encode0(Opcode.kTrap));
  }

  void emitNop(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kNop, ra, rd));
  }

  void emitCompile() {
    emitWord(_encode0(Opcode.kCompile));
  }

  void emitHotCheck(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kHotCheck, ra, rd));
  }

  void emitIntrinsic(int ra) {
    emitWord(_encodeA(Opcode.kIntrinsic, ra));
  }

  void emitDrop1() {
    emitWord(_encode0(Opcode.kDrop1));
  }

  void emitDropR(int ra) {
    emitWord(_encodeA(Opcode.kDropR, ra));
  }

  void emitDrop(int ra) {
    emitWord(_encodeA(Opcode.kDrop, ra));
  }

  void emitJump(Label label) {
    emitWord(_encodeT(Opcode.kJump, label.jumpOperand(offset)));
  }

  void emitJumpIfNoAsserts(Label label) {
    emitWord(_encodeT(Opcode.kJumpIfNoAsserts, label.jumpOperand(offset)));
  }

  void patchJump(int pos, int rt) {
    final Opcode opcode = Opcode.values[_getOpcodeAt(pos)];
    assert(isJump(opcode));
    _setWord(pos, _encodeT(opcode, rt));
  }

  void emitReturn(int ra) {
    emitWord(_encodeA(Opcode.kReturn, ra));
  }

  void emitReturnTOS() {
    emitWord(_encode0(Opcode.kReturnTOS));
  }

  void emitMove(int ra, int rx) {
    emitWord(_encodeAX(Opcode.kMove, ra, rx));
  }

  void emitSwap(int ra, int rx) {
    emitWord(_encodeAX(Opcode.kSwap, ra, rx));
  }

  void emitPush(int rx) {
    emitWord(_encodeX(Opcode.kPush, rx));
  }

  void emitLoadConstant(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kLoadConstant, ra, rd));
  }

  void emitLoadClassId(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kLoadClassId, ra, rd));
  }

  void emitLoadClassIdTOS() {
    emitWord(_encode0(Opcode.kLoadClassIdTOS));
  }

  void emitPushConstant(int rd) {
    emitWord(_encodeD(Opcode.kPushConstant, rd));
  }

  void emitStoreLocal(int rx) {
    emitWord(_encodeX(Opcode.kStoreLocal, rx));
  }

  void emitPopLocal(int rx) {
    emitWord(_encodeX(Opcode.kPopLocal, rx));
  }

  void emitIndirectStaticCall(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIndirectStaticCall, ra, rd));
  }

  void emitStaticCall(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kStaticCall, ra, rd));
  }

  void emitInstanceCall(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kInstanceCall, ra, rd));
  }

  void emitInstanceCall1Opt(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kInstanceCall1Opt, ra, rd));
  }

  void emitInstanceCall2Opt(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kInstanceCall2Opt, ra, rd));
  }

  void emitPushPolymorphicInstanceCall(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kPushPolymorphicInstanceCall, ra, rd));
  }

  void emitPushPolymorphicInstanceCallByRange(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kPushPolymorphicInstanceCallByRange, ra, rd));
  }

  void emitNativeCall(int rd) {
    emitWord(_encodeD(Opcode.kNativeCall, rd));
  }

  void emitOneByteStringFromCharCode(int ra, int rx) {
    emitWord(_encodeAX(Opcode.kOneByteStringFromCharCode, ra, rx));
  }

  void emitStringToCharCode(int ra, int rx) {
    emitWord(_encodeAX(Opcode.kStringToCharCode, ra, rx));
  }

  void emitAddTOS() {
    emitWord(_encode0(Opcode.kAddTOS));
  }

  void emitSubTOS() {
    emitWord(_encode0(Opcode.kSubTOS));
  }

  void emitMulTOS() {
    emitWord(_encode0(Opcode.kMulTOS));
  }

  void emitBitOrTOS() {
    emitWord(_encode0(Opcode.kBitOrTOS));
  }

  void emitBitAndTOS() {
    emitWord(_encode0(Opcode.kBitAndTOS));
  }

  void emitEqualTOS() {
    emitWord(_encode0(Opcode.kEqualTOS));
  }

  void emitLessThanTOS() {
    emitWord(_encode0(Opcode.kLessThanTOS));
  }

  void emitGreaterThanTOS() {
    emitWord(_encode0(Opcode.kGreaterThanTOS));
  }

  void emitSmiAddTOS() {
    emitWord(_encode0(Opcode.kSmiAddTOS));
  }

  void emitSmiSubTOS() {
    emitWord(_encode0(Opcode.kSmiSubTOS));
  }

  void emitSmiMulTOS() {
    emitWord(_encode0(Opcode.kSmiMulTOS));
  }

  void emitSmiBitAndTOS() {
    emitWord(_encode0(Opcode.kSmiBitAndTOS));
  }

  void emitAdd(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kAdd, ra, rb, rc));
  }

  void emitSub(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kSub, ra, rb, rc));
  }

  void emitMul(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kMul, ra, rb, rc));
  }

  void emitDiv(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kDiv, ra, rb, rc));
  }

  void emitMod(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kMod, ra, rb, rc));
  }

  void emitShl(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kShl, ra, rb, rc));
  }

  void emitShr(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kShr, ra, rb, rc));
  }

  void emitShlImm(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kShlImm, ra, rb, rc));
  }

  void emitNeg(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kNeg, ra, rd));
  }

  void emitBitOr(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kBitOr, ra, rb, rc));
  }

  void emitBitAnd(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kBitAnd, ra, rb, rc));
  }

  void emitBitXor(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kBitXor, ra, rb, rc));
  }

  void emitBitNot(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kBitNot, ra, rd));
  }

  void emitMin(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kMin, ra, rb, rc));
  }

  void emitMax(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kMax, ra, rb, rc));
  }

  void emitWriteIntoDouble(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kWriteIntoDouble, ra, rd));
  }

  void emitUnboxDouble(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kUnboxDouble, ra, rd));
  }

  void emitCheckedUnboxDouble(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kCheckedUnboxDouble, ra, rd));
  }

  void emitUnboxInt32(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kUnboxInt32, ra, rb, rc));
  }

  void emitBoxInt32(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kBoxInt32, ra, rd));
  }

  void emitBoxUint32(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kBoxUint32, ra, rd));
  }

  void emitSmiToDouble(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kSmiToDouble, ra, rd));
  }

  void emitDoubleToSmi(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kDoubleToSmi, ra, rd));
  }

  void emitDAdd(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kDAdd, ra, rb, rc));
  }

  void emitDSub(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kDSub, ra, rb, rc));
  }

  void emitDMul(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kDMul, ra, rb, rc));
  }

  void emitDDiv(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kDDiv, ra, rb, rc));
  }

  void emitDNeg(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kDNeg, ra, rd));
  }

  void emitDSqrt(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kDSqrt, ra, rd));
  }

  void emitDMin(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kDMin, ra, rb, rc));
  }

  void emitDMax(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kDMax, ra, rb, rc));
  }

  void emitDCos(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kDCos, ra, rd));
  }

  void emitDSin(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kDSin, ra, rd));
  }

  void emitDPow(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kDPow, ra, rb, rc));
  }

  void emitDMod(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kDMod, ra, rb, rc));
  }

  void emitDTruncate(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kDTruncate, ra, rd));
  }

  void emitDFloor(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kDFloor, ra, rd));
  }

  void emitDCeil(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kDCeil, ra, rd));
  }

  void emitDoubleToFloat(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kDoubleToFloat, ra, rd));
  }

  void emitFloatToDouble(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kFloatToDouble, ra, rd));
  }

  void emitDoubleIsNaN(int ra) {
    emitWord(_encodeA(Opcode.kDoubleIsNaN, ra));
  }

  void emitDoubleIsInfinite(int ra) {
    emitWord(_encodeA(Opcode.kDoubleIsInfinite, ra));
  }

  void emitStoreStaticTOS(int rd) {
    emitWord(_encodeD(Opcode.kStoreStaticTOS, rd));
  }

  void emitPushStatic(int rd) {
    emitWord(_encodeD(Opcode.kPushStatic, rd));
  }

  void emitInitStaticTOS() {
    emitWord(_encode0(Opcode.kInitStaticTOS));
  }

  void emitIfNeStrictTOS() {
    emitWord(_encode0(Opcode.kIfNeStrictTOS));
  }

  void emitIfEqStrictTOS() {
    emitWord(_encode0(Opcode.kIfEqStrictTOS));
  }

  void emitIfNeStrictNumTOS() {
    emitWord(_encode0(Opcode.kIfNeStrictNumTOS));
  }

  void emitIfEqStrictNumTOS() {
    emitWord(_encode0(Opcode.kIfEqStrictNumTOS));
  }

  void emitIfSmiLtTOS() {
    emitWord(_encode0(Opcode.kIfSmiLtTOS));
  }

  void emitIfSmiLeTOS() {
    emitWord(_encode0(Opcode.kIfSmiLeTOS));
  }

  void emitIfSmiGeTOS() {
    emitWord(_encode0(Opcode.kIfSmiGeTOS));
  }

  void emitIfSmiGtTOS() {
    emitWord(_encode0(Opcode.kIfSmiGtTOS));
  }

  void emitIfNeStrict(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfNeStrict, ra, rd));
  }

  void emitIfEqStrict(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfEqStrict, ra, rd));
  }

  void emitIfLe(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfLe, ra, rd));
  }

  void emitIfLt(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfLt, ra, rd));
  }

  void emitIfGe(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfGe, ra, rd));
  }

  void emitIfGt(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfGt, ra, rd));
  }

  void emitIfULe(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfULe, ra, rd));
  }

  void emitIfULt(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfULt, ra, rd));
  }

  void emitIfUGe(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfUGe, ra, rd));
  }

  void emitIfUGt(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfUGt, ra, rd));
  }

  void emitIfDNe(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfDNe, ra, rd));
  }

  void emitIfDEq(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfDEq, ra, rd));
  }

  void emitIfDLe(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfDLe, ra, rd));
  }

  void emitIfDLt(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfDLt, ra, rd));
  }

  void emitIfDGe(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfDGe, ra, rd));
  }

  void emitIfDGt(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfDGt, ra, rd));
  }

  void emitIfNeStrictNum(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfNeStrictNum, ra, rd));
  }

  void emitIfEqStrictNum(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kIfEqStrictNum, ra, rd));
  }

  void emitIfEqNull(int ra) {
    emitWord(_encodeA(Opcode.kIfEqNull, ra));
  }

  void emitIfNeNull(int ra) {
    emitWord(_encodeA(Opcode.kIfNeNull, ra));
  }

  void emitCreateArrayTOS() {
    emitWord(_encode0(Opcode.kCreateArrayTOS));
  }

  void emitCreateArrayOpt(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kCreateArrayOpt, ra, rb, rc));
  }

  void emitAllocate(int rd) {
    emitWord(_encodeD(Opcode.kAllocate, rd));
  }

  void emitAllocateT() {
    emitWord(_encode0(Opcode.kAllocateT));
  }

  void emitAllocateOpt(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kAllocateOpt, ra, rd));
  }

  void emitAllocateTOpt(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kAllocateTOpt, ra, rd));
  }

  void emitStoreIndexedTOS() {
    emitWord(_encode0(Opcode.kStoreIndexedTOS));
  }

  void emitStoreIndexed(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kStoreIndexed, ra, rb, rc));
  }

  void emitStoreIndexedUint8(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kStoreIndexedUint8, ra, rb, rc));
  }

  void emitStoreIndexedExternalUint8(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kStoreIndexedExternalUint8, ra, rb, rc));
  }

  void emitStoreIndexedOneByteString(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kStoreIndexedOneByteString, ra, rb, rc));
  }

  void emitStoreIndexedUint32(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kStoreIndexedUint32, ra, rb, rc));
  }

  void emitStoreIndexedFloat32(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kStoreIndexedFloat32, ra, rb, rc));
  }

  void emitStoreIndexed4Float32(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kStoreIndexed4Float32, ra, rb, rc));
  }

  void emitStoreIndexedFloat64(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kStoreIndexedFloat64, ra, rb, rc));
  }

  void emitStoreIndexed8Float64(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kStoreIndexed8Float64, ra, rb, rc));
  }

  void emitNoSuchMethod() {
    emitWord(_encode0(Opcode.kNoSuchMethod));
  }

  void emitTailCall() {
    emitWord(_encode0(Opcode.kTailCall));
  }

  void emitTailCallOpt(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kTailCallOpt, ra, rd));
  }

  void emitLoadArgDescriptor() {
    emitWord(_encode0(Opcode.kLoadArgDescriptor));
  }

  void emitLoadArgDescriptorOpt(int ra) {
    emitWord(_encodeA(Opcode.kLoadArgDescriptorOpt, ra));
  }

  void emitLoadFpRelativeSlot(int rx) {
    emitWord(_encodeX(Opcode.kLoadFpRelativeSlot, rx));
  }

  void emitLoadFpRelativeSlotOpt(int ra, int rb, int ry) {
    emitWord(_encodeABY(Opcode.kLoadFpRelativeSlotOpt, ra, rb, ry));
  }

  void emitStoreFpRelativeSlot(int rx) {
    emitWord(_encodeX(Opcode.kStoreFpRelativeSlot, rx));
  }

  void emitStoreFpRelativeSlotOpt(int ra, int rb, int ry) {
    emitWord(_encodeABY(Opcode.kStoreFpRelativeSlotOpt, ra, rb, ry));
  }

  void emitLoadIndexedTOS() {
    emitWord(_encode0(Opcode.kLoadIndexedTOS));
  }

  void emitLoadIndexed(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kLoadIndexed, ra, rb, rc));
  }

  void emitLoadIndexedUint8(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kLoadIndexedUint8, ra, rb, rc));
  }

  void emitLoadIndexedInt8(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kLoadIndexedInt8, ra, rb, rc));
  }

  void emitLoadIndexedInt32(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kLoadIndexedInt32, ra, rb, rc));
  }

  void emitLoadIndexedUint32(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kLoadIndexedUint32, ra, rb, rc));
  }

  void emitLoadIndexedExternalUint8(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kLoadIndexedExternalUint8, ra, rb, rc));
  }

  void emitLoadIndexedExternalInt8(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kLoadIndexedExternalInt8, ra, rb, rc));
  }

  void emitLoadIndexedFloat32(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kLoadIndexedFloat32, ra, rb, rc));
  }

  void emitLoadIndexed4Float32(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kLoadIndexed4Float32, ra, rb, rc));
  }

  void emitLoadIndexedFloat64(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kLoadIndexedFloat64, ra, rb, rc));
  }

  void emitLoadIndexed8Float64(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kLoadIndexed8Float64, ra, rb, rc));
  }

  void emitLoadIndexedOneByteString(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kLoadIndexedOneByteString, ra, rb, rc));
  }

  void emitLoadIndexedTwoByteString(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kLoadIndexedTwoByteString, ra, rb, rc));
  }

  void emitStoreField(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kStoreField, ra, rb, rc));
  }

  void emitStoreFieldExt(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kStoreFieldExt, ra, rd));
  }

  void emitStoreFieldTOS(int rd) {
    emitWord(_encodeD(Opcode.kStoreFieldTOS, rd));
  }

  void emitStoreContextParent() {
    emitWord(_encode0(Opcode.kStoreContextParent));
  }

  void emitStoreContextVar(int rd) {
    emitWord(_encodeD(Opcode.kStoreContextVar, rd));
  }

  void emitLoadField(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kLoadField, ra, rb, rc));
  }

  void emitLoadFieldExt(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kLoadFieldExt, ra, rd));
  }

  void emitLoadUntagged(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kLoadUntagged, ra, rb, rc));
  }

  void emitLoadFieldTOS(int rd) {
    emitWord(_encodeD(Opcode.kLoadFieldTOS, rd));
  }

  void emitLoadTypeArgumentsField(int rd) {
    emitWord(_encodeD(Opcode.kLoadTypeArgumentsField, rd));
  }

  void emitLoadContextParent() {
    emitWord(_encode0(Opcode.kLoadContextParent));
  }

  void emitLoadContextVar(int rd) {
    emitWord(_encodeD(Opcode.kLoadContextVar, rd));
  }

  void emitBooleanNegateTOS() {
    emitWord(_encode0(Opcode.kBooleanNegateTOS));
  }

  void emitBooleanNegate(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kBooleanNegate, ra, rd));
  }

  void emitThrow(int ra) {
    emitWord(_encodeA(Opcode.kThrow, ra));
  }

  void emitEntry(int rd) {
    emitWord(_encodeD(Opcode.kEntry, rd));
  }

  void emitEntryOptimized(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kEntryOptimized, ra, rd));
  }

  void emitFrame(int rd) {
    emitWord(_encodeD(Opcode.kFrame, rd));
  }

  void emitSetFrame(int ra) {
    emitWord(_encodeA(Opcode.kSetFrame, ra));
  }

  void emitAllocateContext(int rd) {
    emitWord(_encodeD(Opcode.kAllocateContext, rd));
  }

  void emitAllocateUninitializedContext(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kAllocateUninitializedContext, ra, rd));
  }

  void emitCloneContext() {
    emitWord(_encode0(Opcode.kCloneContext));
  }

  void emitMoveSpecial(int ra, SpecialIndex rd) {
    emitWord(_encodeAD(Opcode.kMoveSpecial, ra, rd.index));
  }

  void emitInstantiateType(int rd) {
    emitWord(_encodeD(Opcode.kInstantiateType, rd));
  }

  void emitInstantiateTypeArgumentsTOS(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kInstantiateTypeArgumentsTOS, ra, rd));
  }

  void emitInstanceOf() {
    emitWord(_encode0(Opcode.kInstanceOf));
  }

  void emitBadTypeError() {
    emitWord(_encode0(Opcode.kBadTypeError));
  }

  void emitAssertAssignable(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kAssertAssignable, ra, rd));
  }

  void emitAssertSubtype() {
    emitWord(_encode0(Opcode.kAssertSubtype));
  }

  void emitAssertBoolean(int ra) {
    emitWord(_encodeA(Opcode.kAssertBoolean, ra));
  }

  void emitTestSmi(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kTestSmi, ra, rd));
  }

  void emitTestCids(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kTestCids, ra, rd));
  }

  void emitCheckSmi(int ra) {
    emitWord(_encodeA(Opcode.kCheckSmi, ra));
  }

  void emitCheckEitherNonSmi(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kCheckEitherNonSmi, ra, rd));
  }

  void emitCheckClassId(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kCheckClassId, ra, rd));
  }

  void emitCheckClassIdRange(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kCheckClassIdRange, ra, rd));
  }

  void emitCheckBitTest(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kCheckBitTest, ra, rd));
  }

  void emitCheckCids(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kCheckCids, ra, rb, rc));
  }

  void emitCheckCidsByRange(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kCheckCidsByRange, ra, rb, rc));
  }

  void emitCheckStack() {
    emitWord(_encode0(Opcode.kCheckStack));
  }

  void emitCheckStackAlwaysExit() {
    emitWord(_encode0(Opcode.kCheckStackAlwaysExit));
  }

  void emitCheckFunctionTypeArgs(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kCheckFunctionTypeArgs, ra, rd));
  }

  void emitDebugStep() {
    emitWord(_encode0(Opcode.kDebugStep));
  }

  void emitDebugBreak(int ra) {
    emitWord(_encodeA(Opcode.kDebugBreak, ra));
  }

  void emitDeopt(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kDeopt, ra, rd));
  }

  void emitDeoptRewind() {
    emitWord(_encode0(Opcode.kDeoptRewind));
  }

  void emitEntryFixed(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kEntryFixed, ra, rd));
  }

  void emitEntryOptional(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kEntryOptional, ra, rb, rc));
  }
}
