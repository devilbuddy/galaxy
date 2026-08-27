-- The political map: provinces that tile, never overlap.
-- Invariants of main/territory.lua, offline under luajit.
package.path = "./?.lua;" .. package.path
local gen = require("galaxy.generate")
local territory = require("main.territory")

local failures = 0
local function check(name, ok, detail)
	if ok then
		print("  ok   " .. name)
	else
		failures = failures + 1
		print("  FAIL " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
	end
end

local g = gen.build(1337)
local cap = g.world_size * 0.05

print("cells for a two-owner split")
-- A blunt split: odd ids to player 1, even to player 2, first 60 systems.
local function owner_of(id)
	if id <= 60 then return (id % 2) + 1, 1.0 end
	return 0, 1.0
end
local cells = territory.build(g, owner_of, cap)

check("every owned system with a neighbourhood gets a cell", #cells >= 55, #cells)

local ok_poly, ok_dist, bordered = true, true, 0
for i = 1, #cells do
	local c = cells[i]
	if #c.poly < 6 then ok_poly = false end
	local s = g.stars[c.site]
	for p = 1, #c.poly, 2 do
		local dx, dy = c.poly[p] - s.x, c.poly[p + 1] - s.y
		if math.sqrt(dx * dx + dy * dy) > cap * 1.3 then ok_dist = false end
	end
	if #c.strokes > 0 then bordered = bordered + 1 end
end
check("every cell is a real polygon", ok_poly)
check("no cell escapes its cap radius", ok_dist)
-- Id parity is not a spatial checkerboard, so a cell CAN sit entirely among
-- friends - but with owners interleaved by id, the vast majority cannot.
check("almost every split cell has a border", bordered >= #cells * 0.8,
	bordered .. " of " .. #cells)

print("borders vanish inside one owner's province")
local all_one = territory.build(g, function(id)
	if id <= 60 then return 1, 1.0 end
	return 0, 1.0
end, cap)
local interior = 0
for i = 1, #all_one do
	if #all_one[i].strokes == 0 then interior = interior + 1 end
end
check("some cells are interior, with no border at all", interior > 0, interior)

print("deterministic")
local again = territory.build(g, owner_of, cap)
local same = #again == #cells
if same then
	for i = 1, #cells do
		local a, b = cells[i], again[i]
		if a.site ~= b.site or #a.poly ~= #b.poly then same = false break end
		for p = 1, #a.poly do
			if a.poly[p] ~= b.poly[p] then same = false break end
		end
	end
end
check("the same ownership builds the same map, twice", same)

if failures > 0 then
	print(failures .. " FAILURES")
	os.exit(1)
end
print("ALL TERRITORY TESTS PASSED")
