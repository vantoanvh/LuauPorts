--!optimize 2
--!native
--!strict

--[[
	GIFDecoder.luau

	Public API:
	- Module returns DecodeGif(GifData: buffer).
	- DecodeGif returns a mutable animation state:
		{
			Animated = boolean,
			Size = Vector2.new(Width, Height),
			RGBA8 = CurrentCanvas,
			Frame = CurrentCanvas,
			AdvanceFrame = AdvanceFrame,
			Reset = Reset,
			Finished = Finished,
			Delay = DelaySeconds,
		}
	- RGBA8 and Frame reference the packed row-major RGBA8 canvas buffer.
	- AdvanceFrame supports both dot and colon calls.
	- Public functions support both dot and colon calls.
	- AdvanceFrame composites the next frame into Frame and updates Delay/Finished.
	- Reset restores the animation to the first rendered frame.
	- Delay is the current frame playback delay in seconds.

	Supported GIF image coding:
	- GIF87a and GIF89a headers.
	- Global and local color tables.
	- Table-based image descriptors.
	- LZW image data with clear/end codes and 12-bit dictionaries.
	- Interlaced and non-interlaced image data.

	Supported animation/display behavior:
	- Graphic Control Extension delay and transparency.
	- Disposal methods 0, 1, 2, and 3.
	- Logical-screen background color.
	- Application extensions, including NETSCAPE2.0/ANIMEXTS1.0 loop metadata parsing.
	- Comment extensions and unknown extension blocks as skipped metadata.
	- Plain Text Extensions are validated and skipped because GIF files do not embed font glyphs.

	Intentionally unsupported or not exposed:
	- Plain Text Extension glyph rendering; GIF stores text bytes and cell metrics but no font.
	- Automatic timer connections; callers advance with their own RunService clock and Delay.
	- Extension payload text/application metadata beyond validation and loop count extraction.
]]

type ColorTable = {
	Colors: buffer,
	Count: number,
}

type GifFrame = {
	Left: number,
	Top: number,
	Width: number,
	Height: number,
	DrawWidth: number,
	DrawHeight: number,
	Interlaced: boolean,
	ColorTable: ColorTable,
	LzwMinimumCodeSize: number,
	ImageData: buffer,
	Indices: buffer?,
	Rendered: buffer?,
	Disposal: number,
	Delay: number,
	HasTransparency: boolean,
	TransparentIndex: number,
}

type DecodedGif = {
	Animated: boolean,
	Size: Vector2,
	RGBA8: buffer,
	Frame: buffer,
	AdvanceFrame: () -> (),
	Reset: () -> (),
	Finished: boolean,
	Delay: number,
}

type GifState = {
	Width: number,
	Height: number,
	CanvasBackgroundColor: number,
	LoopCount: number,
	CompletedLoops: number,
	Frames: { GifFrame },
	Canvas: buffer,
	CanvasBytes: number,
	CacheRenderedFrames: boolean,
	LzwPrefixes: buffer,
	LzwSuffixes: buffer,
	LzwStack: buffer,
	CurrentFrameIndex: number,
	RestoreBuffer: buffer?,
	RestoreLeft: number,
	RestoreTop: number,
	RestoreWidth: number,
	RestoreHeight: number,
	Result: DecodedGif?,
}

type PendingGraphicControl = {
	Disposal: number,
	Delay: number,
	HasTransparency: boolean,
	TransparentIndex: number,
	Active: boolean,
}

const MaxOutputBytes = 2147483647
const DefaultMinimumFrameDelay = 0.02

const function ParseColorTable(Data: buffer, Cursor: number, Length: number, SizeCode: number): (ColorTable, number)
	const Count = bit32.lshift(1, SizeCode + 1)
	const ByteCount = Count * 3
	const End = Cursor + ByteCount

	if End > Length then
		error("truncated GIF color table")
	end

	const Colors = buffer.create(Count * 4)
	local Index = 0

	for Offset = Cursor, End - 1, 3 do
		buffer.writeu32(Colors, Index,
			0xff000000
			+ buffer.readu16(Data, Offset)
			+ buffer.readu8(Data, Offset + 2) * 65536
		)

		Index += 4
	end

	return {
		Colors = Colors,
		Count = Count,
	}, End
end

const function SkipSubBlocks(Data: buffer, Cursor: number, Length: number): number
	while true do
		if Cursor >= Length then
			error("truncated GIF sub-blocks")
		end

		const BlockSize = buffer.readu8(Data, Cursor)
		Cursor += 1

		if BlockSize == 0 then
			return Cursor
		end

		if Cursor + BlockSize > Length then
			error("truncated GIF sub-block")
		end

		Cursor += BlockSize
	end
end

