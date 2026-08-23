-- Dump a full generated galaxy as JSON for the offline renderer.
-- Usage: luajit tools/preview_map.lua <seed> [star_count]
package.path = "./?.lua;" .. package.path
local gen = require("galaxy.generate")
local json = require("tools.dump")

local seed = tonumber(arg[1]) or 1
local cfg = arg[2] and { star_count = tonumber(arg[2]) } or nil
local g = gen.build(seed, cfg)

local stars = {}
for i, s in ipairs(g.stars) do
	stars[i] = { x = s.x, y = s.y, name = s.name, class = s.class, region = s.region,
		r = s.radius * s.size_jitter, glow = s.glow, c = s.colour, feature = s.feature }
end
local lanes = {}
for i, l in ipairs(g.lanes) do lanes[i] = { a = l.a, b = l.b, border = l.border } end
local regions = {}
for i, r in ipairs(g.regions) do
	regions[i] = { name = r.name, colour = r.colour, cx = r.cx, cy = r.cy, n = r.star_count }
end
io.stderr:write(string.format("seed %d: %d stars %d lanes %d regions\n", seed, #stars, #lanes, #regions))
print(json.tojson({ seed = seed, world = g.world_size, stars = stars, lanes = lanes, regions = regions }))
