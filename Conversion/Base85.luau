--!strict
--!optimize 2
--!native

-- This is incredibly fast because it based from the fastest Base64
-- https://github.com/daily3014/rbx-cryptography/blob/main/src/Utilities/Base64.luau
-- Base85 format: Acsii85

local P1, P2, P3, P4 = 85, 7225, 614125, 52200625

local ENC_LUT_HI = buffer.create(14000) 
local ENC_LUT_LO = buffer.create(30000)

local DECODE_A = buffer.create(262144)
local DECODE_B = buffer.create(262144)

for i = 0, 6995 do
	buffer.writeu16(ENC_LUT_HI, i * 2, (i // 85 + 33) + (i % 85 + 33) * 256)
end

for i = 0, 7224 do
	buffer.writeu32(ENC_LUT_LO, i * 4, ((i // 85 + 33) + (i % 85 + 33) * 256) * 65536)
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
	local Output = buffer.create(Len // 4 * 5 + (if Rem > 0 then Rem + 1 else 0))

	local InIdx = 0
	local OutIdx = 0
	local UnrollLimit = Len - 16

	local LutHi = ENC_LUT_HI
	local LutLo = ENC_LUT_LO

	while InIdx <= UnrollLimit do
		local W1 = bit32.byteswap(buffer.readu32(Input, InIdx))
		local W2 = bit32.byteswap(buffer.readu32(Input, InIdx + 4))
		local W3 = bit32.byteswap(buffer.readu32(Input, InIdx + 8))
		local W4 = bit32.byteswap(buffer.readu32(Input, InIdx + 12))

		local P1_1 = W1 // 614125
		local R1_1 = W1 - P1_1 * 614125
		local P1_2 = W2 // 614125
		local R1_2 = W2 - P1_2 * 614125
		local P1_3 = W3 // 614125
		local R1_3 = W3 - P1_3 * 614125
		local P1_4 = W4 // 614125
		local R1_4 = W4 - P1_4 * 614125

		local P2_1 = R1_1 // 85
		local P2_2 = R1_2 // 85
		local P2_3 = R1_3 // 85
		local P2_4 = R1_4 // 85

		local ValHi1 = buffer.readu16(LutHi, P1_1 * 2)
		local ValLo1 = buffer.readu32(LutLo, P2_1 * 4)
		buffer.writeu32(Output, OutIdx, ValHi1 + ValLo1)
		buffer.writeu8(Output, OutIdx + 4, (R1_1 - P2_1 * 85) + 33)

		local ValHi2 = buffer.readu16(LutHi, P1_2 * 2)
		local ValLo2 = buffer.readu32(LutLo, P2_2 * 4)
		buffer.writeu32(Output, OutIdx + 5, ValHi2 + ValLo2)
		buffer.writeu8(Output, OutIdx + 9, (R1_2 - P2_2 * 85) + 33)

		local ValHi3 = buffer.readu16(LutHi, P1_3 * 2)
		local ValLo3 = buffer.readu32(LutLo, P2_3 * 4)
		buffer.writeu32(Output, OutIdx + 10, ValHi3 + ValLo3)
		buffer.writeu8(Output, OutIdx + 14, (R1_3 - P2_3 * 85) + 33)

		local ValHi4 = buffer.readu16(LutHi, P1_4 * 2)
		local ValLo4 = buffer.readu32(LutLo, P2_4 * 4)
		buffer.writeu32(Output, OutIdx + 15, ValHi4 + ValLo4)
		buffer.writeu8(Output, OutIdx + 19, (R1_4 - P2_4 * 85) + 33)

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

	local DecA, DecB = DECODE_A, DECODE_B

	while InIdx <= UnrollLimit do
		local W1 = buffer.readu32(Input, InIdx)
		local W2 = buffer.readu32(Input, InIdx + 5)
		local W3 = buffer.readu32(Input, InIdx + 10)
		local W4 = buffer.readu32(Input, InIdx + 15)

		local C5_1 = buffer.readu8(Input, InIdx + 4)
		local C5_2 = buffer.readu8(Input, InIdx + 9)
		local C5_3 = buffer.readu8(Input, InIdx + 14)
		local C5_4 = buffer.readu8(Input, InIdx + 19)

		local T1 = buffer.readu32(DecA, bit32.band(W1, 0xFFFF) * 4) 
			+ buffer.readu32(DecB, bit32.rshift(W1, 16) * 4) + C5_1 - 33

		local T2 = buffer.readu32(DecA, bit32.band(W2, 0xFFFF) * 4) 
			+ buffer.readu32(DecB, bit32.rshift(W2, 16) * 4) + C5_2 - 33

		local T3 = buffer.readu32(DecA, bit32.band(W3, 0xFFFF) * 4) 
			+ buffer.readu32(DecB, bit32.rshift(W3, 16) * 4) + C5_3 - 33

		local T4 = buffer.readu32(DecA, bit32.band(W4, 0xFFFF) * 4) 
			+ buffer.readu32(DecB, bit32.rshift(W4, 16) * 4) + C5_4 - 33

		buffer.writeu32(Output, OutIdx, bit32.byteswap(T1))
		buffer.writeu32(Output, OutIdx + 4, bit32.byteswap(T2))
		buffer.writeu32(Output, OutIdx + 8, bit32.byteswap(T3))
		buffer.writeu32(Output, OutIdx + 12, bit32.byteswap(T4))

		InIdx += 20
		OutIdx += 16
	end

	while InIdx <= Len - 5 do
		local W = buffer.readu32(Input, InIdx)
		
		local T = buffer.readu32(DecA, bit32.band(W, 0xFFFF) * 4) 
			+ buffer.readu32(DecB, bit32.rshift(W, 16) * 4)
			+ buffer.readu8(Input, InIdx + 4) - 33
		
		buffer.writeu32(Output, OutIdx, bit32.byteswap(T))

		InIdx += 5
		OutIdx += 4
	end

	if InIdx < Len then
		local CharsLeft = Len - InIdx
		local Sum = 0

		for i = 0, CharsLeft - 1 do
			local char = buffer.readu8(Input, InIdx + i)
			local val = char - 33
			
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