const function ReadSubBlocks(Data: buffer, Cursor: number, Length: number): (buffer, number)
	local ScanCursor = Cursor
	local TotalLength = 0

	while true do
		if ScanCursor >= Length then
			error("truncated GIF image data")
		end

		const BlockSize = buffer.readu8(Data, ScanCursor)
		ScanCursor += 1

		if BlockSize == 0 then
			break
		end

		if ScanCursor + BlockSize > Length then
			error("truncated GIF image data")
		end

		if TotalLength > MaxOutputBytes - BlockSize then
			error("GIF image data too large")
		end

		TotalLength += BlockSize
		ScanCursor += BlockSize
	end

	const Output = buffer.create(TotalLength)
	local OutputOffset = 0

	while Cursor < ScanCursor do
		const BlockSize = buffer.readu8(Data, Cursor)
		Cursor += 1

		if BlockSize == 0 then
			return Output, Cursor
		end

		buffer.copy(Output, OutputOffset, Data, Cursor, BlockSize)
		OutputOffset += BlockSize
		Cursor += BlockSize
	end

	return Output, ScanCursor
end

const function FillRectangle(Output: buffer, Width: number, Left: number, Top: number, RectWidth: number, RectHeight: number, Color: number)
	if RectWidth <= 0 or RectHeight <= 0 then
		return
	end

	if Color == 0 then
		for Y = 0, RectHeight - 1 do
			buffer.fill(Output, ((Top + Y) * Width + Left) * 4, 0, RectWidth * 4)
		end

		return
	end

	const OutputOffset = (Top * Width + Left) * 4
	const RowBytes = RectWidth * 4

	for Offset = OutputOffset, OutputOffset + RowBytes - 4, 4 do
		buffer.writeu32(Output, Offset, Color)
	end

	if RectHeight == 1 then
		return
	end

	for Y = 1, RectHeight - 1 do
		buffer.copy(Output, ((Top + Y) * Width + Left) * 4, Output, OutputOffset, RowBytes)
	end
end

const function PreFillCanvas(Output: buffer, Color: number)
	if Color == 0 then
		buffer.fill(Output, 0, 0)
		return
	end

	const Length = buffer.len(Output)
	local FilledBytes = 4096

	if FilledBytes > Length then
		FilledBytes = Length
	end

	for Offset = 0, FilledBytes - 4, 4 do
		buffer.writeu32(Output, Offset, Color)
	end

	local Offset = FilledBytes

	while Offset + FilledBytes <= Length do
		buffer.copy(Output, Offset, Output, 0, FilledBytes)
		Offset += FilledBytes
	end

	while Offset < Length do
		buffer.writeu32(Output, Offset, Color)
		Offset += 4
	end
end

const function NormalizeDelay(DelayCentiseconds: number): number
	const Delay = DelayCentiseconds / 100

	if Delay < DefaultMinimumFrameDelay then
		return DefaultMinimumFrameDelay
	end

	return Delay
end

const function SaveRestoreArea(State: GifState, Frame: GifFrame)
	const Left = Frame.Left
	const Top = Frame.Top
	const Width = Frame.DrawWidth
	const Height = Frame.DrawHeight

	const RestoreBuffer = buffer.create(Width * Height * 4)

	for Y = 0, Height - 1 do
		buffer.copy(RestoreBuffer, Y * Width * 4, State.Canvas, ((Top + Y) * State.Width + Left) * 4, Width * 4)
	end

	State.RestoreBuffer = RestoreBuffer
	State.RestoreLeft = Left
	State.RestoreTop = Top
	State.RestoreWidth = Width
	State.RestoreHeight = Height
end

const function RestorePrevious(State: GifState)
	const RestoreBuffer = State.RestoreBuffer

	if RestoreBuffer == nil then
		return
	end

	for Y = 0, State.RestoreHeight - 1 do
		buffer.copy(
			State.Canvas,
			((State.RestoreTop + Y) * State.Width + State.RestoreLeft) * 4,
			RestoreBuffer,
			Y * State.RestoreWidth * 4,
			State.RestoreWidth * 4
		)
	end
end

const function DisposeFrame(State: GifState, Frame: GifFrame)
	if Frame.Disposal == 2 then
		FillRectangle(State.Canvas, State.Width, Frame.Left, Frame.Top, Frame.DrawWidth, Frame.DrawHeight, State.CanvasBackgroundColor)
	elseif Frame.Disposal == 3 then
		RestorePrevious(State)
	end

	State.RestoreBuffer = nil
	State.RestoreLeft = 0
	State.RestoreTop = 0
	State.RestoreWidth = 0
	State.RestoreHeight = 0
end

