--- Deterministic 2D value noise.
--
-- Used to break up the analytic galaxy shape so the result looks irregular
-- rather than like a mathematical function. Value noise (rather than Perlin or
-- simplex) because it needs nothing but the integer hash we already have, and
-- its lower quality is invisible once it is only nudging a density mask.

local rng = require("galaxy.rng")

local floor = math.floor
local M = {}

--- Hash a lattice point to [0, 1).
local function lattice(seed, ix, iy)
	-- Fold the coordinates into the seed with two odd multipliers before the
	-- avalanche, so x and y stay independent.
	local h = rng.u32(seed + rng.mul32(ix % 4294967296, 374761393) + rng.mul32(iy % 4294967296, 668265263))
	h = rng.mul32(rng.u32(h + 2654435769), 2246822519)
	local bitlib = rawget(_G, "bit") or require("bit")
	h = rng.mul32(rng.u32(bitlib.bxor(h, bitlib.rshift(h, 15))), 3266489917)
	return rng.u32(bitlib.bxor(h, bitlib.rshift(h, 16))) / 4294967296
end

--- Quintic smoothstep: zero first *and* second derivative at the lattice, which
-- removes the visible grid creasing plain smoothstep leaves behind.
local function fade(t)
	return t * t * t * (t * (t * 6 - 15) + 10)
end

--- Value noise in [0, 1) at a point.
function M.value(seed, x, y)
	local ix, iy = floor(x), floor(y)
	local fx, fy = x - ix, y - iy
	local u, v = fade(fx), fade(fy)
	local a = lattice(seed, ix, iy)
	local b = lattice(seed, ix + 1, iy)
	local c = lattice(seed, ix, iy + 1)
	local d = lattice(seed, ix + 1, iy + 1)
	local top = a + (b - a) * u
	local bottom = c + (d - c) * u
	return top + (bottom - top) * v
end

--- Fractal sum of `octaves` noise layers, each doubled in frequency and halved
-- in amplitude. Returns [0, 1).
function M.fbm(seed, x, y, octaves, lacunarity, gain)
	octaves = octaves or 4
	lacunarity = lacunarity or 2.0
	gain = gain or 0.5
	local sum, amp, norm, freq = 0, 1, 0, 1
	for i = 1, octaves do
		-- Offsetting the seed per octave keeps the layers from correlating.
		sum = sum + amp * M.value(rng.u32(seed + i * 1013904223), x * freq, y * freq)
		norm = norm + amp
		amp = amp * gain
		freq = freq * lacunarity
	end
	return sum / norm
end

return M
