--!optimize 2
--!native
--!strict

--[[
	Deflate.luau

	Public API:
	- Deflate(Input: buffer, Level: number?) returns a raw RFC1951 DEFLATE stream.
	- Inflate(Input: buffer) accepts a raw RFC1951 DEFLATE stream and returns the decompressed buffer.
	- Compress(Input: buffer, Level: number?) returns an RFC1950 zlib stream.
	- Decompress(Input: buffer) accepts an RFC1950 zlib stream and returns the decompressed buffer.
	- Level 0 writes stored blocks; levels 1 through 9 use LZ77 tokens with fixed or dynamic Huffman blocks.
]]

type Huffman = {
	Lookup: buffer,
}

type BitWriter = {
	Data: buffer,
	Capacity: number,
	Position: number,
	Bits: number,
	BitCount: number,
}

type BlockChoice = {
	Type: number,
	LiteralLengths: buffer?,
	DistanceLengths: buffer?,
	CodeLengthLengths: buffer?,
	CodeLengthSymbols: buffer?,
	CodeLengthExtras: buffer?,
	CodeLengthExtraBits: buffer?,
	CodeLengthCount: number,
	LiteralCount: number,
	DistanceCount: number,
	CodeLengthCountHeader: number,
}

const EmptyBuffer = buffer.create(0)
const MaxOutputBytes = 2147483647
const MaxLookupBits = 15
const HuffmanLookupSize = 32768
const HashSize = 32768
const MaxWindow = 32768
const MinMatch = 3
const MaxMatch = 258
const MaxStoredBlock = 65535
const MatchTokenFlag = 2147483648
const AdlerBase = 65521

const PowerOfTwo = buffer.create(128)
const BitMask = buffer.create(68)

local Power = 1

for Index = 0, 31 do
	buffer.writeu32(PowerOfTwo, Index * 4, Power)

	if Index <= 16 then
		buffer.writeu32(BitMask, Index * 4, Power - 1)
	end

	Power *= 2
end

const CodeLengthOrder = buffer.create(19)
const CodeLengthOrderValues: { number } = {
	16,
	17,
	18,
	0,
	8,
	7,
	9,
	6,
	10,
	5,
	11,
	4,
	12,
	3,
	13,
	2,
	14,
	1,
	15,
}

for Index = 1, 19 do
	buffer.writeu8(CodeLengthOrder, Index - 1, CodeLengthOrderValues[Index])
end

const LengthBase = buffer.create(116)
const LengthExtra = buffer.create(29)
const DistanceBase = buffer.create(120)
const DistanceExtra = buffer.create(30)

