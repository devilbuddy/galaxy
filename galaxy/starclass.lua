--- Star classification: what a system looks like and roughly what it is worth.
--
-- Weights are tuned for the look of the reference maps, where the field reads
-- as predominantly warm amber with occasional blue-white highlights and a
-- handful of genuinely strange objects to give the map landmarks.

local M = {}

-- radius/glow are multipliers on the base drawn size.
-- colour is linear-ish RGB in 0..1.
M.CLASSES = {
	{ id = "red_dwarf",    label = "Red Dwarf",     weight = 26, colour = { 0.94, 0.44, 0.30 }, radius = 0.62, glow = 0.85, habitable = 0.10 },
	{ id = "orange_dwarf", label = "Orange Dwarf",  weight = 21, colour = { 0.98, 0.66, 0.34 }, radius = 0.74, glow = 0.95, habitable = 0.30 },
	{ id = "yellow",       label = "Yellow Main",   weight = 17, colour = { 1.00, 0.86, 0.50 }, radius = 0.86, glow = 1.05, habitable = 0.45 },
	{ id = "amber_giant",  label = "Amber Giant",   weight = 11, colour = { 1.00, 0.76, 0.38 }, radius = 1.06, glow = 1.25, habitable = 0.20 },
	{ id = "white",        label = "White Main",    weight = 9,  colour = { 0.94, 0.96, 1.00 }, radius = 0.94, glow = 1.15, habitable = 0.25 },
	{ id = "blue_giant",   label = "Blue Giant",    weight = 6,  colour = { 0.60, 0.78, 1.00 }, radius = 1.28, glow = 1.60, habitable = 0.05 },
	{ id = "red_giant",    label = "Red Giant",     weight = 4,  colour = { 1.00, 0.40, 0.32 }, radius = 1.42, glow = 1.55, habitable = 0.02 },
	{ id = "pulsar",       label = "Pulsar",        weight = 2,  colour = { 0.72, 0.92, 1.00 }, radius = 0.46, glow = 1.90, habitable = 0.00 },
	{ id = "black_hole",   label = "Black Hole",    weight = 1,  colour = { 0.52, 0.30, 0.78 }, radius = 0.58, glow = 1.70, habitable = 0.00 },
	{ id = "nebula",       label = "Nebula Node",   weight = 1,  colour = { 0.78, 0.44, 0.92 }, radius = 1.15, glow = 1.80, habitable = 0.00 },
}

-- Rare per-system flavour. Most systems have none; the map needs empty space
-- between points of interest for the interesting ones to register.
M.FEATURES = {
	{ id = "none",      label = "",                 weight = 68 },
	{ id = "anomaly",   label = "Anomaly",          weight = 8 },
	{ id = "derelict",  label = "Derelict",         weight = 6 },
	{ id = "asteroids", label = "Asteroid Field",   weight = 7 },
	{ id = "relay",     label = "Jump Relay",       weight = 4 },
	{ id = "ruins",     label = "Precursor Ruins",  weight = 4 },
	{ id = "nebula",    label = "Nebula Shroud",    weight = 3 },
}

local function weights_of(list)
	local w, total = {}, 0
	for i = 1, #list do
		w[i] = list[i].weight
		total = total + w[i]
	end
	return w, total
end

M.CLASS_WEIGHTS, M.CLASS_TOTAL = weights_of(M.CLASSES)
M.FEATURE_WEIGHTS, M.FEATURE_TOTAL = weights_of(M.FEATURES)

--- Roll a class, biased by how deep in the galaxy the system sits.
--
-- `core_bias` in [0,1] is high near the galactic centre. Real spiral galaxies
-- concentrate old, bright and exotic objects in the bulge, and it also gives
-- the map a reason to care about position: the middle is worth fighting over.
function M.roll_class(r, core_bias)
	local w = {}
	for i = 1, #M.CLASSES do
		local c = M.CLASSES[i]
		local weight = c.weight
		if c.id == "blue_giant" or c.id == "red_giant" or c.id == "amber_giant" then
			weight = weight * (1 + 1.4 * core_bias)
		elseif c.id == "pulsar" or c.id == "black_hole" then
			weight = weight * (1 + 2.5 * core_bias)
		elseif c.id == "red_dwarf" then
			weight = weight * (1 - 0.45 * core_bias)
		end
		w[i] = weight
	end
	return M.CLASSES[r:weighted(w)]
end

function M.roll_feature(r)
	return M.FEATURES[r:weighted(M.FEATURE_WEIGHTS, M.FEATURE_TOTAL)]
end

--- Look a class up by id.
function M.by_id(id)
	for i = 1, #M.CLASSES do
		if M.CLASSES[i].id == id then return M.CLASSES[i] end
	end
	return nil
end

return M
