--- What a tile is made of, and what that is worth.
--
-- Replaces galaxy/starclass.lua and keeps its shape deliberately, because
-- `galaxy/sim/systems.lua` reads it the same way: a **ground** table and a
-- **feature** table, one derived value bundle each, plus a habitability roll
-- that decides where people live.
--
-- The two axes are drawn by two different mechanisms, and that is the whole
-- reason they are two tables:
--
--   terrain   the hex itself, a sprite from /main/tiles.atlas. What the land is.
--   feature   an emoji drawn on top of it. What is *on* the land, and the only
--             thing that makes an uninhabitable tile worth holding.
--
-- **An outpost is exactly a tile with a feature.** The old generator also
-- promoted energetic star classes, which meant an outpost could exist with
-- nothing drawn to say why. Here the glyph *is* the reason, so a player can read
-- the value of somewhere they have never been straight off the map.
--
-- Terrain is not rolled from a weight table like a star class was. It is
-- derived from two noise fields - elevation and moisture - so that forest sits
-- next to forest and a mountain range is a range rather than a scatter. Weights
-- would give a uniform confetti of terrain, which is what a lattice makes
-- painfully obvious and a Poisson scatter used to hide.

local M = {}

-- Ground types. `habitable` is the per-tile chance this terrain supports a
-- colony; the generator tops the count up to config.colony_fraction afterwards,
-- best candidates first, so these set *where* people prefer to live rather than
-- how many there are.
--
-- **Deliberately tuned to land just under the floor.** Against the terrain mix
-- the fields actually produce (about 25% plains, 20% woods, 26% forest, 16%
-- hills, 12% mountains) these average 0.188, so `colony_fraction` of 0.20 always
-- binds and every seed gets exactly the same number of colonies - which is what
-- the old star map did too, and what the economy sweep priced against. Letting
-- the roll win instead gave 28%, or 62 colonies where the prices assume 44.
-- What the roll still decides is *which* tiles they are.
--
-- `industry` and `science` are what a place would be good at. Only `industry` is
-- read today (systems.yield prices supply by it); `science` is carried for the
-- same reason it always was - it costs nothing and it is what research will be
-- priced against.
M.TERRAIN = {
	{ id = "plains",    label = "Plains",    habitable = 0.35, industry = 1.00, science = 0.80 },
	{ id = "woods",     label = "Woodland",  habitable = 0.23, industry = 1.05, science = 0.75 },
	{ id = "forest",    label = "Forest",    habitable = 0.14, industry = 1.10, science = 0.70 },
	{ id = "hills",     label = "Hills",     habitable = 0.10, industry = 1.25, science = 0.85 },
	{ id = "mountains", label = "Mountains", habitable = 0.015, industry = 1.40, science = 0.65 },
	-- Sea. Never appears on a land tile and is never in the graph at all, so
	-- nothing here is ever read - it exists so a lookup by id cannot come back
	-- empty for a tile the renderer is drawing.
	{ id = "water",     label = "Sea",       habitable = 0.00, industry = 0.00, science = 0.00 },
}

-- What is standing on the ground. Most tiles have none: the map needs empty
-- country between the places worth marching to, or none of them register.
--
-- Every one of these is drawn, and drawing it is what makes the tile an
-- outpost - see the note above. `main/theme.lua` owns which glyph.
M.FEATURES = {
	{ id = "none",   label = "",             weight = 66, industry = 0.00, science = 0.00 },
	{ id = "ruins",  label = "Old Ruins",    weight = 8,  industry = 0.10, science = 1.10 },
	{ id = "mine",   label = "Mine",         weight = 8,  industry = 0.85, science = 0.10 },
	{ id = "shrine", label = "Shrine",       weight = 6,  industry = 0.15, science = 0.90 },
	{ id = "barrow", label = "Barrow",       weight = 5,  industry = 0.20, science = 0.60 },
	{ id = "portal", label = "Wild Gate",    weight = 4,  industry = 0.30, science = 1.20 },
	{ id = "gems",   label = "Gem Seam",     weight = 3,  industry = 0.90, science = 0.30 },
}

