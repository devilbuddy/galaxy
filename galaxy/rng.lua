--- Deterministic pseudo-random number generation.
--
-- Every value the generator produces must be identical on every platform and
-- every run, so this deliberately avoids `math.random` (implementation-defined,
-- and shared global state). Instead it implements SplitMix32 on top of two
-- primitives that are exact everywhere Defold runs:
--
--   * BitOp (`bit.*`), bundled with every Defold target, 32-bit signed.
--   * Double arithmetic on integers below 2^53, which IEEE-754 represents exactly.
--
-- Multiplication is the tricky part: a 32x32 bit product overflows the exact
-- range of a double, so `mul32` splits both operands into 16-bit halves and
-- discards the overflow that would be masked off anyway.

local bitlib = rawget(_G, "bit") or require("bit")
local bxor, rshift = bitlib.bxor, bitlib.rshift
local floor = math.floor

local TWO32 = 4294967296

local M = {}

--- Wrap a possibly-negative BitOp result back into [0, 2^32).
local function u32(x)
	return x % TWO32
end

--- Exact (a * b) mod 2^32 for a, b in [0, 2^32).
local function mul32(a, b)
	local ah, al = floor(a / 65536), a % 65536
	local bh, bl = floor(b / 65536), b % 65536
	-- The ah*bh term only contributes above bit 32, so it is dropped entirely.
	return (al * bl + ((ah * bl + al * bh) % 65536) * 65536) % TWO32
end

M.u32 = u32
M.mul32 = mul32

--- FNV-1a over a string, finished with an avalanche so near-identical labels
-- produce completely unrelated seeds.
function M.hash(str, seed)
	local h = u32(seed or 2166136261)
	for i = 1, #str do
		h = mul32(u32(bxor(h, str:byte(i))), 16777619)
	end
	h = mul32(u32(bxor(h, rshift(h, 16))), 2246822507)
	h = mul32(u32(bxor(h, rshift(h, 13))), 3266489909)
	return u32(bxor(h, rshift(h, 16)))
end

local Rng = {}
Rng.__index = Rng

--- Raw 32-bit output. Everything else is built on this.
function Rng:u32()
	local s = (self.s + 2654435769) % TWO32 -- 0x9E3779B9, the golden-ratio step
	self.s = s
	local z = s
	z = mul32(u32(bxor(z, rshift(z, 16))), 569420461) -- 0x21F0AAAD
	z = mul32(u32(bxor(z, rshift(z, 15))), 1935289751) -- 0x735A2D97
	return u32(bxor(z, rshift(z, 15)))
end

--- Uniform in [0, 1).
function Rng:float()
	return self:u32() / TWO32
end

--- Uniform in [lo, hi).
function Rng:range(lo, hi)
	return lo + (hi - lo) * self:float()
end

--- Uniform integer in [lo, hi], inclusive on both ends.
function Rng:int(lo, hi)
	return lo + floor(self:float() * (hi - lo + 1))
end

--- True with probability `p`.
function Rng:chance(p)
	return self:float() < p
end

--- A uniformly chosen element of an array.
function Rng:pick(list)
	return list[self:int(1, #list)]
end

--- Approximately normal, via the sum of 3 uniforms. Cheap, bounded to +/-3 sd,
-- and free of the trig that would risk platform-dependent rounding.
function Rng:gauss(mean, sd)
	local sum = self:float() + self:float() + self:float()
	return (mean or 0) + ((sum - 1.5) * 2) * (sd or 1)
end

--- A point uniformly distributed inside the unit disc.
function Rng:in_disc()
	-- Rejection sampling keeps this free of sqrt/trig rounding differences.
	for _ = 1, 32 do
		local x, y = self:range(-1, 1), self:range(-1, 1)
		if x * x + y * y <= 1 then return x, y end
	end
	return 0, 0
end

--- Pick an index from an array of weights. `total` is optional and precomputed.
function Rng:weighted(weights, total)
	if not total then
		total = 0
		for i = 1, #weights do total = total + weights[i] end
	end
	local roll = self:float() * total
	local acc = 0
	for i = 1, #weights do
		acc = acc + weights[i]
		if roll < acc then return i end
	end
	return #weights
end

--- In-place Fisher-Yates.
function Rng:shuffle(list)
	for i = #list, 2, -1 do
		local j = self:int(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

--- Construct a generator from a numeric seed.
function M.new(seed)
	return setmetatable({ s = u32(floor(seed or 0)) }, Rng)
end

--- Construct an independent generator for one subsystem.
--
-- Deriving a named stream per subsystem means adding, removing or reordering a
-- subsystem cannot shift the numbers every *other* subsystem sees, so a given
-- seed keeps producing the same star positions even as the generator grows.
function M.stream(seed, label)
	return M.new(M.hash(label, u32(floor(seed or 0))))
end

return M