const function DecodeLzw(Frame: GifFrame, Prefixes: buffer, Suffixes: buffer, Stack: buffer): buffer
	const PixelCount = Frame.Width * Frame.Height
	const Output = buffer.create(PixelCount)
	const MinimumCodeSize = Frame.LzwMinimumCodeSize

	if MinimumCodeSize < 2 or MinimumCodeSize > 8 then
		error("invalid GIF LZW minimum code size")
	end

	const ClearCode = bit32.lshift(1, MinimumCodeSize)
	const EndCode = ClearCode + 1
	local CodeSize = MinimumCodeSize + 1
	local CodeLimit = bit32.lshift(1, CodeSize)
	local NextCode = EndCode + 1
	local PreviousCode = -1
	local PreviousFirstColor = 0
	local Position = 0
	local Bits = 0
	local BitCount = 0
	local OutputIndex = 0
	local SawInitialClear = false
	local SawEndCode = false
	
	const Data = Frame.ImageData
	const DataLength = buffer.len(Data)
	for Code = 0, ClearCode - 1 do
		buffer.writeu8(Suffixes, Code, Code)
	end

	while true do
		while BitCount < CodeSize do
			if Position >= DataLength then
				error("truncated GIF LZW data")
			end

			Bits += bit32.lshift(buffer.readu8(Data, Position), BitCount)
			BitCount += 8
			Position += 1
		end

		const Code = bit32.extract(Bits, 0, CodeSize)
		Bits = bit32.rshift(Bits, CodeSize)
		BitCount -= CodeSize

		if Code == ClearCode then
			CodeSize = MinimumCodeSize + 1
			CodeLimit = bit32.lshift(1, CodeSize)
			NextCode = EndCode + 1
			PreviousCode = -1
			PreviousFirstColor = 0
			SawInitialClear = true
			continue
		end

		if not SawInitialClear then
			error("GIF LZW stream missing initial clear code")
		end

		if Code == EndCode then
			SawEndCode = true
			break
		end

		if Code > NextCode or Code >= 4096 then
			error("invalid GIF LZW code")
		end

		if Code < ClearCode then
			if OutputIndex >= PixelCount then
				error("GIF LZW data exceeds image bounds")
			end

			buffer.writeu8(Output, OutputIndex, Code)
			OutputIndex += 1

			if PreviousCode >= 0 and NextCode < 4096 then
				buffer.writeu16(Prefixes, NextCode * 2, PreviousCode)
				buffer.writeu8(Suffixes, NextCode, Code)
				NextCode += 1

				if NextCode == CodeLimit and CodeSize < 12 then
					CodeSize += 1
					CodeLimit *= 2
				end
			end

			PreviousCode = Code
			PreviousFirstColor = Code
			continue
		end

		local WorkCode = Code
		local StackCount = 0

		if WorkCode == NextCode then
			if PreviousCode < 0 then
				error("invalid GIF LZW code")
			end

			buffer.writeu8(Stack, StackCount, PreviousFirstColor)
			StackCount += 1
			WorkCode = PreviousCode
		end

		while WorkCode >= ClearCode do
			if WorkCode >= NextCode or StackCount >= 4096 then
				error("invalid GIF LZW dictionary")
			end

			buffer.writeu8(Stack, StackCount, buffer.readu8(Suffixes, WorkCode))
			StackCount += 1
			WorkCode = buffer.readu16(Prefixes, WorkCode * 2)
		end

		const FirstColor = WorkCode

		if FirstColor >= ClearCode or StackCount >= 4096 then
			error("invalid GIF LZW dictionary")
		end

		buffer.writeu8(Stack, StackCount, FirstColor)
		StackCount += 1

		while StackCount > 0 do
			StackCount -= 1

			if OutputIndex >= PixelCount then
				error("GIF LZW data exceeds image bounds")
			end

			buffer.writeu8(Output, OutputIndex, buffer.readu8(Stack, StackCount))
			OutputIndex += 1
		end

		if PreviousCode >= 0 and NextCode < 4096 then
			buffer.writeu16(Prefixes, NextCode * 2, PreviousCode)
			buffer.writeu8(Suffixes, NextCode, FirstColor)
			NextCode += 1

			if NextCode == CodeLimit and CodeSize < 12 then
				CodeSize += 1
				CodeLimit *= 2
			end
		end

		PreviousCode = Code
		PreviousFirstColor = FirstColor
	end

	if not SawEndCode then
		error("GIF LZW stream missing end code")
	end

	if OutputIndex < PixelCount then
		error("truncated GIF LZW output")
	end

	return Output
end

