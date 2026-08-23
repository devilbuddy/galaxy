--- Variable-radius Poisson-disc sampling (Bridson's algorithm).
--
-- Poisson-disc gives the "evenly scattered but not gridlike" distribution that
-- reads as a star map; pure uniform random produces clumps and voids that look
-- like a mistake. The variable-radius extension lets the galaxy's density field
-- drive local spacing, so the core packs tightly and the rim thins out.

local M = {}

local floor, sqrt, min, max = math.floor, math.sqrt, math.min, math.max

--- Sample points into the box [-1,1]^2, honouring a per-point minimum distance.
--
-- @param r          rng stream to draw from
-- @param spacing_fn function(x, y) -> minimum distance required around (x, y)
-- @param accept_fn  function(x, y) -> [0,1] probability the point is kept
-- @param rmin/rmax  bounds on what spacing_fn can return, used to size the grid
-- @param k          candidates tried per active point before it is retired
function M.sample(r, spacing_fn, accept_fn, rmin, rmax, k)
	k = k or 24

	-- Grid cell sized so a cell can hold at most one point at the *tightest*
	-- spacing, which makes the neighbour query a small fixed-radius box scan.
	local cell = rmin / sqrt(2)
	local lo, hi = -1.0, 1.0
	local dim = floor((hi - lo) / cell) + 1
	local grid = {}

	-- How many cells out we must look: the largest disc any existing point
	-- could project. Rounded up so the scan can never miss a conflict.
	local reach = floor(rmax / cell) + 1

	local points = {}
	local active = {}

	local function grid_key(gx, gy)
		return gy * dim + gx
	end

	local function insert(x, y, radius)
		points[#points + 1] = { x = x, y = y, r = radius }
		local idx = #points
		local gx = floor((x - lo) / cell)
		local gy = floor((y - lo) / cell)
		grid[grid_key(gx, gy)] = idx
		return idx
	end

	--- True if (x, y) is far enough from every existing point.
	local function fits(x, y, radius)
		local gx = floor((x - lo) / cell)
		local gy = floor((y - lo) / cell)
		local x0, x1 = max(0, gx - reach), min(dim - 1, gx + reach)
		local y0, y1 = max(0, gy - reach), min(dim - 1, gy + reach)
		for cy = y0, y1 do
			local row = cy * dim
			for cx = x0, x1 do
				local idx = grid[row + cx]
				if idx then
					local p = points[idx]
					local dx, dy = p.x - x, p.y - y
					-- Symmetric test: respect whichever point wants more room,
					-- otherwise a dense point can crowd a sparse neighbour.
					local need = max(radius, p.r)
					if dx * dx + dy * dy < need * need then return false end
				end
			end
		end
		return true
	end

	-- Seed the front from the densest place we can cheaply find, so growth
	-- starts in the core and spreads outward.
	local seed_x, seed_y, best = 0, 0, -1
	for _ = 1, 64 do
		local x, y = r:in_disc()
		local d = accept_fn(x, y)
		if d > best then best, seed_x, seed_y = d, x, y end
	end
	active[#active + 1] = insert(seed_x, seed_y, spacing_fn(seed_x, seed_y))

	while #active > 0 do
		-- Pick a random active point rather than the newest: front-of-queue
		-- selection biases growth into a spreading blob with a visible frontier.
		local ai = r:int(1, #active)
		local parent = points[active[ai]]
		local placed = false

		for _ = 1, k do
			-- Candidate in the annulus [pr, 2*pr] around the parent.
			local ux, uy = r:in_disc()
			local ulen = sqrt(ux * ux + uy * uy)
			if ulen > 1e-6 then
				local dist = parent.r * (1 + r:float())
				local x = parent.x + (ux / ulen) * dist
				local y = parent.y + (uy / ulen) * dist
				if x > lo and x < hi and y > lo and y < hi then
					local radius = spacing_fn(x, y)
					if fits(x, y, radius) then
						active[#active + 1] = insert(x, y, radius)
						placed = true
						break
					end
				end
			end
		end

		if not placed then
			-- Retire by swapping with the tail: O(1), and the resulting order
			-- change is deterministic because the index came from our own rng.
			active[ai] = active[#active]
			active[#active] = nil
		end
	end

	-- Thin the field by density. Sampling already varies spacing, but rejection
	-- is what carves the actual holes and frayed rim.
	local kept = {}
	for i = 1, #points do
		local p = points[i]
		if r:float() < accept_fn(p.x, p.y) then
			kept[#kept + 1] = { x = p.x, y = p.y }
		end
	end
	return kept
end

return M
