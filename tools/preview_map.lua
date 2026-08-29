-- Dump a full generated map as JSON for the offline renderer.
-- Usage: luajit tools/preview_map.lua <seed> [seats]
--
-- `seats` places that many players' seats with the real opening-state
-- picker (realm/sim/state.lua), so the sketch can judge the seat glyph
-- without a game running - the placement is exactly what a game would open with.
package.path = "./?.lua;" .. package.path
local gen = require("realm.generate")
local json = require("tools.dump")
local tiles_mod = require("realm.sim.tiles")
local theme = require("main.theme")

local seed = tonumber(arg[1]) or 1
local g = gen.build(seed)

local seat_count = tonumber(arg[2]) or 0
local seat_of = {}
if seat_count > 0 then
	local state = require("realm.sim.state")
	local players = {}
	for i = 1, seat_count do
		players[i] = { id = "sketch:" .. i, name = "Sketch " .. i, race = "terran" }
	end
	local st = state.new(g, players)
	for i = 1, #g.tiles do
		if st.tiles[i].seat_of ~= 0 then
			seat_of[i] = st.tiles[i].seat_of
		end
	end
end

-- `tile` and `emoji` are the two art names the engine will also resolve, both
-- through main/theme.lua - so a sketch that looks right is a sketch of the same
-- decisions the renderer makes, not a parallel guess at them. `emoji` is null
-- for open country on purpose: the hex underneath already says what it is.
local tiles = {}
for i, s in ipairs(g.tiles) do
	tiles[i] = { x = s.x, y = s.y, q = s.q, r = s.r, name = s.name,
		terrain = s.terrain, biome = s.biome, feature = s.feature, province = s.province,
		kind = tiles_mod.kind(g, i),
		tile = theme.tile_for(g, i),
		emoji = theme.emoji_for(g, i, seat_of[i] ~= nil),
		seat = seat_of[i] }
end

local water = {}
for i, w in ipairs(g.water) do
	water[i] = { x = w.x, y = w.y, q = w.q, r = w.r }
end

local provinces = {}
for i, r in ipairs(g.provinces) do
	provinces[i] = { name = r.name, colour = r.colour, cx = r.cx, cy = r.cy, n = r.tile_count }
end

io.stderr:write(string.format("seed %d: %d land %d sea %d provinces %d seats\n",
	seed, #tiles, #water, #provinces, seat_count))
print(json.tojson({ seed = seed, world = g.world_size, hex_size = g.hex_size,
	tiles = tiles, water = water, provinces = provinces,
	sea_tile = theme.sea_tile(), emoji = theme.EMOJI }))
