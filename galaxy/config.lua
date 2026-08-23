--- Generation defaults. Everything the map's character depends on lives here so
--- it can be tuned without reading the algorithms.

return {
	-- Seed used when none is supplied. Must stay below 2^24 so it survives a
	-- round trip through a Defold go.property, which is float32.
	default_seed = 424242,

	-- How many star systems to aim for. The sampler solves for the spacing that
	-- lands near this number, so it is a genuine target rather than a hint.
	star_count = 220,

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
