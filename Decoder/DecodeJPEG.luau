--!optimize 2
--!native
--!strict

--[[
	JPEGDecoder.luau

	Public API:
	- Module returns DecodeJpeg(JpegData: buffer).
	- DecodeJpeg returns { Size = Vector2.new(Width, Height), RGBA8 = OutputBuffer }.
	- OutputBuffer is packed row-major RGBA8 using buffer.writeu32-compatible byte order.

	Supported JPEG image coding:
	- Baseline sequential Huffman DCT, SOF0.
	- Extended sequential Huffman DCT, SOF1.
	- Progressive Huffman DCT, SOF2.
	- Lossless Huffman predictive coding, SOF3.
	- Extended sequential arithmetic DCT, SOF9.
	- Progressive arithmetic DCT, SOF10.
	- 8-bit and 12-bit DCT sample precision, downsampled to RGBA8 output.
	- 2-bit through 16-bit lossless sample precision, downsampled to RGBA8 output.
	- Interleaved, subset, and split component scans for sequential images.
	- Progressive DC/AC first scans and successive approximation refinement scans.
	- Restart intervals and restart markers.

	Supported component/color layouts:
	- 1 component: grayscale.
	- 2 components: grayscale + alpha.
	- 3 components: YCbCr or RGB pass-through using Adobe APP14 transform rules.
	- 4 components: CMYK or YCCK using Adobe APP14 transform rules.
	- Exif orientation values 1 through 8.

	Parsed/validated metadata markers:
	- DQT, DHT, DAC, DRI, SOS, SOF0/SOF1/SOF2/SOF3/SOF9/SOF10.
	- APP0 JFIF and JFXX version, density, and thumbnail bounds.
	- APP1 Exif orientation.
	- APP2 ICC profile sequence completeness.
	- APP14 Adobe color transform.

	Explicitly unsupported JPEG families:
	- Arithmetic-coded lossless JPEG.
	- Differential JPEG modes.
	- Hierarchical JPEG.
	- JPEG-LS, JPEG 2000, and JPEG XL.
	- DNL images with height defined after SOF.
]]

type Component = {
	Id: number,
	H: number,
	V: number,
	QuantId: number,
	DcId: number,
	AcId: number,
	PrevDc: number,
	Samples: buffer,
	Coefficients: buffer,
	PlaneWidth: number,
	PlaneHeight: number,
	BlockColumns: number,
	BlockRows: number,
	Scanned: boolean,
	ArithmeticDcContext: number,
	LosslessPointTransform: number,
	ProgressiveDcApprox: number,
	ProgressiveBandApprox: { [number]: number },
}

type HuffmanTable = {
	MinCode: buffer,
	MaxCode: buffer,
	ValueIndex: buffer,
	Values: buffer,
}

type DecodedJpeg = {
	Size: Vector2,
	RGBA8: buffer,
}

const EmptyEntropyData = buffer.create(0)
const MaxOutputBytes = 2147483647
const MarkerAPP0 = 0xe0
const MarkerAPP1 = 0xe1
const MarkerAPP2 = 0xe2
const MarkerAPP14 = 0xee

local EntropyData = EmptyEntropyData
local EntropyLength = 0
local EntropyPos = 0
local EntropyBits = 0
local EntropyBitCount = 0
local ArithmeticC = 0
local ArithmeticA = 0
local ArithmeticCT = 0
local ArithmeticUnreadMarker = -1
local ArithmeticMarkerOffset = 0

const Zigzag: { [number]: number } = {
	0,
	1,
	8,
	16,
	9,
	2,
	3,
	10,
	17,
	24,
	32,
	25,
	18,
	11,
	4,
	5,
	12,
	19,
	26,
	33,
	40,
	48,
	41,
	34,
	27,
	20,
	13,
	6,
	7,
	14,
	21,
	28,
	35,
	42,
	49,
	56,
	57,
	50,
	43,
	36,
	29,
	22,
	15,
	23,
	30,
	37,
	44,
	51,
	58,
	59,
	52,
	45,
	38,
	31,
	39,
	46,
	53,
	60,
	61,
	54,
	47,
	55,
	62,
	63,
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
}

const ArithmeticTable: { [number]: number } = {
	0x5a1d0181,
	0x2586020e,
	0x11140310,
	0x080b0412,
	0x03d80514,
	0x01da0617,
	0x00e50719,
	0x006f081c,
	0x0036091e,
	0x001a0a21,
	0x000d0b23,
	0x00060c09,
	0x00030d0a,
	0x00010d0c,
	0x5a7f0f8f,
	0x3f251024,
	0x2cf21126,
	0x207c1227,
	0x17b91328,
	0x1182142a,
	0x0cef152b,
	0x09a1162d,
	0x072f172e,
	0x055c1830,
	0x04061931,
	0x03031a33,
	0x02401b34,
	0x01b11c36,
	0x01441d38,
	0x00f51e39,
	0x00b71f3b,
	0x008a203c,
	0x0068213e,
	0x004e223f,
	0x003b2320,
	0x002c0921,
	0x5ae125a5,
	0x484c2640,
	0x3a0d2741,
	0x2ef12843,
	0x261f2944,
	0x1f332a45,
	0x19a82b46,
	0x15182c48,
	0x11772d49,
	0x0e742e4a,
	0x0bfb2f4b,
	0x09f8304d,
	0x0861314e,
	0x0706324f,
	0x05cd3330,
	0x04de3432,
	0x040f3532,
	0x03633633,
	0x02d43734,
	0x025c3835,
	0x01f83936,
	0x01a43a37,
	0x01603b38,
	0x01253c39,
	0x00f63d3a,
	0x00cb3e3b,
	0x00ab3f3d,
	0x008f203d,
	0x5b1241c1,
	0x4d044250,
	0x412c4351,
	0x37d84452,
	0x2fe84553,
	0x293c4654,
	0x23794756,
	0x1edf4857,
	0x1aa94957,
	0x174e4a48,
	0x14244b48,
	0x119c4c4a,
	0x0f6b4d4a,
	0x0d514e4b,
	0x0bb64f4d,
	0x0a40304d,
	0x583251d0,
	0x4d1c5258,
	0x438e5359,
	0x3bdd545a,
	0x34ee555b,
	0x2eae565c,
	0x299a575d,
	0x25164756,
	0x557059d8,
	0x4ca95a5f,
	0x44d95b60,
	0x3e225c61,
	0x38245d63,
	0x32b45e63,
	0x2e17565d,
	0x56a860df,
	0x4f466165,
	0x47e56266,
	0x41cf6367,
	0x3c3d6468,
	0x375e5d63,
	0x52316669,
	0x4c0f676a,
	0x4639686b,
	0x415e6367,
	0x56276ae9,
	0x50e76b6c,
	0x4b85676d,
	0x55976d6e,
	0x504f6b6f,
	0x5a106fee,
	0x55226d70,
	0x59eb6ff0,
	0x5a1d7171,
}

const ScaledCosines: { [number]: number } = {}

for Coordinate = 0, 7 do
	for Frequency = 0, 7 do
		local Value = math.cos((2 * Coordinate + 1) * Frequency * math.pi / 16)

		if Frequency == 0 then
			Value *= 0.7071067811865476
		end

		ScaledCosines[Coordinate * 8 + Frequency + 1] = Value
	end
end

const function ReadU16BE(Data: buffer, Offset: number): number
	return buffer.readu8(Data, Offset) * 256 + buffer.readu8(Data, Offset + 1)
end

const function ResetArithmeticCoder()
	ArithmeticC = 0
	ArithmeticA = 0
	ArithmeticCT = -16
	ArithmeticUnreadMarker = -1
	ArithmeticMarkerOffset = 0
end

const function ResetFixedArithmeticStats(FixedStats: buffer)
	buffer.writeu8(FixedStats, 0, 113)
end

const function ReadArithmeticByte(): number
	if ArithmeticUnreadMarker >= 0 then
		return 0
	end

	if EntropyPos >= EntropyLength then
		error("unexpected end of arithmetic entropy data")
	end

	const MarkerOffset = EntropyPos
	const Data = buffer.readu8(EntropyData, EntropyPos)
	EntropyPos += 1

	if Data ~= 0xff then
		return Data
	end

	while EntropyPos < EntropyLength and buffer.readu8(EntropyData, EntropyPos) == 0xff do
		EntropyPos += 1
	end

	if EntropyPos >= EntropyLength then
		error("missing arithmetic entropy marker")
	end

	const Marker = buffer.readu8(EntropyData, EntropyPos)
	EntropyPos += 1

	if Marker == 0 then
		return 0xff
	end

	ArithmeticUnreadMarker = Marker
	ArithmeticMarkerOffset = MarkerOffset
	return 0
end

