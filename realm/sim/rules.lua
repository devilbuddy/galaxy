--- Tunable rules for the simulation.
--
-- Everything the game's balance depends on lives here so it can be adjusted
-- without reading the resolution logic. Values are per *turn*, and a turn is a
-- scheduled batch, not a real-time tick.
--
-- The game is being rebuilt from its foundations. Right now it is this: every
-- player has a seat and one commander, commanders move along tiles, whatever
-- they pass through becomes theirs, and a commander with enough **strength**
-- takes ground somebody else holds. There is still no production and no
-- research; their constants will arrive with the code that reads them rather
-- than sitting here describing a game that is not running.

return {
	-- Movement ----------------------------------------------------------------
	-- Lanes a commander crosses per turn.
	--
	-- **Discrete on purpose.** Movement used to be a distance - 95 world units
	-- a turn along tiles varying from roughly 60 to 200 - which meant "when
	-- does Kess arrive?" had no answer a player could work out. Lane length is
	-- not drawn, not stated and cannot be eyeballed, so the number the rule
	-- depended on was invisible. A step is countable off the map: a four-tile
	-- route takes four turns.
	--
	-- What this gives up is that tile *length* no longer means anything. If it
	-- is missed, the way back is to price some tiles at two steps and draw them
	-- as such - not to return to a continuous speed nobody can see.
	commander_steps = 1,
	-- Rank buys reach rather than pace, so progression is legible: a Commodore
	-- moves two tiles a turn, a Grand Admiral three.
	steps_at_rank = { [5] = 1, [9] = 1 },
	-- A race with a mobility bonus gets a whole extra step. Fractions of a step
	-- would be exactly the invisible arithmetic this replaced.
	step_race_threshold = 0.2,
	-- How far ahead a route may be plotted, in tiles. Standing orders are what
	-- make a game checked twice a day playable rather than tedious.
	max_route_hops = 12,          -- baseline (via hops)

	-- Strength -----------------------------------------------------------------
	-- What a commander can spend to take ground, and the ceiling it recovers to.
	--
	-- **The whole model is one comparison, and every number in it is on screen.**
	-- A commander attacks only when it can win; otherwise it stops at the border
	-- exactly as it did before combat existed. So there are no failed assaults,
	-- no dice, and nothing to misjudge - which is the only way an attack can be
	-- a decision rather than a gamble in a game checked twice a day.
	-- What the officer brings on their own, before anything is bought. It is
	-- never *spent* - a battle takes units, and an officer with none loses
	-- nothing - which is precisely why it has to stay small.
	--
	-- It was 12 and +3 a level, and that made an army optional: a level-four
	-- officer's own command out-fought any city on the map and could do it
	-- again every turn, for ever, at no cost at all. Six and +1 keeps a bare
	-- commander able to walk into empty space and take open country or a holding -
	-- which is what early expansion is - while a city at 9 needs something
	-- aboard and a seat at 21 needs a real army.
	commander_strength = 6,
	strength_per_level = 1,

	-- And how many bought units they can lead on top of that. **Rank must not
	-- cap what a commander can carry**, only what they start with: capping the
	-- total at the rank base walled the game shut, because a fresh commander
	-- could never cover a defended city and could never win the battle that
	-- would have promoted them. Capacity is generous and grows with rank, so
	-- experience buys reach rather than gating the economy.
	commander_units = 6,
	units_per_level = 1,

	-- What it costs to take a tile, by what kind of place it is. Public map
	-- data (realm/sim/tiles.lua derives kind from the tile), so a player can
	-- price a conquest from the other side of the realm.
	--
	-- Open country is terrain and barely resists; a city costs most of a fresh
	-- commander. That is the distinction the map is drawn around.
	defence = { wilds = 2, holding = 5, city = 9 },
	-- On top of the kind. A seat is the losing condition, so taking one
	-- should need a commander who has been winning, not a fresh one.
	seat_defence = 12,


	-- Gold and units ---------------------------------------------------------
	-- **One currency, two things it cannot be in at once.** Gold accrues from
	-- everything you hold and is fungible across the map; units accumulate only
	-- at cities, only up to a cap, and only become strength where a commander is
	-- standing. So wealth alone never wins a front - it converts to force at a
	-- city, and a commander has to walk there.
	--
	-- Per tile per turn, scaled by the tile's own `industry` and rounded to a
	-- whole number.
	--
	-- **Road pays nothing.** Open country used to pay 1, which meant walking a
	-- commander down an empty chain was income for the rest of the game - and the
	-- map had already decided that was the wrong measure. `provinces.lua` counts
	-- only cities and holdings towards victory, so wilds were already
	-- terrain for the purpose of *winning* and still wages for the purpose of
	-- *paying*. This closes that.
	--
	-- Cities are towns and holdings are mines, which is the shape this is
	-- lifted from. **It is a redistribution rather than a cut**: measured over
	-- five seeds, wilds were 45% of the tiles and 22% of the income, and
	-- moving that onto the other two at these rates leaves whole-realm income
	-- within a percent of what it was. What changes is not how much an empire
	-- earns but what it is worth going to get - a city now averages 4.7 a
	-- turn and a holding 3.2, and the road between them averages nothing.
	--
	-- **The rates are what stops gold being meaningless by the midgame.**
	-- Every sink in this game is capped - four slots a city, six units in a
	-- garrison, two of a type ready at a time - so income that outruns them
	-- just piles up. At 4 and 2.5 a four-player game ended with each surviving
	-- player holding ~2,500 gold they could not spend; at 2.5 and 1.5 it is
	-- ~415, and the median game is *faster* rather than slower. Money running
	-- out is what keeps the economy a decision all game.
	gold_yield = { wilds = 0, holding = 1.5, city = 2.5 },

	-- What a player's seat pays on top of its own yield.
	--
	-- **This is what makes the opening work.** With road paying nothing, a
	-- player who has taken two tiles and a stretch of tile earns almost
	-- exactly what they earned on turn one - and the seat is the only thing
	-- anybody is guaranteed to hold. Without it the first stretch of a game is
	-- a player watching a number that does not move.
	--
	-- It is a shape rather than a decision: the seat is placed by the
	-- generator, so there is nothing to choose. The version with a choice in it
	-- is a building that pays, and there is no room for one at four slots.
	seat_yield = 12,

	-- What a city holds ready and how often another becomes available now
	-- live on the *dwelling* rather than here - see `buildings.CATALOGUE`. A
	-- city makes only what it has dwellings for, so there is no single
	-- cadence to state.
	--
	-- Availability accumulates whether or not anyone visits and does not decay,
	-- so a distant city is not wasted production - it is a reason to march.
	-- That is lifted straight from Heroes of Might and Magic, along with the
	-- shape that makes it a decision at all: **you have to pay for what is
	-- available.** Without the cost, collecting is a chore rather than a choice
	-- and you always take everything.

	-- Combat ---------------------------------------------------------------------
	-- **Whether you win is computed; what it costs is simulated.**
	--
	-- Two comparisons decide the first, both integer and both on the sheet: your
	-- siege power against the world's fortification, and your army power
	-- against whatever army is standing on it. Beat both and you take it. That
	-- is the arithmetic a player does before committing a commander to a turn that
	-- resolves twelve hours later, and it is why combat has never needed a
	-- forecast.
	--
	-- The **exchanges** then distribute the cost. An exchange is a trade of
	-- damage *inside* a single turn - the whole battle is over before the turn
	-- that started it finishes, and nobody else acts in between. It is not a
	-- turn, and the two words must not be swapped.
	--
	-- Losses follow Lanchester's linear law: two forces grinding each other down
	-- in proportion leave the winner having lost `D*D/A`, so a well-composed
	-- army both finishes sooner and comes out of it larger. It is also **provably
	-- consistent with the comparison** - `D*D/A < D < A` whenever `A > D` - so a
	-- player who did the arithmetic and was told they would win, wins.
	exchange_depth = 4,       -- how drawn-out an even fight is
	max_exchanges = 6,        -- and the most a replay will ever have to show
	-- What a commander's own rank absorbs each exchange before their units take
	-- anything, as a level divisor. A veteran wins the same fights and comes out
	-- of them stronger, which is worth more than any single battle - and because
	-- it only ever reduces losses, it can never flip a fight the player had
	-- calculated as winnable.
	shield_per_levels = 2,

	-- Stock deliberately does **not** defend the city holding it. It did, and
	-- it nearly doubled what a city cost to take - which re-froze the map that
	-- combat had just unfrozen, because defence accumulated for free while an
	-- attacker had to carry theirs across the realm. Fortifying is a choice a
	-- player makes, not something that happens to a world nobody visited.
	--
	-- What a unit is *worth* and what it *costs* now both depend on its type -
	-- see realm/sim/units.lua. A city's stock is still counted in units of
	-- any kind, because a berth is a berth.

	-- Orders --------------------------------------------------------------------
	-- **How many decisions a turn is worth.** Not a safety limit - a scarcity.
	-- With an empire of four commanders and a dozen cities there is always more
	-- worth doing than this allows, so a turn is a choice about what matters
	-- most rather than a round of housekeeping.
	--
	-- It works at three because **a route is a standing order**: a commander given
	-- somewhere to go keeps going, across as many turns as it takes, without
	-- costing anything further. An order is what it costs to *change* a plan,
	-- not to maintain one, and most turns have only one or two things worth
	-- changing.
	orders_per_turn = 3,

	-- What each kind costs, as data rather than a rule buried in the resolver,
	-- so making one of them free is a single edit. Resupply is deliberately not
	-- free: a commander that could always top up for nothing would always top up,
	-- and collecting would be a chore rather than a decision again.
	-- **An order is something that happens somewhere.** Moving a commander,
	-- raising a building, raising an officer. Buying and transferring are not:
	-- buying is spending, and a transfer is a commander rearranging what is
	-- already yours at a place it is already standing.
	--
	-- Buying used to cost one. That was right while a purchase went straight
	-- into a hold and needed a commander present - "a commander that could always
	-- top up for nothing would always top up". It stopped being right the
	-- moment purchases went into the city instead: charging an empire act
	-- means a rich player with four cities banks gold they cannot convert,
	-- which is precisely the failure buildings were introduced to fix,
	-- reappearing one level down. Gold itself is the scarcity now, the way
	-- gold is.
	order_cost = { move = 1, build = 1, recruit = 1, buy = 0, transfer = 0 },

	-- Buildings ----------------------------------------------------------------
	-- Two slots against four buildings, so a city specialises rather than
	-- accumulating everything. See realm/sim/buildings.lua for what each does.
	-- **Four slots, five buildings.** You give up exactly one, and where the
	-- city sits is what decides which: a Bastion on the frontier, an
	-- Admiralty somewhere safe. Two was right when a building was a multiplier
	-- on production that happened anyway; with a dwelling per unit type it
	-- would have meant a city could never make more than one thing and also
	-- be anything else.
	-- **What a city can hold, and why it is capped at all.**
	--
	-- A garrison being *bought* is not enough to make it safe. An attacker's
	-- power is bounded by `commander_units` - no amount of wealth lets one bring
	-- more than a hold - while a defender's was bounded by nothing, so past
	-- some purse every world became uncrackable. Measured: with an uncapped
	-- garrison three seeds in ten never decided at all, territory bit-identical
	-- from turn 800 to 900, two players on three of the four provinces they
	-- needed. That is the same freeze combat was built to end, wearing a
	-- receipt.
	--
	-- Pegged to what one commander carries, and stated that way on purpose: **a
	-- city holds what one commander can bring.** So a defended world costs
	-- about one officer's worth over its own walls, and both halves of the
	-- comparison stay numbers a player can add up.
	garrison_cap = 6,

	building_slots = 4,
	bastion_defence = 8,      -- Bastion: flat resistance

	-- Commanders. One to begin with, one more per Admiralty, and a hard ceiling
	-- because the commander strip is a row of faces rather than a list.
	commander_cap = 1,
	commander_cap_max = 4,
	commander_cost = 180,

	commander_max_level = 10,
	-- Experience is the strength a commander has overcome, so a city is worth
	-- more than open country without anything having to say so. Low enough that a
	-- promotion is a few real fights rather than a campaign - the ladder was
	-- written when experience meant ships destroyed and there were thousands of
	-- them about.
	commander_xp_base = 8,

	-- Intelligence ------------------------------------------------------------
	-- Lanes of vision from each source. A commander sees barely past itself; a
	-- world you hold sees its own neighbourhood.
	base_vision = 1,              -- baseline (via vision)
	commander_vision = 1,

	-- Provinces -----------------------------------------------------------------
	-- The map is far larger than anyone will hold, so the objective is the
	-- province rather than the tile count - see realm/sim/provinces.lua.
	victory_province_fraction = 0.5,

	-- Starting position -------------------------------------------------------
	-- A seat must have somewhere to expand into, or the game is decided at
	-- generation rather than in play.
	seat_hops = 3,
	seat_neighbours = 3,
}
