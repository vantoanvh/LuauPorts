--!optimize 2
--!native
--!strict

--[[
	PNGDecoder.luau

	Public API:
	- Module returns DecodePng(PngData: buffer).
	- DecodePng always returns:
		{
			Animated: boolean,
			Size: Vector2,
			RGBA8: buffer,
			Frame: buffer,
			AdvanceFrame: () -> (),
			Reset: () -> (),
			Finished: boolean,
			Delay: number,
		}
	- Static PNG returns Animated = false, RGBA8 = Frame, Finished = true, and Delay = 0.
	- APNG returns Animated = true, with Frame/RGBA8 holding the current composited canvas.
	- AdvanceFrame composites the next APNG frame into Frame and updates Delay/Finished.
	- Reset restores APNG playback to the first rendered frame.
	- Frame and RGBA8 buffers are packed row-major RGBA8 using buffer.writeu32-compatible byte order.

	Supported PNG image coding:
	- Static PNG signature/chunk stream with CRC32 validation on every chunk.
	- Zlib stream validation with Adler32 and pure Luau deflate inflate.
	- Deflate uncompressed, fixed Huffman, and dynamic Huffman blocks.
	- Non-interlaced and Adam7 interlaced images.
	- PNG filters None, Sub, Up, Average, and Paeth.

	Supported color formats:
	- Color type 0: grayscale, bit depths 1, 2, 4, 8, and 16.
	- Color type 2: truecolor RGB, bit depths 8 and 16.
	- Color type 3: indexed color with PLTE, bit depths 1, 2, 4, and 8.
	- Color type 4: grayscale + alpha, bit depths 8 and 16.
	- Color type 6: RGBA, bit depths 8 and 16.
	- 16-bit samples are downsampled to their high byte for RGBA8 output.

	Transparency and palette support:
	- PLTE palette expansion.
	- tRNS transparency for grayscale, RGB, and indexed PNG.
	- Straight alpha RGBA8 output.

	Parsed/validated ancillary chunks:
	- sRGB, gAMA, cHRM, iCCP, sBIT, bKGD, pHYs, hIST, tIME.
	- tEXt, zTXt, iTXt text chunks with keyword and compressed payload validation.
	- cICP, eXIf, sPLT, oFFs, gIFg, gIFx, and sTER.
	- Unknown ancillary chunks are CRC-validated and otherwise ignored.

	Supported APNG animation behavior:
	- acTL, fcTL, and fdAT chunks.
	- Default-image first frames and fdAT-backed later frames.
	- Dispose ops 0, 1, and 2; blend ops source and over.
	- Finite and infinite acTL play counts.

	Explicitly unsupported PNG families:
	- Unknown critical chunks.
	- Nonstandard compression, filter, or interlace methods.
]]

type InflateHuffman = {
	Lookup: buffer,
}

type DecodedPng = {
	Animated: boolean,
	Size: Vector2,
	RGBA8: buffer,
	Frame: buffer,
	AdvanceFrame: () -> (),
	Reset: () -> (),
	Finished: boolean,
	Delay: number,
}

type PngFrame = {
	Width: number,
	Height: number,
	XOffset: number,
	YOffset: number,
	DelayNumerator: number,
	DelayDenominator: number,
	DisposeOp: number,
	BlendOp: number,
	DataOffsets: { [number]: number },
	DataLengths: { [number]: number },
	DataLength: number,
	DataFromIdat: boolean,
	Pixels: buffer,
}

type PngState = {
	Width: number,
	Height: number,
	Frames: { PngFrame },
	PlayCount: number,
	CompletedPlays: number,
	Canvas: buffer,
	CurrentFrameIndex: number,
	RestoreBuffer: buffer?,
	RestoreX: number,
	RestoreY: number,
	RestoreWidth: number,
	RestoreHeight: number,
	Result: DecodedPng?,
}

const EmptyInflateData = buffer.create(0)
const MaxLookupBits = 15
const HuffmanLookupSize = 32768
const AdlerBase = 65521
const MaxMetadataInflateBytes = 16777216

const PngSignature0 = 0x89
const PngSignature1 = 0x50
const PngSignature2 = 0x4e
const PngSignature3 = 0x47
const PngSignature4 = 0x0d
const PngSignature5 = 0x0a
const PngSignature6 = 0x1a
const PngSignature7 = 0x0a

const ChunkIHDR = 0x49484452
const ChunkPLTE = 0x504c5445
const ChunkIDAT = 0x49444154
const ChunkIEND = 0x49454e44
const ChunkTRNS = 0x74524e53
const ChunkACTL = 0x6163544c
const ChunkFCTL = 0x6663544c
const ChunkFDAT = 0x66644154
const ChunkSRGB = 0x73524742
const ChunkGAMA = 0x67414d41
const ChunkCHRM = 0x6348524d
const ChunkICCP = 0x69434350
const ChunkSBIT = 0x73424954
const ChunkBKGD = 0x624b4744
const ChunkPHYS = 0x70485973
const ChunkHIST = 0x68495354
const ChunkTIME = 0x74494d45
const ChunkTEXT = 0x74455874
const ChunkZTXT = 0x7a545874
const ChunkITXT = 0x69545874
const ChunkCICP = 0x63494350
const ChunkEXIF = 0x65584966
const ChunkSPLT = 0x73504c54
const ChunkOFFS = 0x6f464673
const ChunkGIFG = 0x67494667
const ChunkGIFX = 0x67494678
const ChunkSTER = 0x73544552

const MaxOutputBytes = 2147483647

const Adam7StartX: { number } = { 0, 4, 0, 2, 0, 1, 0 }
const Adam7StartY: { number } = { 0, 0, 4, 0, 2, 0, 1 }
const Adam7StepX: { number } = { 8, 8, 4, 4, 2, 2, 1 }
const Adam7StepY: { number } = { 8, 8, 8, 4, 4, 2, 2 }
const CodeLengthOrder: { number } = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }
const LengthBase: { number } = {
	3,
	4,
	5,
	6,
	7,
	8,
	9,
	10,
	11,
	13,
	15,
	17,
	19,
	23,
	27,
	31,
	35,
	43,
	51,
	59,
	67,
	83,
	99,
	115,
	131,
	163,
	195,
	227,
	258,
}
const LengthExtra: { number } = {
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	1,
	1,
	1,
	1,
	2,
	2,
	2,
	2,
	3,
	3,
	3,
	3,
	4,
	4,
	4,
	4,
	5,
	5,
	5,
	5,
	0,
}
const DistanceBase: { number } = {
	1,
	2,
	3,
	4,
	5,
	7,
	9,
	13,
	17,
	25,
	33,
	49,
	65,
	97,
	129,
	193,
	257,
	385,
	513,
	769,
	1025,
	1537,
	2049,
	3073,
	4097,
	6145,
	8193,
	12289,
	16385,
	24577,
}
const DistanceExtra: { number } = {
	0,
	0,
	0,
	0,
	1,
	1,
	2,
	2,
	3,
	3,
	4,
	4,
	5,
	5,
	6,
	6,
	7,
	7,
	8,
	8,
	9,
	9,
	10,
	10,
	11,
	11,
	12,
	12,
	13,
	13,
}

const BitPowers: { [number]: number } = {
	[0] = 1,
	2,
	4,
	8,
	16,
	32,
	64,
	128,
	256,
	512,
	1024,
	2048,
	4096,
	8192,
	16384,
	32768,
	65536,
	131072,
	262144,
	524288,
	1048576,
	2097152,
	4194304,
	8388608,
	16777216,
	33554432,
	67108864,
	134217728,
	268435456,
	536870912,
	1073741824,
	2147483648,
	4294967296,
}

const CrcTable = buffer.create(1024)
const CrcTable1 = buffer.create(1024)
const CrcTable2 = buffer.create(1024)
const CrcTable3 = buffer.create(1024)
const CrcTable4 = buffer.create(1024)
const CrcTable5 = buffer.create(1024)
const CrcTable6 = buffer.create(1024)
const CrcTable7 = buffer.create(1024)

for Index = 0, 255 do
	local Crc = Index

	for _ = 1, 8 do
		if bit32.btest(Crc, 1) then
			Crc = bit32.bxor(bit32.rshift(Crc, 1), 0xedb88320)
		else
			Crc = bit32.rshift(Crc, 1)
		end
	end

	buffer.writeu32(CrcTable, Index * 4, Crc)
end

for Index = 0, 255 do
	local Crc = buffer.readu32(CrcTable, Index * 4)
	Crc = bit32.bxor(bit32.rshift(Crc, 8), buffer.readu32(CrcTable, bit32.band(Crc, 0xff) * 4))
	buffer.writeu32(CrcTable1, Index * 4, Crc)
	Crc = bit32.bxor(bit32.rshift(Crc, 8), buffer.readu32(CrcTable, bit32.band(Crc, 0xff) * 4))
	buffer.writeu32(CrcTable2, Index * 4, Crc)
	Crc = bit32.bxor(bit32.rshift(Crc, 8), buffer.readu32(CrcTable, bit32.band(Crc, 0xff) * 4))
	buffer.writeu32(CrcTable3, Index * 4, Crc)
	Crc = bit32.bxor(bit32.rshift(Crc, 8), buffer.readu32(CrcTable, bit32.band(Crc, 0xff) * 4))
	buffer.writeu32(CrcTable4, Index * 4, Crc)
	Crc = bit32.bxor(bit32.rshift(Crc, 8), buffer.readu32(CrcTable, bit32.band(Crc, 0xff) * 4))
	buffer.writeu32(CrcTable5, Index * 4, Crc)
	Crc = bit32.bxor(bit32.rshift(Crc, 8), buffer.readu32(CrcTable, bit32.band(Crc, 0xff) * 4))
	buffer.writeu32(CrcTable6, Index * 4, Crc)
	Crc = bit32.bxor(bit32.rshift(Crc, 8), buffer.readu32(CrcTable, bit32.band(Crc, 0xff) * 4))
	buffer.writeu32(CrcTable7, Index * 4, Crc)
end

local InflateData = EmptyInflateData
local InflateLength = 0
local InflatePos = 0
local InflateBits = 0
local InflateBitCount = 0
local InflateOutput = EmptyInflateData
local InflateOutputPos = 0
local InflateOutputLength = 0

const FixedLiteralLengths = buffer.create(288)
const FixedDistanceLengths = buffer.create(32)

for Symbol = 0, 143 do
	buffer.writeu8(FixedLiteralLengths, Symbol, 8)
end

for Symbol = 144, 255 do
	buffer.writeu8(FixedLiteralLengths, Symbol, 9)
end

for Symbol = 256, 279 do
	buffer.writeu8(FixedLiteralLengths, Symbol, 7)
end

for Symbol = 280, 287 do
	buffer.writeu8(FixedLiteralLengths, Symbol, 8)
end

for Symbol = 0, 31 do
	buffer.writeu8(FixedDistanceLengths, Symbol, 5)
end

const function ReadU32BE(Data: buffer, Offset: number): number
	return bit32.byteswap(buffer.readu32(Data, Offset))
end

const function ReadU16BE(Data: buffer, Offset: number): number
	return bit32.rshift(bit32.byteswap(buffer.readu16(Data, Offset)), 16)
end

const function ReadTiffU16(Data: buffer, Offset: number, BigEndian: boolean): number
	return BigEndian and ReadU16BE(Data, Offset) or buffer.readu16(Data, Offset)
end

const function ReadTiffU32(Data: buffer, Offset: number, BigEndian: boolean): number
	return BigEndian and bit32.byteswap(buffer.readu32(Data, Offset)) or buffer.readu32(Data, Offset)
end

const function TiffTypeSize(ValueType: number): number
	if ValueType == 1 or ValueType == 2 or ValueType == 6 or ValueType == 7 then
		return 1
	elseif ValueType == 3 or ValueType == 8 then
		return 2
	elseif ValueType == 4 or ValueType == 9 or ValueType == 11 then
		return 4
	elseif ValueType == 5 or ValueType == 10 or ValueType == 12 then
		return 8
	end

	error("invalid PNG eXIf type")
	return 0
end

const function ValidateExif(Data: buffer, Start: number, End: number)
	if End - Start < 8 then
		error("invalid PNG eXIf")
	end

	const Byte0 = buffer.readu8(Data, Start)
	const Byte1 = buffer.readu8(Data, Start + 1)
	local BigEndian = false

	if Byte0 == 0x4d and Byte1 == 0x4d then
		BigEndian = true
	elseif Byte0 ~= 0x49 or Byte1 ~= 0x49 then
		error("invalid PNG eXIf")
	end

	if ReadTiffU16(Data, Start + 2, BigEndian) ~= 42 then
		error("invalid PNG eXIf")
	end

	local IfdOffset = ReadTiffU32(Data, Start + 4, BigEndian)
	local IfdCount = 0

	while IfdOffset ~= 0 do
		if IfdOffset < 8 or IfdOffset > End - Start - 2 or IfdCount >= 16 then
			error("invalid PNG eXIf")
		end

		const IfdStart = Start + IfdOffset
		const EntryCount = ReadTiffU16(Data, IfdStart, BigEndian)
		const EntriesStart = IfdStart + 2
		const NextOffsetPosition = EntriesStart + EntryCount * 12

		if NextOffsetPosition + 4 > End then
			error("invalid PNG eXIf")
		end

		for EntryIndex = 0, EntryCount - 1 do
			const EntryOffset = EntriesStart + EntryIndex * 12
			const ValueType = ReadTiffU16(Data, EntryOffset + 2, BigEndian)
			const ValueCount = ReadTiffU32(Data, EntryOffset + 4, BigEndian)
			const ValueSize = TiffTypeSize(ValueType)

			if ValueCount > MaxOutputBytes // ValueSize then
				error("invalid PNG eXIf")
			end

			const ByteCount = ValueCount * ValueSize

			if ByteCount > 4 then
				const ValueOffset = ReadTiffU32(Data, EntryOffset + 8, BigEndian)

				if ValueOffset < 8 or ValueOffset > End - Start or ByteCount > End - Start - ValueOffset then
					error("invalid PNG eXIf")
				end
			end
		end

		IfdOffset = ReadTiffU32(Data, NextOffsetPosition, BigEndian)
		IfdCount += 1
	end
end

const function IsLeapYear(Year: number): boolean
	return Year % 4 == 0 and (Year % 100 ~= 0 or Year % 400 == 0)
end

const function DaysInMonth(Year: number, Month: number): number
	if Month == 2 then
		if IsLeapYear(Year) then
			return 29
		end

		return 28
	elseif Month == 4 or Month == 6 or Month == 9 or Month == 11 then
		return 30
	end

	return 31
end

