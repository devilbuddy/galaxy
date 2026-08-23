--- Delaunay triangulation by Bowyer-Watson incremental insertion.
--
-- The triangulation is the backbone of the lane network. Its useful property
-- here is planarity: no two Delaunay edges cross, so *any* subset of them is
-- also non-crossing. That is what lets the pruning step below throw edges away
-- freely without ever producing lanes that visually intersect.

local M = {}

local abs, huge = math.abs, math.huge

--- Circumcentre and squared circumradius of a triangle, or nil if degenerate.
local function circumcircle(ax, ay, bx, by, cx, cy)
	local d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
	if abs(d) < 1e-14 then return nil end
	local a2 = ax * ax + ay * ay
	local b2 = bx * bx + by * by
	local c2 = cx * cx + cy * cy
	local ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
	local uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
	local dx, dy = ax - ux, ay - uy
	return ux, uy, dx * dx + dy * dy
end

--- Triangulate `pts` (an array of {x=, y=}).
-- Returns an array of triangles as {a, b, c} index triples.
function M.triangulate(pts)
	local n = #pts
	if n < 3 then return {} end

	-- A super-triangle that strictly contains every point. Working on a copy
	-- means the caller's array is never mutated.
	local minx, miny, maxx, maxy = huge, huge, -huge, -huge
	for i = 1, n do
		local p = pts[i]
		if p.x < minx then minx = p.x end
		if p.y < miny then miny = p.y end
		if p.x > maxx then maxx = p.x end
		if p.y > maxy then maxy = p.y end
	end
	local dx, dy = maxx - minx, maxy - miny
	local span = (dx > dy and dx or dy)
	if span < 1e-9 then span = 1 end
	local cx, cy = (minx + maxx) * 0.5, (miny + maxy) * 0.5
	-- 20x is far more headroom than needed, but the cost is three vertices and
	-- it removes any chance of a point landing outside the hull.
	local m = span * 20

	local v = {}
	for i = 1, n do v[i] = pts[i] end
	v[n + 1] = { x = cx - m, y = cy - m }
	v[n + 2] = { x = cx + m, y = cy - m }
	v[n + 3] = { x = cx, y = cy + m }

	local function make(a, b, c)
		local ux, uy, r2 = circumcircle(v[a].x, v[a].y, v[b].x, v[b].y, v[c].x, v[c].y)
		if not ux then return nil end
		return { a = a, b = b, c = c, ux = ux, uy = uy, r2 = r2 }
	end

	local tris = { make(n + 1, n + 2, n + 3) }

	-- Reused between insertions to keep the inner loop allocation-free.
	local edges = {}

	for i = 1, n do
		local px, py = v[i].x, v[i].y
		local ecount = 0

		-- Collect the boundary of the cavity of triangles this point invalidates.
		-- Iterating backwards lets us swap-pop bad triangles in the same pass.
		for t = #tris, 1, -1 do
			local tri = tris[t]
			local ddx, ddy = px - tri.ux, py - tri.uy
			if ddx * ddx + ddy * ddy <= tri.r2 then
				-- Push all three edges with their endpoints ordered, so the same
				-- shared edge from two triangles compares equal.
				local a, b, c = tri.a, tri.b, tri.c
				local e1a, e1b = (a < b) and a or b, (a < b) and b or a
				local e2a, e2b = (b < c) and b or c, (b < c) and c or b
				local e3a, e3b = (c < a) and c or a, (c < a) and a or c
				edges[ecount + 1] = e1a; edges[ecount + 2] = e1b
				edges[ecount + 3] = e2a; edges[ecount + 4] = e2b
				edges[ecount + 5] = e3a; edges[ecount + 6] = e3b
				ecount = ecount + 6
				tris[t] = tris[#tris]
				tris[#tris] = nil
			end
		end

		-- Edges shared by two removed triangles are interior to the cavity;
		-- only the ones appearing exactly once form its boundary.
		for e = 1, ecount, 2 do
			local ea, eb = edges[e], edges[e + 1]
			if ea then
				local shared = false
				for f = e + 2, ecount, 2 do
					if edges[f] == ea and edges[f + 1] == eb then
						edges[f] = false
						shared = true
					end
				end
				if not shared then
					local tri = make(ea, eb, i)
					if tri then tris[#tris + 1] = tri end
				end
			end
		end
		for e = 1, ecount do edges[e] = nil end
	end

	-- Drop anything still attached to the super-triangle.
	local out = {}
	for t = 1, #tris do
		local tri = tris[t]
		if tri.a <= n and tri.b <= n and tri.c <= n then
			out[#out + 1] = { tri.a, tri.b, tri.c }
		end
	end
	return out
end

--- Unique undirected edges of a triangulation, as {a, b} with a < b.
-- Returned in a deterministic order (sorted), independent of triangle order.
function M.edges(tris)
	local seen = {}
	local out = {}
	local function add(a, b)
		if a > b then a, b = b, a end
		local key = a * 1048576 + b
		if not seen[key] then
			seen[key] = true
			out[#out + 1] = { a, b }
		end
	end
	for i = 1, #tris do
		local t = tris[i]
		add(t[1], t[2]); add(t[2], t[3]); add(t[3], t[1])
	end
	table.sort(out, function(p, q)
		if p[1] ~= q[1] then return p[1] < q[1] end
		return p[2] < q[2]
	end)
	return out
end

return M