const function DrawTransparentRow(State: GifState, Frame: GifFrame, Indices: buffer, SourceOffset: number, Y: number): number
	const Canvas = State.Canvas
	const DrawWidth = Frame.DrawWidth
	const SkipWidth = Frame.Width - DrawWidth
	local OutputOffset = ((Frame.Top + Y) * State.Width + Frame.Left) * 4
	const Colors = Frame.ColorTable.Colors
	const ColorCount = Frame.ColorTable.Count
	const TransparentIndex = Frame.TransparentIndex

	if ColorCount == 256 then
		local Remaining = DrawWidth

		while Remaining >= 4 do
			local ColorIndex = buffer.readu8(Indices, SourceOffset)

			if ColorIndex ~= TransparentIndex then
				buffer.writeu32(Canvas, OutputOffset, buffer.readu32(Colors, ColorIndex * 4))
			end

			ColorIndex = buffer.readu8(Indices, SourceOffset + 1)

			if ColorIndex ~= TransparentIndex then
				buffer.writeu32(Canvas, OutputOffset + 4, buffer.readu32(Colors, ColorIndex * 4))
			end

			ColorIndex = buffer.readu8(Indices, SourceOffset + 2)

			if ColorIndex ~= TransparentIndex then
				buffer.writeu32(Canvas, OutputOffset + 8, buffer.readu32(Colors, ColorIndex * 4))
			end

			ColorIndex = buffer.readu8(Indices, SourceOffset + 3)

			if ColorIndex ~= TransparentIndex then
				buffer.writeu32(Canvas, OutputOffset + 12, buffer.readu32(Colors, ColorIndex * 4))
			end

			SourceOffset += 4
			OutputOffset += 16
			Remaining -= 4
		end

		while Remaining > 0 do
			const ColorIndex = buffer.readu8(Indices, SourceOffset)
			SourceOffset += 1

			if ColorIndex ~= TransparentIndex then
				buffer.writeu32(Canvas, OutputOffset, buffer.readu32(Colors, ColorIndex * 4))
			end

			OutputOffset += 4
			Remaining -= 1
		end

		return SourceOffset + SkipWidth
	end

	for _ = 1, DrawWidth do
		const ColorIndex = buffer.readu8(Indices, SourceOffset)
		SourceOffset += 1

		if ColorIndex ~= TransparentIndex then
			if ColorIndex >= ColorCount then
				error("GIF color index out of range")
			end

			buffer.writeu32(Canvas, OutputOffset, buffer.readu32(Colors, ColorIndex * 4))
		end

		OutputOffset += 4
	end

	return SourceOffset + SkipWidth
end

const function DrawOpaqueRow(State: GifState, Frame: GifFrame, Indices: buffer, SourceOffset: number, Y: number): number
	const Canvas = State.Canvas
	const DrawWidth = Frame.DrawWidth
	const SkipWidth = Frame.Width - DrawWidth
	local OutputOffset = ((Frame.Top + Y) * State.Width + Frame.Left) * 4
	const Colors = Frame.ColorTable.Colors
	const ColorCount = Frame.ColorTable.Count

	if ColorCount == 256 then
		local Remaining = DrawWidth

		while Remaining >= 4 do
			buffer.writeu32(Canvas, OutputOffset, buffer.readu32(Colors, buffer.readu8(Indices, SourceOffset) * 4))
			buffer.writeu32(Canvas, OutputOffset + 4, buffer.readu32(Colors, buffer.readu8(Indices, SourceOffset + 1) * 4))
			buffer.writeu32(Canvas, OutputOffset + 8, buffer.readu32(Colors, buffer.readu8(Indices, SourceOffset + 2) * 4))
			buffer.writeu32(Canvas, OutputOffset + 12, buffer.readu32(Colors, buffer.readu8(Indices, SourceOffset + 3) * 4))
			SourceOffset += 4
			OutputOffset += 16
			Remaining -= 4
		end

		while Remaining > 0 do
			buffer.writeu32(Canvas, OutputOffset, buffer.readu32(Colors, buffer.readu8(Indices, SourceOffset) * 4))
			SourceOffset += 1
			OutputOffset += 4
			Remaining -= 1
		end

		return SourceOffset + SkipWidth
	end

	for _ = 1, DrawWidth do
		const ColorIndex = buffer.readu8(Indices, SourceOffset)
		SourceOffset += 1

		if ColorIndex >= ColorCount then
			error("GIF color index out of range")
		end

		buffer.writeu32(Canvas, OutputOffset, buffer.readu32(Colors, ColorIndex * 4))
		OutputOffset += 4
	end

	return SourceOffset + SkipWidth
end

