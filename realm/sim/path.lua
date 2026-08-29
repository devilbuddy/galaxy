--- Shortest paths across the map.
--
-- Commanders never move in straight lines; they walk from tile to neighbouring
-- tile, which is what makes an isthmus or a mountain pass matter.
--
-- **Breadth-first, because every step costs exactly one.** On a hex lattice the
-- six neighbours are all `sqrt(3) * hex_size` away, so there is nothing for a
-- weighted search to weigh. The tile map needed Dijkstra with a length tiebreak
-- because its tiles ran anywhere from 60 to 200 world units and the
-- geometrically shortest route could be one tile longer - and therefore a whole
-- turn slower - than the alternative. That whole class of problem is gone: a
-- four-tile route takes four turns, countable off the map, which is the property
-- discrete movement was introduced to get and the lattice now gives for free.
--
-- Determinism comes from the frontier order, not from a tiebreak.
-- `realm.adjacency` is sorted ascending when it is built (realm/graph.lua), so
-- neighbours are always visited in the same order and the same route is found
-- every time, on every runtime.

local M = {}

--- Cheapest path from `from` to `to`, as an array of tiles *excluding* the
--- origin. Returns nil when unreachable or when it would exceed `max_hops`.
--
-- Unreachable is a real answer here rather than a defensive one: the sea is not
-- in the graph at all, so "no path" is what a player gets for trying to march
-- across a bay. Nothing else in the simulation needs to know water exists.
function M.find(realm, from, to, max_hops)
	if from == to then return {} end

	local prev, seen = {}, { [from] = true }
	local frontier, hops = { from }, 0

	while #frontier > 0 do
		if max_hops and hops >= max_hops then return nil end
		hops = hops + 1
		local next_frontier = {}
		for i = 1, #frontier do
			local u = frontier[i]
			local neighbours = realm.adjacency[u]
			for k = 1, #neighbours do
				local v = neighbours[k]
				if not seen[v] then
					seen[v] = true
					prev[v] = u
					if v == to then
						-- Walk the parents back. The first time BFS reaches a
						-- tile is along a shortest path, so this needs no
						-- relaxation pass.
						local path, node = {}, to
						while node ~= from do
							table.insert(path, 1, node)
							node = prev[node]
							if not node then return nil end
						end
						return path
					end
					next_frontier[#next_frontier + 1] = v
				end
			end
		end
		frontier = next_frontier
	end

	return nil
end

return M
