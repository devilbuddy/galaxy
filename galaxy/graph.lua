--- Turning a triangulation into a playable lane network, and carving it into
--- contiguous regions.

local M = {}

local sqrt, floor = math.sqrt, math.floor

--- Euclidean length of every edge.
function M.lengths(pts, edges)
	local out = {}
	for i = 1, #edges do
		local a, b = pts[edges[i][1]], pts[edges[i][2]]
		local dx, dy = a.x - b.x, a.y - b.y
		out[i] = sqrt(dx * dx + dy * dy)
	end
	return out
end

--- Kruskal's minimum spanning tree. Returns a set keyed by edge index.
--
-- The MST is kept in full and unconditionally: it is the cheapest guarantee
-- that every star stays reachable no matter how aggressively the rest of the
-- triangulation is thinned.
function M.mst(n, edges, lengths)
	local order = {}
	for i = 1, #edges do order[i] = i end
	table.sort(order, function(p, q)
		if lengths[p] ~= lengths[q] then return lengths[p] < lengths[q] end
		-- Deterministic tiebreak: float equality between two edge lengths is
		-- rare but a seed that hits it must not reorder between runs.
		return p < q
	end)

	local parent = {}
	for i = 1, n do parent[i] = i end
	local function find(x)
		while parent[x] ~= x do
			parent[x] = parent[parent[x]] -- path halving
			x = parent[x]
		end
		return x
	end

	local keep, count = {}, 0
	for i = 1, #order do
		local e = order[i]
		local ra, rb = find(edges[e][1]), find(edges[e][2])
		if ra ~= rb then
			parent[ra] = rb
			keep[e] = true
			count = count + 1
			if count == n - 1 then break end
		end
	end
	return keep
end

--- Thin the triangulation down to a lane network of a target average degree.
--
-- @param opts.degree  target mean degree (edges per star * 2)
-- @param opts.jitter  how much randomness biases the short-edge preference
function M.prune(r, pts, edges, opts)
	local n = #pts
	local lengths = M.lengths(pts, edges)
	local mst = M.mst(n, edges, lengths)

	local target = floor(n * (opts.degree or 2.9) * 0.5 + 0.5)

	-- Score the optional edges. Sorting purely by length gives a suspiciously
	-- tidy lattice, so each length is perturbed before ranking: still strongly
	-- short-biased, but with the irregularity a hand-drawn map has.
	local jitter = opts.jitter or 0.45
	local optional = {}
	for i = 1, #edges do
		if not mst[i] then
			optional[#optional + 1] = { i, lengths[i] * r:range(1 - jitter, 1 + jitter) }
		end
	end
	table.sort(optional, function(p, q)
		if p[2] ~= q[2] then return p[2] < q[2] end
		return p[1] < q[1]
	end)

	local keep = {}
	local count = 0
	for i = 1, #edges do
		if mst[i] then keep[#keep + 1] = edges[i]; count = count + 1 end
	end
	for i = 1, #optional do
		if count >= target then break end
		keep[#keep + 1] = edges[optional[i][1]]
		count = count + 1
	end

	table.sort(keep, function(p, q)
		if p[1] ~= q[1] then return p[1] < q[1] end
		return p[2] < q[2]
	end)
	return keep
end

--- Adjacency lists, each sorted so downstream traversals are order-stable.
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

	local cost = {}
	for i = 1, #lanes do
		local a, b = pts[lanes[i][1]], pts[lanes[i][2]]
		local dx, dy = a.x - b.x, a.y - b.y
		cost[lanes[i][1] * 1048576 + lanes[i][2]] = sqrt(dx * dx + dy * dy)
	end
	local function lane_cost(a, b)
		if a > b then a, b = b, a end
		return cost[a * 1048576 + b] or 0
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