const function DrawFrame(State: GifState, Frame: GifFrame)
	if Frame.Disposal == 3 then
		SaveRestoreArea(State, Frame)
	else
		State.RestoreBuffer = nil
		State.RestoreLeft = 0
		State.RestoreTop = 0
		State.RestoreWidth = 0
		State.RestoreHeight = 0
	end

	const Rendered = Frame.Rendered

	if Rendered ~= nil then
		buffer.copy(State.Canvas, 0, Rendered, 0, State.CanvasBytes)
		return
	end

	local Indices = Frame.Indices

	if Indices == nil then
		Indices = DecodeLzw(Frame, State.LzwPrefixes, State.LzwSuffixes, State.LzwStack)
		Frame.Indices = Indices
	end

	const FrameIndices = Indices :: buffer
	local SourceOffset = 0

	if Frame.HasTransparency then
		if Frame.Interlaced then
			for Y = 0, Frame.Height - 1, 8 do
				if Y < Frame.DrawHeight then
					SourceOffset = DrawTransparentRow(State, Frame, FrameIndices, SourceOffset, Y)
				else
					SourceOffset += Frame.Width
				end
			end

			for Y = 4, Frame.Height - 1, 8 do
				if Y < Frame.DrawHeight then
					SourceOffset = DrawTransparentRow(State, Frame, FrameIndices, SourceOffset, Y)
				else
					SourceOffset += Frame.Width
				end
			end

			for Y = 2, Frame.Height - 1, 4 do
				if Y < Frame.DrawHeight then
					SourceOffset = DrawTransparentRow(State, Frame, FrameIndices, SourceOffset, Y)
				else
					SourceOffset += Frame.Width
				end
			end

			for Y = 1, Frame.Height - 1, 2 do
				if Y < Frame.DrawHeight then
					SourceOffset = DrawTransparentRow(State, Frame, FrameIndices, SourceOffset, Y)
				else
					SourceOffset += Frame.Width
				end
			end
		else
			for Y = 0, Frame.Height - 1 do
				if Y < Frame.DrawHeight then
					SourceOffset = DrawTransparentRow(State, Frame, FrameIndices, SourceOffset, Y)
				else
					SourceOffset += Frame.Width
				end
			end
		end
	else
		if Frame.Interlaced then
			for Y = 0, Frame.Height - 1, 8 do
				if Y < Frame.DrawHeight then
					SourceOffset = DrawOpaqueRow(State, Frame, FrameIndices, SourceOffset, Y)
				else
					SourceOffset += Frame.Width
				end
			end

			for Y = 4, Frame.Height - 1, 8 do
				if Y < Frame.DrawHeight then
					SourceOffset = DrawOpaqueRow(State, Frame, FrameIndices, SourceOffset, Y)
				else
					SourceOffset += Frame.Width
				end
			end

			for Y = 2, Frame.Height - 1, 4 do
				if Y < Frame.DrawHeight then
					SourceOffset = DrawOpaqueRow(State, Frame, FrameIndices, SourceOffset, Y)
				else
					SourceOffset += Frame.Width
				end
			end

			for Y = 1, Frame.Height - 1, 2 do
				if Y < Frame.DrawHeight then
					SourceOffset = DrawOpaqueRow(State, Frame, FrameIndices, SourceOffset, Y)
				else
					SourceOffset += Frame.Width
				end
			end
		else
			for Y = 0, Frame.Height - 1 do
				if Y < Frame.DrawHeight then
					SourceOffset = DrawOpaqueRow(State, Frame, FrameIndices, SourceOffset, Y)
				else
					SourceOffset += Frame.Width
				end
			end
		end
	end

	if State.CacheRenderedFrames then
		const RenderedFrame = buffer.create(State.CanvasBytes)
		buffer.copy(RenderedFrame, 0, State.Canvas, 0, State.CanvasBytes)
		Frame.Rendered = RenderedFrame
	end
end

const function InitializeCanvas(State: GifState)
	PreFillCanvas(State.Canvas, State.CanvasBackgroundColor)
	State.RestoreBuffer = nil
	State.RestoreLeft = 0
	State.RestoreTop = 0
	State.RestoreWidth = 0
	State.RestoreHeight = 0
end

const function IsPlaybackFinished(State: GifState): boolean
	if State.LoopCount == 0 then
		return false
	end

	if State.LoopCount > 0 then
		return State.CompletedLoops >= State.LoopCount and State.CurrentFrameIndex >= #State.Frames
	end

	return State.CurrentFrameIndex >= #State.Frames
end

const function SyncResult(State: GifState)
	const Result = State.Result

	if Result == nil then
		return
	end

	const Frame = State.Frames[State.CurrentFrameIndex]
	Result.RGBA8 = State.Canvas
	Result.Frame = State.Canvas
	Result.Delay = Frame.Delay
	Result.Finished = IsPlaybackFinished(State)
end

