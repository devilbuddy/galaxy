-- Determinism check. Run: luajit tools/verify_determinism.lua [repeats]
package.path = "./?.lua;" .. package.path
local gen = require("galaxy.generate")
local digest = require("galaxy.digest")

local repeats = tonumber(arg[1]) or 3
local seeds = { 1, 42, 1337, 424242, 999983, 16777215 }

local ok = true
for _, seed in ipairs(seeds) do
	local first, stats
	for r = 1, repeats do
		local g = gen.build(seed)
		local d = digest.of(g)
		if r == 1 then
			first = d
			stats = string.format("%3d stars %3d lanes %d regions",
				g.stats.star_count, g.stats.lane_count, g.stats.region_count)
		elseif d ~= first then
			ok = false
			print(string.format("MISMATCH seed=%d run=%d %d ~= %d", seed, r, d, first))
		end
	end
	print(string.format("seed %-9d digest %-12d %s", seed, first, stats))
end
print(ok and "ALL DETERMINISTIC" or "FAILED")
os.exit(ok and 0 or 1)
