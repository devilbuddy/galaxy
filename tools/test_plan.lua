-- The staged order plan: what survives a send, and what a resolving turn takes.
--
-- Written for one specific defect. `game.orders` *replaces* the batch the server
-- holds rather than appending to it, and the client used to clear `store.orders`
-- as soon as a send succeeded. So the sequence any player would actually
-- perform - send an order, notice another one, send again - shipped a second
-- batch containing only the new order, and the server dutifully threw the first
-- one away. Nothing errored and the button said SEND both times.
--
-- Run: luajit tools/test_plan.lua

package.path = "./?.lua;" .. package.path

local store = require("main.store")

local failures = 0

local function check(name, ok, detail)
	if ok then
		print("  ok   " .. name)
	else
		failures = failures + 1
		print("  FAIL " .. name .. (detail and ("  (" .. detail .. ")") or ""))
	end
end

local function reset()
	store.orders = {}
	store.pending_research = nil
	store.orders_turn = nil
	store.sent_signature = nil
	store.sent_turn = nil
end

--- What a send would put on the wire, built the way main/hud.gui_script does.
local function payload()
	local out = {}
	for i = 1, #store.orders do out[#out + 1] = store.orders[i] end
	if store.pending_research ~= nil then
		out[#out + 1] = { kind = "research", tech = store.pending_research }
	end
	return out
end

local function unsent()
	if store.plan_count() == 0 then return false end
	return store.sent_signature ~= store.plan_signature()
end

print("plan: counting")
reset()
check("empty plan counts zero", store.plan_count() == 0)
check("empty plan has nothing unsent", not unsent())
store.orders[1] = { kind = "garrison", fleet = 4 }
check("one order counts one", store.plan_count() == 1)
store.pending_research = "ion_drive"
check("research counts as an order", store.plan_count() == 2)
store.pending_research = ""
check('"stop researching" still counts', store.plan_count() == 2)

print("plan: unsent detection")
reset()
store.orders[1] = { kind = "build", at = 7, building = "radar" }
check("a fresh order is unsent", unsent())
store.plan_sent(50)
check("sending clears it", not unsent())
store.orders[2] = { kind = "garrison", fleet = 1 }
check("adding one makes it unsent again", unsent())
store.plan_sent(50)
check("sending again clears it", not unsent())
store.orders[1].building = "fortress"
check("revising an order in place is unsent", unsent())

print("plan: a send does not wipe what it sent")
reset()
store.orders[1] = { kind = "launch", at = 3, ships = 12, route = { 9 } }
local first = payload()
check("first send carries one order", #first == 1, "#=" .. #first)
store.plan_sent(50)
check("the plan survives the send", store.plan_count() == 1,
	"count=" .. store.plan_count())

-- The defect, exactly: notice a second move and send again.
store.orders[2] = { kind = "build", at = 3, building = "shipyard" }
local second = payload()
check("the second send carries BOTH orders", #second == 2, "#=" .. #second)
check("...including the launch from the first send",
	second[1].kind == "launch" and second[1].at == 3)
check("...and the new build", second[2].kind == "build")

store.pending_research = "ion_drive"
local third = payload()
check("research travels with the fleet orders, not instead of them",
	#third == 3 and third[3].kind == "research", "#=" .. #third)

print("plan: a resolving turn consumes it")
reset()
store.orders[1] = { kind = "garrison", fleet = 2 }
store.pending_research = "ion_drive"
store.plan_sent(60)
check("an earlier turn resolving leaves it alone", not store.plan_consumed(59))
check("...and it still holds both", store.plan_count() == 2)
check("its own turn resolving consumes it", store.plan_consumed(60))
check("...leaving nothing staged", store.plan_count() == 0)
check("...and no research", store.pending_research == nil)
check("...and nothing marked sent", store.sent_signature == nil
	and store.sent_turn == nil and store.orders_turn == nil)

-- A player who staged orders but never sent them still has them consumed: the
-- turn they were aimed at has gone, and a launch route is only valid against
-- the map that produced it.
reset()
store.orders[1] = { kind = "move", fleet = 3, route = { 4, 5 } }
store.orders_turn = 61
check("an unsent plan is consumed too", store.plan_consumed(61))
check("...leaving nothing staged", store.plan_count() == 0)

-- A plan with no turn against it cannot be stale: the HUD adopts the coming
-- turn on the frame anything is staged, so this is the pre-staging state.
reset()
store.orders[1] = { kind = "garrison", fleet = 9 }
check("a plan with no turn is left alone", not store.plan_consumed(99))
check("...and keeps its order", store.plan_count() == 1)

print("plan: signatures are stable and specific")
reset()
store.orders[1] = { kind = "launch", at = 1, ships = 2, route = { 3, 4 } }
local a = store.plan_signature()
check("the same plan signs the same twice", a == store.plan_signature())
store.orders[1].route = { 3, 5 }
check("a different route signs differently", a ~= store.plan_signature())
store.orders[1].route = { 3, 4 }
check("and back again", a == store.plan_signature())
store.orders[1].ships = 3
check("a different count signs differently", a ~= store.plan_signature())

if failures > 0 then
	print(string.format("\n%d PLAN TEST(S) FAILED", failures))
	os.exit(1)
end
print("\nALL PLAN TESTS PASSED")