const function AdvanceGifFrame(State: GifState): boolean
	if State.CurrentFrameIndex >= #State.Frames then
		if State.LoopCount == 0 or (State.LoopCount > 0 and State.CompletedLoops < State.LoopCount) then
			DisposeFrame(State, State.Frames[State.CurrentFrameIndex])
			State.CompletedLoops += 1
			InitializeCanvas(State)
			State.CurrentFrameIndex = 1
			DrawFrame(State, State.Frames[1])
			SyncResult(State)
			return true
		end

		SyncResult(State)
		return false
	end

	DisposeFrame(State, State.Frames[State.CurrentFrameIndex])
	State.CurrentFrameIndex += 1
	DrawFrame(State, State.Frames[State.CurrentFrameIndex])
	SyncResult(State)
	return true
end

const function ResetGif(State: GifState)
	InitializeCanvas(State)
	State.CurrentFrameIndex = 1
	State.CompletedLoops = 0
	DrawFrame(State, State.Frames[1])
	SyncResult(State)
end

const function ParseGraphicControl(Data: buffer, Cursor: number, Length: number): (number, number, boolean, number, number)
	if Cursor + 6 > Length then
		error("truncated GIF graphic control extension")
	end

	const BlockSize = buffer.readu8(Data, Cursor)
	Cursor += 1

	if BlockSize ~= 4 then
		error("invalid GIF graphic control extension")
	end

	const Packed = buffer.readu8(Data, Cursor)
	Cursor += 1

	if bit32.btest(Packed, 0xe0) then
		error("invalid GIF graphic control packed fields")
	end

	const Disposal = bit32.extract(Packed, 2, 3)

	if Disposal > 3 then
		error("unsupported GIF disposal method")
	end

	const DelayCentiseconds = buffer.readu16(Data, Cursor)
	Cursor += 2
	const TransparentIndex = buffer.readu8(Data, Cursor)
	Cursor += 1
	const Terminator = buffer.readu8(Data, Cursor)
	Cursor += 1

	if Terminator ~= 0 then
		error("invalid GIF graphic control terminator")
	end

	return Disposal, NormalizeDelay(DelayCentiseconds), bit32.btest(Packed, 1), TransparentIndex, Cursor
end

const function IsNetscapeLoopApplication(Data: buffer, Cursor: number): boolean
	return (
		buffer.readu32(Data, Cursor) == 0x5354454e
		and buffer.readu32(Data, Cursor + 4) == 0x45504143
		and buffer.readu16(Data, Cursor + 8) == 0x2e32
		and buffer.readu8(Data, Cursor + 10) == 0x30
	) or (
		buffer.readu32(Data, Cursor) == 0x4d494e41
		and buffer.readu32(Data, Cursor + 4) == 0x53545845
		and buffer.readu16(Data, Cursor + 8) == 0x2e31
		and buffer.readu8(Data, Cursor + 10) == 0x30
	)
end

const function ParseNetscapeLoopSubBlocks(Data: buffer, Cursor: number, Length: number): (number, number)
	if Cursor >= Length then
		error("truncated GIF loop extension")
	end

	const BlockSize = buffer.readu8(Data, Cursor)
	Cursor += 1

	if BlockSize == 0 then
		return Cursor, -1
	end

	if BlockSize ~= 3 or Cursor + 3 > Length then
		error("invalid GIF loop extension")
	end

	if buffer.readu8(Data, Cursor) ~= 1 then
		error("invalid GIF loop extension")
	end

	const LoopCount = buffer.readu16(Data, Cursor + 1)
	Cursor += 3

	if Cursor >= Length then
		error("truncated GIF loop extension")
	end

	if buffer.readu8(Data, Cursor) ~= 0 then
		error("invalid GIF loop extension")
	end

	return Cursor + 1, LoopCount
end

const function ParseApplicationExtension(Data: buffer, Cursor: number, Length: number): (number, number)
	if Cursor >= Length then
		error("truncated GIF application extension")
	end

	const BlockSize = buffer.readu8(Data, Cursor)
	Cursor += 1

	if BlockSize ~= 11 or Cursor + 11 > Length then
		error("invalid GIF application extension")
	end

	const IsLoopApplication = IsNetscapeLoopApplication(Data, Cursor)
	Cursor += 11

	if IsLoopApplication then
		return ParseNetscapeLoopSubBlocks(Data, Cursor, Length)
	end

	return SkipSubBlocks(Data, Cursor, Length), -1
end

