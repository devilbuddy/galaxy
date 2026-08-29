--- Generation defaults. Everything the map's character depends on lives here so
--- it can be tuned without reading the algorithms.

return {
	-- Seed used when none is supplied. Must stay below 2^24 so it survives a
	-- round trip through a Defold go.property, which is float32.
	default_seed = 424242,

	-- How many land tiles the continent is grown to. An exact count, not a
	-- target: realm/land.lua's loop bound is this number, so every seed gets a
	-- map of the same size. That matters more than it sounds - habitability,
	-- province size and the victory threshold are all fractions of it.
	land_target = 220,

	-- What fraction of the hex field the continent is allowed to fill. The field
	-- only has to be big enough that the growth is never cornered by the rim; if
	-- it is, the coast becomes the field boundary and reads as a straight edge.
	-- 0.55 grows 220 land tiles inside a radius-12 disc of 469, with two further
	-- rings of sea around the coast (realm/land.lua's SEA_MARGIN) - about 220
	-- water tiles, so the whole map is roughly 440 sprites.
	--
	-- A looser disc buys a better coastline and costs sprites, monotonically:
	--
	--   fill  disc  land cells on the disc edge  corridor cells  sprites
	--   0.75   10            17.8                    11.4          399
	--   0.65   11            11.2                    14.0          420
	--   0.55   12             7.8                    15.9          438
	--   0.45   13             4.6                    17.2          453
	--
	-- "on the disc edge" is coast that is the boundary rather than geography -
	-- a suspiciously circular arc. 438 sprites is far inside the 1024 cap, so
	-- the raggedest affordable coast is the one worth having.
	field_fill = 0.55,

	-- World units from a hex's centre to any of its six corners. Neighbouring
	-- centres are `sqrt(3) * hex_size` apart, so 70 gives a 121-unit step - the
	-- middle of the 60-200 range the old tile network spanned, which keeps the
	-- whole map at roughly the scale the camera and the zoom limits were tuned
	-- against. The art is 238x207, exactly the bounding box at size 119, so this
	-- is also the number the sprite scale is derived from.
	hex_size = 70,

	-- Fraction of land tiles that must end up habitable, and therefore cities -
	-- the only places that hold population and host every building.
	--
	-- Habitability is a per-tile roll off the terrain table, and on a map this
	-- size the variance is brutal. The generator promotes the best remaining
	-- candidates until it reaches this floor, so every seed is fair without
	-- making the roll itself uniform.
	city_fraction = 0.20,

	-- Roughly one province per this many tiles, clamped to the range below.
	tiles_per_province = 28,
	min_provinces = 5,
	max_provinces = 10,

	-- Player colours. Deliberately more saturated than the province palette so
	-- ownership never reads as terrain, and ordered so the first few are the
	-- most distinguishable from each other.
	player_palette = {
		{ 0.30, 0.68, 1.00 }, -- blue
		{ 1.00, 0.42, 0.32 }, -- red
		{ 0.42, 0.90, 0.48 }, -- green
		{ 1.00, 0.80, 0.28 }, -- amber
		{ 0.80, 0.44, 1.00 }, -- violet
		{ 0.30, 0.90, 0.86 }, -- cyan
		{ 1.00, 0.55, 0.80 }, -- pink
		{ 0.70, 0.75, 0.35 }, -- olive
		{ 0.95, 0.95, 0.95 }, -- white
		{ 0.55, 0.55, 0.72 }, -- slate
	},

	-- The same ten players, as inks: hand-darkened same-hue twins for the
	-- parchment map, where the bright set above washes out (white on cream is
	-- invisible). The chrome keeps the bright set - it is still dark - so a
	-- player is the same hue everywhere, at the value each ground needs.
	-- Same order and length as player_palette, always: index is identity, and
	-- the digest hashes structure (never these values), so retuning a tone is
	-- free while reordering is not.
	player_palette_ink = {
		{ 0.13, 0.36, 0.62 }, -- blue
		{ 0.62, 0.20, 0.14 }, -- red
		{ 0.16, 0.45, 0.20 }, -- green
		{ 0.58, 0.42, 0.05 }, -- amber
		{ 0.44, 0.20, 0.58 }, -- violet
		{ 0.08, 0.44, 0.42 }, -- cyan
		{ 0.60, 0.24, 0.42 }, -- pink
		{ 0.38, 0.42, 0.12 }, -- olive
		{ 0.42, 0.36, 0.30 }, -- white -> umber
		{ 0.30, 0.30, 0.44 }, -- slate
	},

	-- Province tints, chosen to stay distinguishable against a near-black field
	-- and against each other when two provinces border.
	province_palette = {
		{ 0.42, 0.35, 0.85 }, -- indigo
		{ 0.24, 0.55, 0.88 }, -- blue
		{ 0.22, 0.72, 0.62 }, -- teal
		{ 0.34, 0.72, 0.32 }, -- green
		{ 0.78, 0.66, 0.24 }, -- amber
		{ 0.82, 0.34, 0.28 }, -- crimson
		{ 0.72, 0.30, 0.72 }, -- magenta
		{ 0.30, 0.62, 0.78 }, -- cyan
	},
}
