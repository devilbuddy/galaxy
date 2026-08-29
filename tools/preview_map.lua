-- Dump a full generated map as JSON for the offline renderer.
-- Usage: luajit tools/preview_map.lua <seed> [capitals]
--
-- `capitals` places that many players' capitals with the real opening-state
-- picker (galaxy/sim/state.lua), so the sketch can judge the capital glyph
-- without a game running - the placement is exactly what a game would open with.
package.path = "./?.lua;" .. package.path
local gen = require("galaxy.generate")
local json = require("tools.dump")
local systems = require("galaxy.sim.systems")
local theme = require("main.theme")

local seed = tonumber(arg[1]) or 1
local g = gen.build(seed)

local capital_count = tonumber(arg[2]) or 0
local capital_of = {}
if capital_count > 0 then
	local state = require("galaxy.sim.state")
	local players = {}
	for i = 1, capital_count do
		players[i] = { id = "sketch:" .. i, name = "Sketch " .. i, race = "terran" }
	end
	local st = state.new(g, players)
	for i = 1, #g.stars do
		if st.systems[i].capital_of ~= 0 then
			capital_of[i] = st.systems[i].capital_of
		end
	end
end

-- `tile` and `emoji` are the two art names the engine will also resolve, both
-- through main/theme.lua - so a sketch that looks right is a sketch of the same
-- decisions the renderer makes, not a parallel guess at them. `emoji` is null
-- for open country on purpose: the hex underneath already says what it is.
local tiles = {}
for i, s in ipairs(g.stars) do
	tiles[i] = { x = s.x, y = s.y, q = s.q, r = s.r, name = s.name,
		terrain = s.terrain, biome = s.biome, feature = s.feature, region = s.region,
		kind = systems.kind(g, i),
		tile = theme.tile_for(g, i),
		emoji = theme.emoji_for(g, i, capital_of[i] ~= nil),
		capital = capital_of[i] }
end

local water = {}
for i, w in ipairs(g.water) do
	water[i] = { x = w.x, y = w.y, q = w.q, r = w.r }
end

local regions = {}
for i, r in ipairs(g.regions) do
	regions[i] = { name = r.name, colour = r.colour, cx = r.cx, cy = r.cy, n = r.star_count }
end

io.stderr:write(string.format("seed %d: %d land %d sea %d regions %d capitals\n",
	seed, #tiles, #water, #regions, capital_count))
print(json.tojson({ seed = seed, world = g.world_size, hex_size = g.hex_size,
	tiles = tiles, water = water, regions = regions,
	sea_tile = theme.sea_tile(), emoji = theme.EMOJI }))