const function ParsePlainTextExtension(Data: buffer, Cursor: number, Length: number, GlobalColorTable: ColorTable?): number
	if Cursor >= Length then
		error("truncated GIF plain text extension")
	end

	const BlockSize = buffer.readu8(Data, Cursor)
	Cursor += 1

	if BlockSize ~= 12 or Cursor + 12 > Length then
		error("invalid GIF plain text extension")
	end

	const Left = buffer.readu16(Data, Cursor)
	const Top = buffer.readu16(Data, Cursor + 2)
	const Width = buffer.readu16(Data, Cursor + 4)
	const Height = buffer.readu16(Data, Cursor + 6)
	const CellWidth = buffer.readu8(Data, Cursor + 8)
	const CellHeight = buffer.readu8(Data, Cursor + 9)
	const ForegroundIndex = buffer.readu8(Data, Cursor + 10)
	const BackgroundIndex = buffer.readu8(Data, Cursor + 11)

	if Width <= 0 or Height <= 0 or CellWidth <= 0 or CellHeight <= 0 then
		error("invalid GIF plain text grid")
	end

	if Left > 65535 - Width or Top > 65535 - Height then
		error("invalid GIF plain text grid")
	end

	if GlobalColorTable == nil then
		error("GIF plain text extension requires a global color table")
	end

	if ForegroundIndex >= GlobalColorTable.Count or BackgroundIndex >= GlobalColorTable.Count then
		error("GIF plain text color index out of range")
	end

	Cursor += 12
	return SkipSubBlocks(Data, Cursor, Length)
end

const function ClearPendingGraphicControl(Pending: PendingGraphicControl)
	Pending.Disposal = 0
	Pending.Delay = DefaultMinimumFrameDelay
	Pending.HasTransparency = false
	Pending.TransparentIndex = 0
	Pending.Active = false
end

