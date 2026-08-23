package.path = "./?.lua;" .. package.path
local shape = require("galaxy.shape")
local points = require("galaxy.points")
local json = require("tools.dump")

local seed = tonumber(arg[1]) or 1
local target = tonumber(arg[2]) or 220
local s = shape.new(seed)
local t0 = os.clock()
local pts, scale = points.generate(seed, s, target)
local ms = (os.clock() - t0) * 1000
io.stderr:write(string.format("seed %-6d %4d points (target %d) in %5.0f ms  arms=%d scale=%.3f\n",
	seed, #pts, target, ms, s.arms, scale))
print(json.tojson({ points = pts, seed = seed }))
