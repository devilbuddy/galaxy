--- Deterministic name generation for stars and regions.
--
-- Names carry a surprising amount of a 4X map's character, so this is not a
-- single syllable soup: it mixes invented words with borrowed catalogue,
-- mythological and astronomical vocabulary, then runs them through weighted
-- templates. Uniqueness is enforced globally so no two systems collide.

local M = {}

-- Invented-word building blocks. Split into onset/nucleus/coda so the results
-- stay pronounceable instead of turning into consonant pileups.
local ONSET = {
	"K", "T", "S", "M", "N", "R", "V", "Z", "D", "L", "P", "B", "G", "H", "J", "Y",
	"Kh", "Th", "Sh", "Vr", "Dr", "Tr", "Kr", "Br", "Gl", "Sk", "St", "Xi", "Ch", "Ph",
	"Qu", "Zh", "Mn", "Ny", "Ts", "Ar", "Ak", "Ok", "Um", "An",
}
-- Simple nuclei are safe after any onset; the diphthongs are only used after a
-- single-consonant onset, because "Qu"+"ei"+"a" style pileups are unreadable.
local NUCLEUS_SIMPLE = { "a", "e", "i", "o", "u", "y", "a", "e", "i", "o" }
local NUCLEUS_RICH = {
	"a", "e", "i", "o", "u", "ae", "ai", "ea", "ei", "ia", "io", "ou", "ua",
	"au", "eo",
}
local CODA = {
	"", "", "", "n", "r", "s", "l", "m", "th", "sh", "k", "x", "rn", "ll", "ss",
	"nd", "ng", "st", "rk", "z", "ph", "tt",
}

-- Borrowed vocabulary. These anchor the map: a few recognisable names make the
-- invented ones read as part of the same world rather than as noise.
local CLASSICAL = {
	"Antares", "Capella", "Sirius", "Castor", "Pollux", "Vega", "Altair", "Rigel",
	"Deneb", "Arcturus", "Aldebaran", "Bellatrix", "Procyon", "Canopus", "Spica",
	"Achernar", "Mizar", "Alcor", "Fomalhaut", "Regulus", "Algol", "Mirach",
	"Alphard", "Izar", "Talitha", "Merak", "Phecda", "Dubhe", "Alkaid", "Thuban",
	"Sadalsuud", "Zubeneschamali", "Gacrux", "Menkar", "Alnilam", "Saiph", "Nunki",
}
local MYTHIC = {
	"Mazzaroth", "Akeron", "Tiamat", "Nergal", "Marduk", "Ashur", "Enlil", "Inanna",
	"Xipe", "Tlaloc", "Mictlan", "Quetzal", "Huitzil", "Coatl", "Nebiros", "Belial",
	"Asmodel", "Sachiel", "Raziel", "Ophiel", "Hagith", "Bethor", "Phaleg", "Och",
	"Vishao", "Kitara", "Kasdreya", "Charis", "Dahin", "Yokan", "Ishuan", "Menorb",
	"Kailaasa", "Sulani", "Tarkhan", "Vashti", "Zephon", "Ordan", "Serapis", "Kordan",
}
local FEATURES = {
	"Veil", "Gate", "Cove", "Belt", "Reach", "Rest", "Folly", "Crown", "Wake",
	"Spire", "Deep", "Cradle", "Shadow", "Bastion", "Refuge", "Descent", "Landing",
	"Passage", "Watch", "Hollow", "Threshold", "Anchorage", "Verge", "Bight",
	"Expanse", "Drift", "Span", "Hold", "Perch", "Bridge",
}
local ADJECTIVES = {
	"Swooping", "Burning", "Silent", "Broken", "Golden", "Hollow", "Distant",
	"Frozen", "Shrouded", "Wandering", "Sunken", "Bright", "Fading", "Iron",
	"Amber", "Crimson", "Pale", "Restless", "Sable", "Vermilion",
}
local CREATURES = {
	"Eagle", "Serpent", "Lion", "Kraken", "Hart", "Falcon", "Basilisk", "Wyrm",
	"Mantis", "Leviathan", "Corvid", "Jackal", "Sparrow", "Wolf", "Heron", "Ibis",
}
local GREEK = {
	"Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta", "Iota",
	"Kappa", "Lambda", "Mu", "Nu", "Xi", "Omicron", "Sigma", "Tau", "Upsilon",
	"Phi", "Chi", "Psi", "Omega",
}
local ROMAN = { "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII" }
local CATALOGUE = { "HD", "HIP", "GJ", "KX", "LP", "TYC", "PSR", "NGC", "IC", "WD" }

