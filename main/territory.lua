--- Territory as a political map: provinces that tile, never overlap.
--
-- Each system owns its Voronoi cell - the dual of the Delaunay triangulation
-- the lane network is already built from - and a player's territory is the
-- union of the cells of the systems they hold. That construction is what
-- makes the borders behave like a hand-drawn map's: two territories *share*
-- an edge instead of crossing, a province spanning several systems is one
-- shape with no interior seams, and the fill reaches exactly to the border.
--
-- The organic look is deterministic jitter: every Voronoi edge is subdivided
-- with midpoint displacement keyed on the *pair of systems it separates*, so
-- both adjacent cells displace it identically and the tiling holds. Cells on
-- the hull (or beside sparse ground) are closed with an arc capped at a
-- radius from their own system.
--
-- Pure Lua over plain tables, no engine calls - runnable under standalone
-- luajit (tools/test_territory.lua).

local delaunay = require("galaxy.delaunay")

local M = {}

-- Circumcentre of three points. delaunay.lua computes these internally but
-- returns bare index triples, so the dual has to rebuild them.
local function circumcentre(ax, ay, bx, by, cx, cy)
	local d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
	if math.abs(d) < 1e-9 then return nil end
	local a2, b2, c2 = ax * ax + ay * ay, bx * bx + by * by, cx * cx + cy * cy
	local ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
	local uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
	return ux, uy
end

-- Deterministic signed fraction in [-0.5, 0.5), from two small integers.
-- The same portable shape as the lane bulge hash: no bit ops, exact in doubles.
local function hash2(a, b)
	return ((a * 7919 + b * 104729) % 997) / 997 - 0.5
end

