--!optimize 2
--!native
--!strict

-- Based on Dekkonot's Base91 https://gist.github.com/Dekkonot/5391144931e1bd1a6de86cf21036c651

local DIRECT_LOOKUP = {}
local BIT_MASK = {}

local ENCODE_MAP = {}
local DECODE_MAP = {}

local j = 0 for i = 32, 127 do

	if i ~= 34 and i ~= 92 then
		ENCODE_MAP[j] = i
		DECODE_MAP[i] = j
		j += 1
	end

end

for entry = 0, 8648 do
	DIRECT_LOOKUP[entry] = bit32.bor(
		bit32.lshift(ENCODE_MAP[entry // 93], 8), ENCODE_MAP[entry % 93]
	)

	BIT_MASK[entry] = bit32.band(entry, 8191) > 456 and 13 or 14
end

local function Encode(input: buffer): buffer
	local length = buffer.len(input)
	local output = buffer.create(math.ceil(length * 1.3))

	local counter = 0
	local numBits = 0
	local offset = 0

	for i = 0, length - 1 do
		counter = bit32.bor(counter, bit32.lshift(buffer.readu8(input, i), numBits))
		numBits += 8

		if numBits > 13 then
			local entry = bit32.band(counter, 8191)

			if entry > 456 then
				counter //= 8192
				numBits -= 13
			else
				entry = bit32.band(counter, 16383)
				counter //= 16383
				numBits -= 14
			end

			buffer.writeu16(output, offset, DIRECT_LOOKUP[entry])
			offset += 2
		end
	end

	if numBits > 7 or counter > 92 then
		buffer.writeu16(output, offset, DIRECT_LOOKUP[counter])
		offset += 2
	elseif numBits > 0 then
		buffer.writeu8(output, offset, ENCODE_MAP[counter % 93])
		offset += 1
	end

	local sliced = buffer.create(offset)
	buffer.copy(sliced, 0, output, 0, offset)

	return sliced
end

local function Decode(Input: buffer): buffer
	local InputLength = buffer.len(Input)
	local output = buffer.create(InputLength * 0.9)

	local offset = 0
	local counter = 0
	local numBits = 0
	local entry = -1

	for i = 0, InputLength - 1 do
		local val = DECODE_MAP[buffer.readu8(Input, i)]
		if entry == -1 then
			entry = val
		else
			entry += val * 93

			counter = bit32.bor(counter, bit32.lshift(entry, numBits))
			numBits += BIT_MASK[entry]

			if numBits >= 16 then
				buffer.writeu16(output, offset, counter)
				offset += 2
				counter //= 65536
				numBits -= 16
			elseif numBits >= 8 then
				buffer.writeu8(output, offset, counter)
				offset += 1
				counter //= 256
				numBits -= 8
			end

			entry = -1
		end
	end

	if entry ~= -1 then
		buffer.writeu8(output, offset, bit32.band(bit32.bor(counter, bit32.lshift(entry, numBits)), 255))
		offset += 1
	end

	local sliced = buffer.create(offset)
	buffer.copy(sliced, 0, output, 0, offset)

	return sliced
end

return {
	Encode = Encode,
	Decode = Decode
}