const LengthBaseValues: { number } = {
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

const LengthExtraValues: { number } = {
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

const DistanceBaseValues: { number } = {
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

const DistanceExtraValues: { number } = {
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

for Index = 0, 28 do
	buffer.writeu32(LengthBase, Index * 4, LengthBaseValues[Index + 1])
	buffer.writeu8(LengthExtra, Index, LengthExtraValues[Index + 1])
end

for Index = 0, 29 do
	buffer.writeu32(DistanceBase, Index * 4, DistanceBaseValues[Index + 1])
	buffer.writeu8(DistanceExtra, Index, DistanceExtraValues[Index + 1])
end

const LengthSymbolLookup = buffer.create(259 * 2)
const DistanceSymbolLookup = buffer.create(MaxWindow)

for Symbol = 0, 28 do
	const Base = buffer.readu32(LengthBase, Symbol * 4)
	const Extra = buffer.readu8(LengthExtra, Symbol)
	const Count = buffer.readu32(PowerOfTwo, Extra * 4)

	for Length = Base, Base + Count - 1 do
		if Length <= MaxMatch then
			buffer.writeu16(LengthSymbolLookup, Length * 2, Symbol + 257)
		end
	end
end

for Symbol = 0, 29 do
	const Base = buffer.readu32(DistanceBase, Symbol * 4)
	const Extra = buffer.readu8(DistanceExtra, Symbol)
	const Count = buffer.readu32(PowerOfTwo, Extra * 4)

	for Distance = Base, Base + Count - 1 do
		if Distance <= MaxWindow then
			buffer.writeu8(DistanceSymbolLookup, Distance - 1, Symbol)
		end
	end
end

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

const LevelMaxChain = buffer.create(20)
const LevelNiceLength = buffer.create(20)
const LevelLazyLength = buffer.create(20)
const LevelBlockSize = buffer.create(40)

const LevelMaxChainValues: { number } = { 0, 4, 8, 16, 32, 64, 96, 128, 192, 256 }
const LevelNiceLengthValues: { number } = { 0, 16, 24, 32, 48, 64, 96, 128, 192, 258 }
const LevelLazyLengthValues: { number } = { 0, 4, 5, 6, 8, 12, 16, 24, 32, 48 }
const LevelBlockSizeValues: { number } = { 65535, 32768, 65535, 131072, 262144, 524288, 1048576, 1048576, 1048576, 1048576 }

for Index = 0, 9 do
	buffer.writeu16(LevelMaxChain, Index * 2, LevelMaxChainValues[Index + 1])
	buffer.writeu16(LevelNiceLength, Index * 2, LevelNiceLengthValues[Index + 1])
	buffer.writeu16(LevelLazyLength, Index * 2, LevelLazyLengthValues[Index + 1])
	buffer.writeu32(LevelBlockSize, Index * 4, LevelBlockSizeValues[Index + 1])
end

local InflateData = EmptyBuffer
local InflateLength = 0
local InflatePosition = 0
local InflateBits = 0
local InflateBitCount = 0
local InflateOutput = EmptyBuffer
local InflateOutputPosition = 0
local InflateOutputCapacity = 0
local InflateMaxDistance = MaxWindow

const function ReverseBits(Value: number, Count: number): number
	local Result = 0

	for _ = 1, Count do
		Result = Result * 2 + bit32.band(Value, 1)
		Value = bit32.rshift(Value, 1)
	end

	return Result
end

const function BuildHuffman(Lengths: buffer, SymbolCount: number, StartIndex: number): Huffman
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
			const Stride = buffer.readu32(PowerOfTwo, Length * 4)
			const Replications = HuffmanLookupSize // Stride
			const Entry = Symbol + Length * 65536
			buffer.writeu32(NextCode, NextCodeOffset, CurrentCode + 1)

			for Repeat = 0, Replications - 1 do
				buffer.writeu32(Lookup, (ReversedCode + Repeat * Stride) * 4, Entry)
			end
		end
	end

	return {
		Lookup = Lookup,
	}
end

const FixedLiteralHuffman = BuildHuffman(FixedLiteralLengths, 288, 0)
const FixedDistanceHuffman = BuildHuffman(FixedDistanceLengths, 32, 0)

const function EnsureInflateBits(Count: number)
	while InflateBitCount < Count and InflatePosition < InflateLength do
		InflateBits += buffer.readu8(InflateData, InflatePosition) * buffer.readu32(PowerOfTwo, InflateBitCount * 4)
		InflateBitCount += 8
		InflatePosition += 1
	end
end

const function ReadInflateBits(Count: number): number
	EnsureInflateBits(Count)

	if InflateBitCount < Count then
		error("unexpected end of deflate data")
	end

	const Value = bit32.band(InflateBits, buffer.readu32(BitMask, Count * 4))
	InflateBits = bit32.rshift(InflateBits, Count)
	InflateBitCount -= Count

	return Value
end

const function GrowInflateOutput(Required: number)
	if Required > MaxOutputBytes then
		error("deflate output too large")
	end

	if Required <= InflateOutputCapacity then
		return
	end

	local Capacity = InflateOutputCapacity

	if Capacity < 256 then
		Capacity = 256
	end

	while Capacity < Required do
		if Capacity > MaxOutputBytes // 2 then
			Capacity = MaxOutputBytes
		else
			Capacity *= 2
		end
	end

	const Output = buffer.create(Capacity)
	buffer.copy(Output, 0, InflateOutput, 0, InflateOutputPosition)
	InflateOutput = Output
	InflateOutputCapacity = Capacity
end

const function WriteInflateByte(Value: number)
	GrowInflateOutput(InflateOutputPosition + 1)
	buffer.writeu8(InflateOutput, InflateOutputPosition, Value)
	InflateOutputPosition += 1
end

const function DecodeInflateSymbol(Huffman: Huffman): number
	EnsureInflateBits(MaxLookupBits)

	const Entry = buffer.readu32(Huffman.Lookup, bit32.band(InflateBits, HuffmanLookupSize - 1) * 4)
	const Length = bit32.rshift(Entry, 16)

	if Length == 0 or Length > InflateBitCount then
		error("invalid deflate Huffman code")
	end

	InflateBits = bit32.rshift(InflateBits, Length)
	InflateBitCount -= Length

	return bit32.band(Entry, 0xffff)
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

	GrowInflateOutput(InflateOutputPosition + Length)

	if InflateBitCount == 0 and InflatePosition + Length <= InflateLength then
		buffer.copy(InflateOutput, InflateOutputPosition, InflateData, InflatePosition, Length)
		InflatePosition += Length
		InflateOutputPosition += Length
	else
		for _ = 1, Length do
			WriteInflateByte(ReadInflateBits(8))
		end
	end
end

const function CopyInflateMatch(Distance: number, Length: number)
	if Distance > InflateOutputPosition or Distance > InflateMaxDistance then
		error("invalid deflate distance")
	end

	GrowInflateOutput(InflateOutputPosition + Length)

	if Distance == 1 then
		buffer.fill(InflateOutput, InflateOutputPosition, buffer.readu8(InflateOutput, InflateOutputPosition - 1), Length)
		InflateOutputPosition += Length
	elseif Distance >= Length then
		buffer.copy(InflateOutput, InflateOutputPosition, InflateOutput, InflateOutputPosition - Distance, Length)
		InflateOutputPosition += Length
	elseif Distance >= 4 then
		local Remaining = Length

		while Remaining >= 4 do
			buffer.writeu32(InflateOutput, InflateOutputPosition, buffer.readu32(InflateOutput, InflateOutputPosition - Distance))
			InflateOutputPosition += 4
			Remaining -= 4
		end

		while Remaining > 0 do
			buffer.writeu8(InflateOutput, InflateOutputPosition, buffer.readu8(InflateOutput, InflateOutputPosition - Distance))
			InflateOutputPosition += 1
			Remaining -= 1
		end
	else
		local Remaining = Length

		if Distance == 2 then
			while Remaining >= 2 do
				buffer.writeu16(InflateOutput, InflateOutputPosition, buffer.readu16(InflateOutput, InflateOutputPosition - 2))
				InflateOutputPosition += 2
				Remaining -= 2
			end
		else
			while Remaining >= 3 do
				buffer.writeu16(InflateOutput, InflateOutputPosition, buffer.readu16(InflateOutput, InflateOutputPosition - 3))
				buffer.writeu8(InflateOutput, InflateOutputPosition + 2, buffer.readu8(InflateOutput, InflateOutputPosition - 1))
				InflateOutputPosition += 3
				Remaining -= 3
			end

			if Remaining >= 2 then
				buffer.writeu16(InflateOutput, InflateOutputPosition, buffer.readu16(InflateOutput, InflateOutputPosition - 3))
				InflateOutputPosition += 2
				Remaining -= 2
			end
		end

		while Remaining > 0 do
			buffer.writeu8(InflateOutput, InflateOutputPosition, buffer.readu8(InflateOutput, InflateOutputPosition - Distance))
			InflateOutputPosition += 1
			Remaining -= 1
		end
	end
end

const function DecodeCompressedBlock(LiteralHuffman: Huffman, DistanceHuffman: Huffman)
	while true do
		const Symbol = DecodeInflateSymbol(LiteralHuffman)

		if Symbol < 256 then
			WriteInflateByte(Symbol)
		elseif Symbol == 256 then
			return
		elseif Symbol <= 285 then
			const LengthIndex = Symbol - 257
			local Length = buffer.readu32(LengthBase, LengthIndex * 4)
			const ExtraBits = buffer.readu8(LengthExtra, LengthIndex)

			if ExtraBits > 0 then
				Length += ReadInflateBits(ExtraBits)
			end

			const DistanceSymbol = DecodeInflateSymbol(DistanceHuffman)

			if DistanceSymbol > 29 then
				error("invalid deflate distance symbol")
			end

			local Distance = buffer.readu32(DistanceBase, DistanceSymbol * 4)
			const DistanceExtraBits = buffer.readu8(DistanceExtra, DistanceSymbol)

			if DistanceExtraBits > 0 then
				Distance += ReadInflateBits(DistanceExtraBits)
			end

			CopyInflateMatch(Distance, Length)
		else
			error("invalid deflate literal symbol")
		end
	end
end

const function DecodeDynamicBlock()
	const LiteralCount = ReadInflateBits(5) + 257
	const DistanceCount = ReadInflateBits(5) + 1
	const CodeLengthCount = ReadInflateBits(4) + 4

	if LiteralCount > 286 or DistanceCount > 32 then
		error("invalid deflate Huffman count")
	end

	const CodeLengthLengths = buffer.create(19)
	const Lengths = buffer.create(LiteralCount + DistanceCount)

	for Index = 0, CodeLengthCount - 1 do
		buffer.writeu8(CodeLengthLengths, buffer.readu8(CodeLengthOrder, Index), ReadInflateBits(3))
	end

	const CodeLengthHuffman = BuildHuffman(CodeLengthLengths, 19, 0)
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

			if Index + RepeatCount > LiteralCount + DistanceCount then
				error("deflate repeat exceeds table")
			end

			for _ = 1, RepeatCount do
				buffer.writeu8(Lengths, Index, PreviousLength)
				Index += 1
			end
		elseif Symbol == 17 then
			const RepeatCount = ReadInflateBits(3) + 3

			if Index + RepeatCount > LiteralCount + DistanceCount then
				error("deflate repeat exceeds table")
			end

			buffer.fill(Lengths, Index, 0, RepeatCount)
			PreviousLength = 0
			Index += RepeatCount
		elseif Symbol == 18 then
			const RepeatCount = ReadInflateBits(7) + 11

			if Index + RepeatCount > LiteralCount + DistanceCount then
				error("deflate repeat exceeds table")
			end

			buffer.fill(Lengths, Index, 0, RepeatCount)
			PreviousLength = 0
			Index += RepeatCount
		else
			error("invalid deflate code length symbol")
		end
	end

	if buffer.readu8(Lengths, 256) == 0 then
		error("missing deflate end code")
	end

	DecodeCompressedBlock(BuildHuffman(Lengths, LiteralCount, 0), BuildHuffman(Lengths, DistanceCount, LiteralCount))
end

const function NewBitWriter(Capacity: number): BitWriter
	if Capacity < 256 then
		Capacity = 256
	end

	return {
		Data = buffer.create(Capacity),
		Capacity = Capacity,
		Position = 0,
		Bits = 0,
		BitCount = 0,
	}
end

const function GrowWriter(Writer: BitWriter, Required: number)
	if Required <= Writer.Capacity then
		return
	end

	local Capacity = Writer.Capacity

	while Capacity < Required do
		if Capacity > MaxOutputBytes // 2 then
			Capacity = MaxOutputBytes
		else
			Capacity *= 2
		end
	end

	const Data = buffer.create(Capacity)
	buffer.copy(Data, 0, Writer.Data, 0, Writer.Position)
	Writer.Data = Data
	Writer.Capacity = Capacity
end

const function WriteOutputByte(Writer: BitWriter, Value: number)
	GrowWriter(Writer, Writer.Position + 1)
	buffer.writeu8(Writer.Data, Writer.Position, Value)
	Writer.Position += 1
end

const function WriteBits(Writer: BitWriter, Value: number, Count: number)
	if Count == 0 then
		return
	end

	Writer.Bits += bit32.band(Value, buffer.readu32(BitMask, Count * 4)) * buffer.readu32(PowerOfTwo, Writer.BitCount * 4)
	Writer.BitCount += Count

	while Writer.BitCount >= 8 do
		WriteOutputByte(Writer, bit32.band(Writer.Bits, 0xff))
		Writer.Bits = bit32.rshift(Writer.Bits, 8)
		Writer.BitCount -= 8
	end
end

const function AlignWriter(Writer: BitWriter)
	if Writer.BitCount > 0 then
		WriteOutputByte(Writer, bit32.band(Writer.Bits, 0xff))
		Writer.Bits = 0
		Writer.BitCount = 0
	end
end

const function FinishWriter(Writer: BitWriter): buffer
	AlignWriter(Writer)

	const Output = buffer.create(Writer.Position)
	buffer.copy(Output, 0, Writer.Data, 0, Writer.Position)

	return Output
end

const function BuildCanonicalCodes(Lengths: buffer, Count: number): buffer
	const CountByLength = buffer.create((MaxLookupBits + 1) * 2)
	const NextCode = buffer.create((MaxLookupBits + 1) * 4)
	const Codes = buffer.create(Count * 2)
	local Code = 0

	for Symbol = 0, Count - 1 do
		const Length = buffer.readu8(Lengths, Symbol)

		if Length > 0 then
			const Offset = Length * 2
			buffer.writeu16(CountByLength, Offset, buffer.readu16(CountByLength, Offset) + 1)
		end
	end

	for Length = 1, MaxLookupBits do
		Code = (Code + buffer.readu16(CountByLength, (Length - 1) * 2)) * 2
		buffer.writeu32(NextCode, Length * 4, Code)
	end

	for Symbol = 0, Count - 1 do
		const Length = buffer.readu8(Lengths, Symbol)

		if Length > 0 then
			const Offset = Length * 4
			const CurrentCode = buffer.readu32(NextCode, Offset)
			buffer.writeu16(Codes, Symbol * 2, CurrentCode)
			buffer.writeu32(NextCode, Offset, CurrentCode + 1)
		end
	end

	return Codes
end

const function WriteHuffmanCode(Writer: BitWriter, Codes: buffer, Lengths: buffer, Symbol: number)
	const Length = buffer.readu8(Lengths, Symbol)
	WriteBits(Writer, ReverseBits(buffer.readu16(Codes, Symbol * 2), Length), Length)
end

const function ResetFrequency(Frequency: buffer, Count: number)
	buffer.fill(Frequency, 0, 0, Count * 4)
end

const function AddFrequency(Frequency: buffer, Symbol: number, Amount: number)
	buffer.writeu32(Frequency, Symbol * 4, buffer.readu32(Frequency, Symbol * 4) + Amount)
end

const function CompareFrequency(Frequencies: buffer, Left: number, Right: number): boolean
	const LeftFrequency = buffer.readu32(Frequencies, Left * 4)
	const RightFrequency = buffer.readu32(Frequencies, Right * 4)

	return LeftFrequency < RightFrequency or (LeftFrequency == RightFrequency and Left > Right)
end

const function SortSymbolsByFrequency(Symbols: buffer, Count: number, Frequencies: buffer)
	for Index = 1, Count - 1 do
		const Symbol = buffer.readu16(Symbols, Index * 2)
		local MoveIndex = Index - 1

		while MoveIndex >= 0 and CompareFrequency(Frequencies, Symbol, buffer.readu16(Symbols, MoveIndex * 2)) do
			buffer.writeu16(Symbols, (MoveIndex + 1) * 2, buffer.readu16(Symbols, MoveIndex * 2))
			MoveIndex -= 1
		end

		buffer.writeu16(Symbols, (MoveIndex + 1) * 2, Symbol)
	end
end

const function BuildCodeLengths(Frequencies: buffer, SymbolCount: number, MaxBits: number): buffer
	const Lengths = buffer.create(SymbolCount)
	const Symbols = buffer.create(SymbolCount * 2)
	local UsedCount = 0

	for Symbol = 0, SymbolCount - 1 do
		if buffer.readu32(Frequencies, Symbol * 4) > 0 then
			buffer.writeu16(Symbols, UsedCount * 2, Symbol)
			UsedCount += 1
		end
	end

	if UsedCount == 0 then
		return Lengths
	end

	if UsedCount == 1 then
		buffer.writeu8(Lengths, buffer.readu16(Symbols, 0), 1)
		return Lengths
	end

	SortSymbolsByFrequency(Symbols, UsedCount, Frequencies)

	const NodeCount = UsedCount * 2 - 1
	const NodeFrequency = buffer.create(NodeCount * 4)
	const NodeParent = buffer.create(NodeCount * 2)
	const NodeLeft = buffer.create(NodeCount * 2)
	const NodeRight = buffer.create(NodeCount * 2)
	const Active = buffer.create(NodeCount)

	buffer.fill(NodeParent, 0, 255)

	for Index = 0, UsedCount - 1 do
		const Symbol = buffer.readu16(Symbols, Index * 2)
		buffer.writeu32(NodeFrequency, Index * 4, buffer.readu32(Frequencies, Symbol * 4))
		buffer.writeu8(Active, Index, 1)
	end

	local ActiveCount = UsedCount
	local NextNode = UsedCount

	while ActiveCount > 1 do
		local First = -1
		local Second = -1

		for Node = 0, NextNode - 1 do
			if buffer.readu8(Active, Node) == 1 then
				if First < 0
					or buffer.readu32(NodeFrequency, Node * 4) < buffer.readu32(NodeFrequency, First * 4)
					or (
						buffer.readu32(NodeFrequency, Node * 4) == buffer.readu32(NodeFrequency, First * 4)
						and Node < First
					)
				then
					Second = First
					First = Node
				elseif Second < 0
					or buffer.readu32(NodeFrequency, Node * 4) < buffer.readu32(NodeFrequency, Second * 4)
					or (
						buffer.readu32(NodeFrequency, Node * 4) == buffer.readu32(NodeFrequency, Second * 4)
						and Node < Second
					)
				then
					Second = Node
				end
			end
		end

		buffer.writeu8(Active, First, 0)
		buffer.writeu8(Active, Second, 0)
		buffer.writeu8(Active, NextNode, 1)
		buffer.writeu32(NodeFrequency, NextNode * 4, buffer.readu32(NodeFrequency, First * 4) + buffer.readu32(NodeFrequency, Second * 4))
		buffer.writeu16(NodeLeft, NextNode * 2, First)
		buffer.writeu16(NodeRight, NextNode * 2, Second)
		buffer.writeu16(NodeParent, First * 2, NextNode)
		buffer.writeu16(NodeParent, Second * 2, NextNode)
		NextNode += 1
		ActiveCount -= 1
	end

	const CountByLength = buffer.create((MaxBits + 1) * 2)
	local Overflow = 0

	for Index = 0, UsedCount - 1 do
		local Depth = 0
		local Node = Index

		while buffer.readu16(NodeParent, Node * 2) ~= 65535 do
			Depth += 1
			Node = buffer.readu16(NodeParent, Node * 2)
		end

		if Depth > MaxBits then
			Overflow += 1
			Depth = MaxBits
		end

		buffer.writeu16(CountByLength, Depth * 2, buffer.readu16(CountByLength, Depth * 2) + 1)
	end

	while Overflow > 0 do
		local Bits = MaxBits - 1

		while Bits > 0 and buffer.readu16(CountByLength, Bits * 2) == 0 do
			Bits -= 1
		end

		buffer.writeu16(CountByLength, Bits * 2, buffer.readu16(CountByLength, Bits * 2) - 1)
		buffer.writeu16(CountByLength, (Bits + 1) * 2, buffer.readu16(CountByLength, (Bits + 1) * 2) + 2)
		buffer.writeu16(CountByLength, MaxBits * 2, buffer.readu16(CountByLength, MaxBits * 2) - 1)
		Overflow -= 2
	end

	local SymbolIndex = 0

	for Bits = MaxBits, 1, -1 do
		for _ = 1, buffer.readu16(CountByLength, Bits * 2) do
			const Symbol = buffer.readu16(Symbols, SymbolIndex * 2)
			buffer.writeu8(Lengths, Symbol, Bits)
			SymbolIndex += 1
		end
	end

	return Lengths
end

const function HashBytes(Data: buffer, Position: number): number
	return bit32.band((buffer.readu8(Data, Position) * 251 + buffer.readu8(Data, Position + 1)) * 251 + buffer.readu8(Data, Position + 2), HashSize - 1)
end

const function MatchLength(Data: buffer, Left: number, Right: number, EndPosition: number): number
	local Length = 0
	const Limit = math.min(MaxMatch, EndPosition - Right)

	while Length + 4 <= Limit and buffer.readu32(Data, Left + Length) == buffer.readu32(Data, Right + Length) do
		Length += 4
	end

	while Length < Limit and buffer.readu8(Data, Left + Length) == buffer.readu8(Data, Right + Length) do
		Length += 1
	end

	return Length
end

const function FindMatch(Data: buffer, Position: number, StartPosition: number, EndPosition: number, Head: buffer, Previous: buffer, MaxChain: number, NiceLength: number): (number, number)
	if Position + MinMatch > EndPosition then
		return 0, 0
	end

	const Hash = HashBytes(Data, Position)
	local Candidate = buffer.readu32(Head, Hash * 4)
	local BestLength = 0
	local BestDistance = 0
	local Chain = 0
	const SearchLimit = math.min(MaxMatch, EndPosition - Position)

	while Candidate ~= 4294967295 and Chain < MaxChain do
		if Candidate < StartPosition or Position - Candidate > MaxWindow then
			break
		end

		if BestLength >= SearchLimit then
			break
		end

		if buffer.readu8(Data, Candidate + BestLength) == buffer.readu8(Data, Position + BestLength)
			and buffer.readu16(Data, Candidate) == buffer.readu16(Data, Position)
		then
			const CurrentLength = MatchLength(Data, Candidate, Position, EndPosition)

			if CurrentLength > BestLength then
				BestLength = CurrentLength
				BestDistance = Position - Candidate

				if CurrentLength >= NiceLength then
					break
				end
			end
		end

		Candidate = buffer.readu32(Previous, (Candidate - StartPosition) * 4)
		Chain += 1
	end

	if BestLength >= MinMatch then
		return BestLength, BestDistance
	end

	return 0, 0
end

const function InsertString(Data: buffer, Position: number, StartPosition: number, EndPosition: number, Head: buffer, Previous: buffer)
	if Position + MinMatch > EndPosition then
		return
	end

	const Hash = HashBytes(Data, Position)
	buffer.writeu32(Previous, (Position - StartPosition) * 4, buffer.readu32(Head, Hash * 4))
	buffer.writeu32(Head, Hash * 4, Position)
end

const function LengthSymbol(Length: number): number
	return buffer.readu16(LengthSymbolLookup, Length * 2)
end

const function DistanceSymbol(Distance: number): number
	return buffer.readu8(DistanceSymbolLookup, Distance - 1)
end

const function WriteToken(TokenBuffer: buffer, TokenCount: number, Token: number): number
	buffer.writeu32(TokenBuffer, TokenCount * 4, Token)
	return TokenCount + 1
end

const function TokenizeBlock(Data: buffer, StartPosition: number, EndPosition: number, Level: number): (buffer, number)
	const Length = EndPosition - StartPosition
	const Tokens = buffer.create((Length + 1) * 4)
	const Head = buffer.create(HashSize * 4)
	const Previous = buffer.create(Length * 4)
	const MaxChain = buffer.readu16(LevelMaxChain, Level * 2)
	const NiceLength = buffer.readu16(LevelNiceLength, Level * 2)
	const LazyLength = buffer.readu16(LevelLazyLength, Level * 2)
	local TokenCount = 0
	local Position = StartPosition

	buffer.fill(Head, 0, 255)
	buffer.fill(Previous, 0, 255)

	while Position < EndPosition do
		const CurrentLength, CurrentDistance = FindMatch(Data, Position, StartPosition, EndPosition, Head, Previous, MaxChain, NiceLength)

		if CurrentLength >= MinMatch and CurrentLength <= LazyLength and Position + 1 < EndPosition then
			InsertString(Data, Position, StartPosition, EndPosition, Head, Previous)

			const NextLength, _ = FindMatch(Data, Position + 1, StartPosition, EndPosition, Head, Previous, MaxChain, NiceLength)

			if NextLength > CurrentLength then
				TokenCount = WriteToken(Tokens, TokenCount, buffer.readu8(Data, Position))
				Position += 1
				continue
			end
		end

		if CurrentLength >= MinMatch then
			TokenCount = WriteToken(Tokens, TokenCount, MatchTokenFlag + CurrentLength * MaxWindow + CurrentDistance - 1)

			for InsertPosition = Position, Position + CurrentLength - 1 do
				InsertString(Data, InsertPosition, StartPosition, EndPosition, Head, Previous)
			end

			Position += CurrentLength
		else
			InsertString(Data, Position, StartPosition, EndPosition, Head, Previous)
			TokenCount = WriteToken(Tokens, TokenCount, buffer.readu8(Data, Position))
			Position += 1
		end
	end

	return Tokens, TokenCount
end

const function CollectFrequencies(Tokens: buffer, TokenCount: number, LiteralFrequency: buffer, DistanceFrequency: buffer)
	ResetFrequency(LiteralFrequency, 286)
	ResetFrequency(DistanceFrequency, 30)

	for Index = 0, TokenCount - 1 do
		const Token = buffer.readu32(Tokens, Index * 4)

		if Token >= MatchTokenFlag then
			const Packed = Token - MatchTokenFlag
			const Length = Packed // MaxWindow
			const Distance = Packed % MaxWindow + 1
			const LengthCode = LengthSymbol(Length)
			const DistanceCode = DistanceSymbol(Distance)
			AddFrequency(LiteralFrequency, LengthCode, 1)
			AddFrequency(DistanceFrequency, DistanceCode, 1)
		else
			AddFrequency(LiteralFrequency, Token, 1)
		end
	end

	AddFrequency(LiteralFrequency, 256, 1)
end

const function FixedDataCost(Tokens: buffer, TokenCount: number): number
	local Cost = 7

	for Index = 0, TokenCount - 1 do
		const Token = buffer.readu32(Tokens, Index * 4)

		if Token >= MatchTokenFlag then
			const Packed = Token - MatchTokenFlag
			const Length = Packed // MaxWindow
			const Distance = Packed % MaxWindow + 1
			const LengthCode = LengthSymbol(Length)
			const DistanceCode = DistanceSymbol(Distance)
			Cost += buffer.readu8(FixedLiteralLengths, LengthCode)
				+ buffer.readu8(LengthExtra, LengthCode - 257)
				+ 5
				+ buffer.readu8(DistanceExtra, DistanceCode)
		elseif Token <= 143 then
			Cost += 8
		elseif Token <= 255 then
			Cost += 9
		end
	end

	return Cost
end

const function EmitCodeLengthSymbol(Symbols: buffer, Extras: buffer, ExtraBits: buffer, Count: number, Symbol: number, Extra: number, Bits: number): number
	buffer.writeu8(Symbols, Count, Symbol)
	buffer.writeu8(Extras, Count, Extra)
	buffer.writeu8(ExtraBits, Count, Bits)
	return Count + 1
end

const function BuildCodeLengthRle(LiteralLengths: buffer, LiteralCount: number, DistanceLengths: buffer, DistanceCount: number, Frequencies: buffer): (buffer, buffer, buffer, number)
	const Symbols = buffer.create(1024)
	const Extras = buffer.create(1024)
	const ExtraBits = buffer.create(1024)
	local Count = 0
	local Index = 0
	const Total = LiteralCount + DistanceCount

	ResetFrequency(Frequencies, 19)

	while Index < Total do
		local Length = 0

		if Index < LiteralCount then
			Length = buffer.readu8(LiteralLengths, Index)
		else
			Length = buffer.readu8(DistanceLengths, Index - LiteralCount)
		end

		local Run = 1

		while Index + Run < Total do
			local NextLength = 0

			if Index + Run < LiteralCount then
				NextLength = buffer.readu8(LiteralLengths, Index + Run)
			else
				NextLength = buffer.readu8(DistanceLengths, Index + Run - LiteralCount)
			end

			if NextLength ~= Length then
				break
			end

			Run += 1
		end

		const OriginalRun = Run

		if Length == 0 then
			while Run >= 11 do
				const Take = math.min(Run, 138)
				Count = EmitCodeLengthSymbol(Symbols, Extras, ExtraBits, Count, 18, Take - 11, 7)
				AddFrequency(Frequencies, 18, 1)
				Run -= Take
			end

			if Run >= 3 then
				Count = EmitCodeLengthSymbol(Symbols, Extras, ExtraBits, Count, 17, Run - 3, 3)
				AddFrequency(Frequencies, 17, 1)
				Run = 0
			end

			while Run > 0 do
				Count = EmitCodeLengthSymbol(Symbols, Extras, ExtraBits, Count, 0, 0, 0)
				AddFrequency(Frequencies, 0, 1)
				Run -= 1
			end
		else
			Count = EmitCodeLengthSymbol(Symbols, Extras, ExtraBits, Count, Length, 0, 0)
			AddFrequency(Frequencies, Length, 1)
			Run -= 1

			while Run >= 3 do
				const Take = math.min(Run, 6)
				Count = EmitCodeLengthSymbol(Symbols, Extras, ExtraBits, Count, 16, Take - 3, 2)
				AddFrequency(Frequencies, 16, 1)
				Run -= Take
			end

			while Run > 0 do
				Count = EmitCodeLengthSymbol(Symbols, Extras, ExtraBits, Count, Length, 0, 0)
				AddFrequency(Frequencies, Length, 1)
				Run -= 1
			end
		end

		Index += OriginalRun
	end

	return Symbols, Extras, ExtraBits, Count
end

const function DynamicDataCost(Tokens: buffer, TokenCount: number, LiteralLengths: buffer, DistanceLengths: buffer): number
	local Cost = buffer.readu8(LiteralLengths, 256)

	for Index = 0, TokenCount - 1 do
		const Token = buffer.readu32(Tokens, Index * 4)

		if Token >= MatchTokenFlag then
			const Packed = Token - MatchTokenFlag
			const Length = Packed // MaxWindow
			const Distance = Packed % MaxWindow + 1
			const LengthCode = LengthSymbol(Length)
			const DistanceCode = DistanceSymbol(Distance)
			Cost += buffer.readu8(LiteralLengths, LengthCode)
				+ buffer.readu8(LengthExtra, LengthCode - 257)
				+ buffer.readu8(DistanceLengths, DistanceCode)
				+ buffer.readu8(DistanceExtra, DistanceCode)
		else
			Cost += buffer.readu8(LiteralLengths, Token)
		end
	end

	return Cost
end

const function StoredCost(InputLength: number, CurrentBitCount: number): number
	local Cost = 0
	local Remaining = InputLength
	local BitCount = CurrentBitCount

	while Remaining > 0 do
		const Length = math.min(MaxStoredBlock, Remaining)
		Cost += 3 + ((8 - ((BitCount + 3) % 8)) % 8) + 32 + Length * 8
		BitCount = 0
		Remaining -= Length
	end

	return Cost
end

const function ChooseBlock(Tokens: buffer, TokenCount: number, InputLength: number, CurrentBitCount: number): BlockChoice
	const LiteralFrequency = buffer.create(286 * 4)
	const DistanceFrequency = buffer.create(30 * 4)
	const CodeLengthFrequency = buffer.create(19 * 4)
	CollectFrequencies(Tokens, TokenCount, LiteralFrequency, DistanceFrequency)

	if buffer.readu32(DistanceFrequency, 0) == 0 then
		buffer.writeu32(DistanceFrequency, 0, 1)
	end

	const LiteralLengths = BuildCodeLengths(LiteralFrequency, 286, 15)
	const DistanceLengths = BuildCodeLengths(DistanceFrequency, 30, 15)
	local LiteralCount = 286
	local DistanceCount = 30

	while LiteralCount > 257 and buffer.readu8(LiteralLengths, LiteralCount - 1) == 0 do
		LiteralCount -= 1
	end

	while DistanceCount > 1 and buffer.readu8(DistanceLengths, DistanceCount - 1) == 0 do
		DistanceCount -= 1
	end

	const CodeLengthSymbols, CodeLengthExtras, CodeLengthExtraBits, CodeLengthCount = BuildCodeLengthRle(
		LiteralLengths,
		LiteralCount,
		DistanceLengths,
		DistanceCount,
		CodeLengthFrequency
	)
	const CodeLengthLengths = BuildCodeLengths(CodeLengthFrequency, 19, 7)
	local CodeLengthCountHeader = 19

	while CodeLengthCountHeader > 4 and buffer.readu8(CodeLengthLengths, buffer.readu8(CodeLengthOrder, CodeLengthCountHeader - 1)) == 0 do
		CodeLengthCountHeader -= 1
	end

	local DynamicCost = 3 + 14 + CodeLengthCountHeader * 3 + DynamicDataCost(Tokens, TokenCount, LiteralLengths, DistanceLengths)

	for Index = 0, CodeLengthCount - 1 do
		DynamicCost += buffer.readu8(CodeLengthLengths, buffer.readu8(CodeLengthSymbols, Index)) + buffer.readu8(CodeLengthExtraBits, Index)
	end

	const FixedCost = 3 + FixedDataCost(Tokens, TokenCount)
	const StoredBlockCost = StoredCost(InputLength, CurrentBitCount)
	local Type = 2

	if FixedCost <= DynamicCost then
		Type = 1
		DynamicCost = FixedCost
	end

	if StoredBlockCost <= DynamicCost then
		Type = 0
	end

	return {
		Type = Type,
		LiteralLengths = LiteralLengths,
		DistanceLengths = DistanceLengths,
		CodeLengthLengths = CodeLengthLengths,
		CodeLengthSymbols = CodeLengthSymbols,
		CodeLengthExtras = CodeLengthExtras,
		CodeLengthExtraBits = CodeLengthExtraBits,
		CodeLengthCount = CodeLengthCount,
		LiteralCount = LiteralCount,
		DistanceCount = DistanceCount,
		CodeLengthCountHeader = CodeLengthCountHeader,
	}
end

const function WriteStoredBlock(Writer: BitWriter, Data: buffer, StartPosition: number, Length: number, IsFinal: boolean)
	WriteBits(Writer, if IsFinal then 1 else 0, 1)
	WriteBits(Writer, 0, 2)
	AlignWriter(Writer)
	WriteOutputByte(Writer, bit32.band(Length, 0xff))
	WriteOutputByte(Writer, bit32.rshift(Length, 8))
	WriteOutputByte(Writer, bit32.band(bit32.bnot(Length), 0xff))
	WriteOutputByte(Writer, bit32.band(bit32.rshift(bit32.bnot(Length), 8), 0xff))
	GrowWriter(Writer, Writer.Position + Length)
	buffer.copy(Writer.Data, Writer.Position, Data, StartPosition, Length)
	Writer.Position += Length
end

const function WriteStoredBlocks(Writer: BitWriter, Data: buffer, StartPosition: number, Length: number, IsFinal: boolean)
	local Position = StartPosition
	local Remaining = Length

	while Remaining > 0 do
		const BlockLength = math.min(MaxStoredBlock, Remaining)
		Remaining -= BlockLength
		WriteStoredBlock(Writer, Data, Position, BlockLength, IsFinal and Remaining == 0)
		Position += BlockLength
	end
end

const function WriteCompressedTokens(Writer: BitWriter, Tokens: buffer, TokenCount: number, LiteralCodes: buffer, LiteralLengths: buffer, DistanceCodes: buffer, DistanceLengths: buffer)
	for Index = 0, TokenCount - 1 do
		const Token = buffer.readu32(Tokens, Index * 4)

		if Token >= MatchTokenFlag then
			const Packed = Token - MatchTokenFlag
			const Length = Packed // MaxWindow
			const Distance = Packed % MaxWindow + 1
			const LengthCode = LengthSymbol(Length)
			const DistanceCode = DistanceSymbol(Distance)
			const LengthExtraBits = buffer.readu8(LengthExtra, LengthCode - 257)
			const DistanceExtraBits = buffer.readu8(DistanceExtra, DistanceCode)
			WriteHuffmanCode(Writer, LiteralCodes, LiteralLengths, LengthCode)
			WriteBits(Writer, Length - buffer.readu32(LengthBase, (LengthCode - 257) * 4), LengthExtraBits)
			WriteHuffmanCode(Writer, DistanceCodes, DistanceLengths, DistanceCode)
			WriteBits(Writer, Distance - buffer.readu32(DistanceBase, DistanceCode * 4), DistanceExtraBits)
		else
			WriteHuffmanCode(Writer, LiteralCodes, LiteralLengths, Token)
		end
	end

	WriteHuffmanCode(Writer, LiteralCodes, LiteralLengths, 256)
end

const function WriteFixedBlock(Writer: BitWriter, Tokens: buffer, TokenCount: number, IsFinal: boolean)
	WriteBits(Writer, if IsFinal then 1 else 0, 1)
	WriteBits(Writer, 1, 2)

	const LiteralCodes = BuildCanonicalCodes(FixedLiteralLengths, 288)
	const DistanceCodes = BuildCanonicalCodes(FixedDistanceLengths, 32)
	WriteCompressedTokens(Writer, Tokens, TokenCount, LiteralCodes, FixedLiteralLengths, DistanceCodes, FixedDistanceLengths)
end

const function WriteDynamicBlock(Writer: BitWriter, Tokens: buffer, TokenCount: number, Choice: BlockChoice, IsFinal: boolean)
	const LiteralLengths = Choice.LiteralLengths :: buffer
	const DistanceLengths = Choice.DistanceLengths :: buffer
	const CodeLengthLengths = Choice.CodeLengthLengths :: buffer
	const CodeLengthSymbols = Choice.CodeLengthSymbols :: buffer
	const CodeLengthExtras = Choice.CodeLengthExtras :: buffer
	const CodeLengthExtraBits = Choice.CodeLengthExtraBits :: buffer
	const LiteralCodes = BuildCanonicalCodes(LiteralLengths, 286)
	const DistanceCodes = BuildCanonicalCodes(DistanceLengths, 30)
	const CodeLengthCodes = BuildCanonicalCodes(CodeLengthLengths, 19)

	WriteBits(Writer, if IsFinal then 1 else 0, 1)
	WriteBits(Writer, 2, 2)
	WriteBits(Writer, Choice.LiteralCount - 257, 5)
	WriteBits(Writer, Choice.DistanceCount - 1, 5)
	WriteBits(Writer, Choice.CodeLengthCountHeader - 4, 4)

	for Index = 0, Choice.CodeLengthCountHeader - 1 do
		WriteBits(Writer, buffer.readu8(CodeLengthLengths, buffer.readu8(CodeLengthOrder, Index)), 3)
	end

	for Index = 0, Choice.CodeLengthCount - 1 do
		const Symbol = buffer.readu8(CodeLengthSymbols, Index)
		WriteHuffmanCode(Writer, CodeLengthCodes, CodeLengthLengths, Symbol)
		WriteBits(Writer, buffer.readu8(CodeLengthExtras, Index), buffer.readu8(CodeLengthExtraBits, Index))
	end

	WriteCompressedTokens(Writer, Tokens, TokenCount, LiteralCodes, LiteralLengths, DistanceCodes, DistanceLengths)
end

const function ReadU32BE(Data: buffer, Offset: number): number
	return bit32.byteswap(buffer.readu32(Data, Offset))
end

const function WriteU32BE(Data: buffer, Offset: number, Value: number)
	buffer.writeu32(Data, Offset, bit32.byteswap(Value))
end

const function Adler32(Data: buffer): number
	local S1 = 1
	local S2 = 0
	local Offset = 0
	local Remaining = buffer.len(Data)

	while Remaining >= 5552 do
		Remaining -= 5552

		for _ = 1, 347 do
			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1

			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1

			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1

			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1

			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1

			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1

			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1

			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1

			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1

			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1

			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1

			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1

			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1

			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1

			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1

			S1 += buffer.readu8(Data, Offset)
			S2 += S1
			Offset += 1
		end

		S1 %= AdlerBase
		S2 %= AdlerBase
	end

	while Remaining >= 16 do
		Remaining -= 16

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1

		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1
	end

	while Remaining > 0 do
		S1 += buffer.readu8(Data, Offset)
		S2 += S1
		Offset += 1
		Remaining -= 1
	end

	S1 %= AdlerBase
	S2 %= AdlerBase

	return S2 * 65536 + S1
end

const function NormalizeLevel(Level: number?): number
	if Level == nil then
		return 6
	end

	if Level ~= Level or Level < 0 or Level > 9 or Level % 1 ~= 0 then
		error("deflate level must be an integer from 0 to 9")
	end

	return Level
end

-- Compresses the given input buffer into a raw DEFLATE stream defined by RFC 1951.
const function Deflate(Input: buffer, Level: number?): buffer
	const CompressionLevel = NormalizeLevel(Level or 6)
	const InputLength = buffer.len(Input)
	const Writer = NewBitWriter(InputLength + ((InputLength + MaxStoredBlock - 1) // MaxStoredBlock) * 5 + 64)

	if InputLength == 0 then
		WriteStoredBlock(Writer, Input, 0, 0, true)
		return FinishWriter(Writer)
	end

	if CompressionLevel == 0 then
		WriteStoredBlocks(Writer, Input, 0, InputLength, true)
		return FinishWriter(Writer)
	end

	local Position = 0
	const BlockSize = buffer.readu32(LevelBlockSize, CompressionLevel * 4)

	while Position < InputLength do
		const BlockLength = math.min(BlockSize, InputLength - Position)
		const EndPosition = Position + BlockLength
		const Tokens, TokenCount = TokenizeBlock(Input, Position, EndPosition, CompressionLevel)
		const IsFinal = EndPosition >= InputLength
		const Choice = ChooseBlock(Tokens, TokenCount, BlockLength, Writer.BitCount)

		if Choice.Type == 0 then
			WriteStoredBlocks(Writer, Input, Position, BlockLength, IsFinal)
		elseif Choice.Type == 1 then
			WriteFixedBlock(Writer, Tokens, TokenCount, IsFinal)
		else
			WriteDynamicBlock(Writer, Tokens, TokenCount, Choice, IsFinal)
		end

		Position = EndPosition
	end

	return FinishWriter(Writer)
end

const function InflateRange(Input: buffer, Start: number, EndPosition: number, MaxDistance: number): buffer
	InflateData = Input
	InflateLength = EndPosition
	InflatePosition = Start
	InflateBits = 0
	InflateBitCount = 0
	InflateOutput = buffer.create(256)
	InflateOutputPosition = 0
	InflateOutputCapacity = 256
	InflateMaxDistance = MaxDistance

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

	if InflatePosition < InflateLength or InflateBitCount >= 8 then
		error("trailing deflate data")
	end

	const Output = buffer.create(InflateOutputPosition)
	buffer.copy(Output, 0, InflateOutput, 0, InflateOutputPosition)
	InflateData = EmptyBuffer
	InflateLength = 0
	InflatePosition = 0
	InflateBits = 0
	InflateBitCount = 0
	InflateOutput = EmptyBuffer
	InflateOutputPosition = 0
	InflateOutputCapacity = 0
	InflateMaxDistance = MaxWindow

	return Output
end

-- Decompresses a raw DEFLATE stream defined by RFC 1951.
const function Inflate(Input: buffer): buffer
	return InflateRange(Input, 0, buffer.len(Input), MaxWindow)
end

-- Compresses the given input buffer into the zlib data format defined by RFC 1950.
const function Compress(Input: buffer, Level: number?): buffer
	const CompressionLevel = NormalizeLevel(Level)
	const Deflated = Deflate(Input, CompressionLevel)
	const DeflatedLength = buffer.len(Deflated)
	const Output = buffer.create(DeflatedLength + 6)
	const CompressionMethod = 0x78
	local CompressionFlag = 0

	if CompressionLevel <= 1 then
		CompressionFlag = 0
	elseif CompressionLevel <= 5 then
		CompressionFlag = 64
	elseif CompressionLevel <= 7 then
		CompressionFlag = 128
	else
		CompressionFlag = 192
	end

	CompressionFlag += (31 - (CompressionMethod * 256 + CompressionFlag) % 31) % 31

	buffer.writeu8(Output, 0, CompressionMethod)
	buffer.writeu8(Output, 1, CompressionFlag)
	buffer.copy(Output, 2, Deflated, 0, DeflatedLength)
	WriteU32BE(Output, DeflatedLength + 2, Adler32(Input))

	return Output
end

-- Decompresses a zlib data stream defined by RFC 1950.
const function Decompress(Input: buffer): buffer
	const Length = buffer.len(Input)

	if Length < 6 then
		error("truncated zlib data")
	end

	const CompressionMethod = buffer.readu8(Input, 0)
	const CompressionFlag = buffer.readu8(Input, 1)

	if CompressionMethod % 16 ~= 8 or CompressionMethod // 16 > 7 then
		error("unsupported zlib compression method")
	end

	if (CompressionMethod * 256 + CompressionFlag) % 31 ~= 0 then
		error("invalid zlib header check")
	end

	if bit32.btest(CompressionFlag, 32) then
		error("zlib preset dictionaries are not supported")
	end

	const WindowSize = buffer.readu32(PowerOfTwo, (CompressionMethod // 16 + 8) * 4)
	const Output = InflateRange(Input, 2, Length - 4, WindowSize)
	const ExpectedAdler = ReadU32BE(Input, Length - 4)
	const ActualAdler = Adler32(Output)

	if ActualAdler ~= ExpectedAdler then
		error("invalid zlib Adler32")
	end

	return Output
end

return {
	Compress = Compress,
	Decompress = Decompress,
	
	Deflate = Deflate,
	Inflate = Inflate,
}
