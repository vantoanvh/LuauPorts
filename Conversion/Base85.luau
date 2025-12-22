--!optimize 2
--!native
--!strict

local POW1, POW2, POW3, POW4 = 85, 7225, 614125, 52200625

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
	if v1 < 0 or v1 > 84 then continue end

	for c2 = 0, 255 do
		local v2 = c2 - 33
		if v2 < 0 or v2 > 84 then continue end

		local key = (c1 + c2 * 256) * 4

		buffer.writeu32(DECODE_A, key, v1 * POW4 + v2 * POW3 - 33)
		buffer.writeu32(DECODE_B, key, v1 * POW2 + v2 * POW1)
	end
end

local function Encode(Input: buffer): buffer
	local Len = buffer.len(Input)
	if Len == 0 then return buffer.create(0) end

	local Rem = Len % 4
	local Output = buffer.create(Len // 4 * 5 + (if Rem > 0 then Rem + 1 else 0))

	local OutIdx = 0
	local UnrollLimit = Len - 16

	local LutHi = ENC_LUT_HI
	local LutLo = ENC_LUT_LO

	for i = 0, UnrollLimit, 16 do
		local W1 = bit32.byteswap(buffer.readu32(Input, i))
		local W2 = bit32.byteswap(buffer.readu32(Input, i + 4))
		local W3 = bit32.byteswap(buffer.readu32(Input, i + 8))
		local W4 = bit32.byteswap(buffer.readu32(Input, i + 12))

		local P1_1 = W1 // 614125
		local P1_2 = W2 // 614125
		local P1_3 = W3 // 614125
		local P1_4 = W4 // 614125
		
		local R1_1 = W1 - P1_1 * 614125
		local R1_2 = W2 - P1_2 * 614125
		local R1_3 = W3 - P1_3 * 614125
		local R1_4 = W4 - P1_4 * 614125
		
		local P2_1 = R1_1 // 85
		local P2_2 = R1_2 // 85
		local P2_3 = R1_3 // 85
		local P2_4 = R1_4 // 85

		buffer.writeu32(Output, OutIdx, buffer.readu16(LutHi, P1_1 * 2) + buffer.readu32(LutLo, P2_1 * 4))
		buffer.writeu8(Output, OutIdx + 4, R1_1 - P2_1 * 85 + 33)

		buffer.writeu32(Output, OutIdx + 5, buffer.readu16(LutHi, P1_2 * 2) + buffer.readu32(LutLo, P2_2 * 4))
		buffer.writeu8(Output, OutIdx + 9, R1_2 - P2_2 * 85 + 33)

		buffer.writeu32(Output, OutIdx + 10, buffer.readu16(LutHi, P1_3 * 2) + buffer.readu32(LutLo, P2_3 * 4))
		buffer.writeu8(Output, OutIdx + 14, R1_3 - P2_3 * 85 + 33)

		buffer.writeu32(Output, OutIdx + 15, buffer.readu16(LutHi, P1_4 * 2) + buffer.readu32(LutLo, P2_4 * 4))
		buffer.writeu8(Output, OutIdx + 19, R1_4 - P2_4 * 85 + 33)

		OutIdx += 20
	end

	local InIdx = OutIdx // 5 * 4
	
	while InIdx <= Len - 4 do
		local W = bit32.byteswap(buffer.readu32(Input, InIdx))
		local P1 = W // 614125
		local R1 = W - P1 * 614125
		local P2 = R1 // 85

		buffer.writeu32(Output, OutIdx, buffer.readu16(LutHi, P1 * 2) + buffer.readu32(LutLo, P2 * 4))
		buffer.writeu8(Output, OutIdx + 4, R1 - P2 * 85 + 33)
		
		InIdx += 4
		OutIdx += 5
	end

	if Rem > 0 then
		local Val = buffer.readu8(Input, InIdx)
		if Rem > 1 then
			Val = Val * 256 + buffer.readu8(Input, InIdx + 1)
			if Rem > 2 then
				Val = Val * 256 + buffer.readu8(Input, InIdx + 2)
				Val *= 256
			else
				Val *= 65536
			end
		else
			Val *= 16777216
		end

		local P1 = Val // 614125
		local R1 = Val - P1 * 614125
		
		buffer.writeu16(Output, OutIdx, buffer.readu16(LutHi, P1 * 2))
		if Rem > 1 then
			local Part2 = buffer.readu32(LutLo, R1 // 85 * 4)
			buffer.writeu8(Output, OutIdx + 2, Part2 // 65536 % 256)
			if Rem > 2 then
				buffer.writeu8(Output, OutIdx + 3, Part2 // 16777216)
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

	local OutIdx = 0
	local UnrollLimit = Len - 20

	local DecA = DECODE_A
	local DecB = DECODE_B

	for i = 0, UnrollLimit, 20 do
		local Key00 = buffer.readu16(Input, i) * 4
		local Key01 = buffer.readu16(Input, i + 2) * 4
		local Key10 = buffer.readu16(Input, i + 5) * 4
		local Key11 = buffer.readu16(Input, i + 7) * 4
		local Key20 = buffer.readu16(Input, i + 10) * 4
		local Key21 = buffer.readu16(Input, i + 12) * 4
		local Key30 = buffer.readu16(Input, i + 15) * 4
		local Key31 = buffer.readu16(Input, i + 17) * 4

		buffer.writeu32(Output, OutIdx, bit32.byteswap(
			buffer.readu32(DecA, Key00) + buffer.readu32(DecB, Key01) + buffer.readu8(Input, i + 4)))

		buffer.writeu32(Output, OutIdx + 4, bit32.byteswap(
			buffer.readu32(DecA, Key10) + buffer.readu32(DecB, Key11) + buffer.readu8(Input, i + 9)))

		buffer.writeu32(Output, OutIdx + 8, bit32.byteswap(
			buffer.readu32(DecA, Key20) + buffer.readu32(DecB, Key21) + buffer.readu8(Input, i + 14)))

		buffer.writeu32(Output, OutIdx + 12, bit32.byteswap(
			buffer.readu32(DecA, Key30) + buffer.readu32(DecB, Key31) + buffer.readu8(Input, i + 19)))

		OutIdx += 16
	end

	local InIdx = OutIdx // 4 * 5
	while InIdx <= Len - 5 do
		local Key0 = buffer.readu16(Input, InIdx) * 4
		local Key1 = buffer.readu16(Input, InIdx + 2) * 4

		buffer.writeu32(Output, OutIdx, bit32.byteswap(
			buffer.readu32(DecA, Key0) + buffer.readu32(DecB, Key1) + buffer.readu8(Input, InIdx + 4)))

		InIdx += 5
		OutIdx += 4
	end

	if Rem > 0 then
		local C0 = buffer.readu8(Input, InIdx) - 33
		local C1 = if Rem > 1 then buffer.readu8(Input, InIdx + 1) - 33 else 84
		local C2 = if Rem > 2 then buffer.readu8(Input, InIdx + 2) - 33 else 84
		local C3 = if Rem > 3 then buffer.readu8(Input, InIdx + 3) - 33 else 84

		local Sum = C0 * POW4 + C1 * POW3 + C2 * POW2 + C3 * POW1 + 84

		buffer.writeu8(Output, OutIdx, bit32.rshift(Sum, 24))
		if Rem > 2 then
			buffer.writeu8(Output, OutIdx + 1, bit32.band(bit32.rshift(Sum, 16), 0xFF))
			if Rem > 3 then
				buffer.writeu8(Output, OutIdx + 2, bit32.band(bit32.rshift(Sum, 8), 0xFF))
			end
		end
	end

	return Output
end

return {
	Encode = Encode,
	Decode = Decode
}