const function ReadNullTerminatedKeywordEnd(Data: buffer, Start: number, End: number): number
	local Cursor = Start
	local PreviousSpace = false

	while Cursor < End and buffer.readu8(Data, Cursor) ~= 0 do
		const Value = buffer.readu8(Data, Cursor)

		if Value < 32 or (Value >= 127 and Value <= 160) then
			error("invalid PNG text keyword")
		end

		if Value == 32 then
			if Cursor == Start or PreviousSpace then
				error("invalid PNG text keyword")
			end

			PreviousSpace = true
		else
			PreviousSpace = false
		end

		Cursor += 1
	end

	const Length = Cursor - Start

	if Length < 1 or Length > 79 or Cursor >= End or PreviousSpace then
		error("invalid PNG text keyword")
	end

	return Cursor
end

const function ValidateUtf8(Data: buffer, Start: number, End: number)
	local Cursor = Start

	while Cursor < End do
		const Byte0 = buffer.readu8(Data, Cursor)
		local Codepoint = 0
		local ContinuationCount = 0

		if Byte0 <= 0x7f then
			Cursor += 1
			continue
		elseif Byte0 >= 0xc2 and Byte0 <= 0xdf then
			Codepoint = Byte0 - 0xc0
			ContinuationCount = 1
		elseif Byte0 >= 0xe0 and Byte0 <= 0xef then
			Codepoint = Byte0 - 0xe0
			ContinuationCount = 2
		elseif Byte0 >= 0xf0 and Byte0 <= 0xf4 then
			Codepoint = Byte0 - 0xf0
			ContinuationCount = 3
		else
			error("invalid PNG UTF-8")
		end

		if Cursor + ContinuationCount >= End then
			error("invalid PNG UTF-8")
		end

		for Offset = 1, ContinuationCount do
			const Byte = buffer.readu8(Data, Cursor + Offset)

			if Byte < 0x80 or Byte > 0xbf then
				error("invalid PNG UTF-8")
			end

			Codepoint = Codepoint * 64 + Byte - 0x80
		end

		if (ContinuationCount == 1 and Codepoint < 0x80)
			or (ContinuationCount == 2 and Codepoint < 0x800)
			or (ContinuationCount == 3 and Codepoint < 0x10000)
			or (Codepoint >= 0xd800 and Codepoint <= 0xdfff)
			or Codepoint > 0x10ffff
		then
			error("invalid PNG UTF-8")
		end

		Cursor += ContinuationCount + 1
	end
end

const function ValidateLanguageTag(Data: buffer, Start: number, End: number)
	if Start == End then
		return
	end

	local PartLength = 0

	for Cursor = Start, End - 1 do
		const Value = buffer.readu8(Data, Cursor)

		if (Value >= 0x41 and Value <= 0x5a) or (Value >= 0x61 and Value <= 0x7a) or (Value >= 0x30 and Value <= 0x39) then
			PartLength += 1

			if PartLength > 8 then
				error("invalid PNG iTXt language tag")
			end
		elseif Value == 0x2d then
			if PartLength == 0 then
				error("invalid PNG iTXt language tag")
			end

			PartLength = 0
		else
			error("invalid PNG iTXt language tag")
		end
	end

	if PartLength == 0 then
		error("invalid PNG iTXt language tag")
	end
end

const function FindNullByte(Data: buffer, Start: number, End: number): number
	local Cursor = Start

	while Cursor < End and buffer.readu8(Data, Cursor) ~= 0 do
		Cursor += 1
	end

	if Cursor >= End then
		error("invalid PNG text chunk")
	end

	return Cursor
end

const function SliceBuffer(Data: buffer, Offset: number, Count: number): buffer
	const Result = buffer.create(Count)
	buffer.copy(Result, 0, Data, Offset, Count)
	return Result
end

const function IsChunkNameByte(Value: number): boolean
	return (Value >= 0x41 and Value <= 0x5a) or (Value >= 0x61 and Value <= 0x7a)
end

const function ValidateChunkName(Data: buffer, Offset: number)
	const Byte0 = buffer.readu8(Data, Offset)
	const Byte1 = buffer.readu8(Data, Offset + 1)
	const Byte2 = buffer.readu8(Data, Offset + 2)
	const Byte3 = buffer.readu8(Data, Offset + 3)

	if not IsChunkNameByte(Byte0) or not IsChunkNameByte(Byte1) or not IsChunkNameByte(Byte2) or not IsChunkNameByte(Byte3) then
		error("invalid PNG chunk name")
	end

	if bit32.btest(Byte2, 32) then
		error("invalid PNG chunk reserved bit")
	end
end

const function IsCriticalChunk(Data: buffer, Offset: number): boolean
	return bit32.band(buffer.readu8(Data, Offset), 32) == 0
end

const function Crc32(Data: buffer, TypeOffset: number, DataOffset: number, DataLength: number): number
	const Lookup = CrcTable
	const Lookup1 = CrcTable1
	const Lookup2 = CrcTable2
	const Lookup3 = CrcTable3
	const Lookup4 = CrcTable4
	const Lookup5 = CrcTable5
	const Lookup6 = CrcTable6
	const Lookup7 = CrcTable7
	local Crc = 0xffffffff
	const DataEnd = DataOffset + DataLength
	const TotalLength = DataLength + 4
	const DataBlockEnd8 = DataEnd - bit32.band(TotalLength, 7)
	local Offset = TypeOffset

	while Offset < DataBlockEnd8 do
		const Word0 = bit32.bxor(Crc, buffer.readu32(Data, Offset))
		const Word1 = buffer.readu32(Data, Offset + 4)
		Crc = bit32.bxor(
			buffer.readu32(Lookup7, bit32.band(Word0, 0xff) * 4),
			buffer.readu32(Lookup6, bit32.band(bit32.rshift(Word0, 8), 0xff) * 4),
			buffer.readu32(Lookup5, bit32.band(bit32.rshift(Word0, 16), 0xff) * 4),
			buffer.readu32(Lookup4, bit32.rshift(Word0, 24) * 4),
			buffer.readu32(Lookup3, bit32.band(Word1, 0xff) * 4),
			buffer.readu32(Lookup2, bit32.band(bit32.rshift(Word1, 8), 0xff) * 4),
			buffer.readu32(Lookup1, bit32.band(bit32.rshift(Word1, 16), 0xff) * 4),
			buffer.readu32(Lookup, bit32.rshift(Word1, 24) * 4)
		)
		Offset += 8
	end

	if Offset + 4 <= DataEnd then
		Crc = bit32.bxor(Crc, buffer.readu32(Data, Offset))
		Crc = bit32.bxor(
			buffer.readu32(Lookup3, bit32.band(Crc, 0xff) * 4),
			buffer.readu32(Lookup2, bit32.band(bit32.rshift(Crc, 8), 0xff) * 4),
			buffer.readu32(Lookup1, bit32.band(bit32.rshift(Crc, 16), 0xff) * 4),
			buffer.readu32(Lookup, bit32.rshift(Crc, 24) * 4)
		)
		Offset += 4
	end

	for TailOffset = Offset, DataEnd - 1 do
		const TableIndex = bit32.band(bit32.bxor(Crc, buffer.readu8(Data, TailOffset)), 0xff) * 4
		Crc = bit32.bxor(buffer.readu32(Lookup, TableIndex), bit32.rshift(Crc, 8))
	end

	return bit32.bxor(Crc, 0xffffffff)
end

const function ReverseBits(Value: number, Count: number): number
	local Result = 0

	for _ = 1, Count do
		Result = Result * 2 + bit32.band(Value, 1)
		Value = bit32.rshift(Value, 1)
	end

	return Result
end

const function BuildInflateHuffman(Lengths: buffer, SymbolCount: number, StartIndex: number): InflateHuffman
	const CountByLength = buffer.create((MaxLookupBits + 1) * 2)
	const NextCode = buffer.create((MaxLookupBits + 1) * 4)
	const Lookup = buffer.create(HuffmanLookupSize * 4)
	local Code = 0

	for Symbol = 0, SymbolCount - 1 do
		const Length = buffer.readu8(Lengths, StartIndex + Symbol)

		if Length > MaxLookupBits then
			error("invalid deflate Huffman length")
		end

		if Length > 0 then
			const CountOffset = Length * 2
			buffer.writeu16(CountByLength, CountOffset, buffer.readu16(CountByLength, CountOffset) + 1)
		end
	end

	local RemainingCodes = 1

	for Length = 1, MaxLookupBits do
		RemainingCodes = RemainingCodes * 2 - buffer.readu16(CountByLength, Length * 2)

		if RemainingCodes < 0 then
			error("oversubscribed deflate Huffman table")
		end

		Code = (Code + buffer.readu16(CountByLength, (Length - 1) * 2)) * 2
		buffer.writeu32(NextCode, Length * 4, Code)
	end

	for Symbol = 0, SymbolCount - 1 do
		const Length = buffer.readu8(Lengths, StartIndex + Symbol)

		if Length > 0 then
			const NextCodeOffset = Length * 4
			const CurrentCode = buffer.readu32(NextCode, NextCodeOffset)
			const ReversedCode = ReverseBits(CurrentCode, Length)
			const Stride = BitPowers[Length]
			const Replications = HuffmanLookupSize // Stride
			const Entry = Symbol + Length * 65536
			buffer.writeu32(NextCode, NextCodeOffset, CurrentCode + 1)

			for Repeat = 0, Replications - 1 do
				const LookupIndex = ReversedCode + Repeat * Stride
				buffer.writeu32(Lookup, LookupIndex * 4, Entry)
			end
		end
	end

	return {
		Lookup = Lookup,
	}
end

const FixedLiteralHuffman = BuildInflateHuffman(FixedLiteralLengths, 288, 0)
const FixedDistanceHuffman = BuildInflateHuffman(FixedDistanceLengths, 32, 0)

const function EnsureInflateBits(Count: number)
	while InflateBitCount < Count and InflatePos < InflateLength do
		InflateBits += bit32.lshift(buffer.readu8(InflateData, InflatePos), InflateBitCount)
		InflateBitCount += 8
		InflatePos += 1
	end
end

const function ReadInflateBits(Count: number): number
	EnsureInflateBits(Count)

	if InflateBitCount < Count then
		error("unexpected end of deflate data")
	end

	const Value = bit32.band(InflateBits, BitPowers[Count] - 1)
	InflateBits = bit32.rshift(InflateBits, Count)
	InflateBitCount -= Count

	return Value
end

const function DecodeInflateSymbol(Huffman: InflateHuffman): number
	EnsureInflateBits(MaxLookupBits)

	const LookupIndex = bit32.band(InflateBits, HuffmanLookupSize - 1)
	const Entry = buffer.readu32(Huffman.Lookup, LookupIndex * 4)
	const Length = bit32.rshift(Entry, 16)

	if Length == 0 or Length > InflateBitCount then
		error("invalid deflate Huffman code")
	end

	const Symbol = bit32.band(Entry, 0xffff)
	InflateBits = bit32.rshift(InflateBits, Length)
	InflateBitCount -= Length

	return Symbol
end

const function WriteInflateByte(Value: number)
	if InflateOutputPos >= InflateOutputLength then
		error("deflate output exceeds expected size")
	end

	buffer.writeu8(InflateOutput, InflateOutputPos, Value)
	InflateOutputPos += 1
end

const function DecodeUncompressedBlock()
	const DropBits = InflateBitCount % 8

	if DropBits > 0 then
		ReadInflateBits(DropBits)
	end

	const Length = ReadInflateBits(16)
	const Check = ReadInflateBits(16)

	if bit32.bxor(Length, 0xffff) ~= Check then
		error("invalid deflate uncompressed length")
	end

	if InflateOutputPos + Length > InflateOutputLength then
		error("invalid deflate uncompressed block size")
	end

	if InflateBitCount == 0 and InflatePos + Length <= InflateLength then
		buffer.copy(InflateOutput, InflateOutputPos, InflateData, InflatePos, Length)
		InflatePos += Length
		InflateOutputPos += Length
	else
		for _ = 1, Length do
			WriteInflateByte(ReadInflateBits(8))
		end
	end
end

const function DecodeCompressedBlock(LiteralHuffman: InflateHuffman, DistanceHuffman: InflateHuffman)
	const Output = InflateOutput
	local OutputPos = InflateOutputPos
	const OutputLength = InflateOutputLength

	while true do
		const Symbol = DecodeInflateSymbol(LiteralHuffman)

		if Symbol < 256 then
			if OutputPos >= OutputLength then
				error("deflate output exceeds expected size")
			end

			buffer.writeu8(Output, OutputPos, Symbol)
			OutputPos += 1
		elseif Symbol == 256 then
			break
		elseif Symbol <= 285 then
			const LengthIndex = Symbol - 257 + 1
			local CopyLength = LengthBase[LengthIndex]
			const LengthExtraBits = LengthExtra[LengthIndex]

			if LengthExtraBits > 0 then
				CopyLength += ReadInflateBits(LengthExtraBits)
			end

			const DistanceSymbol = DecodeInflateSymbol(DistanceHuffman)

			if DistanceSymbol > 29 then
				error("invalid deflate distance symbol")
			end

			local CopyDistance = DistanceBase[DistanceSymbol + 1]
			const DistanceExtraBits = DistanceExtra[DistanceSymbol + 1]

			if DistanceExtraBits > 0 then
				CopyDistance += ReadInflateBits(DistanceExtraBits)
			end

			if CopyDistance > OutputPos then
				error("invalid deflate distance")
			end

			if OutputPos + CopyLength > OutputLength then
				error("deflate output exceeds expected size")
			end

			if CopyDistance == 1 then
				buffer.fill(Output, OutputPos, buffer.readu8(Output, OutputPos - 1), CopyLength)
				OutputPos += CopyLength
			elseif CopyDistance >= CopyLength then
				buffer.copy(Output, OutputPos, Output, OutputPos - CopyDistance, CopyLength)
				OutputPos += CopyLength
			else
				for _ = 1, CopyLength do
					buffer.writeu8(Output, OutputPos, buffer.readu8(Output, OutputPos - CopyDistance))
					OutputPos += 1
				end
			end
		else
			error("invalid deflate literal symbol")
		end
	end

	InflateOutputPos = OutputPos
end

