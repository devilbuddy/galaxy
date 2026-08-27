-- Dump a full generated galaxy as JSON for the offline renderer.
-- Usage: luajit tools/preview_map.lua <seed> [star_count] [capitals]
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
local star_count = tonumber(arg[2])
local cfg = (star_count and star_count > 0) and { star_count = star_count } or nil
local g = gen.build(seed, cfg)

local capital_count = tonumber(arg[3]) or 0
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

local stars = {}
for i, s in ipairs(g.stars) do
	stars[i] = { x = s.x, y = s.y, name = s.name, class = s.class, region = s.region,
		r = s.radius * s.size_jitter, glow = s.glow, c = s.colour, feature = s.feature,
		kind = systems.kind(g, i),
		emoji = theme.emoji_for(g, i, capital_of[i] ~= nil),
		capital = capital_of[i] }
end
local lanes = {}
for i, l in ipairs(g.lanes) do lanes[i] = { a = l.a, b = l.b, border = l.border } end
local regions = {}
for i, r in ipairs(g.regions) do
	regions[i] = { name = r.name, colour = r.colour, cx = r.cx, cy = r.cy, n = r.star_count }
end
io.stderr:write(string.format("seed %d: %d stars %d lanes %d regions %d capitals\n",
	seed, #stars, #lanes, #regions, capital_count))
print(json.tojson({ seed = seed, world = g.world_size, stars = stars, lanes = lanes,
	regions = regions, emoji = theme.EMOJI }))
