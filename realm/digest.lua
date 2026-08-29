--- A stable checksum of a generated realm.
--
-- Determinism is the headline requirement, so it needs to be checkable rather
-- than assumed. This folds every field that affects what the player sees into
-- one number, which can be compared between runs, between processes and
-- between runtimes (standalone LuaJIT vs the engine).

local rng = require("realm.rng")

local M = {}

-- %.9g round-trips a float32-precision value exactly and formats identically
-- everywhere, so the digest never depends on the platform's default precision.
local function num(v)
	return string.format("%.9g", v)
end

function M.of(g)
	local h = rng.hash("realm:" .. num(g.seed))
	local parts = {}

	for i = 1, #g.tiles do
		local s = g.tiles[i]
		parts[#parts + 1] = table.concat({
			num(s.q), num(s.r), s.name, s.terrain, s.biome, s.feature,
			num(s.province), tostring(s.habitable),
		}, "|")
	end
	-- No edge list to fold in: adjacency is the six neighbours, so it is a pure
	-- function of the tile coordinates already hashed above. Folding it would
	-- hash the same fact twice.
	for i = 1, #g.provinces do
		local r = g.provinces[i]
		parts[#parts + 1] = table.concat({
			r.name, num(r.colour_index), num(r.seat), num(r.tile_count),
			num(r.cx), num(r.cy),
		}, "|")
	end

	for i = 1, #parts do
		h = rng.hash(parts[i], h)
	end
	return h
end

return M