-- Grand nouns for region names: bigger in scale than a single system's feature.
local REGION_NOUNS = {
	"Maelstrom", "Expanse", "Reach", "Rim", "Verge", "Drift", "Marches", "Cluster",
	"Sector", "Sprawl", "Deeps", "Frontier", "Dominion", "Fringe", "Shoals",
	"Wastes", "Cradle", "Crown", "Gulf", "Spur", "Arm", "Belt", "Trace", "Veil",
}
local REGION_ADJECTIVES = {
	"Outer", "Inner", "Wild", "Lost", "Far", "Deep", "Old", "Shattered", "Forsaken",
	"Radiant", "Obsidian", "Umbral", "Argent", "Verdant", "Ashen", "Gilded",
}

--- One invented word of 1-3 syllables.
local function invent(r)
	local syllables = r:weighted({ 26, 58, 16 }) -- mostly two syllables
	local parts = {}
	for i = 1, syllables do
		local onset = r:pick(ONSET)
		-- Consonant clusters already carry weight, so keep their vowel simple.
		local nucleus = (#onset > 1) and r:pick(NUCLEUS_SIMPLE) or r:pick(NUCLEUS_RICH)
		local piece = onset .. nucleus
		-- Only the final syllable takes a coda, which avoids "Krant-rk-nd".
		if i == syllables then piece = piece .. r:pick(CODA) end
		parts[#parts + 1] = piece
	end
	local word = table.concat(parts)
	return word:sub(1, 1):upper() .. word:sub(2):lower()
end

--- A stem: sometimes borrowed, usually invented.
local function stem(r)
	local roll = r:weighted({ 58, 22, 20 })
	if roll == 1 then return invent(r) end
	if roll == 2 then return r:pick(MYTHIC) end
	return r:pick(CLASSICAL)
end

local Namer = {}
Namer.__index = Namer

--- Reserve a name, or return nil if it is already taken.
function Namer:claim(name)
	local key = name:lower()
	if self.used[key] then return nil end
	self.used[key] = true
	return name
end

--- Generate one system name via weighted templates.
function Namer:system()
	local r = self.r
	for attempt = 1, 40 do
		local t = r:weighted({
			26, -- bare stem
			18, -- possessive feature
			12, -- greek prefix
			10, -- greek suffix
			8,  -- roman numeral
			10, -- adjective creature
			8,  -- compound
			8,  -- catalogue designation
		})
		local name
		if t == 1 then
			name = stem(r)
		elseif t == 2 then
			name = stem(r) .. "'s " .. r:pick(FEATURES)
		elseif t == 3 then
			name = r:pick(GREEK) .. " " .. stem(r)
		elseif t == 4 then
			name = stem(r) .. " " .. r:pick(GREEK)
		elseif t == 5 then
			name = stem(r) .. " " .. r:pick(ROMAN)
		elseif t == 6 then
			name = r:pick(ADJECTIVES) .. " " .. r:pick(CREATURES)
		elseif t == 7 then
			name = stem(r) .. " " .. invent(r)
		else
			name = r:pick(CATALOGUE) .. "-" .. r:int(100, 9999)
		end

		-- After a few collisions stop retrying blind and disambiguate instead,
		-- so a large galaxy cannot stall on an exhausted template.
		if attempt > 12 then
			name = name .. " " .. r:pick(GREEK)
		end
		local claimed = self:claim(name)
		if claimed then return claimed end
	end
	self.fallback = self.fallback + 1
	return self:claim(string.format("%s-%04d", self.r:pick(CATALOGUE), 1000 + self.fallback))
		or string.format("Unnamed %d", self.fallback)
end

--- Generate one region name. Rendered uppercase by the map, so kept in title
--- case here and left to the presentation layer.
function Namer:region()
	local r = self.r
	for attempt = 1, 40 do
		local t = r:weighted({ 26, 18, 20, 14, 12, 10 })
		local name
		if t == 1 then
			name = r:pick(CLASSICAL)
		elseif t == 2 then
			name = r:pick(GREEK) .. " " .. r:pick(CLASSICAL)
		elseif t == 3 then
			name = r:pick(MYTHIC) .. " " .. r:pick(REGION_NOUNS)
		elseif t == 4 or t == 5 then
			local adj, noun = r:pick(REGION_ADJECTIVES), r:pick(REGION_NOUNS)
			-- Reject overlaps like "The Deep Deeps".
			if adj:lower():sub(1, 4) == noun:lower():sub(1, 4) then
				noun = r:pick(REGION_NOUNS)
			end
			name = (t == 4 and "The " or "") .. adj .. " " .. noun
		else
			name = invent(r) .. " " .. r:pick(REGION_NOUNS)
		end
		if attempt > 12 then name = name .. " " .. r:pick(ROMAN) end
		local claimed = self:claim(name)
		if claimed then return claimed end
	end
	self.fallback = self.fallback + 1
	return "Sector " .. self.fallback
end

--- A namer with its own uniqueness set. Region names are drawn before system
--- names by convention, so the memorable vocabulary lands on regions.
function M.new(r)
	return setmetatable({ r = r, used = {}, fallback = 0 }, Namer)
end

return M