const function DecodeGif(GifData: buffer): DecodedGif
	const Length = buffer.len(GifData)

	if Length < 13 then
		error("truncated GIF header")
	end

	const Signature = buffer.readu32(GifData, 0)
	const Version = buffer.readu16(GifData, 4)

	if Signature ~= 0x38464947 or (Version ~= 0x6137 and Version ~= 0x6139) then
		error("invalid GIF signature")
	end

	const Width = buffer.readu16(GifData, 6)
	const Height = buffer.readu16(GifData, 8)
	const Packed = buffer.readu8(GifData, 10)
	const BackgroundIndex = buffer.readu8(GifData, 11)

	if Width <= 0 or Height <= 0 then
		error("invalid GIF dimensions")
	end

	if Width > MaxOutputBytes // 4 // Height then
		error("GIF output too large")
	end

	local Cursor = 13
	local GlobalColorTable: ColorTable? = nil
	const HasGlobalColorTable = bit32.btest(Packed, 0x80)

	if HasGlobalColorTable then
		GlobalColorTable, Cursor = ParseColorTable(GifData, Cursor, Length, bit32.band(Packed, 0x07))
	end

	local BackgroundColor = 0

	if GlobalColorTable ~= nil and BackgroundIndex < GlobalColorTable.Count then
		BackgroundColor = buffer.readu32(GlobalColorTable.Colors, BackgroundIndex * 4)
	elseif GlobalColorTable ~= nil then
		error("GIF background color index out of range")
	end

	const Frames: { GifFrame } = {}
	local HasTransparentFrame = false
	const PendingGraphicControl: PendingGraphicControl = {
		Disposal = 0,
		Delay = DefaultMinimumFrameDelay,
		HasTransparency = false,
		TransparentIndex = 0,
		Active = false,
	}
	local LoopCount = -1
	local SawTrailer = false

	while Cursor < Length do
		const Introducer = buffer.readu8(GifData, Cursor)
		Cursor += 1

		if Introducer == 0x3b then
			SawTrailer = true
			break
		elseif Introducer == 0x21 then
			if Cursor >= Length then
				error("truncated GIF extension")
			end

			const Label = buffer.readu8(GifData, Cursor)
			Cursor += 1

			if Label == 0xf9 then
				if PendingGraphicControl.Active then
					error("duplicate GIF graphic control extension")
				end

				PendingGraphicControl.Disposal,
					PendingGraphicControl.Delay,
					PendingGraphicControl.HasTransparency,
					PendingGraphicControl.TransparentIndex,
					Cursor =
					ParseGraphicControl(GifData, Cursor, Length)
				PendingGraphicControl.Active = true
			elseif Label == 0xff then
				local ParsedLoopCount: number
				Cursor, ParsedLoopCount = ParseApplicationExtension(GifData, Cursor, Length)

				if ParsedLoopCount >= 0 then
					LoopCount = ParsedLoopCount
				end
			elseif Label == 0x01 then
				Cursor = ParsePlainTextExtension(GifData, Cursor, Length, GlobalColorTable)
				ClearPendingGraphicControl(PendingGraphicControl)
			else
				Cursor = SkipSubBlocks(GifData, Cursor, Length)
			end
		elseif Introducer == 0x2c then
			if Cursor + 9 > Length then
				error("truncated GIF image descriptor")
			end

			const Left = buffer.readu16(GifData, Cursor)
			Cursor += 2
			const Top = buffer.readu16(GifData, Cursor)
			Cursor += 2
			const FrameWidth = buffer.readu16(GifData, Cursor)
			Cursor += 2
			const FrameHeight = buffer.readu16(GifData, Cursor)
			Cursor += 2
			const ImagePacked = buffer.readu8(GifData, Cursor)
			Cursor += 1

			if bit32.btest(ImagePacked, 0x18) then
				error("invalid GIF image descriptor packed fields")
			end

			if FrameWidth <= 0 or FrameHeight <= 0 then
				error("invalid GIF frame dimensions")
			end

			if FrameWidth > MaxOutputBytes // FrameHeight then
				error("GIF frame too large")
			end

			local DrawWidth = FrameWidth
			local DrawHeight = FrameHeight

			if Left >= Width or Top >= Height then
				DrawWidth = 0
				DrawHeight = 0
			else
				if DrawWidth > Width - Left then
					DrawWidth = Width - Left
				end

				if DrawHeight > Height - Top then
					DrawHeight = Height - Top
				end
			end

			local FrameColorTable = GlobalColorTable

			if bit32.btest(ImagePacked, 0x80) then
				FrameColorTable, Cursor = ParseColorTable(GifData, Cursor, Length, bit32.band(ImagePacked, 0x07))
			end

			if FrameColorTable == nil then
				error("missing GIF color table")
			end

			if PendingGraphicControl.HasTransparency and PendingGraphicControl.TransparentIndex >= FrameColorTable.Count then
				error("GIF transparent color index out of range")
			end

			if Cursor >= Length then
				error("truncated GIF image data")
			end

			const LzwMinimumCodeSize = buffer.readu8(GifData, Cursor)
			Cursor += 1
			local ImageData: buffer
			ImageData, Cursor = ReadSubBlocks(GifData, Cursor, Length)

			Frames[#Frames + 1] = {
				Left = Left,
				Top = Top,
				Width = FrameWidth,
				Height = FrameHeight,
				DrawWidth = DrawWidth,
				DrawHeight = DrawHeight,
				Interlaced = bit32.btest(ImagePacked, 0x40),
				ColorTable = FrameColorTable,
				LzwMinimumCodeSize = LzwMinimumCodeSize,
				ImageData = ImageData,
				Rendered = nil,
				Disposal = PendingGraphicControl.Disposal,
				Delay = PendingGraphicControl.Delay,
				HasTransparency = PendingGraphicControl.HasTransparency,
				TransparentIndex = PendingGraphicControl.TransparentIndex,
			}

			if PendingGraphicControl.HasTransparency then
				HasTransparentFrame = true
			end

			ClearPendingGraphicControl(PendingGraphicControl)
		else
			error("invalid GIF block introducer")
		end
	end

	if not SawTrailer then
		error("missing GIF trailer")
	end

	if Cursor ~= Length then
		error("invalid GIF trailing data")
	end

	if #Frames == 0 then
		error("missing GIF image frame")
	end

	local CanvasBackgroundColor = BackgroundColor

	if HasTransparentFrame then
		CanvasBackgroundColor = 0
	end

	const State: GifState = {
		Width = Width,
		Height = Height,
		CanvasBackgroundColor = CanvasBackgroundColor,
		LoopCount = LoopCount,
		CompletedLoops = 0,
		Frames = Frames,
		Canvas = buffer.create(Width * Height * 4),
		CanvasBytes = Width * Height * 4,
		CacheRenderedFrames = LoopCount >= 0,
		LzwPrefixes = buffer.create(4096 * 2),
		LzwSuffixes = buffer.create(4096),
		LzwStack = buffer.create(4096),
		CurrentFrameIndex = 1,
		RestoreBuffer = nil,
		RestoreLeft = 0,
		RestoreTop = 0,
		RestoreWidth = 0,
		RestoreHeight = 0,
		Result = nil,
	}

	InitializeCanvas(State)
	DrawFrame(State, Frames[1])

	const function AdvanceFrame()
		AdvanceGifFrame(State)
	end

	const function Reset()
		ResetGif(State)
	end

	local InitialFinished = #Frames <= 1

	if LoopCount == 0 or LoopCount > 0 then
		InitialFinished = false
	end

	const Result: DecodedGif = {
		Animated = #Frames > 1,
		Size = Vector2.new(Width, Height),
		RGBA8 = State.Canvas,
		Frame = State.Canvas,
		AdvanceFrame = AdvanceFrame,
		Reset = Reset,
		Finished = InitialFinished,
		Delay = Frames[1].Delay,
	}

	State.Result = Result
	return Result
end

return DecodeGif
