-- Round-trip test for the client/server wire format.
-- Run: luajit tools/test_wire.lua
package.path = "./?.lua;" .. package.path
local gen = require("galaxy.generate")
local wire = require("galaxy.wire")

local failures = 0
local function check(name, cond, detail)
	if cond then print("  ok   " .. name)
	else failures = failures + 1; print("  FAIL " .. name .. "  " .. (detail or "")) end
end

for _, seed in ipairs({ 1, 424242, 1337 }) do
	local original = gen.build(seed)
	local rebuilt = wire.decode(wire.encode(original))
	print("seed " .. seed)

	check("star count", #rebuilt.stars == #original.stars)
	check("lane count", #rebuilt.lanes == #original.lanes)
	check("region count", #rebuilt.regions == #original.regions)
	check("world size", rebuilt.world_size == original.world_size)

	local worst_pos, bad_field = 0, nil
	for i = 1, #original.stars do
		local a, b = original.stars[i], rebuilt.stars[i]
		worst_pos = math.max(worst_pos, math.abs(a.x - b.x), math.abs(a.y - b.y))
		if a.name ~= b.name or a.class ~= b.class or a.feature ~= b.feature
			or a.region ~= b.region or a.habitable ~= b.habitable
			or a.class_label ~= b.class_label or a.radius ~= b.radius then
			bad_field = bad_field or ("star " .. i .. " (" .. a.name .. ")")
		end
	end
	check("star fields survive the round trip", bad_field == nil, tostring(bad_field))
	check("positions exact", worst_pos == 0, "worst delta " .. worst_pos)

	local bad_lane = nil
	for i = 1, #original.lanes do
		local a, b = original.lanes[i], rebuilt.lanes[i]
		if a.a ~= b.a or a.b ~= b.b or a.border ~= b.border then bad_lane = i end
	end
	check("lanes and border flags rederived", bad_lane == nil, tostring(bad_lane))

	local bad_region = nil
	for i = 1, #original.regions do
		local a, b = original.regions[i], rebuilt.regions[i]
		if a.name ~= b.name or a.colour_index ~= b.colour_index
			or a.star_count ~= b.star_count
			or math.abs(a.cx - b.cx) > 1e-9 or math.abs(a.cy - b.cy) > 1e-9
			or #a.neighbours ~= #b.neighbours then
			bad_region = bad_region or (a.name .. " vs " .. b.name)
		end
	end
	check("regions rederived", bad_region == nil, tostring(bad_region))

	local bad_adj = nil
	for i = 1, #original.adjacency do
		if #original.adjacency[i] ~= #rebuilt.adjacency[i] then bad_adj = i end
	end
	check("adjacency rederived", bad_adj == nil, tostring(bad_adj))

	check("content bounds match",
		math.abs(original.content.width - rebuilt.content.width) < 1e-9
		and math.abs(original.content.centre_y - rebuilt.content.centre_y) < 1e-9)
end

print(failures == 0 and "\nALL WIRE TESTS PASSED" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