const function DecodeDynamicBlock()
	const LiteralCount = ReadInflateBits(5) + 257
	const DistanceCount = ReadInflateBits(5) + 1
	const CodeLengthCount = ReadInflateBits(4) + 4

	if LiteralCount > 286 then
		error("invalid deflate literal count")
	end

	const CodeLengthLengths = buffer.create(19)
	const Lengths = buffer.create(LiteralCount + DistanceCount)

	for Index = 1, CodeLengthCount do
		buffer.writeu8(CodeLengthLengths, CodeLengthOrder[Index], ReadInflateBits(3))
	end

	const CodeLengthHuffman = BuildInflateHuffman(CodeLengthLengths, 19, 0)
	local Index = 0
	local PreviousLength = 0

	while Index < LiteralCount + DistanceCount do
		const Symbol = DecodeInflateSymbol(CodeLengthHuffman)

		if Symbol <= 15 then
			buffer.writeu8(Lengths, Index, Symbol)
			PreviousLength = Symbol
			Index += 1
		elseif Symbol == 16 then
			if Index == 0 then
				error("invalid deflate repeat length")
			end

			const RepeatCount = ReadInflateBits(2) + 3

			for _ = 1, RepeatCount do
				if Index >= LiteralCount + DistanceCount then
					error("deflate repeat exceeds table")
				end

				buffer.writeu8(Lengths, Index, PreviousLength)
				Index += 1
			end
		elseif Symbol == 17 then
			const RepeatCount = ReadInflateBits(3) + 3
			PreviousLength = 0

			for _ = 1, RepeatCount do
				if Index >= LiteralCount + DistanceCount then
					error("deflate repeat exceeds table")
				end

				buffer.writeu8(Lengths, Index, 0)
				Index += 1
			end
		elseif Symbol == 18 then
			const RepeatCount = ReadInflateBits(7) + 11
			PreviousLength = 0

			for _ = 1, RepeatCount do
				if Index >= LiteralCount + DistanceCount then
					error("deflate repeat exceeds table")
				end

				buffer.writeu8(Lengths, Index, 0)
				Index += 1
			end
		else
			error("invalid deflate code length symbol")
		end
	end

	if buffer.readu8(Lengths, 256) == 0 then
		error("missing deflate end code")
	end

	DecodeCompressedBlock(BuildInflateHuffman(Lengths, LiteralCount, 0), BuildInflateHuffman(Lengths, DistanceCount, LiteralCount))
end

const function InflateZlibInternal(Compressed: buffer, Start: number, Length: number, OutputLimit: number, ExactLength: number): buffer
	if Length < 6 then
		error("truncated zlib data")
	end

	if OutputLimit > MaxOutputBytes then
		error("zlib output too large")
	end

	const CompressionMethod = buffer.readu8(Compressed, Start)
	const Flags = buffer.readu8(Compressed, Start + 1)

	if bit32.band(CompressionMethod, 15) ~= 8 or bit32.rshift(CompressionMethod, 4) > 7 then
		error("unsupported zlib compression method")
	end

	if (CompressionMethod * 256 + Flags) % 31 ~= 0 then
		error("invalid zlib header check")
	end

	if bit32.btest(Flags, 32) then
		error("zlib preset dictionaries are not supported")
	end

	InflateData = Compressed
	InflateLength = Start + Length - 4
	InflatePos = Start + 2
	InflateBits = 0
	InflateBitCount = 0
	InflateOutput = buffer.create(OutputLimit)
	InflateOutputLength = OutputLimit
	InflateOutputPos = 0

	local FinalBlock = false

	while not FinalBlock do
		FinalBlock = ReadInflateBits(1) == 1
		const BlockType = ReadInflateBits(2)

		if BlockType == 0 then
			DecodeUncompressedBlock()
		elseif BlockType == 1 then
			DecodeCompressedBlock(FixedLiteralHuffman, FixedDistanceHuffman)
		elseif BlockType == 2 then
			DecodeDynamicBlock()
		else
			error("invalid deflate block type")
		end
	end

	if InflatePos < InflateLength or InflateBitCount >= 8 then
		error("trailing zlib deflate data")
	end

	if ExactLength >= 0 and InflateOutputPos ~= ExactLength then
		error("deflate output length mismatch")
	end

	local S1 = 1
	local S2 = 0
	local AdlerOffset = 0
	local RemainingAdlerBytes = InflateOutputPos

	while RemainingAdlerBytes >= 5552 do
		RemainingAdlerBytes -= 5552

		for _ = 1, 347 do
			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1

			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1

			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1

			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1

			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1

			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1

			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1

			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1

			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1

			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1

			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1

			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1

			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1

			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1

			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1

			S1 += buffer.readu8(InflateOutput, AdlerOffset)
			S2 += S1
			AdlerOffset += 1
		end

		S1 %= AdlerBase
		S2 %= AdlerBase
	end

	while RemainingAdlerBytes >= 16 do
		RemainingAdlerBytes -= 16

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1

		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1
	end

	while RemainingAdlerBytes > 0 do
		S1 += buffer.readu8(InflateOutput, AdlerOffset)
		S2 += S1
		AdlerOffset += 1
		RemainingAdlerBytes -= 1
	end

	S1 %= AdlerBase
	S2 %= AdlerBase

	const ActualAdler = S2 * 65536 + S1
	const ExpectedAdler = ReadU32BE(Compressed, Start + Length - 4)

	if ActualAdler ~= ExpectedAdler then
		error("invalid zlib Adler32")
	end

	local Output = InflateOutput

	if InflateOutputPos ~= OutputLimit then
		Output = buffer.create(InflateOutputPos)
		buffer.copy(Output, 0, InflateOutput, 0, InflateOutputPos)
	end

	InflateData = EmptyInflateData
	InflateLength = 0
	InflatePos = 0
	InflateBits = 0
	InflateBitCount = 0
	InflateOutput = EmptyInflateData
	InflateOutputPos = 0
	InflateOutputLength = 0

	return Output
end

const function InflateZlib(Compressed: buffer, ExpectedLength: number): buffer
	return InflateZlibInternal(Compressed, 0, buffer.len(Compressed), ExpectedLength, ExpectedLength)
end

const function ValidateZlibRange(Compressed: buffer, Start: number, Length: number)
	InflateZlibInternal(Compressed, Start, Length, MaxMetadataInflateBytes, -1)
end

const function ValidateColorType(ColorType: number, BitDepth: number): number
	if ColorType == 0 then
		if BitDepth == 1 or BitDepth == 2 or BitDepth == 4 or BitDepth == 8 or BitDepth == 16 then
			return 1
		end
	elseif ColorType == 2 then
		if BitDepth == 8 or BitDepth == 16 then
			return 3
		end
	elseif ColorType == 3 then
		if BitDepth == 1 or BitDepth == 2 or BitDepth == 4 or BitDepth == 8 then
			return 1
		end
	elseif ColorType == 4 then
		if BitDepth == 8 or BitDepth == 16 then
			return 2
		end
	elseif ColorType == 6 then
		if BitDepth == 8 or BitDepth == 16 then
			return 4
		end
	end

	error("unsupported PNG color type or bit depth")
	return 0
end

const function PassSize(Size: number, Start: number, Step: number): number
	if Size <= Start then
		return 0
	end

	return (Size - Start + Step - 1) // Step
end

const function Paeth(Left: number, Up: number, UpLeft: number): number
	const Estimate = Left + Up - UpLeft
	local LeftDistance = Estimate - Left
	local UpDistance = Estimate - Up
	local UpLeftDistance = Estimate - UpLeft

	if LeftDistance < 0 then
		LeftDistance = -LeftDistance
	end

	if UpDistance < 0 then
		UpDistance = -UpDistance
	end

	if UpLeftDistance < 0 then
		UpLeftDistance = -UpLeftDistance
	end

	if LeftDistance <= UpDistance and LeftDistance <= UpLeftDistance then
		return Left
	elseif UpDistance <= UpLeftDistance then
		return Up
	end

	return UpLeft
end

const function ReconstructRow(
	Inflated: buffer,
	InflatedOffset: number,
	CurrentRow: buffer,
	PreviousRow: buffer,
	RowBytes: number,
	FilterBpp: number
): number
	const Filter = buffer.readu8(Inflated, InflatedOffset)
	InflatedOffset += 1

	if Filter == 0 then
		buffer.copy(CurrentRow, 0, Inflated, InflatedOffset, RowBytes)
	elseif Filter == 1 then
		local InitialBytes = FilterBpp

		if InitialBytes > RowBytes then
			InitialBytes = RowBytes
		end

		buffer.copy(CurrentRow, 0, Inflated, InflatedOffset, InitialBytes)

		for Index = FilterBpp, RowBytes - 1 do
			buffer.writeu8(CurrentRow, Index, buffer.readu8(Inflated, InflatedOffset + Index) + buffer.readu8(CurrentRow, Index - FilterBpp))
		end
	elseif Filter == 2 then
		for Index = 0, RowBytes - 1 do
			buffer.writeu8(CurrentRow, Index, buffer.readu8(Inflated, InflatedOffset + Index) + buffer.readu8(PreviousRow, Index))
		end
	elseif Filter == 3 then
		local InitialBytes = FilterBpp

		if InitialBytes > RowBytes then
			InitialBytes = RowBytes
		end

		for Index = 0, InitialBytes - 1 do
			buffer.writeu8(
				CurrentRow,
				Index,
				buffer.readu8(Inflated, InflatedOffset + Index) + buffer.readu8(PreviousRow, Index) // 2
			)
		end

		for Index = FilterBpp, RowBytes - 1 do
			buffer.writeu8(
				CurrentRow,
				Index,
				buffer.readu8(Inflated, InflatedOffset + Index)
					+ (buffer.readu8(CurrentRow, Index - FilterBpp) + buffer.readu8(PreviousRow, Index)) // 2
			)
		end
	elseif Filter == 4 then
		local InitialBytes = FilterBpp

		if InitialBytes > RowBytes then
			InitialBytes = RowBytes
		end

		for Index = 0, InitialBytes - 1 do
			buffer.writeu8(CurrentRow, Index, buffer.readu8(Inflated, InflatedOffset + Index) + buffer.readu8(PreviousRow, Index))
		end

		for Index = FilterBpp, RowBytes - 1 do
			buffer.writeu8(
				CurrentRow,
				Index,
				buffer.readu8(Inflated, InflatedOffset + Index)
					+ Paeth(
						buffer.readu8(CurrentRow, Index - FilterBpp),
						buffer.readu8(PreviousRow, Index),
						buffer.readu8(PreviousRow, Index - FilterBpp)
					)
			)
		end
	else
		error("invalid PNG filter")
	end

	return InflatedOffset + RowBytes
end