const function DecodeArithmeticBit(Stats: buffer, StatsOffset: number): number
	while ArithmeticA < 0x8000 do
		ArithmeticCT -= 1

		if ArithmeticCT < 0 then
			ArithmeticC = ArithmeticC * 256 + ReadArithmeticByte()
			ArithmeticCT += 8

			if ArithmeticCT < 0 then
				ArithmeticCT += 1

				if ArithmeticCT == 0 then
					ArithmeticA = 0x8000
				end
			end
		end

		ArithmeticA *= 2
	end

	local StateValue = buffer.readu8(Stats, StatsOffset)
	const Packed = ArithmeticTable[bit32.band(StateValue, 0x7f) + 1]
	const Qe = Packed // 65536
	const NextMps = bit32.band(Packed // 256, 0xff)
	const NextLps = bit32.band(Packed, 0xff)
	local Temp = ArithmeticA - Qe

	ArithmeticA = Temp
	Temp *= BitPowers[ArithmeticCT]

	if ArithmeticC >= Temp then
		ArithmeticC -= Temp

		if ArithmeticA < Qe then
			ArithmeticA = Qe
			buffer.writeu8(Stats, StatsOffset, bit32.bxor(bit32.band(StateValue, 0x80), NextMps))
		else
			ArithmeticA = Qe
			buffer.writeu8(Stats, StatsOffset, bit32.bxor(bit32.band(StateValue, 0x80), NextLps))
			StateValue = bit32.bxor(StateValue, 0x80)
		end
	elseif ArithmeticA < 0x8000 then
		if ArithmeticA < Qe then
			buffer.writeu8(Stats, StatsOffset, bit32.bxor(bit32.band(StateValue, 0x80), NextLps))
			StateValue = bit32.bxor(StateValue, 0x80)
		else
			buffer.writeu8(Stats, StatsOffset, bit32.bxor(bit32.band(StateValue, 0x80), NextMps))
		end
	end

	return bit32.rshift(StateValue, 7)
end

const function BuildHuffmanTable(Counts: { [number]: number }, Values: { [number]: number }): HuffmanTable
	const MinCode = buffer.create(68)
	const MaxCode = buffer.create(68)
	const ValueIndex = buffer.create(34)
	const ValueBytes = buffer.create(#Values)
	local Code = 0
	local ValuesOffset = 0

	for Index = 1, #Values do
		buffer.writeu8(ValueBytes, Index - 1, Values[Index])
	end

	for Length = 1, 16 do
		const Count = Counts[Length] or 0

		if Count == 0 then
			buffer.writei32(MinCode, Length * 4, 0)
			buffer.writei32(MaxCode, Length * 4, -1)
			buffer.writeu16(ValueIndex, Length * 2, ValuesOffset)
		else
			buffer.writei32(MinCode, Length * 4, Code)
			buffer.writei32(MaxCode, Length * 4, Code + Count - 1)
			buffer.writeu16(ValueIndex, Length * 2, ValuesOffset)
			Code += Count

			if Code > BitPowers[Length] then
				error("oversubscribed JPEG Huffman table")
			end

			ValuesOffset += Count
		end

		Code *= 2
	end

	return {
		MinCode = MinCode,
		MaxCode = MaxCode,
		ValueIndex = ValueIndex,
		Values = ValueBytes,
	}
end

const function ReadEntropyByte(): number
	if EntropyPos >= EntropyLength then
		error("unexpected end of entropy data")
	end

	const Byte = buffer.readu8(EntropyData, EntropyPos)
	EntropyPos += 1

	if Byte ~= 0xff then
		return Byte
	end

	while EntropyPos < EntropyLength and buffer.readu8(EntropyData, EntropyPos) == 0xff do
		EntropyPos += 1
	end

	if EntropyPos >= EntropyLength then
		error("missing entropy marker")
	end

	const Marker = buffer.readu8(EntropyData, EntropyPos)
	EntropyPos += 1

	if Marker == 0x00 then
		return 0xff
	end

	error(`unexpected marker 0x{string.format("%02X", Marker)} in entropy data`)
	return 0
end

const function ReadBits(Count: number): number
	local Value = 0
	local Bits = EntropyBits
	local BitCount = EntropyBitCount

	while Count > 0 do
		if BitCount == 0 then
			Bits = ReadEntropyByte()
			BitCount = 8
		end

		local Take = Count

		if Take > BitCount then
			Take = BitCount
		end

		BitCount -= Take
		Value = Value * BitPowers[Take] + bit32.extract(Bits, BitCount, Take)
		Count -= Take
	end

	EntropyBits = Bits
	EntropyBitCount = BitCount

	return Value
end

const function Receive(Count: number): number
	if Count == 0 then
		return 0
	end

	const Value = ReadBits(Count)

	if Value < BitPowers[Count - 1] then
		return Value + 1 - BitPowers[Count]
	end

	return Value
end

const function DecodeHuffman(Huffman: HuffmanTable): number
	local Code = 0
	local Bits = EntropyBits
	local BitCount = EntropyBitCount
	const MinCodes = Huffman.MinCode
	const MaxCodes = Huffman.MaxCode
	const ValueIndexes = Huffman.ValueIndex
	const Values = Huffman.Values

	for Length = 1, 16 do
		if BitCount == 0 then
			Bits = ReadEntropyByte()
			BitCount = 8
		end

		BitCount -= 1
		Code = Code * 2 + bit32.extract(Bits, BitCount, 1)

		const MaxCode = buffer.readi32(MaxCodes, Length * 4)

		if Code <= MaxCode then
			EntropyBits = Bits
			EntropyBitCount = BitCount
			return buffer.readu8(Values, buffer.readu16(ValueIndexes, Length * 2) + Code - buffer.readi32(MinCodes, Length * 4))
		end
	end

	EntropyBits = Bits
	EntropyBitCount = BitCount
	error("invalid Huffman code")
	return 0
end

const function ResetDc(Components: { Component })
	for Index = 1, #Components do
		Components[Index].PrevDc = 0
	end
end

const function ConsumeRestartMarker(Expected: number): number
	EntropyBitCount = 0
	EntropyBits = 0

	if EntropyPos >= EntropyLength or buffer.readu8(EntropyData, EntropyPos) ~= 0xff then
		error("missing restart marker")
	end

	while EntropyPos < EntropyLength and buffer.readu8(EntropyData, EntropyPos) == 0xff do
		EntropyPos += 1
	end

	if EntropyPos >= EntropyLength then
		error("missing restart marker")
	end

	const Marker = buffer.readu8(EntropyData, EntropyPos)
	EntropyPos += 1

	if Marker == 0x00 then
		error("missing restart marker")
	end

	const Wanted = 0xd0 + Expected

	if Marker ~= Wanted then
		error(`expected restart marker 0x{string.format("%02X", Wanted)}, got 0x{string.format("%02X", Marker)}`)
	end

	return (Expected + 1) % 8
end

const function ConsumeArithmeticRestartMarker(Expected: number): number
	if ArithmeticUnreadMarker >= 0 then
		const Wanted = 0xd0 + Expected
		const Marker = ArithmeticUnreadMarker
		ArithmeticUnreadMarker = -1
		ArithmeticMarkerOffset = 0

		if Marker ~= Wanted then
			error(`expected restart marker 0x{string.format("%02X", Wanted)}, got 0x{string.format("%02X", Marker)}`)
		end

		return (Expected + 1) % 8
	end

	return ConsumeRestartMarker(Expected)
end

const function InverseDct(
	Coefficients: { [number]: number },
	Workspace: { [number]: number },
	Output: buffer,
	OutputOffset: number,
	OutputStride: number,
	SamplePrecision: number
)
	const Center = BitPowers[SamplePrecision - 1]
	const Scale = 255 / (BitPowers[SamplePrecision] - 1)

	for Y = 0, 7 do
		const ScaledY = Y * 8

		for U = 0, 7 do
			local Sum = 0

			for V = 0, 7 do
				Sum += Coefficients[V * 8 + U + 1] * ScaledCosines[ScaledY + V + 1]
			end

			Workspace[ScaledY + U + 1] = Sum
		end
	end

	for Y = 0, 7 do
		const RowOffset = OutputOffset + Y * OutputStride
		const WorkspaceOffset = Y * 8

		for X = 0, 7 do
			local Sum = 0
			const ScaledX = X * 8

			for U = 0, 7 do
				Sum += Workspace[WorkspaceOffset + U + 1] * ScaledCosines[ScaledX + U + 1]
			end

			buffer.writeu8(Output, RowOffset + X, math.clamp(math.round((Sum * 0.25 + Center) * Scale), 0, 255))
		end
	end
end

const function FillDcBlock(Value: number, Output: buffer, OutputOffset: number, OutputStride: number, SamplePrecision: number)
	const Center = BitPowers[SamplePrecision - 1]
	const Scale = 255 / (BitPowers[SamplePrecision] - 1)
	const Byte = math.clamp(math.round((Value * 0.125 + Center) * Scale), 0, 255)

	for Y = 0, 7 do
		buffer.fill(Output, OutputOffset + Y * OutputStride, Byte, 8)
	end
end

const function CoefficientOffset(ComponentInfo: Component, BlockX: number, BlockY: number, NaturalIndex: number): number
	return ((BlockY * ComponentInfo.BlockColumns + BlockX) * 64 + NaturalIndex) * 4
end

const function RefineCoefficient(Value: number, Bit: number): number
	if ReadBits(1) == 0 then
		return Value
	end

	local Magnitude = Value

	if Magnitude < 0 then
		Magnitude = -Magnitude
	end

	if Magnitude % (Bit * 2) >= Bit then
		return Value
	end

	if Value < 0 then
		return Value - Bit
	end

	return Value + Bit
end

const function DecodeBlock(
	ComponentInfo: Component,
	QuantizationTables: { [number]: buffer },
	DcTables: { [number]: HuffmanTable },
	AcTables: { [number]: HuffmanTable },
	OutputOffset: number,
	Coefficients: { [number]: number },
	Workspace: { [number]: number },
	TouchedCoefficients: { [number]: number },
	SamplePrecision: number
)
	const Quantization = QuantizationTables[ComponentInfo.QuantId]
	const DcTable = DcTables[ComponentInfo.DcId]
	const AcTable = AcTables[ComponentInfo.AcId]

	if Quantization == nil then
		error(`missing quantization table {ComponentInfo.QuantId}`)
	end

	if DcTable == nil then
		error(`missing DC Huffman table {ComponentInfo.DcId}`)
	end

	if AcTable == nil then
		error(`missing AC Huffman table {ComponentInfo.AcId}`)
	end

	const DcLength = DecodeHuffman(DcTable)

	if DcLength > SamplePrecision + 3 then
		error("invalid DC coefficient length")
	end

	ComponentInfo.PrevDc += Receive(DcLength)
	Coefficients[1] = ComponentInfo.PrevDc * buffer.readu32(Quantization, 0)

	local Index = 1
	local TouchedCount = 1
	local HasAc = false
	TouchedCoefficients[1] = 1

	while Index < 64 do
		const Symbol = DecodeHuffman(AcTable)
		const Run = bit32.rshift(Symbol, 4)
		const Size = bit32.band(Symbol, 0x0f)

		if Size == 0 then
			if Run == 15 then
				Index += 16
				continue
			end

			break
		end

		Index += Run

		if Index >= 64 then
			error("invalid AC run length")
		end

		if Size > SamplePrecision + 2 then
			error("invalid AC coefficient length")
		end

		const NaturalIndex = Zigzag[Index + 1] + 1
		Coefficients[NaturalIndex] = Receive(Size) * buffer.readu32(Quantization, (NaturalIndex - 1) * 4)
		TouchedCount += 1
		TouchedCoefficients[TouchedCount] = NaturalIndex
		HasAc = true
		Index += 1
	end

	if HasAc then
		InverseDct(Coefficients, Workspace, ComponentInfo.Samples, OutputOffset, ComponentInfo.PlaneWidth, SamplePrecision)

		for TouchedIndex = 1, TouchedCount do
			Coefficients[TouchedCoefficients[TouchedIndex]] = 0
		end
	else
		FillDcBlock(Coefficients[1], ComponentInfo.Samples, OutputOffset, ComponentInfo.PlaneWidth, SamplePrecision)
	end
end

const function ReadMarker(Data: buffer, Cursor: number, AllowEntropyPadding: boolean): (number, number)
	const Length = buffer.len(Data)

	if Cursor < Length and buffer.readu8(Data, Cursor) ~= 0xff then
		if AllowEntropyPadding then
			error("invalid entropy padding")
		end

		error("missing marker")
	end

	if Cursor >= Length then
		error("missing marker")
	end

	while Cursor < Length and buffer.readu8(Data, Cursor) == 0xff do
		Cursor += 1
	end

	if Cursor >= Length then
		error("missing marker code")
	end

	const Marker = buffer.readu8(Data, Cursor)
	Cursor += 1

	if Marker == 0 then
		error("invalid JPEG marker")
	end

	return Marker, Cursor
end

const function ParseQuantizationTables(Data: buffer, Cursor: number, SegmentEnd: number, QuantizationTables: { [number]: buffer })
	while Cursor < SegmentEnd do
		const Selector = buffer.readu8(Data, Cursor)
		Cursor += 1

		const Precision = bit32.rshift(Selector, 4)
		const Id = bit32.band(Selector, 0x0f)

		if Id > 3 then
			error("invalid quantization table id")
		end

		if Precision > 1 then
			error("invalid quantization precision")
		end

		if Cursor + (Precision + 1) * 64 > SegmentEnd then
			error("invalid quantization segment length")
		end

		const TableValues = buffer.create(256)

		for Index = 0, 63 do
			const NaturalIndex = Zigzag[Index + 1] + 1

			if Precision == 0 then
				const Value = buffer.readu8(Data, Cursor)
				Cursor += 1

				if Value == 0 then
					error("invalid quantization table value")
				end

				buffer.writeu32(TableValues, (NaturalIndex - 1) * 4, Value)
			else
				const Value = ReadU16BE(Data, Cursor)
				Cursor += 2

				if Value == 0 then
					error("invalid quantization table value")
				end

				buffer.writeu32(TableValues, (NaturalIndex - 1) * 4, Value)
			end
		end

		QuantizationTables[Id] = TableValues
	end

	if Cursor ~= SegmentEnd then
		error("invalid quantization segment length")
	end
end

const function ParseHuffmanTables(
	Data: buffer,
	Cursor: number,
	SegmentEnd: number,
	DcTables: { [number]: HuffmanTable },
	AcTables: { [number]: HuffmanTable }
)
	while Cursor < SegmentEnd do
		const Selector = buffer.readu8(Data, Cursor)
		Cursor += 1

		const Class = bit32.rshift(Selector, 4)
		const Id = bit32.band(Selector, 0x0f)
		const Counts: { [number]: number } = {}
		local Total = 0

		if Id > 3 then
			error("invalid Huffman table id")
		end

		if Class > 1 then
			error("invalid Huffman table class")
		end

		if Cursor + 16 > SegmentEnd then
			error("invalid Huffman segment length")
		end

		for Length = 1, 16 do
			const Count = buffer.readu8(Data, Cursor)
			Cursor += 1
			Counts[Length] = Count
			Total += Count
		end

		if Total == 0 or Total > 256 or Cursor + Total > SegmentEnd then
			error("invalid Huffman segment length")
		end

		const Values: { [number]: number } = {}

		for Index = 1, Total do
			const Value = buffer.readu8(Data, Cursor)
			Cursor += 1

			if Class == 0 then
				if Value > 16 then
					error("invalid DC Huffman value")
				end
			elseif Class == 1 then
				if bit32.band(Value, 0x0f) > 14 then
					error("invalid AC Huffman value")
				end
			end

			Values[Index] = Value
		end

		if Class == 0 then
			DcTables[Id] = BuildHuffmanTable(Counts, Values)
		else
			AcTables[Id] = BuildHuffmanTable(Counts, Values)
		end
	end

	if Cursor ~= SegmentEnd then
		error("invalid Huffman segment length")
	end
end

const function ParseFrame(
	Data: buffer,
	Cursor: number,
	SegmentEnd: number,
	FrameMarker: number
): (number, number, number, { Component }, { [number]: Component }, number, number)
	const Lossless = FrameMarker == 0xc3

	if SegmentEnd - Cursor < 6 then
		error("invalid frame segment length")
	end

	const Precision = buffer.readu8(Data, Cursor)
	Cursor += 1

	if Lossless then
		if Precision < 2 or Precision > 16 then
			error("only 2-bit through 16-bit lossless JPEG images are supported")
		end
	elseif Precision ~= 8 and Precision ~= 12 then
		error("only 8-bit and 12-bit DCT JPEG images are supported")
	end

	if FrameMarker == 0xc0 and Precision ~= 8 then
		error("baseline JPEG must be 8-bit")
	end

	const Height = ReadU16BE(Data, Cursor)
	Cursor += 2
	const Width = ReadU16BE(Data, Cursor)
	Cursor += 2
	const ComponentCount = buffer.readu8(Data, Cursor)
	Cursor += 1

	if ComponentCount < 1 or ComponentCount > 4 then
		error("only one-component through four-component JPEG images are supported")
	end

	if Cursor + ComponentCount * 3 ~= SegmentEnd then
		error("invalid frame segment length")
	end

	const Components: { Component } = {}
	const ComponentsById: { [number]: Component } = {}
	local MaxH = 1
	local MaxV = 1
	local McuBlockCount = 0

	for Index = 1, ComponentCount do
		const Id = buffer.readu8(Data, Cursor)
		Cursor += 1
		const Sampling = buffer.readu8(Data, Cursor)
		Cursor += 1
		const H = bit32.rshift(Sampling, 4)
		const V = bit32.band(Sampling, 0x0f)
		const QuantId = buffer.readu8(Data, Cursor)
		Cursor += 1

		if H < 1 or H > 4 or V < 1 or V > 4 then
			error("invalid component sampling factor")
		end

		if QuantId > 3 then
			error("invalid component quantization table")
		end

		if ComponentsById[Id] ~= nil then
			error("duplicate JPEG component id")
		end

		McuBlockCount += H * V

		if H > MaxH then
			MaxH = H
		end

		if V > MaxV then
			MaxV = V
		end

		const ComponentInfo: Component = {
			Id = Id,
			H = H,
			V = V,
			QuantId = QuantId,
			DcId = 0,
			AcId = 0,
			PrevDc = 0,
			Samples = EmptyEntropyData,
			Coefficients = EmptyEntropyData,
			PlaneWidth = 0,
			PlaneHeight = 0,
			BlockColumns = 0,
			BlockRows = 0,
			Scanned = false,
			ArithmeticDcContext = 0,
			LosslessPointTransform = -1,
			ProgressiveDcApprox = -1,
			ProgressiveBandApprox = {},
		}

		Components[Index] = ComponentInfo
		ComponentsById[Id] = ComponentInfo
	end

	if McuBlockCount > 10 then
		error("invalid JPEG MCU block count")
	end

	if Cursor ~= SegmentEnd then
		error("invalid frame segment length")
	end

	if Width <= 0 or Height <= 0 then
		error("invalid image dimensions")
	end

	local McuWidth = MaxH * 8
	local McuHeight = MaxV * 8

	if Lossless then
		McuWidth = MaxH
		McuHeight = MaxV
	end

	const McuColumns = (Width + McuWidth - 1) // McuWidth
	const McuRows = (Height + McuHeight - 1) // McuHeight

	for Index = 1, ComponentCount do
		const ComponentInfo = Components[Index]
		local PlaneWidth = McuColumns * ComponentInfo.H
		local PlaneHeight = McuRows * ComponentInfo.V

		if not Lossless then
			PlaneWidth *= 8
			PlaneHeight *= 8
		end

		if PlaneWidth > MaxOutputBytes // PlaneHeight then
			error("JPEG component sample plane too large")
		end

		ComponentInfo.PlaneWidth = PlaneWidth
		ComponentInfo.PlaneHeight = PlaneHeight
		ComponentInfo.BlockColumns = McuColumns * ComponentInfo.H
		ComponentInfo.BlockRows = McuRows * ComponentInfo.V
		ComponentInfo.Samples = buffer.create(PlaneWidth * PlaneHeight)

		if Lossless then
			if PlaneWidth > MaxOutputBytes // 2 // PlaneHeight then
				error("JPEG lossless sample plane too large")
			end

			ComponentInfo.Coefficients = buffer.create(PlaneWidth * PlaneHeight * 2)
		end
	end

	return Precision, Width, Height, Components, ComponentsById, MaxH, MaxV
end

const function ParseScan(
	Data: buffer,
	Cursor: number,
	SegmentEnd: number,
	Components: { Component },
	ComponentsById: { [number]: Component },
	Progressive: boolean,
	Baseline: boolean,
	Lossless: boolean
): ({ Component }, number, number, number, number)
	if SegmentEnd - Cursor < 4 then
		error("invalid scan segment length")
	end

	const ScanComponentCount = buffer.readu8(Data, Cursor)
	Cursor += 1

	if ScanComponentCount < 1 or ScanComponentCount > #Components then
		error("invalid JPEG scan component count")
	end

	if Cursor + ScanComponentCount * 2 + 3 ~= SegmentEnd then
		error("invalid scan segment length")
	end

	const ScanComponents: { Component } = {}

	for Index = 1, ScanComponentCount do
		const Id = buffer.readu8(Data, Cursor)
		Cursor += 1
		const Tables = buffer.readu8(Data, Cursor)
		Cursor += 1
		const ComponentInfo = ComponentsById[Id]

		if ComponentInfo == nil then
			error("scan references an unknown component")
		end

		for SeenIndex = 1, Index - 1 do
			if ScanComponents[SeenIndex] == ComponentInfo then
				error("duplicate JPEG scan component")
			end
		end

		ComponentInfo.DcId = bit32.rshift(Tables, 4)
		ComponentInfo.AcId = bit32.band(Tables, 0x0f)

		if ComponentInfo.DcId > 3 or ComponentInfo.AcId > 3 then
			error("invalid scan table id")
		end

		if Lossless and ComponentInfo.AcId ~= 0 then
			error("invalid lossless JPEG scan table id")
		end

		if Baseline and (ComponentInfo.DcId > 1 or ComponentInfo.AcId > 1) then
			error("invalid baseline JPEG scan table id")
		end

		ScanComponents[Index] = ComponentInfo
	end

	const SpectralStart = buffer.readu8(Data, Cursor)
	Cursor += 1
	const SpectralEnd = buffer.readu8(Data, Cursor)
	Cursor += 1
	const Approximation = buffer.readu8(Data, Cursor)
	Cursor += 1
	const ApproxHigh = bit32.rshift(Approximation, 4)
	const ApproxLow = bit32.band(Approximation, 0x0f)

	if Cursor ~= SegmentEnd then
		error("invalid scan segment length")
	end

	if Lossless then
		if SpectralStart < 1 or SpectralStart > 7 or SpectralEnd ~= 0 or ApproxHigh ~= 0 or ApproxLow > 15 then
			error("invalid lossless JPEG scan")
		end
	elseif Progressive then
		if SpectralStart > SpectralEnd or SpectralEnd > 63 or ApproxLow > 13 or ApproxHigh > 13 then
			error("invalid progressive JPEG scan")
		end

		if ApproxHigh > 0 and ApproxHigh ~= ApproxLow + 1 then
			error("invalid progressive JPEG approximation")
		end

		if SpectralStart == 0 then
			if SpectralEnd ~= 0 then
				error("invalid progressive JPEG DC scan")
			end
		elseif ScanComponentCount ~= 1 then
			error("invalid progressive JPEG AC scan")
		end
	else
		if SpectralStart ~= 0 or SpectralEnd ~= 63 or Approximation ~= 0 then
			error("invalid sequential JPEG scan")
		end
	end

	return ScanComponents, SpectralStart, SpectralEnd, ApproxHigh, ApproxLow
end

const function ResetArithmeticStats(
	ScanComponents: { Component },
	DcStats: { [number]: buffer },
	AcStats: { [number]: buffer },
	Progressive: boolean,
	SpectralStart: number,
	ApproxHigh: number
)
	for Index = 1, #ScanComponents do
		const ComponentInfo = ScanComponents[Index]

		if (not Progressive) or (SpectralStart == 0 and ApproxHigh == 0) then
			buffer.fill(DcStats[ComponentInfo.DcId], 0, 0)
			ComponentInfo.PrevDc = 0
			ComponentInfo.ArithmeticDcContext = 0
		end

		if (not Progressive) or SpectralStart > 0 then
			buffer.fill(AcStats[ComponentInfo.AcId], 0, 0)
		end
	end
end

const function DecodeArithmeticDcValue(
	ComponentInfo: Component,
	DcStats: { [number]: buffer },
	ArithmeticDcL: { [number]: number },
	ArithmeticDcU: { [number]: number },
	ApproxLow: number
): number
	const Stats = DcStats[ComponentInfo.DcId]
	local StatsOffset = ComponentInfo.ArithmeticDcContext

	if DecodeArithmeticBit(Stats, StatsOffset) == 0 then
		ComponentInfo.ArithmeticDcContext = 0
	else
		const Sign = DecodeArithmeticBit(Stats, StatsOffset + 1)
		StatsOffset += 2 + Sign
		local Magnitude = DecodeArithmeticBit(Stats, StatsOffset)

		if Magnitude ~= 0 then
			StatsOffset = 20

			while DecodeArithmeticBit(Stats, StatsOffset) ~= 0 do
				Magnitude *= 2

				if Magnitude == 0x8000 then
					error("invalid arithmetic DC magnitude")
				end

				StatsOffset += 1
			end
		end

		if Magnitude < BitPowers[ArithmeticDcL[ComponentInfo.DcId]] // 2 then
			ComponentInfo.ArithmeticDcContext = 0
		elseif Magnitude > BitPowers[ArithmeticDcU[ComponentInfo.DcId]] // 2 then
			ComponentInfo.ArithmeticDcContext = 12 + Sign * 4
		else
			ComponentInfo.ArithmeticDcContext = 4 + Sign * 4
		end

		local Value = Magnitude
		StatsOffset += 14

		while Magnitude > 1 do
			Magnitude //= 2

			if DecodeArithmeticBit(Stats, StatsOffset) ~= 0 then
				Value += Magnitude
			end
		end

		Value += 1

		if Sign ~= 0 then
			Value = -Value
		end

		ComponentInfo.PrevDc += Value
	end

	return ComponentInfo.PrevDc * BitPowers[ApproxLow]
end

const function DecodeArithmeticAcCoefficients(
	Coefficients: { [number]: number },
	ComponentInfo: Component,
	Quantization: buffer,
	AcStats: { [number]: buffer },
	FixedStats: buffer,
	ArithmeticAcK: { [number]: number },
	SpectralStart: number,
	SpectralEnd: number,
	ApproxLow: number,
	TouchedCoefficients: { [number]: number },
	TouchedCount: number
): (number, boolean)
	const Stats = AcStats[ComponentInfo.AcId]
	local K = SpectralStart - 1
	local HasAc = false
	const Bit = BitPowers[ApproxLow]

	while K < SpectralEnd do
		local StatsOffset = K * 3

		if DecodeArithmeticBit(Stats, StatsOffset) ~= 0 then
			break
		end

		while true do
			K += 1

			if DecodeArithmeticBit(Stats, StatsOffset + 1) ~= 0 then
				break
			end

			StatsOffset += 3

			if K >= SpectralEnd then
				error("invalid arithmetic AC run length")
			end
		end

		const Sign = DecodeArithmeticBit(FixedStats, 0)
		StatsOffset += 2
		local Magnitude = DecodeArithmeticBit(Stats, StatsOffset)

		if Magnitude ~= 0 and DecodeArithmeticBit(Stats, StatsOffset) ~= 0 then
			Magnitude *= 2

			if K <= ArithmeticAcK[ComponentInfo.AcId] then
				StatsOffset = 189
			else
				StatsOffset = 217
			end

			while DecodeArithmeticBit(Stats, StatsOffset) ~= 0 do
				Magnitude *= 2

				if Magnitude == 0x8000 then
					error("invalid arithmetic AC magnitude")
				end

				StatsOffset += 1
			end
		end

		local Value = Magnitude
		StatsOffset += 14

		while Magnitude > 1 do
			Magnitude //= 2

			if DecodeArithmeticBit(Stats, StatsOffset) ~= 0 then
				Value += Magnitude
			end
		end

		Value += 1

		if Sign ~= 0 then
			Value = -Value
		end

		const NaturalIndex = Zigzag[K + 1] + 1
		Coefficients[NaturalIndex] = Value * buffer.readu32(Quantization, (NaturalIndex - 1) * 4) * Bit
		TouchedCount += 1
		TouchedCoefficients[TouchedCount] = NaturalIndex
		HasAc = true
	end

	return TouchedCount, HasAc
end

const function ReceiveLosslessDifference(DcTable: HuffmanTable, DifferencePrecision: number): number
	const Length = DecodeHuffman(DcTable)

	if Length > DifferencePrecision then
		error("invalid lossless JPEG difference length")
	end

	return Receive(Length)
end

const function LosslessPredictor(Selection: number, Left: number, Up: number, UpLeft: number): number
	if Selection == 1 then
		return Left
	elseif Selection == 2 then
		return Up
	elseif Selection == 3 then
		return UpLeft
	elseif Selection == 4 then
		return Left + Up - UpLeft
	elseif Selection == 5 then
		return Left + (Up - UpLeft) // 2
	elseif Selection == 6 then
		return Up + (Left - UpLeft) // 2
	end

	return (Left + Up) // 2
end

const function DecodeLosslessSample(
	ComponentInfo: Component,
	DcTables: { [number]: HuffmanTable },
	X: number,
	Y: number,
	FirstAfterRestart: boolean,
	PredictorSelection: number,
	PointTransform: number,
	SamplePrecision: number
)
	const DcTable = DcTables[ComponentInfo.DcId]

	if DcTable == nil then
		error(`missing DC Huffman table {ComponentInfo.DcId}`)
	end

	const PlaneWidth = ComponentInfo.PlaneWidth
	const Offset = (Y * PlaneWidth + X) * 2
	local Prediction = BitPowers[SamplePrecision - PointTransform - 1]

	if FirstAfterRestart then
		Prediction = BitPowers[SamplePrecision - PointTransform - 1]
	elseif Y == 0 then
		Prediction = buffer.readu16(ComponentInfo.Coefficients, Offset - 2)
	elseif X == 0 then
		Prediction = buffer.readu16(ComponentInfo.Coefficients, Offset - PlaneWidth * 2)
	else
		const Left = buffer.readu16(ComponentInfo.Coefficients, Offset - 2)
		const Up = buffer.readu16(ComponentInfo.Coefficients, Offset - PlaneWidth * 2)
		const UpLeft = buffer.readu16(ComponentInfo.Coefficients, Offset - PlaneWidth * 2 - 2)
		Prediction = LosslessPredictor(PredictorSelection, Left, Up, UpLeft)
	end

	const DifferencePrecision = SamplePrecision - PointTransform
	const Value = Prediction + ReceiveLosslessDifference(DcTable, DifferencePrecision)

	if Value < 0 or Value >= BitPowers[DifferencePrecision] then
		error("lossless JPEG sample out of range")
	end

	buffer.writeu16(ComponentInfo.Coefficients, Offset, Value)
end

const function RenderLosslessComponents(Components: { Component }, SamplePrecision: number)
	const MaxSample = BitPowers[SamplePrecision] - 1

	for ComponentIndex = 1, #Components do
		const ComponentInfo = Components[ComponentIndex]
		const PixelCount = ComponentInfo.PlaneWidth * ComponentInfo.PlaneHeight
		const PointScale = BitPowers[ComponentInfo.LosslessPointTransform]

		for Index = 0, PixelCount - 1 do
			const Value = buffer.readu16(ComponentInfo.Coefficients, Index * 2) * PointScale
			buffer.writeu8(ComponentInfo.Samples, Index, math.clamp(math.round(Value * 255 / MaxSample), 0, 255))
		end
	end
end

const function DecodeLosslessScan(
	ScanComponents: { Component },
	DcTables: { [number]: HuffmanTable },
	RestartInterval: number,
	McuColumns: number,
	McuRows: number,
	PredictorSelection: number,
	PointTransform: number,
	SamplePrecision: number
)
	if PointTransform >= SamplePrecision then
		error("invalid lossless JPEG point transform")
	end

	for Index = 1, #ScanComponents do
		const ComponentInfo = ScanComponents[Index]

		if ComponentInfo.Scanned then
			error("duplicate lossless JPEG component scan")
		end

		ComponentInfo.Scanned = true
		ComponentInfo.LosslessPointTransform = PointTransform
	end

	local RestartCounter = 0
	local ExpectedRestart = 0

	if #ScanComponents == 1 then
		const ComponentInfo = ScanComponents[1]
		local FirstAfterRestart = true
		local UnitIndex = 0

		for Y = 0, ComponentInfo.PlaneHeight - 1 do
			for X = 0, ComponentInfo.PlaneWidth - 1 do
				DecodeLosslessSample(ComponentInfo, DcTables, X, Y, FirstAfterRestart, PredictorSelection, PointTransform, SamplePrecision)
				FirstAfterRestart = false
				UnitIndex += 1

				if RestartInterval > 0 then
					RestartCounter += 1

					if RestartCounter == RestartInterval and UnitIndex < ComponentInfo.PlaneWidth * ComponentInfo.PlaneHeight then
						ExpectedRestart = ConsumeRestartMarker(ExpectedRestart)
						FirstAfterRestart = true
						RestartCounter = 0
					end
				end
			end
		end
	else
		const FirstAfterRestart: { [number]: boolean } = {}

		for ComponentIndex = 1, #ScanComponents do
			FirstAfterRestart[ComponentIndex] = true
		end

		for McuY = 0, McuRows - 1 do
			for McuX = 0, McuColumns - 1 do
				for ComponentIndex = 1, #ScanComponents do
					const ComponentInfo = ScanComponents[ComponentIndex]

					for SampleY = 0, ComponentInfo.V - 1 do
						for SampleX = 0, ComponentInfo.H - 1 do
							DecodeLosslessSample(
								ComponentInfo,
								DcTables,
								McuX * ComponentInfo.H + SampleX,
								McuY * ComponentInfo.V + SampleY,
								FirstAfterRestart[ComponentIndex],
								PredictorSelection,
								PointTransform,
								SamplePrecision
							)
							FirstAfterRestart[ComponentIndex] = false
						end
					end
				end

				if RestartInterval > 0 then
					RestartCounter += 1

					if RestartCounter == RestartInterval and not (McuY == McuRows - 1 and McuX == McuColumns - 1) then
						ExpectedRestart = ConsumeRestartMarker(ExpectedRestart)
						for ComponentIndex = 1, #ScanComponents do
							FirstAfterRestart[ComponentIndex] = true
						end

						RestartCounter = 0
					end
				end
			end
		end
	end

	EntropyBits = 0
	EntropyBitCount = 0
end

const function DecodeSequentialScan(
	ScanComponents: { Component },
	QuantizationTables: { [number]: buffer },
	DcTables: { [number]: HuffmanTable },
	AcTables: { [number]: HuffmanTable },
	RestartInterval: number,
	McuColumns: number,
	McuRows: number,
	Coefficients: { [number]: number },
	Workspace: { [number]: number },
	TouchedCoefficients: { [number]: number },
	SamplePrecision: number
)
	ResetDc(ScanComponents)

	for Index = 1, #ScanComponents do
		const ComponentInfo = ScanComponents[Index]

		if ComponentInfo.Scanned then
			error("duplicate sequential JPEG component scan")
		end

		ComponentInfo.Scanned = true
	end

	local RestartCounter = 0
	local ExpectedRestart = 0

	if #ScanComponents == 1 then
		const ComponentInfo = ScanComponents[1]
		const BlockColumns = McuColumns * ComponentInfo.H
		const BlockRows = McuRows * ComponentInfo.V

		for BlockY = 0, BlockRows - 1 do
			for BlockX = 0, BlockColumns - 1 do
				DecodeBlock(
					ComponentInfo,
					QuantizationTables,
					DcTables,
					AcTables,
					BlockY * 8 * ComponentInfo.PlaneWidth + BlockX * 8,
					Coefficients,
					Workspace,
					TouchedCoefficients,
					SamplePrecision
				)

				if RestartInterval > 0 then
					RestartCounter += 1

					if RestartCounter == RestartInterval and not (BlockY == BlockRows - 1 and BlockX == BlockColumns - 1) then
						ExpectedRestart = ConsumeRestartMarker(ExpectedRestart)
						ResetDc(ScanComponents)
						RestartCounter = 0
					end
				end
			end
		end
	else
		for McuY = 0, McuRows - 1 do
			for McuX = 0, McuColumns - 1 do
				for ComponentIndex = 1, #ScanComponents do
					const ComponentInfo = ScanComponents[ComponentIndex]

					for BlockY = 0, ComponentInfo.V - 1 do
						for BlockX = 0, ComponentInfo.H - 1 do
							DecodeBlock(
								ComponentInfo,
								QuantizationTables,
								DcTables,
								AcTables,
								(McuY * ComponentInfo.V + BlockY) * 8 * ComponentInfo.PlaneWidth
									+ (McuX * ComponentInfo.H + BlockX) * 8,
								Coefficients,
								Workspace,
								TouchedCoefficients,
								SamplePrecision
							)
						end
					end
				end

				if RestartInterval > 0 then
					RestartCounter += 1

					if RestartCounter == RestartInterval and not (McuY == McuRows - 1 and McuX == McuColumns - 1) then
						ExpectedRestart = ConsumeRestartMarker(ExpectedRestart)
						ResetDc(ScanComponents)
						RestartCounter = 0
					end
				end
			end
		end
	end

	EntropyBits = 0
	EntropyBitCount = 0
end

const function DecodeArithmeticBlock(
	ComponentInfo: Component,
	QuantizationTables: { [number]: buffer },
	DcStats: { [number]: buffer },
	AcStats: { [number]: buffer },
	FixedStats: buffer,
	ArithmeticDcL: { [number]: number },
	ArithmeticDcU: { [number]: number },
	ArithmeticAcK: { [number]: number },
	OutputOffset: number,
	Coefficients: { [number]: number },
	Workspace: { [number]: number },
	TouchedCoefficients: { [number]: number },
	SamplePrecision: number
)
	const Quantization = QuantizationTables[ComponentInfo.QuantId]

	if Quantization == nil then
		error(`missing quantization table {ComponentInfo.QuantId}`)
	end

	Coefficients[1] = DecodeArithmeticDcValue(ComponentInfo, DcStats, ArithmeticDcL, ArithmeticDcU, 0) * buffer.readu32(Quantization, 0)
	local TouchedCount = 1
	local HasAc = false
	TouchedCoefficients[1] = 1
	TouchedCount, HasAc = DecodeArithmeticAcCoefficients(
		Coefficients,
		ComponentInfo,
		Quantization,
		AcStats,
		FixedStats,
		ArithmeticAcK,
		1,
		63,
		0,
		TouchedCoefficients,
		TouchedCount
	)

	if HasAc then
		InverseDct(Coefficients, Workspace, ComponentInfo.Samples, OutputOffset, ComponentInfo.PlaneWidth, SamplePrecision)

		for TouchedIndex = 1, TouchedCount do
			Coefficients[TouchedCoefficients[TouchedIndex]] = 0
		end
	else
		FillDcBlock(Coefficients[1], ComponentInfo.Samples, OutputOffset, ComponentInfo.PlaneWidth, SamplePrecision)
	end
end

const function DecodeArithmeticSequentialScan(
	ScanComponents: { Component },
	QuantizationTables: { [number]: buffer },
	DcStats: { [number]: buffer },
	AcStats: { [number]: buffer },
	FixedStats: buffer,
	ArithmeticDcL: { [number]: number },
	ArithmeticDcU: { [number]: number },
	ArithmeticAcK: { [number]: number },
	RestartInterval: number,
	McuColumns: number,
	McuRows: number,
	Coefficients: { [number]: number },
	Workspace: { [number]: number },
	TouchedCoefficients: { [number]: number },
	SamplePrecision: number
)
	for Index = 1, #ScanComponents do
		const ComponentInfo = ScanComponents[Index]

		if ComponentInfo.Scanned then
			error("duplicate sequential JPEG component scan")
		end

		ComponentInfo.Scanned = true
	end

	ResetArithmeticStats(ScanComponents, DcStats, AcStats, false, 0, 0)
	ResetFixedArithmeticStats(FixedStats)
	ResetArithmeticCoder()

	local RestartCounter = 0
	local ExpectedRestart = 0

	if #ScanComponents == 1 then
		const ComponentInfo = ScanComponents[1]
		const BlockColumns = McuColumns * ComponentInfo.H
		const BlockRows = McuRows * ComponentInfo.V

		for BlockY = 0, BlockRows - 1 do
			for BlockX = 0, BlockColumns - 1 do
				DecodeArithmeticBlock(
					ComponentInfo,
					QuantizationTables,
					DcStats,
					AcStats,
					FixedStats,
					ArithmeticDcL,
					ArithmeticDcU,
					ArithmeticAcK,
					BlockY * 8 * ComponentInfo.PlaneWidth + BlockX * 8,
					Coefficients,
					Workspace,
					TouchedCoefficients,
					SamplePrecision
				)

				if RestartInterval > 0 then
					RestartCounter += 1

					if RestartCounter == RestartInterval and not (BlockY == BlockRows - 1 and BlockX == BlockColumns - 1) then
						ExpectedRestart = ConsumeArithmeticRestartMarker(ExpectedRestart)
						ResetArithmeticStats(ScanComponents, DcStats, AcStats, false, 0, 0)
						ResetFixedArithmeticStats(FixedStats)
						ResetArithmeticCoder()
						RestartCounter = 0
					end
				end
			end
		end
	else
		for McuY = 0, McuRows - 1 do
			for McuX = 0, McuColumns - 1 do
				for ComponentIndex = 1, #ScanComponents do
					const ComponentInfo = ScanComponents[ComponentIndex]

					for BlockY = 0, ComponentInfo.V - 1 do
						for BlockX = 0, ComponentInfo.H - 1 do
							DecodeArithmeticBlock(
								ComponentInfo,
								QuantizationTables,
								DcStats,
								AcStats,
								FixedStats,
								ArithmeticDcL,
								ArithmeticDcU,
								ArithmeticAcK,
								(McuY * ComponentInfo.V + BlockY) * 8 * ComponentInfo.PlaneWidth
									+ (McuX * ComponentInfo.H + BlockX) * 8,
								Coefficients,
								Workspace,
								TouchedCoefficients,
								SamplePrecision
							)
						end
					end
				end

				if RestartInterval > 0 then
					RestartCounter += 1

					if RestartCounter == RestartInterval and not (McuY == McuRows - 1 and McuX == McuColumns - 1) then
						ExpectedRestart = ConsumeArithmeticRestartMarker(ExpectedRestart)
						ResetArithmeticStats(ScanComponents, DcStats, AcStats, false, 0, 0)
						ResetFixedArithmeticStats(FixedStats)
						ResetArithmeticCoder()
						RestartCounter = 0
					end
				end
			end
		end
	end

	EntropyBits = 0
	EntropyBitCount = 0
end

const function AllocateProgressiveCoefficients(Components: { Component })
	for Index = 1, #Components do
		const ComponentInfo = Components[Index]
		const CoefficientCount = ComponentInfo.BlockColumns * ComponentInfo.BlockRows * 64

		if CoefficientCount > MaxOutputBytes // 4 then
			error("JPEG coefficient data too large")
		end

		ComponentInfo.Coefficients = buffer.create(CoefficientCount * 4)
	end
end

const function ParseArithmeticConditioning(
	Data: buffer,
	Cursor: number,
	SegmentEnd: number,
	ArithmeticDcL: { [number]: number },
	ArithmeticDcU: { [number]: number },
	ArithmeticAcK: { [number]: number }
)
	while Cursor < SegmentEnd do
		if Cursor + 2 > SegmentEnd then
			error("invalid arithmetic conditioning segment length")
		end

		const Index = buffer.readu8(Data, Cursor)
		Cursor += 1
		const Value = buffer.readu8(Data, Cursor)
		Cursor += 1

		if Index < 4 then
			const L = bit32.band(Value, 0x0f)
			const U = bit32.rshift(Value, 4)

			if L > U then
				error("invalid arithmetic DC conditioning")
			end

			ArithmeticDcL[Index] = L
			ArithmeticDcU[Index] = U
		elseif Index >= 16 and Index < 20 then
			if Value > 63 then
				error("invalid arithmetic AC conditioning")
			end

			ArithmeticAcK[Index - 16] = Value
		else
			error("unsupported arithmetic conditioning table")
		end
	end

	if Cursor ~= SegmentEnd then
		error("invalid arithmetic conditioning segment length")
	end
end

const function DecodeProgressiveDcBlock(
	ComponentInfo: Component,
	BlockX: number,
	BlockY: number,
	DcTable: HuffmanTable?,
	ApproxHigh: number,
	ApproxLow: number,
	SamplePrecision: number
)
	const Offset = CoefficientOffset(ComponentInfo, BlockX, BlockY, 0)

	if ApproxHigh == 0 then
		if DcTable == nil then
			error(`missing DC Huffman table {ComponentInfo.DcId}`)
		end

		const DcLength = DecodeHuffman(DcTable)

		if DcLength > SamplePrecision + 3 then
			error("invalid DC coefficient length")
		end

		ComponentInfo.PrevDc += Receive(DcLength)
		buffer.writei32(ComponentInfo.Coefficients, Offset, ComponentInfo.PrevDc * BitPowers[ApproxLow])
	elseif ApproxHigh == ApproxLow + 1 then
		if ReadBits(1) ~= 0 then
			local Value = buffer.readi32(ComponentInfo.Coefficients, Offset)

			if Value < 0 then
				Value -= BitPowers[ApproxLow]
			else
				Value += BitPowers[ApproxLow]
			end

			buffer.writei32(ComponentInfo.Coefficients, Offset, Value)
		end
	else
		error("invalid progressive JPEG DC approximation")
	end
end

const function DecodeProgressiveAcFirstBlock(
	ComponentInfo: Component,
	BlockX: number,
	BlockY: number,
	AcTable: HuffmanTable,
	SpectralStart: number,
	SpectralEnd: number,
	ApproxLow: number,
	EndOfBandRun: number,
	SamplePrecision: number
): number
	if EndOfBandRun > 0 then
		return EndOfBandRun - 1
	end

	local SpectralIndex = SpectralStart
	const CoefficientBase = (BlockY * ComponentInfo.BlockColumns + BlockX) * 64 * 4
	const Bit = BitPowers[ApproxLow]

	while SpectralIndex <= SpectralEnd do
		const Symbol = DecodeHuffman(AcTable)
		const Run = bit32.rshift(Symbol, 4)
		const Size = bit32.band(Symbol, 0x0f)

		if Size == 0 then
			if Run == 15 then
				SpectralIndex += 16

				if SpectralIndex > SpectralEnd + 1 then
					error("invalid progressive JPEG AC run length")
				end
			else
				return BitPowers[Run] - 1 + ReadBits(Run)
			end
		elseif Size <= SamplePrecision + 2 then
			SpectralIndex += Run

			if SpectralIndex > SpectralEnd then
				error("invalid progressive JPEG AC run length")
			end

			const Coefficient = Receive(Size) * Bit
			const Offset = CoefficientBase + Zigzag[SpectralIndex + 1] * 4

			if buffer.readi32(ComponentInfo.Coefficients, Offset) ~= 0 then
				error("duplicate progressive JPEG AC coefficient")
			end

			buffer.writei32(ComponentInfo.Coefficients, Offset, Coefficient)
			SpectralIndex += 1
		else
			error("invalid progressive JPEG AC coefficient length")
		end
	end

	return 0
end

const function RefineProgressiveAcBlock(
	ComponentInfo: Component,
	BlockX: number,
	BlockY: number,
	AcTable: HuffmanTable,
	SpectralStart: number,
	SpectralEnd: number,
	ApproxLow: number,
	EndOfBandRun: number
): number
	local SpectralIndex = SpectralStart
	const CoefficientBase = (BlockY * ComponentInfo.BlockColumns + BlockX) * 64 * 4
	const Bit = BitPowers[ApproxLow]

	if EndOfBandRun > 0 then
		while SpectralIndex <= SpectralEnd do
			const Offset = CoefficientBase + Zigzag[SpectralIndex + 1] * 4
			local Value = buffer.readi32(ComponentInfo.Coefficients, Offset)

			if Value ~= 0 then
				Value = RefineCoefficient(Value, Bit)
				buffer.writei32(ComponentInfo.Coefficients, Offset, Value)
			end

			SpectralIndex += 1
		end

		return EndOfBandRun - 1
	end

	while SpectralIndex <= SpectralEnd do
		const Symbol = DecodeHuffman(AcTable)
		local Run = bit32.rshift(Symbol, 4)
		const Size = bit32.band(Symbol, 0x0f)
		local NewCoefficient = 0
		local SkipOnly = false

		if Size == 0 then
			if Run < 15 then
				EndOfBandRun = BitPowers[Run] - 1 + ReadBits(Run)

				while SpectralIndex <= SpectralEnd do
					const Offset = CoefficientBase + Zigzag[SpectralIndex + 1] * 4
					local Value = buffer.readi32(ComponentInfo.Coefficients, Offset)

					if Value ~= 0 then
						Value = RefineCoefficient(Value, Bit)
						buffer.writei32(ComponentInfo.Coefficients, Offset, Value)
					end

					SpectralIndex += 1
				end

				return EndOfBandRun
			end

			Run = 16
			SkipOnly = true
		elseif Size == 1 then
			if ReadBits(1) == 0 then
				NewCoefficient = -Bit
			else
				NewCoefficient = Bit
			end
		else
			error("invalid progressive JPEG AC refinement")
		end

		local PlacedNewCoefficient = false

		while SpectralIndex <= SpectralEnd do
			const Offset = CoefficientBase + Zigzag[SpectralIndex + 1] * 4
			local Value = buffer.readi32(ComponentInfo.Coefficients, Offset)

			if Value ~= 0 then
				Value = RefineCoefficient(Value, Bit)
				buffer.writei32(ComponentInfo.Coefficients, Offset, Value)
			elseif Run > 0 then
				Run -= 1
			elseif SkipOnly then
				break
			else
				buffer.writei32(ComponentInfo.Coefficients, Offset, NewCoefficient)
				SpectralIndex += 1
				PlacedNewCoefficient = true
				break
			end

			SpectralIndex += 1
		end

		if SkipOnly then
			if Run > 0 then
				error("invalid progressive JPEG AC run length")
			end
		elseif NewCoefficient ~= 0 and not PlacedNewCoefficient then
			error("invalid progressive JPEG AC run length")
		end
	end

	return 0
end

const function DecodeProgressiveScan(
	ScanComponents: { Component },
	DcTables: { [number]: HuffmanTable },
	AcTables: { [number]: HuffmanTable },
	RestartInterval: number,
	McuColumns: number,
	McuRows: number,
	SpectralStart: number,
	SpectralEnd: number,
	ApproxHigh: number,
	ApproxLow: number,
	SamplePrecision: number
)
	local RestartCounter = 0
	local ExpectedRestart = 0
	local EndOfBandRun = 0

	if SpectralStart == 0 then
		if ApproxHigh == 0 then
			ResetDc(ScanComponents)

			for Index = 1, #ScanComponents do
				if ScanComponents[Index].Scanned then
					error("duplicate progressive JPEG DC scan")
				end

				ScanComponents[Index].Scanned = true
				ScanComponents[Index].ProgressiveDcApprox = ApproxLow
			end
		end

		if #ScanComponents == 1 then
			const ComponentInfo = ScanComponents[1]
			const DcTable = DcTables[ComponentInfo.DcId]

			if ApproxHigh == 0 and DcTable == nil then
				error(`missing DC Huffman table {ComponentInfo.DcId}`)
			end

			if ApproxHigh > 0 and not ComponentInfo.Scanned then
				error("progressive JPEG DC refinement before DC scan")
			end

			if ApproxHigh > 0 then
				if ComponentInfo.ProgressiveDcApprox ~= ApproxHigh then
					error("invalid progressive JPEG DC refinement order")
				end

				ComponentInfo.ProgressiveDcApprox = ApproxLow
			end

			for BlockY = 0, ComponentInfo.BlockRows - 1 do
				for BlockX = 0, ComponentInfo.BlockColumns - 1 do
					DecodeProgressiveDcBlock(ComponentInfo, BlockX, BlockY, DcTable, ApproxHigh, ApproxLow, SamplePrecision)

					if RestartInterval > 0 then
						RestartCounter += 1

						if RestartCounter == RestartInterval and not (BlockY == ComponentInfo.BlockRows - 1 and BlockX == ComponentInfo.BlockColumns - 1) then
							ExpectedRestart = ConsumeRestartMarker(ExpectedRestart)
							ResetDc(ScanComponents)
							RestartCounter = 0
							EndOfBandRun = 0
						end
					end
				end
			end
		else
			for McuY = 0, McuRows - 1 do
				for McuX = 0, McuColumns - 1 do
					for ComponentIndex = 1, #ScanComponents do
						const ComponentInfo = ScanComponents[ComponentIndex]
						const DcTable = DcTables[ComponentInfo.DcId]

						if ApproxHigh == 0 and DcTable == nil then
							error(`missing DC Huffman table {ComponentInfo.DcId}`)
						end

						if ApproxHigh > 0 and not ComponentInfo.Scanned then
							error("progressive JPEG DC refinement before DC scan")
						end

						if ApproxHigh > 0 then
							if ComponentInfo.ProgressiveDcApprox ~= ApproxHigh then
								error("invalid progressive JPEG DC refinement order")
							end

							ComponentInfo.ProgressiveDcApprox = ApproxLow
						end

						for BlockY = 0, ComponentInfo.V - 1 do
							for BlockX = 0, ComponentInfo.H - 1 do
								DecodeProgressiveDcBlock(
									ComponentInfo,
									McuX * ComponentInfo.H + BlockX,
									McuY * ComponentInfo.V + BlockY,
									DcTable,
									ApproxHigh,
									ApproxLow,
									SamplePrecision
								)
							end
						end
					end

					if RestartInterval > 0 then
						RestartCounter += 1

						if RestartCounter == RestartInterval and not (McuY == McuRows - 1 and McuX == McuColumns - 1) then
							ExpectedRestart = ConsumeRestartMarker(ExpectedRestart)
							ResetDc(ScanComponents)
							RestartCounter = 0
							EndOfBandRun = 0
						end
					end
				end
			end
		end
	else
		const ComponentInfo = ScanComponents[1]
		const AcTable = AcTables[ComponentInfo.AcId]

		if AcTable == nil then
			error(`missing AC Huffman table {ComponentInfo.AcId}`)
		end

		if not ComponentInfo.Scanned then
			error("progressive JPEG AC scan before DC scan")
		end

		if ApproxHigh == 0 then
			for SpectralIndex = SpectralStart, SpectralEnd do
				if ComponentInfo.ProgressiveBandApprox[SpectralIndex] ~= nil then
					error("duplicate progressive JPEG AC band scan")
				end
			end

			for SpectralIndex = SpectralStart, SpectralEnd do
				ComponentInfo.ProgressiveBandApprox[SpectralIndex] = ApproxLow
			end
		else
			for SpectralIndex = SpectralStart, SpectralEnd do
				if ComponentInfo.ProgressiveBandApprox[SpectralIndex] ~= ApproxHigh then
					error("progressive JPEG AC refinement before AC scan")
				end
			end

			for SpectralIndex = SpectralStart, SpectralEnd do
				ComponentInfo.ProgressiveBandApprox[SpectralIndex] = ApproxLow
			end
		end

		for BlockY = 0, ComponentInfo.BlockRows - 1 do
			for BlockX = 0, ComponentInfo.BlockColumns - 1 do
				if ApproxHigh == 0 then
					EndOfBandRun = DecodeProgressiveAcFirstBlock(
						ComponentInfo,
						BlockX,
						BlockY,
						AcTable,
						SpectralStart,
						SpectralEnd,
						ApproxLow,
						EndOfBandRun,
						SamplePrecision
					)
				elseif ApproxHigh == ApproxLow + 1 then
					EndOfBandRun = RefineProgressiveAcBlock(
						ComponentInfo,
						BlockX,
						BlockY,
						AcTable,
						SpectralStart,
						SpectralEnd,
						ApproxLow,
						EndOfBandRun
					)
				else
					error("invalid progressive JPEG AC approximation")
				end

				if RestartInterval > 0 then
					RestartCounter += 1

					if RestartCounter == RestartInterval and not (BlockY == ComponentInfo.BlockRows - 1 and BlockX == ComponentInfo.BlockColumns - 1) then
						ExpectedRestart = ConsumeRestartMarker(ExpectedRestart)
						RestartCounter = 0
						EndOfBandRun = 0
					end
				end
			end
		end
	end

	EntropyBits = 0
	EntropyBitCount = 0
end

const function DecodeArithmeticProgressiveAcFirstBlock(
	ComponentInfo: Component,
	BlockX: number,
	BlockY: number,
	AcStats: { [number]: buffer },
	FixedStats: buffer,
	ArithmeticAcK: { [number]: number },
	SpectralStart: number,
	SpectralEnd: number,
	ApproxLow: number
)
	const Stats = AcStats[ComponentInfo.AcId]
	local K = SpectralStart - 1
	const Bit = BitPowers[ApproxLow]
	const CoefficientBase = (BlockY * ComponentInfo.BlockColumns + BlockX) * 64 * 4

	while K < SpectralEnd do
		local StatsOffset = K * 3

		if DecodeArithmeticBit(Stats, StatsOffset) ~= 0 then
			break
		end

		while true do
			K += 1

			if DecodeArithmeticBit(Stats, StatsOffset + 1) ~= 0 then
				break
			end

			StatsOffset += 3

			if K >= SpectralEnd then
				error("invalid arithmetic progressive AC run length")
			end
		end

		const Sign = DecodeArithmeticBit(FixedStats, 0)
		StatsOffset += 2
		local Magnitude = DecodeArithmeticBit(Stats, StatsOffset)

		if Magnitude ~= 0 and DecodeArithmeticBit(Stats, StatsOffset) ~= 0 then
			Magnitude *= 2

			if K <= ArithmeticAcK[ComponentInfo.AcId] then
				StatsOffset = 189
			else
				StatsOffset = 217
			end

			while DecodeArithmeticBit(Stats, StatsOffset) ~= 0 do
				Magnitude *= 2

				if Magnitude == 0x8000 then
					error("invalid arithmetic progressive AC magnitude")
				end

				StatsOffset += 1
			end
		end

		local Value = Magnitude
		StatsOffset += 14

		while Magnitude > 1 do
			Magnitude //= 2

			if DecodeArithmeticBit(Stats, StatsOffset) ~= 0 then
				Value += Magnitude
			end
		end

		Value += 1

		if Sign ~= 0 then
			Value = -Value
		end

		const Offset = CoefficientBase + Zigzag[K + 1] * 4

		if buffer.readi32(ComponentInfo.Coefficients, Offset) ~= 0 then
			error("duplicate arithmetic progressive AC coefficient")
		end

		buffer.writei32(ComponentInfo.Coefficients, Offset, Value * Bit)
	end
end

const function RefineArithmeticProgressiveAcBlock(
	ComponentInfo: Component,
	BlockX: number,
	BlockY: number,
	AcStats: { [number]: buffer },
	FixedStats: buffer,
	SpectralStart: number,
	SpectralEnd: number,
	ApproxLow: number
)
	const Stats = AcStats[ComponentInfo.AcId]
	const Bit = BitPowers[ApproxLow]
	const NegativeBit = -Bit
	local Kex = SpectralEnd
	const CoefficientBase = (BlockY * ComponentInfo.BlockColumns + BlockX) * 64 * 4

	while Kex > 0 and buffer.readi32(ComponentInfo.Coefficients, CoefficientBase + Zigzag[Kex + 1] * 4) == 0 do
		Kex -= 1
	end

	local K = SpectralStart - 1

	while K < SpectralEnd do
		local StatsOffset = K * 3

		if K >= Kex and DecodeArithmeticBit(Stats, StatsOffset) ~= 0 then
			break
		end

		while true do
			K += 1

			const Offset = CoefficientBase + Zigzag[K + 1] * 4
			local Value = buffer.readi32(ComponentInfo.Coefficients, Offset)

			if Value ~= 0 then
				if DecodeArithmeticBit(Stats, StatsOffset + 2) ~= 0 then
					if Value < 0 then
						Value += NegativeBit
					else
						Value += Bit
					end

					buffer.writei32(ComponentInfo.Coefficients, Offset, Value)
				end

				break
			end

			if DecodeArithmeticBit(Stats, StatsOffset + 1) ~= 0 then
				if DecodeArithmeticBit(FixedStats, 0) ~= 0 then
					buffer.writei32(ComponentInfo.Coefficients, Offset, NegativeBit)
				else
					buffer.writei32(ComponentInfo.Coefficients, Offset, Bit)
				end

				break
			end

			StatsOffset += 3

			if K >= SpectralEnd then
				error("invalid arithmetic progressive AC refinement")
			end
		end
	end
end

const function DecodeArithmeticProgressiveScan(
	ScanComponents: { Component },
	DcStats: { [number]: buffer },
	AcStats: { [number]: buffer },
	FixedStats: buffer,
	ArithmeticDcL: { [number]: number },
	ArithmeticDcU: { [number]: number },
	ArithmeticAcK: { [number]: number },
	RestartInterval: number,
	McuColumns: number,
	McuRows: number,
	SpectralStart: number,
	SpectralEnd: number,
	ApproxHigh: number,
	ApproxLow: number
)
	local RestartCounter = 0
	local ExpectedRestart = 0

	ResetArithmeticStats(ScanComponents, DcStats, AcStats, true, SpectralStart, ApproxHigh)
	ResetFixedArithmeticStats(FixedStats)
	ResetArithmeticCoder()

	if SpectralStart == 0 then
		if ApproxHigh == 0 then
			for Index = 1, #ScanComponents do
				if ScanComponents[Index].Scanned then
					error("duplicate progressive JPEG DC scan")
				end

				ScanComponents[Index].Scanned = true
				ScanComponents[Index].ProgressiveDcApprox = ApproxLow
			end
		end

		if #ScanComponents == 1 then
			const ComponentInfo = ScanComponents[1]

			if ApproxHigh > 0 and not ComponentInfo.Scanned then
				error("progressive JPEG DC refinement before DC scan")
			end

			if ApproxHigh > 0 then
				if ComponentInfo.ProgressiveDcApprox ~= ApproxHigh then
					error("invalid progressive JPEG DC refinement order")
				end

				ComponentInfo.ProgressiveDcApprox = ApproxLow
			end

			for BlockY = 0, ComponentInfo.BlockRows - 1 do
				for BlockX = 0, ComponentInfo.BlockColumns - 1 do
					const Offset = CoefficientOffset(ComponentInfo, BlockX, BlockY, 0)

					if ApproxHigh == 0 then
						buffer.writei32(ComponentInfo.Coefficients, Offset, DecodeArithmeticDcValue(ComponentInfo, DcStats, ArithmeticDcL, ArithmeticDcU, ApproxLow))
					elseif DecodeArithmeticBit(FixedStats, 0) ~= 0 then
						local Value = buffer.readi32(ComponentInfo.Coefficients, Offset)

						if Value < 0 then
							Value -= BitPowers[ApproxLow]
						else
							Value += BitPowers[ApproxLow]
						end

						buffer.writei32(ComponentInfo.Coefficients, Offset, Value)
					end

					if RestartInterval > 0 then
						RestartCounter += 1

						if RestartCounter == RestartInterval and not (BlockY == ComponentInfo.BlockRows - 1 and BlockX == ComponentInfo.BlockColumns - 1) then
							ExpectedRestart = ConsumeArithmeticRestartMarker(ExpectedRestart)
							ResetArithmeticStats(ScanComponents, DcStats, AcStats, true, SpectralStart, ApproxHigh)
							ResetFixedArithmeticStats(FixedStats)
							ResetArithmeticCoder()
							RestartCounter = 0
						end
					end
				end
			end
		else
			for McuY = 0, McuRows - 1 do
				for McuX = 0, McuColumns - 1 do
					for ComponentIndex = 1, #ScanComponents do
						const ComponentInfo = ScanComponents[ComponentIndex]

						if ApproxHigh > 0 and not ComponentInfo.Scanned then
							error("progressive JPEG DC refinement before DC scan")
						end

						if ApproxHigh > 0 then
							if ComponentInfo.ProgressiveDcApprox ~= ApproxHigh then
								error("invalid progressive JPEG DC refinement order")
							end

							ComponentInfo.ProgressiveDcApprox = ApproxLow
						end

						for BlockY = 0, ComponentInfo.V - 1 do
							for BlockX = 0, ComponentInfo.H - 1 do
								const CoefficientX = McuX * ComponentInfo.H + BlockX
								const CoefficientY = McuY * ComponentInfo.V + BlockY
								const Offset = CoefficientOffset(ComponentInfo, CoefficientX, CoefficientY, 0)

								if ApproxHigh == 0 then
									buffer.writei32(ComponentInfo.Coefficients, Offset, DecodeArithmeticDcValue(ComponentInfo, DcStats, ArithmeticDcL, ArithmeticDcU, ApproxLow))
								elseif DecodeArithmeticBit(FixedStats, 0) ~= 0 then
									local Value = buffer.readi32(ComponentInfo.Coefficients, Offset)

									if Value < 0 then
										Value -= BitPowers[ApproxLow]
									else
										Value += BitPowers[ApproxLow]
									end

									buffer.writei32(ComponentInfo.Coefficients, Offset, Value)
								end
							end
						end
					end

					if RestartInterval > 0 then
						RestartCounter += 1

						if RestartCounter == RestartInterval and not (McuY == McuRows - 1 and McuX == McuColumns - 1) then
							ExpectedRestart = ConsumeArithmeticRestartMarker(ExpectedRestart)
							ResetArithmeticStats(ScanComponents, DcStats, AcStats, true, SpectralStart, ApproxHigh)
							ResetFixedArithmeticStats(FixedStats)
							ResetArithmeticCoder()
							RestartCounter = 0
						end
					end
				end
			end
		end
	else
		const ComponentInfo = ScanComponents[1]

		if not ComponentInfo.Scanned then
			error("progressive JPEG AC scan before DC scan")
		end

		if ApproxHigh == 0 then
			for SpectralIndex = SpectralStart, SpectralEnd do
				if ComponentInfo.ProgressiveBandApprox[SpectralIndex] ~= nil then
					error("duplicate progressive JPEG AC band scan")
				end
			end

			for SpectralIndex = SpectralStart, SpectralEnd do
				ComponentInfo.ProgressiveBandApprox[SpectralIndex] = ApproxLow
			end
		else
			for SpectralIndex = SpectralStart, SpectralEnd do
				if ComponentInfo.ProgressiveBandApprox[SpectralIndex] ~= ApproxHigh then
					error("progressive JPEG AC refinement before AC scan")
				end
			end

			for SpectralIndex = SpectralStart, SpectralEnd do
				ComponentInfo.ProgressiveBandApprox[SpectralIndex] = ApproxLow
			end
		end

		for BlockY = 0, ComponentInfo.BlockRows - 1 do
			for BlockX = 0, ComponentInfo.BlockColumns - 1 do
				if ApproxHigh == 0 then
					DecodeArithmeticProgressiveAcFirstBlock(ComponentInfo, BlockX, BlockY, AcStats, FixedStats, ArithmeticAcK, SpectralStart, SpectralEnd, ApproxLow)
				elseif ApproxHigh == ApproxLow + 1 then
					RefineArithmeticProgressiveAcBlock(ComponentInfo, BlockX, BlockY, AcStats, FixedStats, SpectralStart, SpectralEnd, ApproxLow)
				else
					error("invalid progressive JPEG AC approximation")
				end

				if RestartInterval > 0 then
					RestartCounter += 1

					if RestartCounter == RestartInterval and not (BlockY == ComponentInfo.BlockRows - 1 and BlockX == ComponentInfo.BlockColumns - 1) then
						ExpectedRestart = ConsumeArithmeticRestartMarker(ExpectedRestart)
						ResetArithmeticStats(ScanComponents, DcStats, AcStats, true, SpectralStart, ApproxHigh)
						ResetFixedArithmeticStats(FixedStats)
						ResetArithmeticCoder()
						RestartCounter = 0
					end
				end
			end
		end
	end

	EntropyBits = 0
	EntropyBitCount = 0
end

const function RenderProgressiveComponents(
	Components: { Component },
	QuantizationTables: { [number]: buffer },
	Coefficients: { [number]: number },
	Workspace: { [number]: number },
	SamplePrecision: number
)
	for ComponentIndex = 1, #Components do
		const ComponentInfo = Components[ComponentIndex]
		const Quantization = QuantizationTables[ComponentInfo.QuantId]

		if Quantization == nil then
			error(`missing quantization table {ComponentInfo.QuantId}`)
		end

		for BlockY = 0, ComponentInfo.BlockRows - 1 do
			for BlockX = 0, ComponentInfo.BlockColumns - 1 do
				local HasAc = false
				const CoefficientBase = (BlockY * ComponentInfo.BlockColumns + BlockX) * 64 * 4

				for NaturalIndex = 0, 63 do
					const Value = buffer.readi32(ComponentInfo.Coefficients, CoefficientBase + NaturalIndex * 4) * buffer.readu32(Quantization, NaturalIndex * 4)
					Coefficients[NaturalIndex + 1] = Value

					if NaturalIndex > 0 and Value ~= 0 then
						HasAc = true
					end
				end

				if HasAc then
					InverseDct(
						Coefficients,
						Workspace,
						ComponentInfo.Samples,
						BlockY * 8 * ComponentInfo.PlaneWidth + BlockX * 8,
						ComponentInfo.PlaneWidth,
						SamplePrecision
					)
				else
					FillDcBlock(
						Coefficients[1],
						ComponentInfo.Samples,
						BlockY * 8 * ComponentInfo.PlaneWidth + BlockX * 8,
						ComponentInfo.PlaneWidth,
						SamplePrecision
					)
				end

				for NaturalIndex = 1, 64 do
					Coefficients[NaturalIndex] = 0
				end
			end
		end
	end
end

const function ParseAdobeTransform(Data: buffer, Cursor: number, SegmentEnd: number): number
	if SegmentEnd - Cursor < 12 then
		return -1
	end

	if buffer.readu8(Data, Cursor) ~= 0x41
		or buffer.readu8(Data, Cursor + 1) ~= 0x64
		or buffer.readu8(Data, Cursor + 2) ~= 0x6f
		or buffer.readu8(Data, Cursor + 3) ~= 0x62
		or buffer.readu8(Data, Cursor + 4) ~= 0x65
	then
		return -1
	end

	if SegmentEnd - Cursor ~= 12 then
		error("invalid Adobe color transform")
	end

	const Transform = buffer.readu8(Data, Cursor + 11)

	if Transform > 2 then
		error("invalid Adobe color transform")
	end

	return Transform
end

const function ParseApp0Segment(Data: buffer, Cursor: number, SegmentEnd: number): number
	if SegmentEnd - Cursor < 5 then
		return 0
	end

	const Identifier0 = buffer.readu8(Data, Cursor)
	const Identifier1 = buffer.readu8(Data, Cursor + 1)
	const Identifier2 = buffer.readu8(Data, Cursor + 2)
	const Identifier3 = buffer.readu8(Data, Cursor + 3)
	const Identifier4 = buffer.readu8(Data, Cursor + 4)

	if Identifier0 ~= 0x4a or Identifier1 ~= 0x46 or Identifier4 ~= 0 then
		return 0
	end

	if Identifier2 == 0x49 and Identifier3 == 0x46 then
		if SegmentEnd - Cursor < 14 then
			error("invalid JFIF segment")
		end

		const VersionMajor = buffer.readu8(Data, Cursor + 5)
		const Units = buffer.readu8(Data, Cursor + 7)
		const XDensity = ReadU16BE(Data, Cursor + 8)
		const YDensity = ReadU16BE(Data, Cursor + 10)
		const ThumbnailWidth = buffer.readu8(Data, Cursor + 12)
		const ThumbnailHeight = buffer.readu8(Data, Cursor + 13)
		const ThumbnailBytes = ThumbnailWidth * ThumbnailHeight * 3

		if VersionMajor ~= 1 or Units > 2 or XDensity == 0 or YDensity == 0 or Cursor + 14 + ThumbnailBytes ~= SegmentEnd then
			error("invalid JFIF segment")
		end

		return 1
	elseif Identifier2 == 0x58 and Identifier3 == 0x58 then
		if SegmentEnd - Cursor < 6 then
			error("invalid JFXX segment")
		end

		const ExtensionCode = buffer.readu8(Data, Cursor + 5)

		if ExtensionCode == 0x10 then
			if SegmentEnd - Cursor < 10
				or buffer.readu8(Data, Cursor + 6) ~= 0xff
				or buffer.readu8(Data, Cursor + 7) ~= 0xd8
				or buffer.readu8(Data, SegmentEnd - 2) ~= 0xff
				or buffer.readu8(Data, SegmentEnd - 1) ~= 0xd9
			then
				error("invalid JFXX segment")
			end
		elseif ExtensionCode == 0x11 then
			if SegmentEnd - Cursor < 776 then
				error("invalid JFXX segment")
			end

			const ThumbnailWidth = buffer.readu8(Data, Cursor + 6)
			const ThumbnailHeight = buffer.readu8(Data, Cursor + 7)

			if Cursor + 776 + ThumbnailWidth * ThumbnailHeight ~= SegmentEnd then
				error("invalid JFXX segment")
			end
		elseif ExtensionCode == 0x13 then
			if SegmentEnd - Cursor < 8 then
				error("invalid JFXX segment")
			end

			const ThumbnailWidth = buffer.readu8(Data, Cursor + 6)
			const ThumbnailHeight = buffer.readu8(Data, Cursor + 7)

			if Cursor + 8 + ThumbnailWidth * ThumbnailHeight * 3 ~= SegmentEnd then
				error("invalid JFXX segment")
			end
		else
			error("invalid JFXX segment")
		end

		return 2
	end

	return 0
end

const function ParseIccProfileSegment(Data: buffer, Cursor: number, SegmentEnd: number): (number, number)
	if SegmentEnd - Cursor < 14 then
		return 0, 0
	end

	if buffer.readu8(Data, Cursor) ~= 0x49
		or buffer.readu8(Data, Cursor + 1) ~= 0x43
		or buffer.readu8(Data, Cursor + 2) ~= 0x43
		or buffer.readu8(Data, Cursor + 3) ~= 0x5f
		or buffer.readu8(Data, Cursor + 4) ~= 0x50
		or buffer.readu8(Data, Cursor + 5) ~= 0x52
		or buffer.readu8(Data, Cursor + 6) ~= 0x4f
		or buffer.readu8(Data, Cursor + 7) ~= 0x46
		or buffer.readu8(Data, Cursor + 8) ~= 0x49
		or buffer.readu8(Data, Cursor + 9) ~= 0x4c
		or buffer.readu8(Data, Cursor + 10) ~= 0x45
		or buffer.readu8(Data, Cursor + 11) ~= 0
	then
		return 0, 0
	end

	const Sequence = buffer.readu8(Data, Cursor + 12)
	const Count = buffer.readu8(Data, Cursor + 13)

	if Sequence < 1 or Count < 1 or Sequence > Count or SegmentEnd - Cursor == 14 then
		error("invalid ICC profile segment")
	end

	return Sequence, Count
end

const function ReadTiffU16(Data: buffer, Offset: number, BigEndian: boolean): number
	return BigEndian and ReadU16BE(Data, Offset) or buffer.readu16(Data, Offset)
end

const function ReadTiffU32(Data: buffer, Offset: number, BigEndian: boolean): number
	return BigEndian and bit32.byteswap(buffer.readu32(Data, Offset)) or buffer.readu32(Data, Offset)
end

const function ParseExifOrientation(Data: buffer, Cursor: number, SegmentEnd: number): number
	if SegmentEnd - Cursor < 6 then
		return 0
	end

	if buffer.readu8(Data, Cursor) ~= 0x45
		or buffer.readu8(Data, Cursor + 1) ~= 0x78
		or buffer.readu8(Data, Cursor + 2) ~= 0x69
		or buffer.readu8(Data, Cursor + 3) ~= 0x66
		or buffer.readu8(Data, Cursor + 4) ~= 0
		or buffer.readu8(Data, Cursor + 5) ~= 0
	then
		return 0
	end

	if SegmentEnd - Cursor < 14 then
		error("invalid Exif segment")
	end

	const TiffStart = Cursor + 6
	const Byte0 = buffer.readu8(Data, TiffStart)
	const Byte1 = buffer.readu8(Data, TiffStart + 1)
	local BigEndian = false

	if Byte0 == 0x4d and Byte1 == 0x4d then
		BigEndian = true
	elseif Byte0 ~= 0x49 or Byte1 ~= 0x49 then
		error("invalid Exif segment")
	end

	if TiffStart + 8 > SegmentEnd or ReadTiffU16(Data, TiffStart + 2, BigEndian) ~= 42 then
		error("invalid Exif segment")
	end

	const IfdOffset = ReadTiffU32(Data, TiffStart + 4, BigEndian)
	const IfdStart = TiffStart + IfdOffset

	if IfdOffset < 8 or IfdStart + 2 > SegmentEnd then
		error("invalid Exif segment")
	end

	const EntryCount = ReadTiffU16(Data, IfdStart, BigEndian)
	local EntryOffset = IfdStart + 2

	for _ = 1, EntryCount do
		if EntryOffset + 12 > SegmentEnd then
			error("invalid Exif segment")
		end

		const Tag = ReadTiffU16(Data, EntryOffset, BigEndian)

		if Tag == 0x0112 then
			const ValueType = ReadTiffU16(Data, EntryOffset + 2, BigEndian)
			const ValueCount = ReadTiffU32(Data, EntryOffset + 4, BigEndian)

			if ValueType == 3 and ValueCount == 1 then
				local Orientation = 1

				if BigEndian then
					Orientation = ReadTiffU16(Data, EntryOffset + 8, true)
				else
					Orientation = ReadTiffU16(Data, EntryOffset + 8, false)
				end

				if Orientation >= 1 and Orientation <= 8 then
					return Orientation
				end
			end

			error("invalid Exif orientation")
		end

		EntryOffset += 12
	end

	return 0
end

const function WriteOrientedPixel(
	Output: buffer,
	Width: number,
	Height: number,
	OutputWidth: number,
	SourceX: number,
	SourceY: number,
	Orientation: number,
	Value: number
)
	local X = SourceX
	local Y = SourceY

	if Orientation == 2 then
		X = Width - 1 - SourceX
	elseif Orientation == 3 then
		X = Width - 1 - SourceX
		Y = Height - 1 - SourceY
	elseif Orientation == 4 then
		Y = Height - 1 - SourceY
	elseif Orientation == 5 then
		X = SourceY
		Y = SourceX
	elseif Orientation == 6 then
		X = Height - 1 - SourceY
		Y = SourceX
	elseif Orientation == 7 then
		X = Height - 1 - SourceY
		Y = Width - 1 - SourceX
	elseif Orientation == 8 then
		X = SourceY
		Y = Width - 1 - SourceX
	end

	buffer.writeu32(Output, (Y * OutputWidth + X) * 4, Value)
end

const function DecodeJpeg(JpegData: buffer): DecodedJpeg
	const Length = buffer.len(JpegData)

	if Length < 4 or buffer.readu8(JpegData, 0) ~= 0xff or buffer.readu8(JpegData, 1) ~= 0xd8 then
		error("missing SOI marker")
	end

	local Cursor = 2
	local SamplePrecision = 8
	local Width = 0
	local Height = 0
	local MaxH = 1
	local MaxV = 1
	local RestartInterval = 0
	local Components: { Component } = {}
	local ComponentsById: { [number]: Component } = {}
	const QuantizationTables: { [number]: buffer } = {}
	const DcTables: { [number]: HuffmanTable } = {}
	const AcTables: { [number]: HuffmanTable } = {}
	const ArithmeticDcL: { [number]: number } = {}
	const ArithmeticDcU: { [number]: number } = {}
	const ArithmeticAcK: { [number]: number } = {}
	const ArithmeticDcStats: { [number]: buffer } = {}
	const ArithmeticAcStats: { [number]: buffer } = {}
	const FixedArithmeticStats = buffer.create(4)
	local SawScan = false
	local SawEndImage = false
	local AllowEntropyPadding = false
	local IsBaseline = false
	local IsArithmetic = false
	local IsLossless = false
	local IsProgressive = false
	local AdobeTransform = -1
	local Orientation = 1
	local SawJfif = false
	local SawAdobe = false
	local IccProfileChunkCount = 0
	const IccProfileSeen: { [number]: boolean } = {}
	const Coefficients: { [number]: number } = table.create(64, 0)
	const Workspace: { [number]: number } = table.create(64, 0)
	const TouchedCoefficients: { [number]: number } = table.create(64, 0)

	for TableIndex = 0, 3 do
		ArithmeticDcL[TableIndex] = 0
		ArithmeticDcU[TableIndex] = 1
		ArithmeticAcK[TableIndex] = 5
		ArithmeticDcStats[TableIndex] = buffer.create(64)
		ArithmeticAcStats[TableIndex] = buffer.create(256)
	end

	ResetFixedArithmeticStats(FixedArithmeticStats)

	while Cursor < Length do
		local Marker: number
		Marker, Cursor = ReadMarker(JpegData, Cursor, AllowEntropyPadding)
		AllowEntropyPadding = false

		if Marker == 0xda then
			if Cursor + 2 > Length then
				error("invalid segment length")
			end

			const SegmentLength = ReadU16BE(JpegData, Cursor)
			Cursor += 2
			const SegmentEnd = Cursor + SegmentLength - 2

			if SegmentLength < 2 or SegmentEnd > Length then
				error("invalid segment length")
			end

			if Width == 0 or Height == 0 then
				error("missing frame header")
			end

			local ScanComponents: { Component }
			local SpectralStart: number
			local SpectralEnd: number
			local ApproxHigh: number
			local ApproxLow: number
			ScanComponents, SpectralStart, SpectralEnd, ApproxHigh, ApproxLow =
				ParseScan(JpegData, Cursor, SegmentEnd, Components, ComponentsById, IsProgressive, IsBaseline, IsLossless)
			local McuWidth = MaxH * 8
			local McuHeight = MaxV * 8

			if IsLossless then
				McuWidth = MaxH
				McuHeight = MaxV
			end

			const McuColumns = (Width + McuWidth - 1) // McuWidth
			const McuRows = (Height + McuHeight - 1) // McuHeight

			EntropyData = JpegData
			EntropyLength = Length
			EntropyPos = SegmentEnd
			EntropyBits = 0
			EntropyBitCount = 0

			if IsLossless then
				DecodeLosslessScan(
					ScanComponents,
					DcTables,
					RestartInterval,
					McuColumns,
					McuRows,
					SpectralStart,
					ApproxLow,
					SamplePrecision
				)
				Cursor = EntropyPos
			elseif IsArithmetic then
				if IsProgressive then
					DecodeArithmeticProgressiveScan(
						ScanComponents,
						ArithmeticDcStats,
						ArithmeticAcStats,
						FixedArithmeticStats,
						ArithmeticDcL,
						ArithmeticDcU,
						ArithmeticAcK,
						RestartInterval,
						McuColumns,
						McuRows,
						SpectralStart,
						SpectralEnd,
						ApproxHigh,
						ApproxLow
					)
				else
					DecodeArithmeticSequentialScan(
						ScanComponents,
						QuantizationTables,
						ArithmeticDcStats,
						ArithmeticAcStats,
						FixedArithmeticStats,
						ArithmeticDcL,
						ArithmeticDcU,
						ArithmeticAcK,
						RestartInterval,
						McuColumns,
						McuRows,
						Coefficients,
						Workspace,
						TouchedCoefficients,
						SamplePrecision
					)
				end

				if ArithmeticUnreadMarker >= 0 then
					Cursor = ArithmeticMarkerOffset
				else
					Cursor = EntropyPos
				end
			elseif IsProgressive then
				DecodeProgressiveScan(
					ScanComponents,
					DcTables,
					AcTables,
					RestartInterval,
					McuColumns,
					McuRows,
					SpectralStart,
					SpectralEnd,
					ApproxHigh,
					ApproxLow,
					SamplePrecision
				)
				Cursor = EntropyPos
			else
				DecodeSequentialScan(
					ScanComponents,
					QuantizationTables,
					DcTables,
					AcTables,
					RestartInterval,
					McuColumns,
					McuRows,
					Coefficients,
					Workspace,
					TouchedCoefficients,
					SamplePrecision
				)
				Cursor = EntropyPos
			end

			AllowEntropyPadding = true
			SawScan = true
			continue
		end

		if Marker == 0xd9 then
			if not SawScan then
				error("missing scan data")
			end

			SawEndImage = true
			break
		end

		if Marker == 0xd8 then
			error("unexpected SOI marker")
		end

		if Marker == 0x01 then
			continue
		end

		if Marker >= 0xd0 and Marker <= 0xd7 then
			error("unexpected restart marker")
		end

		if Marker < 0xc0 then
			error("unsupported JPEG marker")
		end

		if Cursor + 2 > Length then
			error("invalid segment length")
		end

		const SegmentLength = ReadU16BE(JpegData, Cursor)
		Cursor += 2
		const SegmentEnd = Cursor + SegmentLength - 2

		if SegmentLength < 2 or SegmentEnd > Length then
			error("invalid segment length")
		end

		if Marker == 0xdb then
			ParseQuantizationTables(JpegData, Cursor, SegmentEnd, QuantizationTables)
		elseif Marker == 0xc4 then
			ParseHuffmanTables(JpegData, Cursor, SegmentEnd, DcTables, AcTables)
		elseif Marker == 0xc0 or Marker == 0xc1 or Marker == 0xc2 or Marker == 0xc3 or Marker == 0xc9 or Marker == 0xca then
			if Width ~= 0 or SawScan then
				error("invalid JPEG frame order")
			end

			IsBaseline = Marker == 0xc0
			IsArithmetic = Marker == 0xc9 or Marker == 0xca
			IsLossless = Marker == 0xc3
			IsProgressive = Marker == 0xc2 or Marker == 0xca
			SamplePrecision, Width, Height, Components, ComponentsById, MaxH, MaxV = ParseFrame(JpegData, Cursor, SegmentEnd, Marker)

			if IsProgressive then
				AllocateProgressiveCoefficients(Components)
			end
		elseif Marker == 0xdd then
			if SegmentLength ~= 4 then
				error("invalid restart interval segment")
			end

			RestartInterval = ReadU16BE(JpegData, Cursor)
		elseif Marker == 0xcc then
			ParseArithmeticConditioning(JpegData, Cursor, SegmentEnd, ArithmeticDcL, ArithmeticDcU, ArithmeticAcK)
		elseif Marker == MarkerAPP0 then
			const App0Kind = ParseApp0Segment(JpegData, Cursor, SegmentEnd)

			if App0Kind == 1 then
				if SawJfif then
					error("duplicate JFIF segment")
				end

				SawJfif = true
			elseif App0Kind == 2 and not SawJfif then
				error("JFXX segment without JFIF segment")
			end
		elseif Marker == MarkerAPP1 then
			const ParsedOrientation = ParseExifOrientation(JpegData, Cursor, SegmentEnd)

			if ParsedOrientation > 0 then
				Orientation = ParsedOrientation
			end
		elseif Marker == MarkerAPP2 then
			local IccSequence: number
			local IccCount: number
			IccSequence, IccCount = ParseIccProfileSegment(JpegData, Cursor, SegmentEnd)

			if IccSequence > 0 then
				if IccProfileChunkCount == 0 then
					IccProfileChunkCount = IccCount
				elseif IccProfileChunkCount ~= IccCount then
					error("inconsistent ICC profile segment count")
				end

				if IccProfileSeen[IccSequence] then
					error("duplicate ICC profile segment")
				end

				IccProfileSeen[IccSequence] = true
			end
		elseif Marker == MarkerAPP14 then
			const ParsedAdobeTransform = ParseAdobeTransform(JpegData, Cursor, SegmentEnd)

			if ParsedAdobeTransform >= 0 then
				if SawAdobe then
					error("duplicate Adobe segment")
				end

				AdobeTransform = ParsedAdobeTransform
				SawAdobe = true
			end
		elseif Marker == 0xc7 or Marker == 0xcb or Marker == 0xcf then
			error("arithmetic-coded or differential lossless JPEG images are not supported")
		elseif Marker == 0xc5 or Marker == 0xc6 or Marker == 0xcd or Marker == 0xce then
			error("differential JPEG images are not supported")
		elseif Marker == 0xc8 or Marker == 0xde or Marker == 0xdf then
			error("hierarchical JPEG images are not supported")
		elseif Marker == 0xdc then
			error("DNL JPEG images are not supported")
		elseif Marker >= 0xf0 and Marker <= 0xfd then
			error("unsupported JPEG extension marker")
		elseif Marker >= 0xc3 and Marker <= 0xcf and Marker ~= 0xc4 and Marker ~= 0xc8 and Marker ~= 0xcc then
			error("only Huffman DCT JPEG images are supported")
		end

		Cursor = SegmentEnd
	end

	if not SawScan then
		error("missing SOS marker")
	end

	if not SawEndImage then
		error("missing EOI marker")
	end

	if Width == 0 or Height == 0 then
		error("missing frame header")
	end

	for Index = 1, IccProfileChunkCount do
		if not IccProfileSeen[Index] then
			error("missing ICC profile segment")
		end
	end

	for Index = 1, #Components do
		if not Components[Index].Scanned then
			error("missing JPEG component scan")
		end
	end

	if IsLossless then
		RenderLosslessComponents(Components, SamplePrecision)
	elseif IsProgressive then
		RenderProgressiveComponents(Components, QuantizationTables, Coefficients, Workspace, SamplePrecision)
	end

	local OutputWidth = Width
	local OutputHeight = Height

	if Orientation >= 5 and Orientation <= 8 then
		OutputWidth = Height
		OutputHeight = Width
	end

	if OutputWidth > MaxOutputBytes // 4 // OutputHeight then
		error("JPEG output too large")
	end

	const Output = buffer.create(OutputWidth * OutputHeight * 4)
	const ComponentCount = #Components
	const YComponent = Components[1]
	const CbComponent = Components[2]
	const CrComponent = Components[3]
	const KComponent = Components[4]
	local UseThreeComponentColorTransform = ComponentCount == 3
	const YXMap = buffer.create(Width * 4)
	const YYMap = buffer.create(Height * 4)
	const CbXMap = buffer.create(Width * 4)
	const CbYMap = buffer.create(Height * 4)
	const CrXMap = buffer.create(Width * 4)
	const CrYMap = buffer.create(Height * 4)
	const KXMap = buffer.create(Width * 4)
	const KYMap = buffer.create(Height * 4)

	if (AdobeTransform == 1 and ComponentCount ~= 3) or (AdobeTransform == 2 and ComponentCount ~= 4) then
		error("invalid Adobe color transform")
	end

	if ComponentCount == 3 and (AdobeTransform == 0 or (AdobeTransform < 0 and YComponent.Id == 0x52 and CbComponent.Id == 0x47 and CrComponent.Id == 0x42)) then
		UseThreeComponentColorTransform = false
	end

	for X = 0, Width - 1 do
		const MapOffset = X * 4
		buffer.writeu32(YXMap, MapOffset, (X * YComponent.H) // MaxH)

		if ComponentCount >= 2 then
			buffer.writeu32(CbXMap, MapOffset, (X * CbComponent.H) // MaxH)
		end

		if ComponentCount >= 3 then
			buffer.writeu32(CrXMap, MapOffset, (X * CrComponent.H) // MaxH)
		end

		if ComponentCount == 4 then
			buffer.writeu32(KXMap, MapOffset, (X * KComponent.H) // MaxH)
		end
	end

	for Y = 0, Height - 1 do
		const MapOffset = Y * 4
		buffer.writeu32(YYMap, MapOffset, (Y * YComponent.V) // MaxV)

		if ComponentCount >= 2 then
			buffer.writeu32(CbYMap, MapOffset, (Y * CbComponent.V) // MaxV)
		end

		if ComponentCount >= 3 then
			buffer.writeu32(CrYMap, MapOffset, (Y * CrComponent.V) // MaxV)
		end

		if ComponentCount == 4 then
			buffer.writeu32(KYMap, MapOffset, (Y * KComponent.V) // MaxV)
		end
	end

	if ComponentCount == 1 then
		for Y = 0, Height - 1 do
			const OutputStart = Y * Width * 4
			const OutputEnd = OutputStart + (Width - 1) * 4
			const YRow = buffer.readu32(YYMap, Y * 4) * YComponent.PlaneWidth
			local X = 0

			for OutputIndex = OutputStart, OutputEnd, 4 do
				const Gray = buffer.readu8(YComponent.Samples, YRow + buffer.readu32(YXMap, X * 4))
				const Value = 0xff000000 + Gray * 65793

				if Orientation == 1 then
					buffer.writeu32(Output, OutputIndex, Value)
				else
					WriteOrientedPixel(Output, Width, Height, OutputWidth, X, Y, Orientation, Value)
				end

				X += 1
			end
		end
	elseif ComponentCount == 2 then
		for Y = 0, Height - 1 do
			const OutputStart = Y * Width * 4
			const OutputEnd = OutputStart + (Width - 1) * 4
			const MapY = Y * 4
			const YRow = buffer.readu32(YYMap, MapY) * YComponent.PlaneWidth
			const AlphaRow = buffer.readu32(CbYMap, MapY) * CbComponent.PlaneWidth
			local X = 0

			for OutputIndex = OutputStart, OutputEnd, 4 do
				const MapX = X * 4
				const Gray = buffer.readu8(YComponent.Samples, YRow + buffer.readu32(YXMap, MapX))
				const Alpha = buffer.readu8(CbComponent.Samples, AlphaRow + buffer.readu32(CbXMap, MapX))
				const Value = Alpha * 16777216 + Gray * 65793

				if Orientation == 1 then
					buffer.writeu32(Output, OutputIndex, Value)
				else
					WriteOrientedPixel(Output, Width, Height, OutputWidth, X, Y, Orientation, Value)
				end

				X += 1
			end
		end
	elseif ComponentCount == 3 then
		if Orientation == 1 then
			for Y = 0, Height - 1 do
				const OutputStart = Y * Width * 4
				const OutputEnd = OutputStart + (Width - 1) * 4
				const MapY = Y * 4
				const YRow = buffer.readu32(YYMap, MapY) * YComponent.PlaneWidth
				const CbRow = buffer.readu32(CbYMap, MapY) * CbComponent.PlaneWidth
				const CrRow = buffer.readu32(CrYMap, MapY) * CrComponent.PlaneWidth
				local X = 0

				for OutputIndex = OutputStart, OutputEnd, 4 do
					const MapX = X * 4
					const YValue = buffer.readu8(YComponent.Samples, YRow + buffer.readu32(YXMap, MapX))
					local R = YValue
					local G = buffer.readu8(CbComponent.Samples, CbRow + buffer.readu32(CbXMap, MapX))
					local B = buffer.readu8(CrComponent.Samples, CrRow + buffer.readu32(CrXMap, MapX))

					if UseThreeComponentColorTransform then
						const Cb = G - 128
						const Cr = B - 128
						R = math.clamp(math.round(YValue + 1.402 * Cr), 0, 255)
						G = math.clamp(math.round(YValue - 0.344136 * Cb - 0.714136 * Cr), 0, 255)
						B = math.clamp(math.round(YValue + 1.772 * Cb), 0, 255)
					end

					buffer.writeu32(Output, OutputIndex, 0xff000000 + R + G * 256 + B * 65536)
					X += 1
				end
			end
		else
			for Y = 0, Height - 1 do
				const OutputStart = Y * Width * 4
				const OutputEnd = OutputStart + (Width - 1) * 4
				const MapY = Y * 4
				const YRow = buffer.readu32(YYMap, MapY) * YComponent.PlaneWidth
				const CbRow = buffer.readu32(CbYMap, MapY) * CbComponent.PlaneWidth
				const CrRow = buffer.readu32(CrYMap, MapY) * CrComponent.PlaneWidth
				local X = 0

				for OutputIndex = OutputStart, OutputEnd, 4 do
					const MapX = X * 4
					const YValue = buffer.readu8(YComponent.Samples, YRow + buffer.readu32(YXMap, MapX))
					local R = YValue
					local G = buffer.readu8(CbComponent.Samples, CbRow + buffer.readu32(CbXMap, MapX))
					local B = buffer.readu8(CrComponent.Samples, CrRow + buffer.readu32(CrXMap, MapX))

					if UseThreeComponentColorTransform then
						const Cb = G - 128
						const Cr = B - 128
						R = math.clamp(math.round(YValue + 1.402 * Cr), 0, 255)
						G = math.clamp(math.round(YValue - 0.344136 * Cb - 0.714136 * Cr), 0, 255)
						B = math.clamp(math.round(YValue + 1.772 * Cb), 0, 255)
					end

					WriteOrientedPixel(Output, Width, Height, OutputWidth, X, Y, Orientation, 0xff000000 + R + G * 256 + B * 65536)
					X += 1
				end
			end
		end
	else
		for Y = 0, Height - 1 do
			const OutputStart = Y * Width * 4
			const OutputEnd = OutputStart + (Width - 1) * 4
			const MapY = Y * 4
			const YRow = buffer.readu32(YYMap, MapY) * YComponent.PlaneWidth
			const CbRow = buffer.readu32(CbYMap, MapY) * CbComponent.PlaneWidth
			const CrRow = buffer.readu32(CrYMap, MapY) * CrComponent.PlaneWidth
			const KRow = buffer.readu32(KYMap, MapY) * KComponent.PlaneWidth
			local X = 0

			for OutputIndex = OutputStart, OutputEnd, 4 do
				const MapX = X * 4
				local C = buffer.readu8(YComponent.Samples, YRow + buffer.readu32(YXMap, MapX))
				local M = buffer.readu8(CbComponent.Samples, CbRow + buffer.readu32(CbXMap, MapX))
				local Yellow = buffer.readu8(CrComponent.Samples, CrRow + buffer.readu32(CrXMap, MapX))
				local K = buffer.readu8(KComponent.Samples, KRow + buffer.readu32(KXMap, MapX))

				if AdobeTransform == 2 then
					const Luma = C
					const Cb = M - 128
					const Cr = Yellow - 128
					C = math.clamp(math.round(Luma + 1.402 * Cr), 0, 255)
					M = math.clamp(math.round(Luma - 0.344136 * Cb - 0.714136 * Cr), 0, 255)
					Yellow = math.clamp(math.round(Luma + 1.772 * Cb), 0, 255)
				elseif AdobeTransform < 0 then
					C = 255 - C
					M = 255 - M
					Yellow = 255 - Yellow
					K = 255 - K
				end

				const R = (C * K + 127) // 255
				const G = (M * K + 127) // 255
				const B = (Yellow * K + 127) // 255
				const Value = 0xff000000 + R + G * 256 + B * 65536

				if Orientation == 1 then
					buffer.writeu32(Output, OutputIndex, Value)
				else
					WriteOrientedPixel(Output, Width, Height, OutputWidth, X, Y, Orientation, Value)
				end

				X += 1
			end
		end
	end

	EntropyData = EmptyEntropyData
	EntropyLength = 0
	EntropyPos = 0
	EntropyBits = 0
	EntropyBitCount = 0

	return {
		Size = Vector2.new(OutputWidth, OutputHeight),
		RGBA8 = Output,
	}
end

return DecodeJpeg
