--- Carving the map into contiguous regions.
--
-- Everything here is generic over `pts` (anything with `.x`/`.y`), an edge list
-- of index pairs, and an adjacency list. That is why it needed no changes when
-- the substrate went from a pruned Delaunay lane network to a hex lattice.

local M = {}

local sqrt, floor = math.sqrt, math.floor

--- Adjacency lists from an edge list.
--
-- On the hex map the edges are the six neighbours, so this is a formatting step
-- rather than a graph decision - but it stays here because the region carver
-- below is written against `pts + edges + adj` and works on any graph, which is
-- exactly what let it survive the move off the star map untouched.
--
-- What used to live above this line was `lengths`, `mst` and `prune`: Kruskal
-- and a degree-targeted thinning pass that turned a Delaunay triangulation into
-- a lane network. A lattice has no arbitrary connections to choose, so all three
-- went with the triangulation.
function M.adjacency(n, lanes)
	local adj = {}
	for i = 1, n do adj[i] = {} end
	for i = 1, #lanes do
		local a, b = lanes[i][1], lanes[i][2]
		adj[a][#adj[a] + 1] = b
		adj[b][#adj[b] + 1] = a
	end
	for i = 1, n do table.sort(adj[i]) end
	return adj
end

--- Is every star reachable from star 1?
function M.is_connected(n, adj)
	if n == 0 then return true end
	local seen, stack, count = { [1] = true }, { 1 }, 1
	while #stack > 0 do
		local v = stack[#stack]; stack[#stack] = nil
		local nb = adj[v]
		for i = 1, #nb do
			if not seen[nb[i]] then
				seen[nb[i]] = true
				count = count + 1
				stack[#stack + 1] = nb[i]
			end
		end
	end
	return count == n, count
end

--- Choose `k` spread-out seed stars, k-means++ style.
--
-- Strict farthest-point sampling drives every seed onto the rim, because the
-- extremes are always the farthest thing from anything already chosen. That
-- leaves the dense core unclaimed by any nearby seed and it all collapses into
-- one enormous region. Sampling proportional to squared distance keeps the
-- seeds well spread while still letting them land in populated space.
local function spread_seeds(r, pts, k)
	local n = #pts
	k = k < n and k or n
	local seeds = { r:int(1, n) }
	local best = {}
	for i = 1, n do
		local dx, dy = pts[i].x - pts[seeds[1]].x, pts[i].y - pts[seeds[1]].y
		best[i] = dx * dx + dy * dy
	end
	for _ = 2, k do
		local total = 0
		for i = 1, n do total = total + best[i] end
		local pick = n
		if total > 0 then
			local roll, acc = r:float() * total, 0
			for i = 1, n do
				acc = acc + best[i]
				if roll < acc then pick = i; break end
			end
		else
			pick = r:int(1, n)
		end
		seeds[#seeds + 1] = pick
		for i = 1, n do
			local dx, dy = pts[i].x - pts[pick].x, pts[i].y - pts[pick].y
			local d = dx * dx + dy * dy
			if d < best[i] then best[i] = d end
		end
	end
	return seeds
end

--- Partition stars into contiguous regions of comparable size.
--
-- Plain multi-source Dijkstra produces wildly lopsided regions: whichever seed
-- sits nearest the galactic core claims most of the map. So growth is balanced
-- instead - at every step the region that currently owns the fewest stars takes
-- the cheapest star on its own frontier. Expanding only along lanes keeps each
-- region contiguous in travel terms, and the balancing keeps them playable.
function M.regions(r, pts, lanes, adj, k)
	local n = #pts
	local seeds = spread_seeds(r, pts, k)

	-- Nested tables keyed by vertex index, as in delaunay.edges.
	local cost = {}
	for i = 1, #lanes do
		local ia, ib = lanes[i][1], lanes[i][2]
		local a, b = pts[ia], pts[ib]
		local dx, dy = a.x - b.x, a.y - b.y
		local row = cost[ia]
		if not row then
			row = {}
			cost[ia] = row
		end
		row[ib] = sqrt(dx * dx + dy * dy)
	end
	local function lane_cost(a, b)
		if a > b then
			local swap = a
			a = b
			b = swap
		end
		local row = cost[a]
		return (row and row[b]) or 0
	end

	local owner = {}
	for i = 1, n do owner[i] = 0 end

	-- One frontier per region, each a flat list of {star, distance}. They stay
	-- short enough that scanning for the minimum costs less than a heap would.
	local frontier, size = {}, {}
	for s = 1, #seeds do
		frontier[s] = {}
		size[s] = 0
	end

	local claimed = 0
	local function claim(star, region, dist)
		owner[star] = region
		size[region] = size[region] + 1
		claimed = claimed + 1
		local nb = adj[star]
		for i = 1, #nb do
			if owner[nb[i]] == 0 then
				local f = frontier[region]
				f[#f + 1] = { nb[i], dist + lane_cost(star, nb[i]) }
			end
		end
	end

	for s = 1, #seeds do
		if owner[seeds[s]] == 0 then claim(seeds[s], s, 0) end
	end

	while claimed < n do
		-- Smallest region first; ties go to the lower index so the sweep order
		-- never depends on table iteration.
		local pick, picksize = nil, math.huge
		for s = 1, #seeds do
			if #frontier[s] > 0 and size[s] < picksize then
				pick, picksize = s, size[s]
			end
		end
		if not pick then break end

		local f = frontier[pick]
		local bi, bd = nil, math.huge

		-- Drop stale entries (stars another region already took) by compacting
		-- in place. Swap-popping inside the loop would not work: Lua evaluates
		-- a numeric for's limit once, so the index runs off the shrunk array.
		local w = 0
		for i = 1, #f do
			local e = f[i]
			if owner[e[1]] == 0 then
				w = w + 1
				f[w] = e
			end
		end
		for i = #f, w + 1, -1 do f[i] = nil end

		for i = 1, #f do
			if f[i][2] < bd then bi, bd = i, f[i][2] end
		end
		if bi then
			local star = f[bi][1]
			f[bi] = f[#f]; f[#f] = nil
			claim(star, pick, bd)
		end
	end

	-- Only reachable if the lane graph is disconnected; fall back to geometry.
	for i = 1, n do
		if owner[i] == 0 then
			local bs, bd = 1, math.huge
			for s = 1, #seeds do
				local dx, dy = pts[i].x - pts[seeds[s]].x, pts[i].y - pts[seeds[s]].y
				local d = dx * dx + dy * dy
				if d < bd then bs, bd = s, d end
			end
			owner[i] = bs
		end
	end

	return owner, seeds
end

--- Which regions touch which, via lanes that cross a border.
function M.region_adjacency(owner, lanes, k)
	local adj = {}
	for i = 1, k do adj[i] = {} end
	for i = 1, #lanes do
		local ra, rb = owner[lanes[i][1]], owner[lanes[i][2]]
		if ra ~= rb and ra > 0 and rb > 0 then
			adj[ra][rb] = true
			adj[rb][ra] = true
		end
	end
	local out = {}
	for i = 1, k do
		local list = {}
		for j in pairs(adj[i]) do list[#list + 1] = j end
		table.sort(list) -- pairs() order is undefined; sorting restores determinism
		out[i] = list
	end
	return out
end

--- Greedy graph colouring so no two bordering regions share a palette entry.
function M.colour_regions(radj, palette_size, k)
	-- Colour the most-constrained regions first: standard Welsh-Powell, which
	-- keeps the number of colours needed close to the minimum.
	local order = {}
	for i = 1, k do order[i] = i end
	table.sort(order, function(p, q)
		if #radj[p] ~= #radj[q] then return #radj[p] > #radj[q] end
		return p < q
	end)

	local colour = {}
	for oi = 1, #order do
		local i = order[oi]
		local taken = {}
		for _, j in ipairs(radj[i]) do
			if colour[j] then taken[colour[j]] = true end
		end
		local pick = 1
		for c = 1, palette_size do
			if not taken[c] then pick = c; break end
		end
		colour[i] = pick
	end
	return colour
end

return M
