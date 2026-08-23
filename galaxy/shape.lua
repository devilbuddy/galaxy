--- The galaxy's density field: where stars are likely to exist, and how tightly.
--
-- Generation samples this in two ways. `density` drives rejection (is there a
-- star here at all?) and `spacing` drives the Poisson-disc radius (how far
-- apart are stars here?). Coupling both to the same field is what produces a
-- crowded core and a thin rim instead of a uniform field with holes punched in
-- it.

local rng = require("galaxy.rng")
local noise = require("galaxy.noise")

local M = {}

local Shape = {}
Shape.__index = Shape

--- Signed "armness" in [0, 1]: how close a point is to the ridge of a spiral arm.
local function arm_strength(self, x, y)
	local r = math.sqrt(x * x + y * y)
	if r < 1e-6 then return 1.0 end
	local theta = math.atan2(y, x)
	-- A logarithmic spiral has theta = ln(r) / tan(pitch); the arm ridge is
	-- wherever the point's angle matches that, modulo the arm spacing.
	local spiral = math.log(math.max(r, 0.02)) / self.tightness
	local best = 0
	local spacing = (2 * math.pi) / self.arms
	for i = 0, self.arms - 1 do
		local offset = theta - spiral - i * spacing - self.arm_phase
		-- Wrap the angular error into [-pi, pi].
		offset = offset - (2 * math.pi) * math.floor(offset / (2 * math.pi) + 0.5)
		-- Arms widen towards the rim, otherwise they pinch to invisibility.
		local width = self.arm_width * (0.45 + 0.85 * r)
		local falloff = math.exp(-(offset * offset) / (2 * width * width))
		if falloff > best then best = falloff end
	end
	return best
end

--- Unnormalised density. Its peak varies unpredictably with the rolled
-- parameters, which is why `density` divides it out.
function Shape:raw_density(x, y)
	local r = math.sqrt(x * x + y * y)
	if r > 1.0 then return 0 end

	-- Radial envelope: a bright bulge that decays into a disc, then a soft edge
	-- so the rim frays instead of ending on a clean circle.
	local bulge = math.exp(-(r * r) / (2 * self.core * self.core))
	local disc = math.exp(-r / self.scale_length)
	local edge = 1.0 - M.smoothstep(self.rim_start, 1.0, r)
	local radial = (self.core_weight * bulge + (1 - self.core_weight) * disc) * edge

	-- Spiral structure, blended rather than multiplied so inter-arm space keeps
	-- some stars (a galaxy with empty gaps reads as a pinwheel, not a map).
	local arm = arm_strength(self, x, y)
	local structure = self.inter_arm + (1 - self.inter_arm) * arm

	-- Irregularity. Kept deliberately mild: strong noise washes the spiral
	-- structure out into an even disc, which is exactly what it looked like
	-- before this was toned down.
	local lumps = noise.fbm(self.noise_seed, x * self.lump_scale + 100, y * self.lump_scale + 100, 4)
	local irregular = 0.72 + 0.58 * lumps

	local d = radial * structure * irregular
	return d < 0 and 0 or d
end

--- Density in [0, 1], normalised so every seed peaks at 1.0.
--
-- Without this, the rolled parameters move the peak by 2-3x between seeds and
-- any threshold expressed in density units (the rim cutoff, the spacing curve)
-- would mean something different for each galaxy.
function Shape:density(x, y)
	local d = self:raw_density(x, y) * self.norm
	return d > 1 and 1 or d
end

--- Probability a sampled point survives. This is the *only* place density
-- thins the field: spacing already handles how tightly packed it is, so
-- rejecting by density again would compound the falloff and empty the map.
-- Its job is just to cut the faint rim off with a soft, frayed edge.
function Shape:acceptance(x, y)
	return M.smoothstep(self.cutoff_lo, self.cutoff_hi, self:density(x, y))
end

--- Poisson-disc radius at a point, in normalised units.
--
-- Number density per unit area is proportional to `density`, and points packed
-- at spacing s have area density ~1/s^2, so s must go as 1/sqrt(density). An
-- earlier version lerped between rmin and rmax by sqrt(density), which is a far
-- flatter curve and flattened the galaxy into a featureless even disc.
function Shape:spacing(x, y, rmin, rmax)
	local d = self:density(x, y)
	if d < 1e-4 then return rmax end
	local s = rmin / math.sqrt(d)
	return s > rmax and rmax or s
end

--- Standard smoothstep, exposed because both this module and the caller need it.
function M.smoothstep(edge0, edge1, x)
	if edge1 == edge0 then return x < edge0 and 0 or 1 end
	local t = (x - edge0) / (edge1 - edge0)
	t = t < 0 and 0 or (t > 1 and 1 or t)
	return t * t * (3 - 2 * t)
end

--- Roll a galaxy shape from a seed.
function M.new(seed, cfg)
	cfg = cfg or {}
	local r = rng.stream(seed, "shape")
	local self = setmetatable({}, Shape)
	self.noise_seed = r:u32()
	self.arms = cfg.arms or r:int(2, 4)
	-- Pitch angle of the spiral: smaller is a tighter wind.
	self.tightness = cfg.tightness or r:range(0.30, 0.62)
	self.arm_phase = r:range(0, 2 * math.pi)
	self.arm_width = cfg.arm_width or r:range(0.38, 0.58)
	-- How much of the galaxy survives between the arms.
	self.inter_arm = cfg.inter_arm or r:range(0.24, 0.42)
	self.core = cfg.core or r:range(0.13, 0.22)
	self.core_weight = cfg.core_weight or r:range(0.42, 0.62)
	self.scale_length = cfg.scale_length or r:range(0.36, 0.52)
	self.rim_start = cfg.rim_start or r:range(0.72, 0.90)
	self.lump_scale = cfg.lump_scale or r:range(2.4, 4.2)
	-- Below cutoff_lo nothing survives; above cutoff_hi everything does.
	self.cutoff_lo = cfg.cutoff_lo or 0.035
	self.cutoff_hi = cfg.cutoff_hi or 0.20

	-- Estimate the peak on a fixed grid. Fixed resolution keeps this
	-- deterministic, and a slight underestimate is harmless: density() clamps.
	self.norm = 1.0
	local peak = 0
	local N = 72
	for i = 0, N do
		for j = 0, N do
			local x = (i / N) * 2 - 1
			local y = (j / N) * 2 - 1
			if x * x + y * y <= 1 then
				local d = self:raw_density(x, y)
				if d > peak then peak = d end
			end
		end
	end
	self.norm = peak > 1e-9 and (1.0 / peak) or 1.0
	return self
end

return M
