--- Generation defaults. Everything the map's character depends on lives here so
--- it can be tuned without reading the algorithms.

return {
	-- Seed used when none is supplied. Must stay below 2^24 so it survives a
	-- round trip through a Defold go.property, which is float32.
	default_seed = 424242,

	-- How many star systems to aim for. The sampler solves for the spacing that
	-- lands near this number, so it is a genuine target rather than a hint.
	star_count = 220,

	-- Fraction of systems that must end up habitable, and therefore colonies -
	-- the only places that hold population and host every building.
	--
	-- Habitability is a per-star roll off the class table, and on a small map
	-- the variance is brutal: 120 stars produced anywhere from 13 to 26
	-- colonies across seeds, and 13 is not a playable four-player game. The
	-- generator promotes the best remaining candidates until it reaches this
	-- floor, so every seed is fair without making the roll itself uniform.
	colony_fraction = 0.20,

	-- Mean lanes per system. Below ~2.4 the map degenerates towards a tree with
	-- no strategic choices; above ~3.4 it stops reading as a lane network.
	lane_degree = 2.9,

	-- How strongly lane selection is randomised away from "shortest first".
	lane_jitter = 0.45,

	-- Roughly one region per this many stars, clamped to the range below.
	stars_per_region = 28,
	min_regions = 5,
	max_regions = 10,

	-- World size in pixels. The map is deliberately much larger than a portrait
	-- phone viewport; panning across it is the point.
	world_size = 2600,

	-- Player colours. Deliberately more saturated than the region palette so
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

	-- Region tints, chosen to stay distinguishable against a near-black field
	-- and against each other when two regions border.
	region_palette = {
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
