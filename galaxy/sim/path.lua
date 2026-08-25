--- Shortest paths along hyperlanes.
--
-- Fleets never move in straight lines; they follow the lane graph, which is
-- what makes chokepoints and border systems matter.

local M = {}

local sqrt, huge = math.sqrt, math.huge

--- Lane lengths as a nested lookup, built once per galaxy.
-- Nested rather than a packed `a * 2^20 + b` key, matching galaxy/graph.lua.
function M.lane_lengths(galaxy)
	local lengths = {}
	for i = 1, #galaxy.lanes do
		local lane = galaxy.lanes[i]
		local a, b = lane.a, lane.b
		local row = lengths[a]
		if not row then
			row = {}
			lengths[a] = row
		end
		row[b] = lane.length
		row = lengths[b]
		if not row then
			row = {}
			lengths[b] = row
		end
		row[a] = lane.length
	end
	return lengths
end

--- Distance along the lane joining two adjacent systems, or nil if none.
function M.lane_length(lengths, a, b)
	local row = lengths[a]
	return row and row[b]
end

--- Cheapest path from `from` to `to`, as an array of systems *excluding* the
--- origin. Returns nil when unreachable or when it would exceed `max_hops`.
--
-- Dijkstra with a linear scan for the minimum: the frontier stays small at this
-- graph size, and a heap would cost more bookkeeping than it saves.
-- Small enough that no accumulation of it can ever outweigh one whole lane:
-- the longest conceivable route is a few thousand world units, and this scales
-- that under one.
local TIEBREAK = 1e-6

function M.find(galaxy, lengths, from, to, max_hops)
	if from == to then return {} end
	local n = #galaxy.stars
	local dist, prev, hops, done = {}, {}, {}, {}
	for i = 1, n do dist[i] = huge end
	dist[from] = 0
	hops[from] = 0

	for _ = 1, n do
		local u, ud = nil, huge
		for i = 1, n do
			if not done[i] and dist[i] < ud then u, ud = i, dist[i] end
		end
		if not u then break end
		if u == to then break end
		done[u] = true

		local neighbours = galaxy.adjacency[u]
		for k = 1, #neighbours do
			local v = neighbours[k]
			if not done[v] then
				-- **Lanes, not distance.** A captain crosses a whole number of
				-- lanes a turn, so the cheapest route is the one with the
				-- fewest of them - the geometrically shortest path can easily
				-- be one lane longer and therefore a turn slower. Lane length
				-- is kept as a tiebreak so a route through the same number of
				-- lanes still prefers the tighter one, which reads better on
				-- the map.
				local step = 1 + (M.lane_length(lengths, u, v) or 0) * TIEBREAK
				local alt = ud + step
				if alt < dist[v] then
					dist[v] = alt
					prev[v] = u
					hops[v] = hops[u] + 1
				end
			end
		end
	end

	if dist[to] == huge then return nil end
	if max_hops and hops[to] and hops[to] > max_hops then return nil end

	local path, node = {}, to
	while node ~= from do
		table.insert(path, 1, node)
		node = prev[node]
		if not node then return nil end
	end
	return path
end

return M