const function DecodeRgba8NonInterlaced(Inflated: buffer, Width: number, Height: number): buffer
	const RowBytes = Width * 4
	const Output = buffer.create(RowBytes * Height)
	local InflatedOffset = 0

	for Y = 0, Height - 1 do
		const Filter = buffer.readu8(Inflated, InflatedOffset)
		InflatedOffset += 1
		const OutputOffset = Y * RowBytes
		const PreviousOffset = OutputOffset - RowBytes

		if Filter == 0 then
			buffer.copy(Output, OutputOffset, Inflated, InflatedOffset, RowBytes)
		elseif Filter == 1 or (Filter == 4 and Y == 0) then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset
			local LeftRed = 0
			local LeftGreen = 0
			local LeftBlue = 0
			local LeftAlpha = 0

			for _ = 1, Width do
				LeftRed = bit32.band(buffer.readu8(Inflated, SourceOffset) + LeftRed, 0xff)
				LeftGreen = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + LeftGreen, 0xff)
				LeftBlue = bit32.band(buffer.readu8(Inflated, SourceOffset + 2) + LeftBlue, 0xff)
				LeftAlpha = bit32.band(buffer.readu8(Inflated, SourceOffset + 3) + LeftAlpha, 0xff)
				buffer.writeu32(Output, TargetOffset, LeftRed + LeftGreen * 256 + LeftBlue * 65536 + LeftAlpha * 16777216)
				SourceOffset += 4
				TargetOffset += 4
			end
		elseif Filter == 2 then
			if Y == 0 then
				buffer.copy(Output, OutputOffset, Inflated, InflatedOffset, RowBytes)
			else
				local SourceOffset = InflatedOffset
				local TargetOffset = OutputOffset
				local UpOffset = PreviousOffset

				for _ = 1, Width do
					const Red = bit32.band(buffer.readu8(Inflated, SourceOffset) + buffer.readu8(Output, UpOffset), 0xff)
					const Green = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + buffer.readu8(Output, UpOffset + 1), 0xff)
					const Blue = bit32.band(buffer.readu8(Inflated, SourceOffset + 2) + buffer.readu8(Output, UpOffset + 2), 0xff)
					const Alpha = bit32.band(buffer.readu8(Inflated, SourceOffset + 3) + buffer.readu8(Output, UpOffset + 3), 0xff)
					buffer.writeu32(Output, TargetOffset, Red + Green * 256 + Blue * 65536 + Alpha * 16777216)
					SourceOffset += 4
					TargetOffset += 4
					UpOffset += 4
				end
			end
		elseif Filter == 3 then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset
			local UpOffset = PreviousOffset
			local LeftRed = 0
			local LeftGreen = 0
			local LeftBlue = 0
			local LeftAlpha = 0

			if Y == 0 then
				for _ = 1, Width do
					LeftRed = bit32.band(buffer.readu8(Inflated, SourceOffset) + LeftRed // 2, 0xff)
					LeftGreen = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + LeftGreen // 2, 0xff)
					LeftBlue = bit32.band(buffer.readu8(Inflated, SourceOffset + 2) + LeftBlue // 2, 0xff)
					LeftAlpha = bit32.band(buffer.readu8(Inflated, SourceOffset + 3) + LeftAlpha // 2, 0xff)
					buffer.writeu32(Output, TargetOffset, LeftRed + LeftGreen * 256 + LeftBlue * 65536 + LeftAlpha * 16777216)
					SourceOffset += 4
					TargetOffset += 4
				end
			else
				for _ = 1, Width do
					LeftRed = bit32.band(buffer.readu8(Inflated, SourceOffset) + (LeftRed + buffer.readu8(Output, UpOffset)) // 2, 0xff)
					LeftGreen = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + (LeftGreen + buffer.readu8(Output, UpOffset + 1)) // 2, 0xff)
					LeftBlue = bit32.band(buffer.readu8(Inflated, SourceOffset + 2) + (LeftBlue + buffer.readu8(Output, UpOffset + 2)) // 2, 0xff)
					LeftAlpha = bit32.band(buffer.readu8(Inflated, SourceOffset + 3) + (LeftAlpha + buffer.readu8(Output, UpOffset + 3)) // 2, 0xff)
					buffer.writeu32(Output, TargetOffset, LeftRed + LeftGreen * 256 + LeftBlue * 65536 + LeftAlpha * 16777216)
					SourceOffset += 4
					TargetOffset += 4
					UpOffset += 4
				end
			end
		elseif Filter == 4 then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset
			local UpOffset = PreviousOffset
			local UpLeftRed = 0
			local UpLeftGreen = 0
			local UpLeftBlue = 0
			local UpLeftAlpha = 0
			local LeftRed = 0
			local LeftGreen = 0
			local LeftBlue = 0
			local LeftAlpha = 0

			for _ = 1, Width do
				const UpRed = buffer.readu8(Output, UpOffset)
				const UpGreen = buffer.readu8(Output, UpOffset + 1)
				const UpBlue = buffer.readu8(Output, UpOffset + 2)
				const UpAlpha = buffer.readu8(Output, UpOffset + 3)
				LeftRed = bit32.band(buffer.readu8(Inflated, SourceOffset) + Paeth(LeftRed, UpRed, UpLeftRed), 0xff)
				LeftGreen = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + Paeth(LeftGreen, UpGreen, UpLeftGreen), 0xff)
				LeftBlue = bit32.band(buffer.readu8(Inflated, SourceOffset + 2) + Paeth(LeftBlue, UpBlue, UpLeftBlue), 0xff)
				LeftAlpha = bit32.band(buffer.readu8(Inflated, SourceOffset + 3) + Paeth(LeftAlpha, UpAlpha, UpLeftAlpha), 0xff)
				buffer.writeu32(Output, TargetOffset, LeftRed + LeftGreen * 256 + LeftBlue * 65536 + LeftAlpha * 16777216)
				UpLeftRed = UpRed
				UpLeftGreen = UpGreen
				UpLeftBlue = UpBlue
				UpLeftAlpha = UpAlpha
				SourceOffset += 4
				TargetOffset += 4
				UpOffset += 4
			end
		else
			error("invalid PNG filter")
		end

		InflatedOffset += RowBytes
	end

	if InflatedOffset ~= buffer.len(Inflated) then
		error("PNG image data length mismatch")
	end

	return Output
end

const function DecodeRgb8NonInterlaced(Inflated: buffer, Width: number, Height: number, TransparentRed: number, TransparentGreen: number, TransparentBlue: number): buffer
	const OutputRowBytes = Width * 4
	const InputRowBytes = Width * 3
	const Output = buffer.create(OutputRowBytes * Height)
	const TransparentRgb = TransparentRed + TransparentGreen * 256 + TransparentBlue * 65536
	local InflatedOffset = 0

	for Y = 0, Height - 1 do
		const Filter = buffer.readu8(Inflated, InflatedOffset)
		InflatedOffset += 1
		const OutputOffset = Y * OutputRowBytes
		const PreviousOffset = OutputOffset - OutputRowBytes

		if Filter == 0 or (Filter == 2 and Y == 0) then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset

			if TransparentRed < 0 then
				for _ = 1, Width do
					buffer.writeu32(Output, TargetOffset, 0xff000000 + buffer.readu16(Inflated, SourceOffset) + buffer.readu8(Inflated, SourceOffset + 2) * 65536)
					SourceOffset += 3
					TargetOffset += 4
				end
			else
				for _ = 1, Width do
					const Rgb = buffer.readu16(Inflated, SourceOffset) + buffer.readu8(Inflated, SourceOffset + 2) * 65536
					local Alpha = 255

					if Rgb == TransparentRgb then
						Alpha = 0
					end

					buffer.writeu32(Output, TargetOffset, Rgb + Alpha * 16777216)
					SourceOffset += 3
					TargetOffset += 4
				end
			end
		elseif Filter == 1 or (Filter == 4 and Y == 0) then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset
			local LeftRed = 0
			local LeftGreen = 0
			local LeftBlue = 0

			if TransparentRed < 0 then
				for _ = 1, Width do
					LeftRed = bit32.band(buffer.readu8(Inflated, SourceOffset) + LeftRed, 0xff)
					LeftGreen = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + LeftGreen, 0xff)
					LeftBlue = bit32.band(buffer.readu8(Inflated, SourceOffset + 2) + LeftBlue, 0xff)
					buffer.writeu32(Output, TargetOffset, 0xff000000 + LeftRed + LeftGreen * 256 + LeftBlue * 65536)
					SourceOffset += 3
					TargetOffset += 4
				end
			else
				for _ = 1, Width do
					LeftRed = bit32.band(buffer.readu8(Inflated, SourceOffset) + LeftRed, 0xff)
					LeftGreen = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + LeftGreen, 0xff)
					LeftBlue = bit32.band(buffer.readu8(Inflated, SourceOffset + 2) + LeftBlue, 0xff)
					const Rgb = LeftRed + LeftGreen * 256 + LeftBlue * 65536
					local Alpha = 255

					if Rgb == TransparentRgb then
						Alpha = 0
					end

					buffer.writeu32(Output, TargetOffset, Rgb + Alpha * 16777216)
					SourceOffset += 3
					TargetOffset += 4
				end
			end
		elseif Filter == 2 then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset
			local UpOffset = PreviousOffset

			if TransparentRed < 0 then
				for _ = 1, Width do
					const Red = bit32.band(buffer.readu8(Inflated, SourceOffset) + buffer.readu8(Output, UpOffset), 0xff)
					const Green = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + buffer.readu8(Output, UpOffset + 1), 0xff)
					const Blue = bit32.band(buffer.readu8(Inflated, SourceOffset + 2) + buffer.readu8(Output, UpOffset + 2), 0xff)
					buffer.writeu32(Output, TargetOffset, 0xff000000 + Red + Green * 256 + Blue * 65536)
					SourceOffset += 3
					TargetOffset += 4
					UpOffset += 4
				end
			else
				for _ = 1, Width do
					const Red = bit32.band(buffer.readu8(Inflated, SourceOffset) + buffer.readu8(Output, UpOffset), 0xff)
					const Green = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + buffer.readu8(Output, UpOffset + 1), 0xff)
					const Blue = bit32.band(buffer.readu8(Inflated, SourceOffset + 2) + buffer.readu8(Output, UpOffset + 2), 0xff)
					const Rgb = Red + Green * 256 + Blue * 65536
					local Alpha = 255

					if Rgb == TransparentRgb then
						Alpha = 0
					end

					buffer.writeu32(Output, TargetOffset, Rgb + Alpha * 16777216)
					SourceOffset += 3
					TargetOffset += 4
					UpOffset += 4
				end
			end
		elseif Filter == 3 then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset
			local UpOffset = PreviousOffset
			local LeftRed = 0
			local LeftGreen = 0
			local LeftBlue = 0

			if Y == 0 then
				if TransparentRed < 0 then
					for _ = 1, Width do
						LeftRed = bit32.band(buffer.readu8(Inflated, SourceOffset) + LeftRed // 2, 0xff)
						LeftGreen = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + LeftGreen // 2, 0xff)
						LeftBlue = bit32.band(buffer.readu8(Inflated, SourceOffset + 2) + LeftBlue // 2, 0xff)
						buffer.writeu32(Output, TargetOffset, 0xff000000 + LeftRed + LeftGreen * 256 + LeftBlue * 65536)
						SourceOffset += 3
						TargetOffset += 4
					end
				else
					for _ = 1, Width do
						LeftRed = bit32.band(buffer.readu8(Inflated, SourceOffset) + LeftRed // 2, 0xff)
						LeftGreen = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + LeftGreen // 2, 0xff)
						LeftBlue = bit32.band(buffer.readu8(Inflated, SourceOffset + 2) + LeftBlue // 2, 0xff)
						const Rgb = LeftRed + LeftGreen * 256 + LeftBlue * 65536
						local Alpha = 255

						if Rgb == TransparentRgb then
							Alpha = 0
						end

						buffer.writeu32(Output, TargetOffset, Rgb + Alpha * 16777216)
						SourceOffset += 3
						TargetOffset += 4
					end
				end
			elseif TransparentRed < 0 then
				for _ = 1, Width do
					LeftRed = bit32.band(buffer.readu8(Inflated, SourceOffset) + (LeftRed + buffer.readu8(Output, UpOffset)) // 2, 0xff)
					LeftGreen = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + (LeftGreen + buffer.readu8(Output, UpOffset + 1)) // 2, 0xff)
					LeftBlue = bit32.band(buffer.readu8(Inflated, SourceOffset + 2) + (LeftBlue + buffer.readu8(Output, UpOffset + 2)) // 2, 0xff)
					buffer.writeu32(Output, TargetOffset, 0xff000000 + LeftRed + LeftGreen * 256 + LeftBlue * 65536)
					SourceOffset += 3
					TargetOffset += 4
					UpOffset += 4
				end
			else
				for _ = 1, Width do
					LeftRed = bit32.band(buffer.readu8(Inflated, SourceOffset) + (LeftRed + buffer.readu8(Output, UpOffset)) // 2, 0xff)
					LeftGreen = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + (LeftGreen + buffer.readu8(Output, UpOffset + 1)) // 2, 0xff)
					LeftBlue = bit32.band(buffer.readu8(Inflated, SourceOffset + 2) + (LeftBlue + buffer.readu8(Output, UpOffset + 2)) // 2, 0xff)
					const Rgb = LeftRed + LeftGreen * 256 + LeftBlue * 65536
					local Alpha = 255

					if Rgb == TransparentRgb then
						Alpha = 0
					end

					buffer.writeu32(Output, TargetOffset, Rgb + Alpha * 16777216)
					SourceOffset += 3
					TargetOffset += 4
					UpOffset += 4
				end
			end
		elseif Filter == 4 then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset
			local UpOffset = PreviousOffset
			local UpLeftRed = 0
			local UpLeftGreen = 0
			local UpLeftBlue = 0
			local LeftRed = 0
			local LeftGreen = 0
			local LeftBlue = 0

			if TransparentRed < 0 then
				for _ = 1, Width do
					const UpRed = buffer.readu8(Output, UpOffset)
					const UpGreen = buffer.readu8(Output, UpOffset + 1)
					const UpBlue = buffer.readu8(Output, UpOffset + 2)
					LeftRed = bit32.band(buffer.readu8(Inflated, SourceOffset) + Paeth(LeftRed, UpRed, UpLeftRed), 0xff)
					LeftGreen = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + Paeth(LeftGreen, UpGreen, UpLeftGreen), 0xff)
					LeftBlue = bit32.band(buffer.readu8(Inflated, SourceOffset + 2) + Paeth(LeftBlue, UpBlue, UpLeftBlue), 0xff)
					buffer.writeu32(Output, TargetOffset, 0xff000000 + LeftRed + LeftGreen * 256 + LeftBlue * 65536)
					UpLeftRed = UpRed
					UpLeftGreen = UpGreen
					UpLeftBlue = UpBlue
					SourceOffset += 3
					TargetOffset += 4
					UpOffset += 4
				end
			else
				for _ = 1, Width do
					const UpRed = buffer.readu8(Output, UpOffset)
					const UpGreen = buffer.readu8(Output, UpOffset + 1)
					const UpBlue = buffer.readu8(Output, UpOffset + 2)
					LeftRed = bit32.band(buffer.readu8(Inflated, SourceOffset) + Paeth(LeftRed, UpRed, UpLeftRed), 0xff)
					LeftGreen = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + Paeth(LeftGreen, UpGreen, UpLeftGreen), 0xff)
					LeftBlue = bit32.band(buffer.readu8(Inflated, SourceOffset + 2) + Paeth(LeftBlue, UpBlue, UpLeftBlue), 0xff)
					const Rgb = LeftRed + LeftGreen * 256 + LeftBlue * 65536
					local Alpha = 255

					if Rgb == TransparentRgb then
						Alpha = 0
					end

					buffer.writeu32(Output, TargetOffset, Rgb + Alpha * 16777216)
					UpLeftRed = UpRed
					UpLeftGreen = UpGreen
					UpLeftBlue = UpBlue
					SourceOffset += 3
					TargetOffset += 4
					UpOffset += 4
				end
			end
		else
			error("invalid PNG filter")
		end

		InflatedOffset += InputRowBytes
	end

	if InflatedOffset ~= buffer.len(Inflated) then
		error("PNG image data length mismatch")
	end

	return Output
end

const function DecodeGray8NonInterlaced(Inflated: buffer, Width: number, Height: number, TransparentGray: number): buffer
	const OutputRowBytes = Width * 4
	const Output = buffer.create(OutputRowBytes * Height)
	local InflatedOffset = 0

	for Y = 0, Height - 1 do
		const Filter = buffer.readu8(Inflated, InflatedOffset)
		InflatedOffset += 1
		const OutputOffset = Y * OutputRowBytes
		const PreviousOffset = OutputOffset - OutputRowBytes

		if Filter == 0 or (Filter == 2 and Y == 0) then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset

			if TransparentGray < 0 then
				for _ = 1, Width do
					const Gray = buffer.readu8(Inflated, SourceOffset)
					buffer.writeu32(Output, TargetOffset, 0xff000000 + Gray * 65793)
					SourceOffset += 1
					TargetOffset += 4
				end
			else
				for _ = 1, Width do
					const Gray = buffer.readu8(Inflated, SourceOffset)
					local Alpha = 255

					if Gray == TransparentGray then
						Alpha = 0
					end

					buffer.writeu32(Output, TargetOffset, Alpha * 16777216 + Gray * 65793)
					SourceOffset += 1
					TargetOffset += 4
				end
			end
		elseif Filter == 1 or (Filter == 4 and Y == 0) then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset
			local Left = 0

			if TransparentGray < 0 then
				for _ = 1, Width do
					Left = bit32.band(buffer.readu8(Inflated, SourceOffset) + Left, 0xff)
					buffer.writeu32(Output, TargetOffset, 0xff000000 + Left * 65793)
					SourceOffset += 1
					TargetOffset += 4
				end
			else
				for _ = 1, Width do
					Left = bit32.band(buffer.readu8(Inflated, SourceOffset) + Left, 0xff)
					local Alpha = 255

					if Left == TransparentGray then
						Alpha = 0
					end

					buffer.writeu32(Output, TargetOffset, Alpha * 16777216 + Left * 65793)
					SourceOffset += 1
					TargetOffset += 4
				end
			end
		elseif Filter == 2 then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset
			local UpOffset = PreviousOffset

			if TransparentGray < 0 then
				for _ = 1, Width do
					const Gray = bit32.band(buffer.readu8(Inflated, SourceOffset) + buffer.readu8(Output, UpOffset), 0xff)
					buffer.writeu32(Output, TargetOffset, 0xff000000 + Gray * 65793)
					SourceOffset += 1
					TargetOffset += 4
					UpOffset += 4
				end
			else
				for _ = 1, Width do
					const Gray = bit32.band(buffer.readu8(Inflated, SourceOffset) + buffer.readu8(Output, UpOffset), 0xff)
					local Alpha = 255

					if Gray == TransparentGray then
						Alpha = 0
					end

					buffer.writeu32(Output, TargetOffset, Alpha * 16777216 + Gray * 65793)
					SourceOffset += 1
					TargetOffset += 4
					UpOffset += 4
				end
			end
		elseif Filter == 3 then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset
			local UpOffset = PreviousOffset
			local Left = 0

			if Y == 0 then
				if TransparentGray < 0 then
					for _ = 1, Width do
						Left = bit32.band(buffer.readu8(Inflated, SourceOffset) + Left // 2, 0xff)
						buffer.writeu32(Output, TargetOffset, 0xff000000 + Left * 65793)
						SourceOffset += 1
						TargetOffset += 4
					end
				else
					for _ = 1, Width do
						Left = bit32.band(buffer.readu8(Inflated, SourceOffset) + Left // 2, 0xff)
						local Alpha = 255

						if Left == TransparentGray then
							Alpha = 0
						end

						buffer.writeu32(Output, TargetOffset, Alpha * 16777216 + Left * 65793)
						SourceOffset += 1
						TargetOffset += 4
					end
				end
			elseif TransparentGray < 0 then
				for _ = 1, Width do
					Left = bit32.band(buffer.readu8(Inflated, SourceOffset) + (Left + buffer.readu8(Output, UpOffset)) // 2, 0xff)
					buffer.writeu32(Output, TargetOffset, 0xff000000 + Left * 65793)
					SourceOffset += 1
					TargetOffset += 4
					UpOffset += 4
				end
			else
				for _ = 1, Width do
					Left = bit32.band(buffer.readu8(Inflated, SourceOffset) + (Left + buffer.readu8(Output, UpOffset)) // 2, 0xff)
					local Alpha = 255

					if Left == TransparentGray then
						Alpha = 0
					end

					buffer.writeu32(Output, TargetOffset, Alpha * 16777216 + Left * 65793)
					SourceOffset += 1
					TargetOffset += 4
					UpOffset += 4
				end
			end
		elseif Filter == 4 then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset
			local UpOffset = PreviousOffset
			local UpLeft = 0
			local Left = 0

			if TransparentGray < 0 then
				for _ = 1, Width do
					const Up = buffer.readu8(Output, UpOffset)
					Left = bit32.band(buffer.readu8(Inflated, SourceOffset) + Paeth(Left, Up, UpLeft), 0xff)
					buffer.writeu32(Output, TargetOffset, 0xff000000 + Left * 65793)
					UpLeft = Up
					SourceOffset += 1
					TargetOffset += 4
					UpOffset += 4
				end
			else
				for _ = 1, Width do
					const Up = buffer.readu8(Output, UpOffset)
					Left = bit32.band(buffer.readu8(Inflated, SourceOffset) + Paeth(Left, Up, UpLeft), 0xff)
					local Alpha = 255

					if Left == TransparentGray then
						Alpha = 0
					end

					buffer.writeu32(Output, TargetOffset, Alpha * 16777216 + Left * 65793)
					UpLeft = Up
					SourceOffset += 1
					TargetOffset += 4
					UpOffset += 4
				end
			end
		else
			error("invalid PNG filter")
		end

		InflatedOffset += Width
	end

	if InflatedOffset ~= buffer.len(Inflated) then
		error("PNG image data length mismatch")
	end

	return Output
end

const function DecodeGrayAlpha8NonInterlaced(Inflated: buffer, Width: number, Height: number): buffer
	const OutputRowBytes = Width * 4
	const InputRowBytes = Width * 2
	const Output = buffer.create(OutputRowBytes * Height)
	local InflatedOffset = 0

	for Y = 0, Height - 1 do
		const Filter = buffer.readu8(Inflated, InflatedOffset)
		InflatedOffset += 1
		const OutputOffset = Y * OutputRowBytes
		const PreviousOffset = OutputOffset - OutputRowBytes

		if Filter == 0 or (Filter == 2 and Y == 0) then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset

			for _ = 1, Width do
				const GrayAlpha = buffer.readu16(Inflated, SourceOffset)
				const Gray = bit32.band(GrayAlpha, 0xff)
				const Alpha = bit32.rshift(GrayAlpha, 8)
				buffer.writeu32(Output, TargetOffset, Alpha * 16777216 + Gray * 65793)
				SourceOffset += 2
				TargetOffset += 4
			end
		elseif Filter == 1 or (Filter == 4 and Y == 0) then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset
			local LeftGray = 0
			local LeftAlpha = 0

			for _ = 1, Width do
				LeftGray = bit32.band(buffer.readu8(Inflated, SourceOffset) + LeftGray, 0xff)
				LeftAlpha = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + LeftAlpha, 0xff)
				buffer.writeu32(Output, TargetOffset, LeftAlpha * 16777216 + LeftGray * 65793)
				SourceOffset += 2
				TargetOffset += 4
			end
		elseif Filter == 2 then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset
			local UpOffset = PreviousOffset

			for _ = 1, Width do
				const Gray = bit32.band(buffer.readu8(Inflated, SourceOffset) + buffer.readu8(Output, UpOffset), 0xff)
				const Alpha = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + buffer.readu8(Output, UpOffset + 3), 0xff)
				buffer.writeu32(Output, TargetOffset, Alpha * 16777216 + Gray * 65793)
				SourceOffset += 2
				TargetOffset += 4
				UpOffset += 4
			end
		elseif Filter == 3 then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset
			local UpOffset = PreviousOffset
			local LeftGray = 0
			local LeftAlpha = 0

			if Y == 0 then
				for _ = 1, Width do
					LeftGray = bit32.band(buffer.readu8(Inflated, SourceOffset) + LeftGray // 2, 0xff)
					LeftAlpha = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + LeftAlpha // 2, 0xff)
					buffer.writeu32(Output, TargetOffset, LeftAlpha * 16777216 + LeftGray * 65793)
					SourceOffset += 2
					TargetOffset += 4
				end
			else
				for _ = 1, Width do
					LeftGray = bit32.band(buffer.readu8(Inflated, SourceOffset) + (LeftGray + buffer.readu8(Output, UpOffset)) // 2, 0xff)
					LeftAlpha = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + (LeftAlpha + buffer.readu8(Output, UpOffset + 3)) // 2, 0xff)
					buffer.writeu32(Output, TargetOffset, LeftAlpha * 16777216 + LeftGray * 65793)
					SourceOffset += 2
					TargetOffset += 4
					UpOffset += 4
				end
			end
		elseif Filter == 4 then
			local SourceOffset = InflatedOffset
			local TargetOffset = OutputOffset
			local UpOffset = PreviousOffset
			local UpLeftGray = 0
			local UpLeftAlpha = 0
			local LeftGray = 0
			local LeftAlpha = 0

			for _ = 1, Width do
				const UpGray = buffer.readu8(Output, UpOffset)
				const UpAlpha = buffer.readu8(Output, UpOffset + 3)
				LeftGray = bit32.band(buffer.readu8(Inflated, SourceOffset) + Paeth(LeftGray, UpGray, UpLeftGray), 0xff)
				LeftAlpha = bit32.band(buffer.readu8(Inflated, SourceOffset + 1) + Paeth(LeftAlpha, UpAlpha, UpLeftAlpha), 0xff)
				buffer.writeu32(Output, TargetOffset, LeftAlpha * 16777216 + LeftGray * 65793)
				UpLeftGray = UpGray
				UpLeftAlpha = UpAlpha
				SourceOffset += 2
				TargetOffset += 4
				UpOffset += 4
			end
		else
			error("invalid PNG filter")
		end

		InflatedOffset += InputRowBytes
	end

	if InflatedOffset ~= buffer.len(Inflated) then
		error("PNG image data length mismatch")
	end

	return Output
end

const function DecodePalette8NonInterlaced(Inflated: buffer, Width: number, Height: number, Palette: buffer, PaletteEntries: number): buffer
	const OutputRowBytes = Width * 4
	const Output = buffer.create(OutputRowBytes * Height)
	local CurrentRow = buffer.create(Width)
	local PreviousRow = buffer.create(Width)
	local InflatedOffset = 0

	for Y = 0, Height - 1 do
		InflatedOffset = ReconstructRow(Inflated, InflatedOffset, CurrentRow, PreviousRow, Width, 1)
		const OutputOffset = Y * OutputRowBytes
		local TargetOffset = OutputOffset

		if PaletteEntries == 256 then
			for X = 0, Width - 1 do
				const PaletteIndex = buffer.readu8(CurrentRow, X)
				buffer.writeu32(Output, TargetOffset, buffer.readu32(Palette, PaletteIndex * 4))
				TargetOffset += 4
			end
		else
			for X = 0, Width - 1 do
				const PaletteIndex = buffer.readu8(CurrentRow, X)

				if PaletteIndex >= PaletteEntries then
					error("PNG palette index out of range")
				end

				buffer.writeu32(Output, TargetOffset, buffer.readu32(Palette, PaletteIndex * 4))
				TargetOffset += 4
			end
		end

		const SwapRow = PreviousRow
		PreviousRow = CurrentRow
		CurrentRow = SwapRow
	end

	if InflatedOffset ~= buffer.len(Inflated) then
		error("PNG image data length mismatch")
	end

	return Output
end

const function ReadPackedSample(Row: buffer, BitDepth: number, PixelIndex: number): number
	if BitDepth == 8 then
		return buffer.readu8(Row, PixelIndex)
	elseif BitDepth == 4 then
		return bit32.extract(buffer.readu8(Row, PixelIndex // 2), 4 - (PixelIndex % 2) * 4, 4)
	elseif BitDepth == 2 then
		return bit32.extract(buffer.readu8(Row, PixelIndex // 4), 6 - (PixelIndex % 4) * 2, 2)
	end

	return bit32.extract(buffer.readu8(Row, PixelIndex // 8), 7 - PixelIndex % 8, 1)
end

const function ScaleSample(Value: number, BitDepth: number): number
	if BitDepth == 1 then
		return Value * 255
	elseif BitDepth == 2 then
		return Value * 85
	elseif BitDepth == 4 then
		return Value * 17
	end

	return Value
end

const function WritePixel(
	Output: buffer,
	OutputOffset: number,
	Row: buffer,
	PixelIndex: number,
	ColorType: number,
	BitDepth: number,
	Palette: buffer,
	PaletteEntries: number,
	TransparentGray: number,
	TransparentRed: number,
	TransparentGreen: number,
	TransparentBlue: number
)
	local Red = 0
	local Green = 0
	local Blue = 0
	local Alpha = 255

	if ColorType == 0 then
		if BitDepth == 16 then
			const Offset = PixelIndex * 2
			Red = buffer.readu8(Row, Offset)
			Green = Red
			Blue = Red

			if TransparentGray >= 0 and ReadU16BE(Row, Offset) == TransparentGray then
				Alpha = 0
			end
		else
			const Gray = ReadPackedSample(Row, BitDepth, PixelIndex)
			Red = ScaleSample(Gray, BitDepth)
			Green = Red
			Blue = Red

			if Gray == TransparentGray then
				Alpha = 0
			end
		end
	elseif ColorType == 2 then
		if BitDepth == 16 then
			const Offset = PixelIndex * 6
			Red = buffer.readu8(Row, Offset)
			Green = buffer.readu8(Row, Offset + 2)
			Blue = buffer.readu8(Row, Offset + 4)

			if TransparentRed >= 0
				and ReadU16BE(Row, Offset) == TransparentRed
				and ReadU16BE(Row, Offset + 2) == TransparentGreen
				and ReadU16BE(Row, Offset + 4) == TransparentBlue
			then
				Alpha = 0
			end
		else
			const Offset = PixelIndex * 3
			Red = buffer.readu8(Row, Offset)
			Green = buffer.readu8(Row, Offset + 1)
			Blue = buffer.readu8(Row, Offset + 2)

			if Red == TransparentRed and Green == TransparentGreen and Blue == TransparentBlue then
				Alpha = 0
			end
		end
	elseif ColorType == 3 then
		const PaletteIndex = ReadPackedSample(Row, BitDepth, PixelIndex)

		if PaletteIndex >= PaletteEntries then
			error("PNG palette index out of range")
		end

		buffer.writeu32(Output, OutputOffset, buffer.readu32(Palette, PaletteIndex * 4))
		return
	elseif ColorType == 4 then
		if BitDepth == 16 then
			const Offset = PixelIndex * 4
			Red = buffer.readu8(Row, Offset)
			Green = Red
			Blue = Red
			Alpha = buffer.readu8(Row, Offset + 2)
		else
			const Offset = PixelIndex * 2
			Red = buffer.readu8(Row, Offset)
			Green = Red
			Blue = Red
			Alpha = buffer.readu8(Row, Offset + 1)
		end
	else
		if BitDepth == 16 then
			const Offset = PixelIndex * 8
			Red = buffer.readu8(Row, Offset)
			Green = buffer.readu8(Row, Offset + 2)
			Blue = buffer.readu8(Row, Offset + 4)
			Alpha = buffer.readu8(Row, Offset + 6)
		else
			const Offset = PixelIndex * 4
			Red = buffer.readu8(Row, Offset)
			Green = buffer.readu8(Row, Offset + 1)
			Blue = buffer.readu8(Row, Offset + 2)
			Alpha = buffer.readu8(Row, Offset + 3)
		end
	end

	buffer.writeu32(Output, OutputOffset, Red + Green * 256 + Blue * 65536 + Alpha * 16777216)
end

const function WriteFastRow(
	Output: buffer,
	OutputOffset: number,
	Row: buffer,
	Width: number,
	ColorType: number,
	BitDepth: number,
	Palette: buffer,
	PaletteEntries: number,
	TransparentGray: number,
	TransparentRed: number,
	TransparentGreen: number,
	TransparentBlue: number
): boolean
	if ColorType == 6 and BitDepth == 8 then
		buffer.copy(Output, OutputOffset, Row, 0, Width * 4)
		return true
	elseif ColorType == 6 and BitDepth == 16 then
		local SourceOffset = 0

		for _ = 1, Width do
			const Red = buffer.readu8(Row, SourceOffset)
			const Green = buffer.readu8(Row, SourceOffset + 2)
			const Blue = buffer.readu8(Row, SourceOffset + 4)
			const Alpha = buffer.readu8(Row, SourceOffset + 6)
			buffer.writeu32(Output, OutputOffset, Red + Green * 256 + Blue * 65536 + Alpha * 16777216)
			SourceOffset += 8
			OutputOffset += 4
		end

		return true
	elseif ColorType == 2 and BitDepth == 8 then
		local SourceOffset = 0

		if TransparentRed < 0 then
			for _ = 1, Width do
				buffer.writeu32(Output, OutputOffset, 0xff000000 + buffer.readu16(Row, SourceOffset) + buffer.readu8(Row, SourceOffset + 2) * 65536)
				SourceOffset += 3
				OutputOffset += 4
			end
		else
			const TransparentRgb = TransparentRed + TransparentGreen * 256 + TransparentBlue * 65536

			for _ = 1, Width do
				const Rgb = buffer.readu16(Row, SourceOffset) + buffer.readu8(Row, SourceOffset + 2) * 65536
				local Alpha = 255

				if Rgb == TransparentRgb then
					Alpha = 0
				end

				buffer.writeu32(Output, OutputOffset, Rgb + Alpha * 16777216)
				SourceOffset += 3
				OutputOffset += 4
			end
		end

		return true
	elseif ColorType == 2 and BitDepth == 16 then
		local SourceOffset = 0

		if TransparentRed < 0 then
			for _ = 1, Width do
				const Red = buffer.readu8(Row, SourceOffset)
				const Green = buffer.readu8(Row, SourceOffset + 2)
				const Blue = buffer.readu8(Row, SourceOffset + 4)
				buffer.writeu32(Output, OutputOffset, 0xff000000 + Red + Green * 256 + Blue * 65536)
				SourceOffset += 6
				OutputOffset += 4
			end
		else
			for _ = 1, Width do
				const Red16 = ReadU16BE(Row, SourceOffset)
				const Green16 = ReadU16BE(Row, SourceOffset + 2)
				const Blue16 = ReadU16BE(Row, SourceOffset + 4)
				const Red = buffer.readu8(Row, SourceOffset)
				const Green = buffer.readu8(Row, SourceOffset + 2)
				const Blue = buffer.readu8(Row, SourceOffset + 4)
				local Alpha = 255

				if Red16 == TransparentRed and Green16 == TransparentGreen and Blue16 == TransparentBlue then
					Alpha = 0
				end

				buffer.writeu32(Output, OutputOffset, Red + Green * 256 + Blue * 65536 + Alpha * 16777216)
				SourceOffset += 6
				OutputOffset += 4
			end
		end

		return true
	elseif ColorType == 3 and BitDepth == 8 then
		for X = 0, Width - 1 do
			const PaletteIndex = buffer.readu8(Row, X)

			if PaletteIndex >= PaletteEntries then
				error("PNG palette index out of range")
			end

			buffer.writeu32(Output, OutputOffset, buffer.readu32(Palette, PaletteIndex * 4))
			OutputOffset += 4
		end

		return true
	elseif ColorType == 3 then
		local SourceOffset = 0
		local PixelIndex = 0

		while PixelIndex < Width do
			const Packed = buffer.readu8(Row, SourceOffset)
			SourceOffset += 1

			for Shift = 8 - BitDepth, 0, -BitDepth do
				const PaletteIndex = bit32.extract(Packed, Shift, BitDepth)

				if PaletteIndex >= PaletteEntries then
					error("PNG palette index out of range")
				end

				buffer.writeu32(Output, OutputOffset, buffer.readu32(Palette, PaletteIndex * 4))
				OutputOffset += 4
				PixelIndex += 1

				if PixelIndex >= Width then
					break
				end
			end
		end

		return true
	elseif ColorType == 0 and BitDepth == 8 then
		if TransparentGray < 0 then
			for X = 0, Width - 1 do
				const Gray = buffer.readu8(Row, X)
				buffer.writeu32(Output, OutputOffset, 0xff000000 + Gray * 65793)
				OutputOffset += 4
			end
		else
			for X = 0, Width - 1 do
				const Gray = buffer.readu8(Row, X)
				local Alpha = 255

				if Gray == TransparentGray then
					Alpha = 0
				end

				buffer.writeu32(Output, OutputOffset, Alpha * 16777216 + Gray * 65793)
				OutputOffset += 4
			end
		end

		return true
	elseif ColorType == 0 and BitDepth < 8 then
		local Scale = 17

		if BitDepth == 1 then
			Scale = 255
		elseif BitDepth == 2 then
			Scale = 85
		end

		local SourceOffset = 0
		local PixelIndex = 0

		while PixelIndex < Width do
			const Packed = buffer.readu8(Row, SourceOffset)
			SourceOffset += 1

			for Shift = 8 - BitDepth, 0, -BitDepth do
				const GraySample = bit32.extract(Packed, Shift, BitDepth)
				const Gray = GraySample * Scale
				local Alpha = 255

				if GraySample == TransparentGray then
					Alpha = 0
				end

				buffer.writeu32(Output, OutputOffset, Alpha * 16777216 + Gray * 65793)
				OutputOffset += 4
				PixelIndex += 1

				if PixelIndex >= Width then
					break
				end
			end
		end

		return true
	elseif ColorType == 0 and BitDepth == 16 then
		local SourceOffset = 0

		if TransparentGray < 0 then
			for _ = 1, Width do
				const Gray = buffer.readu8(Row, SourceOffset)
				buffer.writeu32(Output, OutputOffset, 0xff000000 + Gray * 65793)
				SourceOffset += 2
				OutputOffset += 4
			end
		else
			for _ = 1, Width do
				const Gray16 = ReadU16BE(Row, SourceOffset)
				const Gray = buffer.readu8(Row, SourceOffset)
				local Alpha = 255

				if Gray16 == TransparentGray then
					Alpha = 0
				end

				buffer.writeu32(Output, OutputOffset, Alpha * 16777216 + Gray * 65793)
				SourceOffset += 2
				OutputOffset += 4
			end
		end

		return true
	elseif ColorType == 4 and BitDepth == 8 then
		local SourceOffset = 0

		for _ = 1, Width do
			const GrayAlpha = buffer.readu16(Row, SourceOffset)
			const Gray = bit32.band(GrayAlpha, 0xff)
			const Alpha = bit32.rshift(GrayAlpha, 8)
			buffer.writeu32(Output, OutputOffset, Alpha * 16777216 + Gray * 65793)
			SourceOffset += 2
			OutputOffset += 4
		end

		return true
	elseif ColorType == 4 and BitDepth == 16 then
		local SourceOffset = 0

		for _ = 1, Width do
			const Gray = buffer.readu8(Row, SourceOffset)
			const Alpha = buffer.readu8(Row, SourceOffset + 2)
			buffer.writeu32(Output, OutputOffset, Alpha * 16777216 + Gray * 65793)
			SourceOffset += 4
			OutputOffset += 4
		end

		return true
	end

	return false
end

const function DecodePixels(
	Inflated: buffer,
	Width: number,
	Height: number,
	ColorType: number,
	BitDepth: number,
	Channels: number,
	InterlaceMethod: number,
	Palette: buffer,
	PaletteEntries: number,
	TransparentGray: number,
	TransparentRed: number,
	TransparentGreen: number,
	TransparentBlue: number
): buffer
	if InterlaceMethod == 0 and ColorType == 6 and BitDepth == 8 then
		return DecodeRgba8NonInterlaced(Inflated, Width, Height)
	elseif InterlaceMethod == 0 and ColorType == 2 and BitDepth == 8 then
		return DecodeRgb8NonInterlaced(Inflated, Width, Height, TransparentRed, TransparentGreen, TransparentBlue)
	elseif InterlaceMethod == 0 and ColorType == 0 and BitDepth == 8 then
		return DecodeGray8NonInterlaced(Inflated, Width, Height, TransparentGray)
	elseif InterlaceMethod == 0 and ColorType == 4 and BitDepth == 8 then
		return DecodeGrayAlpha8NonInterlaced(Inflated, Width, Height)
	elseif InterlaceMethod == 0 and ColorType == 3 and BitDepth == 8 then
		return DecodePalette8NonInterlaced(Inflated, Width, Height, Palette, PaletteEntries)
	end

	const Output = buffer.create(Width * Height * 4)
	const BitsPerPixel = Channels * BitDepth
	const FilterBpp = math.max(1, (BitsPerPixel + 7) // 8)
	local InflatedOffset = 0

	if InterlaceMethod == 0 then
		const RowBytes = (Width * BitsPerPixel + 7) // 8
		local CurrentRow = buffer.create(RowBytes)
		local PreviousRow = buffer.create(RowBytes)

		for Y = 0, Height - 1 do
			InflatedOffset = ReconstructRow(Inflated, InflatedOffset, CurrentRow, PreviousRow, RowBytes, FilterBpp)

			const OutputOffset = Y * Width * 4

			if not WriteFastRow(
				Output,
				OutputOffset,
				CurrentRow,
				Width,
				ColorType,
				BitDepth,
				Palette,
				PaletteEntries,
				TransparentGray,
				TransparentRed,
				TransparentGreen,
				TransparentBlue
			) then
				for X = 0, Width - 1 do
					WritePixel(
						Output,
						OutputOffset + X * 4,
						CurrentRow,
						X,
						ColorType,
						BitDepth,
						Palette,
						PaletteEntries,
						TransparentGray,
						TransparentRed,
						TransparentGreen,
						TransparentBlue
					)
				end
			end

			const SwapRow = PreviousRow
			PreviousRow = CurrentRow
			CurrentRow = SwapRow
		end
	else
		for Pass = 1, 7 do
			const PassWidth = PassSize(Width, Adam7StartX[Pass], Adam7StepX[Pass])
			const PassHeight = PassSize(Height, Adam7StartY[Pass], Adam7StepY[Pass])

			if PassWidth > 0 and PassHeight > 0 then
				const RowBytes = (PassWidth * BitsPerPixel + 7) // 8
				local CurrentRow = buffer.create(RowBytes)
				local PreviousRow = buffer.create(RowBytes)

				for PassY = 0, PassHeight - 1 do
					InflatedOffset = ReconstructRow(Inflated, InflatedOffset, CurrentRow, PreviousRow, RowBytes, FilterBpp)

					for PassX = 0, PassWidth - 1 do
						const X = Adam7StartX[Pass] + PassX * Adam7StepX[Pass]
						const Y = Adam7StartY[Pass] + PassY * Adam7StepY[Pass]
						WritePixel(
							Output,
							(Y * Width + X) * 4,
							CurrentRow,
							PassX,
							ColorType,
							BitDepth,
							Palette,
							PaletteEntries,
							TransparentGray,
							TransparentRed,
							TransparentGreen,
							TransparentBlue
						)
					end

					const SwapRow = PreviousRow
					PreviousRow = CurrentRow
					CurrentRow = SwapRow
				end
			end
		end
	end

	if InflatedOffset ~= buffer.len(Inflated) then
		error("PNG image data length mismatch")
	end

	return Output
end

const function ExpectedInflatedLength(Width: number, Height: number, BitsPerPixel: number, InterlaceMethod: number): number
	local Total = 0

	if InterlaceMethod == 0 then
		return Height * (((Width * BitsPerPixel + 7) // 8) + 1)
	end

	for Pass = 1, 7 do
		const PassWidth = PassSize(Width, Adam7StartX[Pass], Adam7StepX[Pass])
		const PassHeight = PassSize(Height, Adam7StartY[Pass], Adam7StepY[Pass])

		if PassWidth > 0 and PassHeight > 0 then
			Total += PassHeight * (((PassWidth * BitsPerPixel + 7) // 8) + 1)
		end
	end

	return Total
end

const function StaticAdvanceFrame()
end

const function StaticReset()
end

const function AddFrameData(Frame: PngFrame, Offset: number, Count: number)
	if Count > MaxOutputBytes - Frame.DataLength then
		error("APNG frame data too large")
	end

	Frame.DataLength += Count
	Frame.DataOffsets[#Frame.DataOffsets + 1] = Offset
	Frame.DataLengths[#Frame.DataLengths + 1] = Count
end

const function BuildChunkData(Source: buffer, Offsets: { [number]: number }, Lengths: { [number]: number }, TotalLength: number): buffer
	const Data = buffer.create(TotalLength)
	local DataOffset = 0

	for Index = 1, #Offsets do
		const SegmentLength = Lengths[Index]
		buffer.copy(Data, DataOffset, Source, Offsets[Index], SegmentLength)
		DataOffset += SegmentLength
	end

	return Data
end

const function DecodeFramePixels(
	PngData: buffer,
	Frame: PngFrame,
	ColorType: number,
	BitDepth: number,
	Channels: number,
	InterlaceMethod: number,
	Palette: buffer,
	PaletteEntries: number,
	TransparentGray: number,
	TransparentRed: number,
	TransparentGreen: number,
	TransparentBlue: number
): buffer
	if Frame.DataLength <= 0 then
		error("missing APNG frame data")
	end

	const BitsPerPixel = Channels * BitDepth
	const ExpectedLength = ExpectedInflatedLength(Frame.Width, Frame.Height, BitsPerPixel, InterlaceMethod)

	if ExpectedLength > MaxOutputBytes then
		error("APNG frame data too large")
	end

	local Inflated = EmptyInflateData

	if #Frame.DataOffsets == 1 then
		Inflated = InflateZlibInternal(PngData, Frame.DataOffsets[1], Frame.DataLength, ExpectedLength, ExpectedLength)
	else
		const FrameData = BuildChunkData(PngData, Frame.DataOffsets, Frame.DataLengths, Frame.DataLength)
		Inflated = InflateZlib(FrameData, ExpectedLength)
	end

	return DecodePixels(
		Inflated,
		Frame.Width,
		Frame.Height,
		ColorType,
		BitDepth,
		Channels,
		InterlaceMethod,
		Palette,
		PaletteEntries,
		TransparentGray,
		TransparentRed,
		TransparentGreen,
		TransparentBlue
	)
end

const function DecodeAnimationFrames(
	PngData: buffer,
	Frames: { PngFrame },
	StartIndex: number,
	ColorType: number,
	BitDepth: number,
	Channels: number,
	InterlaceMethod: number,
	Palette: buffer,
	PaletteEntries: number,
	TransparentGray: number,
	TransparentRed: number,
	TransparentGreen: number,
	TransparentBlue: number
)
	for Index = StartIndex, #Frames do
		Frames[Index].Pixels = DecodeFramePixels(
			PngData,
			Frames[Index],
			ColorType,
			BitDepth,
			Channels,
			InterlaceMethod,
			Palette,
			PaletteEntries,
			TransparentGray,
			TransparentRed,
			TransparentGreen,
			TransparentBlue
		)
	end
end

const function ClearFrameArea(Canvas: buffer, CanvasWidth: number, XOffset: number, YOffset: number, Width: number, Height: number)
	if Width <= 0 or Height <= 0 then
		return
	end

	for Y = 0, Height - 1 do
		buffer.fill(Canvas, ((YOffset + Y) * CanvasWidth + XOffset) * 4, 0, Width * 4)
	end
end

const function SaveFrameArea(State: PngState, Frame: PngFrame)
	const RestoreBuffer = buffer.create(Frame.Width * Frame.Height * 4)

	for Y = 0, Frame.Height - 1 do
		buffer.copy(
			RestoreBuffer,
			Y * Frame.Width * 4,
			State.Canvas,
			((Frame.YOffset + Y) * State.Width + Frame.XOffset) * 4,
			Frame.Width * 4
		)
	end

	State.RestoreBuffer = RestoreBuffer
	State.RestoreX = Frame.XOffset
	State.RestoreY = Frame.YOffset
	State.RestoreWidth = Frame.Width
	State.RestoreHeight = Frame.Height
end

const function RestoreFrameArea(State: PngState)
	const RestoreBuffer = State.RestoreBuffer

	if RestoreBuffer == nil then
		return
	end

	for Y = 0, State.RestoreHeight - 1 do
		buffer.copy(
			State.Canvas,
			((State.RestoreY + Y) * State.Width + State.RestoreX) * 4,
			RestoreBuffer,
			Y * State.RestoreWidth * 4,
			State.RestoreWidth * 4
		)
	end
end

const function BlendPixel(Source: number, Destination: number): number
	const SourceAlpha = bit32.rshift(Source, 24)

	if SourceAlpha == 0 then
		return Destination
	elseif SourceAlpha == 255 then
		return Source
	end

	const DestinationAlpha = bit32.rshift(Destination, 24)

	if DestinationAlpha == 0 then
		return Source
	end

	const SourceRed = bit32.extract(Source, 0, 8)
	const SourceGreen = bit32.extract(Source, 8, 8)
	const SourceBlue = bit32.extract(Source, 16, 8)
	const DestinationRed = bit32.extract(Destination, 0, 8)
	const DestinationGreen = bit32.extract(Destination, 8, 8)
	const DestinationBlue = bit32.extract(Destination, 16, 8)
	const DestinationWeight = (DestinationAlpha * (255 - SourceAlpha) + 127) // 255
	const OutputAlpha = SourceAlpha + DestinationWeight
	const Red = (SourceRed * SourceAlpha + DestinationRed * DestinationWeight + OutputAlpha // 2) // OutputAlpha
	const Green = (SourceGreen * SourceAlpha + DestinationGreen * DestinationWeight + OutputAlpha // 2) // OutputAlpha
	const Blue = (SourceBlue * SourceAlpha + DestinationBlue * DestinationWeight + OutputAlpha // 2) // OutputAlpha

	return Red + Green * 256 + Blue * 65536 + OutputAlpha * 16777216
end

const function DrawAnimationFrame(State: PngState, Frame: PngFrame)
	if Frame.DisposeOp == 2 then
		SaveFrameArea(State, Frame)
	else
		State.RestoreBuffer = nil
		State.RestoreX = 0
		State.RestoreY = 0
		State.RestoreWidth = 0
		State.RestoreHeight = 0
	end

	const Pixels = Frame.Pixels

	if Frame.BlendOp == 0 then
		for Y = 0, Frame.Height - 1 do
			buffer.copy(
				State.Canvas,
				((Frame.YOffset + Y) * State.Width + Frame.XOffset) * 4,
				Pixels,
				Y * Frame.Width * 4,
				Frame.Width * 4
			)
		end
	else
		for Y = 0, Frame.Height - 1 do
			local OutputOffset = ((Frame.YOffset + Y) * State.Width + Frame.XOffset) * 4
			local SourceOffset = Y * Frame.Width * 4

			for _ = 1, Frame.Width do
				buffer.writeu32(State.Canvas, OutputOffset, BlendPixel(buffer.readu32(Pixels, SourceOffset), buffer.readu32(State.Canvas, OutputOffset)))
				OutputOffset += 4
				SourceOffset += 4
			end
		end
	end
end

const function DisposeAnimationFrame(State: PngState, Frame: PngFrame)
	if Frame.DisposeOp == 1 then
		ClearFrameArea(State.Canvas, State.Width, Frame.XOffset, Frame.YOffset, Frame.Width, Frame.Height)
	elseif Frame.DisposeOp == 2 then
		RestoreFrameArea(State)
	end

	State.RestoreBuffer = nil
	State.RestoreX = 0
	State.RestoreY = 0
	State.RestoreWidth = 0
	State.RestoreHeight = 0
end

const function FrameDelay(Frame: PngFrame): number
	local Denominator = Frame.DelayDenominator

	if Denominator == 0 then
		Denominator = 100
	end

	return Frame.DelayNumerator / Denominator
end

const function SyncAnimationResult(State: PngState)
	const Result = State.Result

	if Result == nil then
		return
	end

	const Frame = State.Frames[State.CurrentFrameIndex]
	Result.Frame = State.Canvas
	Result.RGBA8 = State.Canvas
	Result.Delay = FrameDelay(Frame)
	Result.Finished = State.PlayCount > 0 and State.CurrentFrameIndex >= #State.Frames and State.CompletedPlays + 1 >= State.PlayCount
end

const function AdvancePngFrame(State: PngState)
	if State.CurrentFrameIndex >= #State.Frames then
		if State.PlayCount == 0 or State.CompletedPlays + 1 < State.PlayCount then
			DisposeAnimationFrame(State, State.Frames[State.CurrentFrameIndex])
			State.CompletedPlays += 1
			State.CurrentFrameIndex = 1
			DrawAnimationFrame(State, State.Frames[State.CurrentFrameIndex])
			SyncAnimationResult(State)
			return
		end

		SyncAnimationResult(State)
		return
	end

	DisposeAnimationFrame(State, State.Frames[State.CurrentFrameIndex])
	State.CurrentFrameIndex += 1
	DrawAnimationFrame(State, State.Frames[State.CurrentFrameIndex])
	SyncAnimationResult(State)
end

const function ResetPngAnimation(State: PngState)
	buffer.fill(State.Canvas, 0, 0)
	State.CurrentFrameIndex = 1
	State.CompletedPlays = 0
	State.RestoreBuffer = nil
	State.RestoreX = 0
	State.RestoreY = 0
	State.RestoreWidth = 0
	State.RestoreHeight = 0
	DrawAnimationFrame(State, State.Frames[1])
	SyncAnimationResult(State)
end

const function DecodePng(PngData: buffer): DecodedPng
	const Length = buffer.len(PngData)

	if Length < 8
		or buffer.readu8(PngData, 0) ~= PngSignature0
		or buffer.readu8(PngData, 1) ~= PngSignature1
		or buffer.readu8(PngData, 2) ~= PngSignature2
		or buffer.readu8(PngData, 3) ~= PngSignature3
		or buffer.readu8(PngData, 4) ~= PngSignature4
		or buffer.readu8(PngData, 5) ~= PngSignature5
		or buffer.readu8(PngData, 6) ~= PngSignature6
		or buffer.readu8(PngData, 7) ~= PngSignature7
	then
		error("missing PNG signature")
	end

	local Cursor = 8
	local Width = 0
	local Height = 0
	local BitDepth = 0
	local ColorType = 0
	local CompressionMethod = 0
	local FilterMethod = 0
	local InterlaceMethod = 0
	local Channels = 0
	local SawIHDR = false
	local SawPLTE = false
	local SawIDAT = false
	local SawTRNS = false
	local FinishedIDAT = false
	local SawIEND = false
	local SawSRGB = false
	local SawGAMA = false
	local SawCHRM = false
	local SawICCP = false
	local SawSBIT = false
	local SawBKGD = false
	local SawPHYS = false
	local SawHIST = false
	local SawTIME = false
	local SawCICP = false
	local SawEXIF = false
	local SawOFFS = false
	local SawGIFG = false
	local SawSTER = false
	local SawACTL = false
	local IdatLength = 0
	local ApngFrameCount = 0
	local ApngPlayCount = 0
	local NextApngSequence = 0
	local CurrentAnimationFrameIndex = 0
	local PaletteEntries = 0
	local TransparentGray = -1
	local TransparentRed = -1
	local TransparentGreen = -1
	local TransparentBlue = -1
	const Palette = buffer.create(1024)
	const IdatOffsets: { [number]: number } = {}
	const IdatLengths: { [number]: number } = {}
	const AnimationFrames: { PngFrame } = {}
	const SuggestedPaletteNames: { [string]: boolean } = {}

	buffer.fill(Palette, 3, 255, 1021)

	while Cursor < Length do
		if Cursor + 12 > Length then
			error("truncated PNG chunk")
		end

		const ChunkLength = ReadU32BE(PngData, Cursor)
		const ChunkTypeOffset = Cursor + 4
		const ChunkType = ReadU32BE(PngData, ChunkTypeOffset)
		const ChunkDataOffset = Cursor + 8
		const ChunkCrcOffset = ChunkDataOffset + ChunkLength

		if ChunkLength > 0x7fffffff then
			error("invalid PNG chunk length")
		end

		if ChunkCrcOffset + 4 > Length then
			error("PNG chunk extends past data")
		end

		ValidateChunkName(PngData, ChunkTypeOffset)

		if Crc32(PngData, ChunkTypeOffset, ChunkDataOffset, ChunkLength) ~= ReadU32BE(PngData, ChunkCrcOffset) then
			error("invalid PNG chunk CRC")
		end

		if not SawIHDR and ChunkType ~= ChunkIHDR then
			error("PNG IHDR must be first")
		end

		if SawIDAT and ChunkType ~= ChunkIDAT then
			FinishedIDAT = true
		end

		if ChunkType == ChunkACTL then
			if not SawIHDR or SawACTL or SawIDAT or ChunkLength ~= 8 then
				error("invalid APNG acTL")
			end

			ApngFrameCount = ReadU32BE(PngData, ChunkDataOffset)
			ApngPlayCount = ReadU32BE(PngData, ChunkDataOffset + 4)

			if ApngFrameCount <= 0 then
				error("invalid APNG frame count")
			end

			SawACTL = true
		elseif ChunkType == ChunkFCTL then
			if not SawACTL or ChunkLength ~= 26 then
				error("invalid APNG fcTL")
			end

			if CurrentAnimationFrameIndex > 0 and AnimationFrames[CurrentAnimationFrameIndex].DataLength <= 0 then
				error("missing APNG frame data")
			end

			const SequenceNumber = ReadU32BE(PngData, ChunkDataOffset)

			if SequenceNumber ~= NextApngSequence then
				error("invalid APNG sequence number")
			end

			NextApngSequence += 1

			const FrameWidth = ReadU32BE(PngData, ChunkDataOffset + 4)
			const FrameHeight = ReadU32BE(PngData, ChunkDataOffset + 8)
			const XOffset = ReadU32BE(PngData, ChunkDataOffset + 12)
			const YOffset = ReadU32BE(PngData, ChunkDataOffset + 16)
			const DelayNumerator = ReadU16BE(PngData, ChunkDataOffset + 20)
			const DelayDenominator = ReadU16BE(PngData, ChunkDataOffset + 22)
			const DisposeOp = buffer.readu8(PngData, ChunkDataOffset + 24)
			const BlendOp = buffer.readu8(PngData, ChunkDataOffset + 25)

			if FrameWidth <= 0
				or FrameHeight <= 0
				or XOffset > Width
				or YOffset > Height
				or FrameWidth > Width - XOffset
				or FrameHeight > Height - YOffset
				or DisposeOp > 2
				or BlendOp > 1
				or FrameWidth > MaxOutputBytes // 4 // FrameHeight
			then
				error("invalid APNG frame control")
			end

			if not SawIDAT and #AnimationFrames == 0 and (FrameWidth ~= Width or FrameHeight ~= Height or XOffset ~= 0 or YOffset ~= 0) then
				error("invalid APNG default frame")
			end

			if #AnimationFrames >= ApngFrameCount then
				error("too many APNG frames")
			end

			AnimationFrames[#AnimationFrames + 1] = {
				Width = FrameWidth,
				Height = FrameHeight,
				XOffset = XOffset,
				YOffset = YOffset,
				DelayNumerator = DelayNumerator,
				DelayDenominator = DelayDenominator,
				DisposeOp = DisposeOp,
				BlendOp = BlendOp,
				DataOffsets = {},
				DataLengths = {},
				DataLength = 0,
				DataFromIdat = false,
				Pixels = EmptyInflateData,
			}
			CurrentAnimationFrameIndex = #AnimationFrames
		elseif ChunkType == ChunkFDAT then
			if not SawACTL or not SawIDAT or CurrentAnimationFrameIndex <= 0 or ChunkLength < 4 then
				error("invalid APNG fdAT")
			end

			if AnimationFrames[CurrentAnimationFrameIndex].DataFromIdat then
				error("invalid APNG fdAT")
			end

			const SequenceNumber = ReadU32BE(PngData, ChunkDataOffset)

			if SequenceNumber ~= NextApngSequence then
				error("invalid APNG sequence number")
			end

			NextApngSequence += 1
			AddFrameData(AnimationFrames[CurrentAnimationFrameIndex], ChunkDataOffset + 4, ChunkLength - 4)
		elseif ChunkType == ChunkIHDR then
			if SawIHDR or Cursor ~= 8 or ChunkLength ~= 13 then
				error("invalid PNG IHDR")
			end

			Width = ReadU32BE(PngData, ChunkDataOffset)
			Height = ReadU32BE(PngData, ChunkDataOffset + 4)
			BitDepth = buffer.readu8(PngData, ChunkDataOffset + 8)
			ColorType = buffer.readu8(PngData, ChunkDataOffset + 9)
			CompressionMethod = buffer.readu8(PngData, ChunkDataOffset + 10)
			FilterMethod = buffer.readu8(PngData, ChunkDataOffset + 11)
			InterlaceMethod = buffer.readu8(PngData, ChunkDataOffset + 12)

			if Width <= 0 or Height <= 0 or Width > MaxOutputBytes // 4 // Height then
				error("invalid PNG image dimensions")
			end

			if CompressionMethod ~= 0 or FilterMethod ~= 0 or (InterlaceMethod ~= 0 and InterlaceMethod ~= 1) then
				error("unsupported PNG header method")
			end

			Channels = ValidateColorType(ColorType, BitDepth)
			SawIHDR = true
		elseif ChunkType == ChunkPLTE then
			if not SawIHDR or SawPLTE or SawIDAT or ChunkLength % 3 ~= 0 or ChunkLength <= 0 or ChunkLength > 768 then
				error("invalid PNG PLTE")
			end

			PaletteEntries = ChunkLength // 3

			if ColorType == 0 or ColorType == 4 or (ColorType == 3 and PaletteEntries > BitPowers[BitDepth]) then
				error("invalid PNG PLTE for color type")
			end

			for Index = 0, PaletteEntries - 1 do
				const SourceOffset = ChunkDataOffset + Index * 3
				const PaletteOffset = Index * 4
				buffer.writeu8(Palette, PaletteOffset, buffer.readu8(PngData, SourceOffset))
				buffer.writeu8(Palette, PaletteOffset + 1, buffer.readu8(PngData, SourceOffset + 1))
				buffer.writeu8(Palette, PaletteOffset + 2, buffer.readu8(PngData, SourceOffset + 2))
				buffer.writeu8(Palette, PaletteOffset + 3, 255)
			end

			SawPLTE = true
		elseif ChunkType == ChunkTRNS then
			if not SawIHDR or SawTRNS or SawIDAT then
				error("invalid PNG tRNS order")
			end

			if ColorType == 0 then
				if ChunkLength ~= 2 then
					error("invalid grayscale PNG tRNS")
				end

				TransparentGray = ReadU16BE(PngData, ChunkDataOffset)

				if TransparentGray >= BitPowers[BitDepth] then
					error("invalid grayscale PNG tRNS value")
				end
			elseif ColorType == 2 then
				if ChunkLength ~= 6 then
					error("invalid RGB PNG tRNS")
				end

				TransparentRed = ReadU16BE(PngData, ChunkDataOffset)
				TransparentGreen = ReadU16BE(PngData, ChunkDataOffset + 2)
				TransparentBlue = ReadU16BE(PngData, ChunkDataOffset + 4)

				if BitDepth == 8 and (TransparentRed > 255 or TransparentGreen > 255 or TransparentBlue > 255) then
					error("invalid RGB PNG tRNS value")
				end
			elseif ColorType == 3 then
				if not SawPLTE or ChunkLength > PaletteEntries then
					error("invalid indexed PNG tRNS")
				end

				for Index = 0, ChunkLength - 1 do
					buffer.writeu8(Palette, Index * 4 + 3, buffer.readu8(PngData, ChunkDataOffset + Index))
				end
			else
				error("invalid PNG tRNS for color type")
			end

			SawTRNS = true
		elseif ChunkType == ChunkSRGB then
			if SawSRGB or SawICCP or SawIDAT or ChunkLength ~= 1 then
				error("invalid PNG sRGB")
			end

			if buffer.readu8(PngData, ChunkDataOffset) > 3 then
				error("invalid PNG sRGB intent")
			end

			SawSRGB = true
		elseif ChunkType == ChunkGAMA then
			if SawGAMA or SawICCP or SawIDAT or ChunkLength ~= 4 or ReadU32BE(PngData, ChunkDataOffset) == 0 then
				error("invalid PNG gAMA")
			end

			SawGAMA = true
		elseif ChunkType == ChunkCHRM then
			if SawCHRM or SawICCP or SawIDAT or ChunkLength ~= 32 then
				error("invalid PNG cHRM")
			end

			SawCHRM = true
		elseif ChunkType == ChunkICCP then
			if SawICCP or SawSRGB or SawIDAT or ChunkLength < 3 then
				error("invalid PNG iCCP")
			end

			const DataEnd = ChunkDataOffset + ChunkLength
			const NameEnd = ReadNullTerminatedKeywordEnd(PngData, ChunkDataOffset, DataEnd)

			if NameEnd == ChunkDataOffset or NameEnd + 2 > DataEnd or buffer.readu8(PngData, NameEnd + 1) ~= 0 then
				error("invalid PNG iCCP")
			end

			ValidateZlibRange(PngData, NameEnd + 2, DataEnd - NameEnd - 2)
			SawICCP = true
		elseif ChunkType == ChunkSBIT then
			if SawSBIT or SawIDAT then
				error("invalid PNG sBIT order")
			end

			local ExpectedLength = 0

			if ColorType == 0 then
				ExpectedLength = 1
			elseif ColorType == 2 or ColorType == 3 then
				ExpectedLength = 3
			elseif ColorType == 4 then
				ExpectedLength = 2
			elseif ColorType == 6 then
				ExpectedLength = 4
			end

			if ChunkLength ~= ExpectedLength then
				error("invalid PNG sBIT")
			end

			for Index = 0, ChunkLength - 1 do
				const Value = buffer.readu8(PngData, ChunkDataOffset + Index)
				local Maximum = BitDepth

				if ColorType == 3 then
					Maximum = 8
				end

				if Value == 0 or Value > Maximum then
					error("invalid PNG sBIT value")
				end
			end

			SawSBIT = true
		elseif ChunkType == ChunkBKGD then
			if SawBKGD or SawIDAT then
				error("invalid PNG bKGD order")
			end

			if ColorType == 3 then
				if not SawPLTE or ChunkLength ~= 1 or buffer.readu8(PngData, ChunkDataOffset) >= PaletteEntries then
					error("invalid PNG bKGD")
				end
			elseif ColorType == 0 or ColorType == 4 then
				if ChunkLength ~= 2 or ReadU16BE(PngData, ChunkDataOffset) >= BitPowers[BitDepth] then
					error("invalid PNG bKGD")
				end
			else
				if ChunkLength ~= 6
					or ReadU16BE(PngData, ChunkDataOffset) >= BitPowers[BitDepth]
					or ReadU16BE(PngData, ChunkDataOffset + 2) >= BitPowers[BitDepth]
					or ReadU16BE(PngData, ChunkDataOffset + 4) >= BitPowers[BitDepth]
				then
					error("invalid PNG bKGD")
				end
			end

			SawBKGD = true
		elseif ChunkType == ChunkPHYS then
			if SawPHYS or SawIDAT or ChunkLength ~= 9 then
				error("invalid PNG pHYs")
			end

			if buffer.readu8(PngData, ChunkDataOffset + 8) > 1 then
				error("invalid PNG pHYs unit")
			end

			SawPHYS = true
		elseif ChunkType == ChunkHIST then
			if SawHIST or not SawPLTE or SawIDAT or ChunkLength ~= PaletteEntries * 2 then
				error("invalid PNG hIST")
			end

			SawHIST = true
		elseif ChunkType == ChunkTIME then
			if SawTIME or ChunkLength ~= 7 then
				error("invalid PNG tIME")
			end

			const Year = ReadU16BE(PngData, ChunkDataOffset)
			const Month = buffer.readu8(PngData, ChunkDataOffset + 2)
			const Day = buffer.readu8(PngData, ChunkDataOffset + 3)
			const Hour = buffer.readu8(PngData, ChunkDataOffset + 4)
			const Minute = buffer.readu8(PngData, ChunkDataOffset + 5)
			const Second = buffer.readu8(PngData, ChunkDataOffset + 6)

			if Year < 1 or Month < 1 or Month > 12 or Day < 1 or Day > DaysInMonth(Year, Month) or Hour > 23 or Minute > 59 or Second > 60 then
				error("invalid PNG tIME value")
			end

			SawTIME = true
		elseif ChunkType == ChunkZTXT then
			const DataEnd = ChunkDataOffset + ChunkLength
			const NameEnd = ReadNullTerminatedKeywordEnd(PngData, ChunkDataOffset, DataEnd)

			if NameEnd + 2 > DataEnd or buffer.readu8(PngData, NameEnd + 1) ~= 0 then
				error("invalid PNG zTXt")
			end

			ValidateZlibRange(PngData, NameEnd + 2, DataEnd - NameEnd - 2)
		elseif ChunkType == ChunkITXT then
			const DataEnd = ChunkDataOffset + ChunkLength

			if ChunkLength < 5 then
				error("invalid PNG iTXt")
			end

			const KeywordEnd = ReadNullTerminatedKeywordEnd(PngData, ChunkDataOffset, DataEnd)

			if KeywordEnd + 3 > DataEnd then
				error("invalid PNG iTXt")
			end

			const TextCompressionFlag = buffer.readu8(PngData, KeywordEnd + 1)
			const TextCompressionMethod = buffer.readu8(PngData, KeywordEnd + 2)

			if TextCompressionFlag > 1
				or (TextCompressionFlag == 1 and TextCompressionMethod ~= 0)
				or (TextCompressionFlag == 0 and TextCompressionMethod ~= 0)
			then
				error("invalid PNG iTXt compression")
			end

			const LanguageEnd = FindNullByte(PngData, KeywordEnd + 3, DataEnd)
			const TranslatedKeywordEnd = FindNullByte(PngData, LanguageEnd + 1, DataEnd)
			ValidateLanguageTag(PngData, KeywordEnd + 3, LanguageEnd)
			ValidateUtf8(PngData, LanguageEnd + 1, TranslatedKeywordEnd)

			if TextCompressionFlag == 1 then
				const TextData = InflateZlibInternal(PngData, TranslatedKeywordEnd + 1, DataEnd - TranslatedKeywordEnd - 1, MaxMetadataInflateBytes, -1)
				ValidateUtf8(TextData, 0, buffer.len(TextData))
			else
				ValidateUtf8(PngData, TranslatedKeywordEnd + 1, DataEnd)
			end
		elseif ChunkType == ChunkCICP then
			if SawCICP or SawIDAT or ChunkLength ~= 4 then
				error("invalid PNG cICP")
			end

			if buffer.readu8(PngData, ChunkDataOffset + 3) > 1 then
				error("invalid PNG cICP")
			end

			SawCICP = true
		elseif ChunkType == ChunkEXIF then
			if SawEXIF or SawIDAT then
				error("invalid PNG eXIf")
			end

			ValidateExif(PngData, ChunkDataOffset, ChunkDataOffset + ChunkLength)
			SawEXIF = true
		elseif ChunkType == ChunkSPLT then
			if SawIDAT or ChunkLength < 4 then
				error("invalid PNG sPLT")
			end

			const DataEnd = ChunkDataOffset + ChunkLength
			const NameEnd = ReadNullTerminatedKeywordEnd(PngData, ChunkDataOffset, DataEnd)

			if NameEnd + 2 > DataEnd then
				error("invalid PNG sPLT")
			end

			const SampleDepth = buffer.readu8(PngData, NameEnd + 1)
			const EntryBytes = DataEnd - NameEnd - 2
			const Name = buffer.tostring(SliceBuffer(PngData, ChunkDataOffset, NameEnd - ChunkDataOffset))

			if SuggestedPaletteNames[Name] then
				error("duplicate PNG sPLT")
			end

			if SampleDepth == 8 then
				if EntryBytes == 0 or EntryBytes % 6 ~= 0 then
					error("invalid PNG sPLT")
				end
			elseif SampleDepth == 16 then
				if EntryBytes == 0 or EntryBytes % 10 ~= 0 then
					error("invalid PNG sPLT")
				end
			else
				error("invalid PNG sPLT")
			end

			SuggestedPaletteNames[Name] = true
		elseif ChunkType == ChunkOFFS then
			if SawOFFS or SawIDAT or ChunkLength ~= 9 then
				error("invalid PNG oFFs")
			end

			if buffer.readu8(PngData, ChunkDataOffset + 8) > 1 then
				error("invalid PNG oFFs unit")
			end

			SawOFFS = true
		elseif ChunkType == ChunkGIFG then
			if SawGIFG or ChunkLength ~= 4 then
				error("invalid PNG gIFg")
			end

			if buffer.readu8(PngData, ChunkDataOffset) > 3 or buffer.readu8(PngData, ChunkDataOffset + 1) > 1 then
				error("invalid PNG gIFg")
			end

			SawGIFG = true
		elseif ChunkType == ChunkGIFX then
			if ChunkLength < 11 then
				error("invalid PNG gIFx")
			end
		elseif ChunkType == ChunkSTER then
			if SawSTER or SawIDAT or ChunkLength ~= 1 then
				error("invalid PNG sTER")
			end

			if buffer.readu8(PngData, ChunkDataOffset) > 1 then
				error("invalid PNG sTER")
			end

			SawSTER = true
		elseif ChunkType == ChunkTEXT then
			ReadNullTerminatedKeywordEnd(PngData, ChunkDataOffset, ChunkDataOffset + ChunkLength)
		elseif ChunkType == ChunkIDAT then
			if not SawIHDR or FinishedIDAT then
				error("invalid PNG IDAT order")
			end

			if ColorType == 3 and not SawPLTE then
				error("indexed PNG missing PLTE")
			end

			if ChunkLength > MaxOutputBytes - IdatLength then
				error("PNG IDAT data too large")
			end

			SawIDAT = true
			IdatLength += ChunkLength
			IdatOffsets[#IdatOffsets + 1] = ChunkDataOffset
			IdatLengths[#IdatLengths + 1] = ChunkLength

			if SawACTL and CurrentAnimationFrameIndex > 0 and #AnimationFrames == 1 then
				AddFrameData(AnimationFrames[CurrentAnimationFrameIndex], ChunkDataOffset, ChunkLength)
				AnimationFrames[CurrentAnimationFrameIndex].DataFromIdat = true
			end
		elseif ChunkType == ChunkIEND then
			if not SawIHDR or not SawIDAT or ChunkLength ~= 0 then
				error("invalid PNG IEND")
			end

			SawIEND = true
			Cursor = ChunkCrcOffset + 4
			break
		else
			if IsCriticalChunk(PngData, ChunkTypeOffset) then
				error("unsupported critical PNG chunk")
			end
		end

		Cursor = ChunkCrcOffset + 4
	end

	if not SawIEND or Cursor ~= Length then
		error("invalid PNG end")
	end

	if SawACTL then
		if #AnimationFrames ~= ApngFrameCount then
			error("invalid APNG frame count")
		end

		for Index = 1, #AnimationFrames do
			if AnimationFrames[Index].DataLength <= 0 then
				error("missing APNG frame data")
			end
		end
	end

	const BitsPerPixel = Channels * BitDepth
	const ExpectedLength = ExpectedInflatedLength(Width, Height, BitsPerPixel, InterlaceMethod)

	if ExpectedLength > MaxOutputBytes then
		error("PNG image data too large")
	end

	local Inflated = EmptyInflateData

	if #IdatOffsets == 1 then
		Inflated = InflateZlibInternal(PngData, IdatOffsets[1], IdatLength, ExpectedLength, ExpectedLength)
	else
		const IdatData = BuildChunkData(PngData, IdatOffsets, IdatLengths, IdatLength)
		Inflated = InflateZlib(IdatData, ExpectedLength)
	end

	const Output = DecodePixels(
		Inflated,
		Width,
		Height,
		ColorType,
		BitDepth,
		Channels,
		InterlaceMethod,
		Palette,
		PaletteEntries,
		TransparentGray,
		TransparentRed,
		TransparentGreen,
		TransparentBlue
	)

	if SawACTL then
		local AnimationDecodeStart = 1

		if AnimationFrames[1].DataFromIdat then
			AnimationFrames[1].Pixels = Output
			AnimationDecodeStart = 2
		end

		DecodeAnimationFrames(
			PngData,
			AnimationFrames,
			AnimationDecodeStart,
			ColorType,
			BitDepth,
			Channels,
			InterlaceMethod,
			Palette,
			PaletteEntries,
			TransparentGray,
			TransparentRed,
			TransparentGreen,
			TransparentBlue
		)

		const State: PngState = {
			Width = Width,
			Height = Height,
			Frames = AnimationFrames,
			PlayCount = ApngPlayCount,
			CompletedPlays = 0,
			Canvas = buffer.create(Width * Height * 4),
			CurrentFrameIndex = 1,
			RestoreBuffer = nil,
			RestoreX = 0,
			RestoreY = 0,
			RestoreWidth = 0,
			RestoreHeight = 0,
			Result = nil,
		}

		DrawAnimationFrame(State, AnimationFrames[1])

		const function AdvanceFrame()
			AdvancePngFrame(State)
		end

		const function Reset()
			ResetPngAnimation(State)
		end

		const Result: DecodedPng = {
			Animated = true,
			Size = Vector2.new(Width, Height),
			RGBA8 = State.Canvas,
			Frame = State.Canvas,
			AdvanceFrame = AdvanceFrame,
			Reset = Reset,
			Finished = ApngPlayCount == 1 and #AnimationFrames <= 1,
			Delay = FrameDelay(AnimationFrames[1]),
		}

		State.Result = Result
		return Result
	end

	return {
		Animated = false,
		Size = Vector2.new(Width, Height),
		RGBA8 = Output,
		Frame = Output,
		AdvanceFrame = StaticAdvanceFrame,
		Reset = StaticReset,
		Finished = true,
		Delay = 0,
	}
end

return DecodePng
