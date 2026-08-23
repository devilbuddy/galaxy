-- Stage timings for generation. Run under luajit (client speed) or lua
-- (interpreter speed, closer to Nakama's gopher-lua).
package.path = "./?.lua;" .. package.path
rawset(_G, "GALAXY_FORCE_PURE_BITOPS", os.getenv("GALAXY_PURE_BITOPS") == "1")

local rng = require("galaxy.rng")
local shape_mod = require("galaxy.shape")
local points_mod = require("galaxy.points")
local delaunay = require("galaxy.delaunay")
local graph = require("galaxy.graph")
local names_mod = require("galaxy.names")
local cfg = require("galaxy.config")

local seed = tonumber(arg[1]) or 424242
local function ms(t0) return (os.clock() - t0) * 1000 end

print("bit-ops: " .. rng.implementation .. "  (_VERSION " .. _VERSION .. ")")

local t = os.clock()
local shape = shape_mod.new(seed)
print(string.format("%-22s %8.0f ms", "shape", ms(t)))

t = os.clock()
local pts, scale, passes = points_mod.generate(seed, shape, cfg.star_count)
print(string.format("%-22s %8.0f ms   (%d points, scale %.3f, %d sampling passes)",
	"points (poisson)", ms(t), #pts, scale, passes))

t = os.clock()
local tris = delaunay.triangulate(pts)
local edges = delaunay.edges(tris)
print(string.format("%-22s %8.0f ms   (%d tris)", "delaunay", ms(t), #tris))

t = os.clock()
local lanes = graph.prune(rng.stream(seed, "lanes"), pts, edges, { degree = cfg.lane_degree })
local adj = graph.adjacency(#pts, lanes)
local owner = graph.regions(rng.stream(seed, "regions"), pts, lanes, adj, 8)
print(string.format("%-22s %8.0f ms", "graph + regions", ms(t)))

t = os.clock()
local namer = names_mod.new(rng.stream(seed, "names"))
for _ = 1, 8 do namer:region() end
for _ = 1, #pts do namer:system() end
print(string.format("%-22s %8.0f ms", "names", ms(t)))

-- how many full poisson samplings did the count solver need?
local count = 0
local orig = points_mod.generate
print(string.format("\n%-22s %8s", "RNG calls (u32) est", "-"))
