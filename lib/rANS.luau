--!optimize 2
--!native

local PROB_BITS = 12
local PROB_SCALE = 4096

local function compress(src: buffer): buffer
	local n = buffer.len(src)
	if n == 0 then
		return buffer.create(4)
	end
	
	local freqs = table.create(256, 0)
	
	for i = 0, n - 1 do
		local s = buffer.readu8(src, i) + 1
		freqs[s] += 1
	end
	
	local norm_freqs = table.create(256, 0)
	
	local total = 0
	local max_f, max_i = 0, 1
	
	local active_count = 0
	local active_syms = table.create(256)

	for i = 1, 256 do
		local f = freqs[i]
		if f > 0 then
			local nf = f * PROB_SCALE // n
			
			if nf == 0 then
				nf = 1
			end
			
			norm_freqs[i] = nf
			total += nf
			
			if nf > max_f then
				max_f, max_i = nf, i
			end

			active_count += 1
			active_syms[active_count] = i
		end
	end
	
	if total < PROB_SCALE then
		norm_freqs[max_i] += PROB_SCALE - total
	elseif total > PROB_SCALE then
		local diff = total - PROB_SCALE
		
		while diff > 0 do
			local best_i, best_v = 1, 0
			
			for i = 1, 256 do
				if norm_freqs[i] > 1 and norm_freqs[i] > best_v then
					best_v, best_i = norm_freqs[i], i
				end
			end
			
			norm_freqs[best_i] -= 1
			diff -= 1
		end
	end
	
	local head_buf = buffer.create(1024)
	buffer.writeu8(head_buf, 0, active_count - 1)
	local head_ptr = 1
	
	for k = 1, active_count do
		local s = active_syms[k]
		local f = norm_freqs[s]

		buffer.writeu8(head_buf, head_ptr, s - 1)
		head_ptr += 1
		
		if f < 128 then
			buffer.writeu8(head_buf, head_ptr, f)
			head_ptr += 1
		else
			buffer.writeu8(head_buf, head_ptr, bit32.bor(0x80, bit32.rshift(f, 8)))
			buffer.writeu8(head_buf, head_ptr + 1, bit32.band(f, 0xFF))
			head_ptr += 2
		end
	end

	local starts = table.create(256)
	local run = 0
	
	for k = 1, 256 do
		starts[k] = run
		run += norm_freqs[k]
	end

	local out_cap = n + 256 
	local out_buf = buffer.create(out_cap)
	local ptr = out_cap

	local state = 0x800000

	for k = n - 1, 0, -1 do
		local sym = buffer.readu8(src, k) + 1
		local freq = norm_freqs[sym]
		local start = starts[sym]

		local x_max = 524288 * freq
		while state >= x_max do
			ptr = ptr - 1
			buffer.writeu8(out_buf, ptr, state)
			state = bit32.rshift(state, 8)
		end

		state = bit32.lshift(state // freq, PROB_BITS) + (state % freq) + start
	end

	local stream_len = out_cap - ptr

	local final_size = 8 + head_ptr + stream_len
	local final = buffer.create(final_size)

	buffer.writeu32(final, 0, n)
	buffer.writeu32(final, 4, state)

	buffer.copy(final, 8, head_buf, 0, head_ptr)
	buffer.copy(final, 8 + head_ptr, out_buf, ptr, stream_len)

	return final
end

local function decompress(src: buffer): buffer
	local len = buffer.len(src)
	if len < 8 then return buffer.create(0) end

	local out_size = buffer.readu32(src, 0)
	if out_size == 0 then return buffer.create(0) end

	local state = buffer.readu32(src, 4)

	local map_sym = buffer.create(4096)
	local map_freq = table.create(4096) 
	local map_start = table.create(4096)

	local offset = 8
	local active_count = buffer.readu8(src, offset) + 1
	offset += 1

	local cum_freq = 0

	for _ = 1, active_count do
		local sym = buffer.readu8(src, offset)
		offset += 1

		local freq = buffer.readu8(src, offset)
		offset += 1

		if freq >= 128 then
			local low = buffer.readu8(src, offset)
			offset += 1
			freq = bit32.lshift(bit32.band(freq, 127), 8) + low
		end

		for i = 0, freq - 1 do
			local slot = cum_freq + i
			buffer.writeu8(map_sym, slot, sym)
			map_freq[slot] = freq
			map_start[slot] = cum_freq
		end

		cum_freq += freq
	end

	local out_buf = buffer.create(out_size)

	for i = 0, out_size - 1 do
		local slot = bit32.band(state, 4095)

		local sym = buffer.readu8(map_sym, slot)
		local freq = map_freq[slot]
		local start = map_start[slot]

		buffer.writeu8(out_buf, i, sym)

		state = freq * bit32.rshift(state, PROB_BITS) + slot - start

		while state < 0x800000 do
			state = bit32.lshift(state, 8) + buffer.readu8(src, offset)
			offset += 1
		end
	end

	return out_buf
end

return {
	compress = compress,
	decompress = decompress
}