-- The five ground palettes, and the climate each one means. Order matches
-- main/theme.lua's M.BIOMES, and like the player palettes the *index* is
-- identity: retuning which climate picks which biome is free, reordering is not.
M.BIOMES = { "greenlands", "sandlands", "drylands", "deadlands", "icelands" }

local function weights_of(list)
	local w, total = {}, 0
	for i = 1, #list do
		w[i] = list[i].weight
		total = total + w[i]
	end
	return w, total
end

M.FEATURE_WEIGHTS, M.FEATURE_TOTAL = weights_of(M.FEATURES)

--- Ground type from the two fields.
--
-- **Both inputs are ranks, not raw noise**, in [0, 1): a tile's position in the
-- sorted order of that field across the whole map. So `> 0.88` means "the top
-- 12% of the continent by height" and reads as the fraction it actually is.
--
-- That is not cosmetic. Fractal noise clusters hard around 0.5 - it is a sum of
-- uniforms - so an absolute threshold of 0.72 is nearly two standard deviations
-- out and picked 3.6% of the map rather than the ~25% it looks like. The first
-- pass shipped 8 mountains on a 220-tile map for exactly that reason. Ranking
-- also makes the mix identical on every seed while leaving *where* the mountains
-- are entirely to the noise, which is the same trade galaxy/land.lua makes to
-- get an exact land count.
--
-- Height first, then wetness: above the treeline nothing else matters, and below
-- it how wet somewhere is decides whether it is forest or open country.
function M.classify(elevation, moisture)
	if elevation > 0.88 then return "mountains" end
	if elevation > 0.72 then return "hills" end
	if moisture > 0.62 then return "forest" end
	if moisture > 0.34 then return "woods" end
	return "plains"
end

--- Which ground palette a tile is drawn in.
--
-- `moisture` and `blight` are ranks, as above. `warmth` is **not**: it is a real
-- latitude, 1 across the middle of the continent and 0 at its northern and
-- southern edges, so the ice caps land where an atlas puts them rather than on
-- a fixed share of the map. A cold seed should be able to be cold.
--
-- The latitude curve is steep on purpose (see generate.lua): a linear one put
-- the ice line at 70% of the way to the pole, which iced nearly half the
-- continent. Ice belongs at the ends of the map, not across it.
--
-- Blight is tested first because deadlands are a scar rather than a climate -
-- they can appear at any latitude, on any ground.
--   deadlands  blight, at any latitude on any ground
--   icelands   the far north and south
--   sandlands  hot *and* genuinely arid - a desert belt
--   drylands   merely dry
--   greenlands everything else, and the majority
--
-- **Order is the whole tuning.** Each test only sees what the ones above it did
-- not claim, so a loose early threshold starves everything below: `sandlands` at
-- `warmth > 0.68 and moisture < 0.40` took 40% of the continent and left
-- drylands with the scraps, because the steep warmth curve makes almost
-- everything "warm". Requiring real aridity is what turns it back into a belt.
function M.biome(warmth, moisture, blight)
	if blight > 0.90 then return "deadlands" end
	if warmth < 0.45 then return "icelands" end
	if warmth > 0.78 and moisture < 0.30 then return "sandlands" end
	if moisture < 0.42 then return "drylands" end
	return "greenlands"
end

function M.roll_feature(r)
	return M.FEATURES[r:weighted(M.FEATURE_WEIGHTS, M.FEATURE_TOTAL)]
end

-- Lookup tables, built once. The client rebuilds a map received from the server
-- by terrain and feature id, so these are on the hot path of every map load.
local TERRAIN_BY_ID, FEATURE_BY_ID = {}, {}
for i = 1, #M.TERRAIN do TERRAIN_BY_ID[M.TERRAIN[i].id] = M.TERRAIN[i] end
for i = 1, #M.FEATURES do FEATURE_BY_ID[M.FEATURES[i].id] = M.FEATURES[i] end

--- Look a ground type up by id.
function M.by_id(id)
	return TERRAIN_BY_ID[id]
end

--- Look a feature up by id.
function M.feature_by_id(id)
	return FEATURE_BY_ID[id]
end

--- Is this feature worth holding ground for? Anything but `none`.
function M.productive_feature(id)
	local entry = FEATURE_BY_ID[id]
	return entry ~= nil and entry.id ~= "none"
end

return M
