--- Star positions: Poisson-disc sampling tuned to hit a requested star count.
--
-- The raw sampler is parameterised by spacing, but "how many systems" is the
-- knob a designer actually wants. Solving for spacing keeps the density field's
-- *shape* intact while letting the caller ask for a specific size of galaxy.

local rng = require("galaxy.rng")
local poisson = require("galaxy.poisson")

local M = {}

-- Spacing at peak density, before the scale factor is solved for.
local BASE_TIGHT = 0.030
-- Spacing where density falls to zero. The ratio to BASE_TIGHT sets how much
-- more open the rim looks than the core.
local BASE_LOOSE = 4.5 * BASE_TIGHT

--- Sample once at a given spacing scale.
local function sample_at(seed, shape, scale)
	-- A fresh stream per attempt, seeded identically, so the search itself
	-- cannot leak into the result: the same scale always yields the same points.
	local r = rng.stream(seed, "points")
	local tight, loose = BASE_TIGHT * scale, BASE_LOOSE * scale
	return poisson.sample(r,
		function(x, y) return shape:spacing(x, y, tight, loose) end,
		function(x, y) return shape:acceptance(x, y) end,
		tight, loose)
end

--- Generate approximately `target` star positions in the unit disc.
--
-- Count scales roughly as 1/scale^2, so the search works in that space and
-- converges in a handful of steps.
function M.generate(seed, shape, target, tolerance)
	tolerance = tolerance or 0.06

	local scale = 1.0
	local best, best_err = nil, math.huge
	local passes = 0

	-- Bracket first: walk the scale until the count straddles the target.
	local lo, hi = 0.25, 4.0
	for _ = 1, 12 do
		passes = passes + 1
		local pts = sample_at(seed, shape, scale)
		local n = #pts
		local err = math.abs(n - target) / target
		if err < best_err then best, best_err = pts, err end
		if best_err <= tolerance then break end

		if n > target then
			-- Too many points: spread them out.
			lo = scale
		else
			hi = scale
		end
		-- First few steps use the analytic 1/scale^2 relation, which lands
		-- close immediately; afterwards fall back to bisection for safety.
		local predicted = scale * math.sqrt(n / target)
		if predicted > lo and predicted < hi then
			scale = predicted
		else
			scale = (lo + hi) * 0.5
		end
	end

	return best, scale, passes
end

return M
