--!strict
--!optimize 2
--!native

-- This is incredibly fast because it based from the fastest Base64
-- https://github.com/daily3014/rbx-cryptography/blob/main/src/Utilities/Base64.luau
-- Base85 format: Acsii85

local P1, P2, P3, P4 = 85, 7225, 614125, 52200625

local ENC_LUT_HI = buffer.create(14000) 
local ENC_LUT_LO = buffer.create(30000)

for i = 0, 6995 do
	buffer.writeu16(ENC_LUT_HI, i * 2, (i // 85 + 33) + (i % 85 + 33) * 256)
end

for i = 0, 7224 do
	local val = ((i // 85 + 33) + (i % 85 + 33) * 256) * 65536
	buffer.writeu32(ENC_LUT_LO, i * 4, val)
end

local DECODE_A = buffer.create(262144)
local DECODE_B = buffer.create(262144)
local DECODE_C = buffer.create(256)

for i = 0, 255 do
	local v = i - 33
	if v >= 0 and v <= 84 then buffer.writeu8(DECODE_C, i, v) end
end

for c1 = 0, 255 do
	local v1 = c1 - 33
	if v1 < 0 or v1 > 84 then
		continue
	end

	for c2 = 0, 255 do
		local v2 = c2 - 33
		if v2 < 0 or v2 > 84 then
			continue
		end

		local key = (c1 + c2 * 256) * 4
		buffer.writeu32(DECODE_A, key, v1 * P4 + v2 * P3)
		buffer.writeu32(DECODE_B, key, v1 * P2 + v2 * P1)
	end
end

local function Encode(Input: buffer): buffer
	local Len = buffer.len(Input)
	if Len == 0 then return buffer.create(0) end

	local Rem = Len % 4
	local Output = buffer.create((Len // 4) * 5 + (if Rem > 0 then Rem + 1 else 0))

	local InIdx = 0
	local OutIdx = 0
	local UnrollLimit = Len - 20

	local LutHi = ENC_LUT_HI
	local LutLo = ENC_LUT_LO

	while InIdx <= UnrollLimit do
		local W, P1, R1, P2

		W = bit32.byteswap(buffer.readu32(Input, InIdx))
		P1 = W // 614125
		R1 = W - P1 * 614125
		P2 = R1 // 85
		buffer.writeu32(Output, OutIdx, buffer.readu16(LutHi, P1 * 2) + buffer.readu32(LutLo, P2 * 4))
		buffer.writeu8(Output, OutIdx + 4, (R1 - P2 * 85) + 33)

		W = bit32.byteswap(buffer.readu32(Input, InIdx + 4))
		P1 = W // 614125
		R1 = W - P1 * 614125
		P2 = R1 // 85
		buffer.writeu32(Output, OutIdx + 5, buffer.readu16(LutHi, P1 * 2) + buffer.readu32(LutLo, P2 * 4))
		buffer.writeu8(Output, OutIdx + 9, (R1 - P2 * 85) + 33)

		W = bit32.byteswap(buffer.readu32(Input, InIdx + 8))
		P1 = W // 614125
		R1 = W - P1 * 614125
		P2 = R1 // 85
		buffer.writeu32(Output, OutIdx + 10, buffer.readu16(LutHi, P1 * 2) + buffer.readu32(LutLo, P2 * 4))
		buffer.writeu8(Output, OutIdx + 14, (R1 - P2 * 85) + 33)

		W = bit32.byteswap(buffer.readu32(Input, InIdx + 12))
		P1 = W // 614125
		R1 = W - P1 * 614125
		P2 = R1 // 85
		buffer.writeu32(Output, OutIdx + 15, buffer.readu16(LutHi, P1 * 2) + buffer.readu32(LutLo, P2 * 4))
		buffer.writeu8(Output, OutIdx + 19, (R1 - P2 * 85) + 33)

		InIdx += 16
		OutIdx += 20
	end

	while InIdx <= Len - 4 do
		local W = bit32.byteswap(buffer.readu32(Input, InIdx))
		local P1 = W // 614125
		local R1 = W - P1 * 614125
		local P2 = R1 // 85

		buffer.writeu32(Output, OutIdx, buffer.readu16(LutHi, P1 * 2) + buffer.readu32(LutLo, P2 * 4))
		buffer.writeu8(Output, OutIdx + 4, (R1 - P2 * 85) + 33)

		InIdx += 4
		OutIdx += 5
	end

	if Rem > 0 then
		local Val = 0

		for i = 0, Rem - 1 do
			Val = Val * 256 + buffer.readu8(Input, InIdx + i)
		end
		
		if Rem == 1 then
			Val *= 16777216 
		elseif Rem == 2 then
			Val *= 65536
		elseif Rem == 3 then
			Val *= 256
		end

		local P1 = Val // 614125
		local R1 = Val - P1 * 614125
		local P2 = R1 // 85

		local Part2 = buffer.readu32(LutLo, P2 * 4)
		buffer.writeu16(Output, OutIdx, buffer.readu16(LutHi, P1 * 2))
		if Rem > 1 then
			buffer.writeu8(Output, OutIdx + 2, bit32.extract(Part2, 16, 8))
			if Rem > 2 then
				buffer.writeu8(Output, OutIdx + 3, bit32.extract(Part2, 24, 8))
			end
		end
	end

	return Output
end

local function Decode(Input: buffer): buffer
	local Len = buffer.len(Input)
	if Len == 0 then return buffer.create(0) end

	local Rem = Len % 5
	local Output = buffer.create((Len // 5) * 4 + (if Rem > 0 then Rem - 1 else 0))

	local InIdx = 0
	local OutIdx = 0
	local UnrollLimit = Len - 20

	local DecA, DecB, DecC = DECODE_A, DECODE_B, DECODE_C

	while InIdx <= UnrollLimit do
		local W, T

		W = buffer.readu32(Input, InIdx)
		T = buffer.readu32(DecA, bit32.band(W, 0xFFFF) * 4) 
			+ buffer.readu32(DecB, bit32.rshift(W, 16) * 4)
			+ buffer.readu8(DecC, buffer.readu8(Input, InIdx + 4))
		buffer.writeu32(Output, OutIdx, bit32.byteswap(T))

		W = buffer.readu32(Input, InIdx + 5)
		T = buffer.readu32(DecA, bit32.band(W, 0xFFFF) * 4) 
			+ buffer.readu32(DecB, bit32.rshift(W, 16) * 4)
			+ buffer.readu8(DecC, buffer.readu8(Input, InIdx + 9))
		buffer.writeu32(Output, OutIdx + 4, bit32.byteswap(T))

		W = buffer.readu32(Input, InIdx + 10)
		T = buffer.readu32(DecA, bit32.band(W, 0xFFFF) * 4) 
			+ buffer.readu32(DecB, bit32.rshift(W, 16) * 4)
			+ buffer.readu8(DecC, buffer.readu8(Input, InIdx + 14))
		buffer.writeu32(Output, OutIdx + 8, bit32.byteswap(T))

		W = buffer.readu32(Input, InIdx + 15)
		T = buffer.readu32(DecA, bit32.band(W, 0xFFFF) * 4) 
			+ buffer.readu32(DecB, bit32.rshift(W, 16) * 4)
			+ buffer.readu8(DecC, buffer.readu8(Input, InIdx + 19))
		buffer.writeu32(Output, OutIdx + 12, bit32.byteswap(T))

		InIdx += 20
		OutIdx += 16
	end

	while InIdx <= Len - 5 do
		local W = buffer.readu32(Input, InIdx)
		local T = buffer.readu32(DecA, bit32.band(W, 0xFFFF) * 4) 
			+ buffer.readu32(DecB, bit32.rshift(W, 16) * 4)
			+ buffer.readu8(DecC, buffer.readu8(Input, InIdx + 4))
		buffer.writeu32(Output, OutIdx, bit32.byteswap(T))

		InIdx += 5
		OutIdx += 4
	end

	if InIdx < Len then
		local CharsLeft = Len - InIdx
		local Sum = 0

		for i = 0, CharsLeft - 1 do
			local char = buffer.readu8(Input, InIdx + i)
			local val = buffer.readu8(DECODE_C, char)
			if i == 0 then
				Sum += val * P4
			elseif i == 1 then
				Sum += val * P3
			elseif i == 2 then
				Sum += val * P2
			elseif i == 3 then
				Sum += val * P1
			end
		end

		for i = CharsLeft, 4 do
			if i == 1 then
				Sum += 84 * P3
			elseif i == 2 then
				Sum += 84 * P2
			elseif i == 3 then
				Sum += 84 * P1
			elseif i == 4 then
				Sum += 84
			end
		end

		buffer.writeu8(Output, OutIdx, bit32.extract(Sum, 24, 8))
		if CharsLeft > 2 then
			buffer.writeu8(Output, OutIdx + 1, bit32.extract(Sum, 16, 8))
			if CharsLeft > 3 then
				buffer.writeu8(Output, OutIdx + 2, bit32.extract(Sum, 8, 8))
			end
		end
	end

	return Output
end

return {
	Encode = Encode,
	Decode = Decode
}