--- Midpoint-displace the segment (x1,y1)-(x2,y2), appending every point after
-- the first to `out`. `ka, kb` key the displacement; callers pass the ids of
-- the two systems the edge separates, canonically ordered, so both sides of a
-- shared border displace identically.
local function displace(x1, y1, x2, y2, ka, kb, depth, salt, out)
	if depth == 0 then
		out[#out + 1] = x2
		out[#out + 1] = y2
		return
	end
	local mx, my = (x1 + x2) * 0.5, (y1 + y2) * 0.5
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	if len > 1e-6 then
		local amp = hash2(ka * 3 + salt, kb * 5 + salt) * 0.24 * len
		mx = mx - dy / len * amp
		my = my + dx / len * amp
	end
	displace(x1, y1, mx, my, ka, kb, depth - 1, salt * 2 + 1, out)
	displace(mx, my, x2, y2, ka, kb, depth - 1, salt * 2 + 2, out)
end

--- The Delaunay triangles of a galaxy, memoised on it the way
-- `sim.systems.profile` memoises kinds: the triangulation never changes for a
-- seed, and rebuilding territory every turn must not pay for it twice.
function M.triangles(g)
	local cached = g.territory_triangles
	if cached then return cached end
	local tris = delaunay.triangulate(g.stars)
	g.territory_triangles = tris
	return tris
end

--- Build the owned provinces.
--
-- `owner_of(id)` returns the owning player (0/nil for none) and a visibility
-- alpha. Returns a list of cells, one per owned system:
--   { owner, alpha, poly = {x,y,...},         the cell outline, closed
--     strokes = { {x,y,...}, ... } }          the parts of it that border
--                                             another owner or open ground
function M.build(g, owner_of, cap_radius)
	local stars = g.stars
	local tris = M.triangles(g)

	-- Incident triangles per site, with centres clamped to the cap so sliver
	-- triangles' distant circumcentres cannot fling a cell across the map.
	local incident = {}
	local centres = {}
	for t = 1, #tris do
		local tri = tris[t]
		local pa, pb, pc = stars[tri[1]], stars[tri[2]], stars[tri[3]]
		local ux, uy = circumcentre(pa.x, pa.y, pb.x, pb.y, pc.x, pc.y)
		if ux then
			centres[t] = { ux, uy }
			for k = 1, 3 do
				local s = tri[k]
				incident[s] = incident[s] or {}
				local list = incident[s]
				list[#list + 1] = t
			end
		end
	end

	local cells = {}
	for id = 1, #stars do
		local owner, alpha = owner_of(id)
		local list = incident[id]
		if owner and owner > 0 and list and #list >= 2 then
			local sx, sy = stars[id].x, stars[id].y

			-- The cell fan: incident circumcentres sorted by angle around the
			-- site, clamped to the cap radius. Radial clamping cannot change
			-- the angle, so it is safe to clamp first.
			local fan = {}
			for i = 1, #list do
				local c = centres[list[i]]
				local dx, dy = c[1] - sx, c[2] - sy
				local d = math.sqrt(dx * dx + dy * dy)
				local x, y = c[1], c[2]
				if d > cap_radius then
					x = sx + dx / d * cap_radius
					y = sy + dy / d * cap_radius
				end
				fan[#fan + 1] = { ang = math.atan2(y - sy, x - sx),
					x = x, y = y, tri = list[i] }
			end
			table.sort(fan, function(a, b)
				if a.ang ~= b.ang then return a.ang < b.ang end
				return a.tri < b.tri
			end)

			local poly = {}
			local strokes = {}
			for i = 1, #fan do
				local a = fan[i]
				local b = fan[(i % #fan) + 1]
				poly[#poly + 1] = a.x
				poly[#poly + 1] = a.y

				-- The neighbour this stretch of border separates us from: the
				-- vertex the two triangles share besides the site itself.
				local ta, tb = tris[a.tri], tris[b.tri]
				local other = nil
				for m = 1, 3 do
					local v = ta[m]
					if v ~= id then
						for w = 1, 3 do
							if tb[w] == v then other = v end
						end
					end
				end

				local seg = { a.x, a.y }
				if other then
					-- A shared Voronoi edge. Displace it canonically - the
					-- lower endpoint first - so the neighbouring cell builds
					-- the same curve from its own side.
					local ka = math.min(id, other)
					local kb = math.max(id, other)
					local forward = id == ka
					local x1, y1, x2, y2 = a.x, a.y, b.x, b.y
					if not forward then
						x1, y1, x2, y2 = b.x, b.y, a.x, a.y
					end
					local pts = { x1, y1 }
					displace(x1, y1, x2, y2, ka, kb, 2, 1, pts)
					if not forward then
						-- Walk it back the way this cell travels.
						for p = #pts - 1, 1, -2 do
							seg[#seg + 1] = pts[p]
							seg[#seg + 1] = pts[p + 1]
						end
					else
						for p = 3, #pts, 2 do
							seg[#seg + 1] = pts[p]
							seg[#seg + 1] = pts[p + 1]
						end
					end
				else
					-- An angular gap - the hull, or ground too sparse to have
					-- a triangle - closed with an arc at the cap radius.
					local a1, a2 = a.ang, b.ang
					if a2 <= a1 then a2 = a2 + 2 * math.pi end
					local steps = math.max(2, math.ceil((a2 - a1) / 0.45))
					for k = 1, steps do
						local ang = a1 + (a2 - a1) * k / steps
						seg[#seg + 1] = sx + math.cos(ang) * cap_radius
						seg[#seg + 1] = sy + math.sin(ang) * cap_radius
					end
				end

				-- Everything after the first point joins the cell outline.
				for p = 3, #seg, 2 do
					poly[#poly + 1] = seg[p]
					poly[#poly + 1] = seg[p + 1]
				end

				-- A border is drawn only against *somebody else* - another
				-- owner, unowned ground, or the open edge of the map. Interior
				-- edges between two systems of the same owner disappear, which
				-- is what merges cells into one province.
				local no = other and owner_of(other) or 0
				if (no or 0) ~= owner then
					strokes[#strokes + 1] = seg
				end
			end

			cells[#cells + 1] = {
				site = id, owner = owner, alpha = alpha,
				poly = poly, strokes = strokes,
			}
		end
	end
	return cells
end

return M
