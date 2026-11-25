#+test
#+private file
package engine

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:math"
import "core:testing"

// ---------------- Project ----------------

import "../state"

// -------------------------------- Procedures --------------------------------

// ---------------- File ----------------

@(test)
atomic_transactions_and_automatic_subscriptions :: proc(t: ^testing.T) {
	live = {}
	tx := begin()
	testing.expect(t, commit(&tx))
	testing.expect_value(t, tx.checks, CONSTRAINT_COUNT)
	testing.expect(t, commit(&tx))
	testing.expect_value(t, tx.checks, 0)
	stale := begin()
	tx.data.facts.combatants[0].health = 10
	testing.expect(t, commit(&tx))
	testing.expect_value(t, tx.checks, 1)
	testing.expect(t, !commit(&stale))

	testing.expect_value(t, stale.error, Commit_Error.Stale)
	// A real conditional constraint subscribes only while the Battle needs bodies.
	testing.expect(t, BODIES not_in live.dependencies[BATTLE])
	tx.data.facts.battle.phase = .Active
	for &c in tx.data.facts.combatants {c.health = 100}
	for &b in tx.data.facts.bodies {b.starting_health = 100}
	testing.expect(t, commit(&tx))
	testing.expect(t, BODIES in live.dependencies[BATTLE] && COMBATANT in live.dependencies[BATTLE])
	tx.data.facts.bodies[0].starting_health = 0
	testing.expect(t, !commit(&tx) && tx.error == .Invalid && tx.constraint == BATTLE)
	tx = begin()
	tx.data.facts.battle.phase = .Picking
	testing.expect(t, commit(&tx))
	testing.expect(t, BODIES not_in live.dependencies[BATTLE] && COMBATANT not_in live.dependencies[BATTLE])
	tx.data.facts.bodies[0].starting_health = 0
	testing.expect(t, commit(&tx) && tx.checks == 1, "Picking removes conditional body dependencies")

	before := live
	tx.data.facts.combatants[0].health = math.INF_F64
	tx.data.ui.selected = 1
	testing.expect(t, !commit(&tx))
	testing.expect(t, live == before, "Invalid commits publish neither facts nor subscriptions")
	tx = begin()
	tx.data.facts.session.speed_index = 255
	testing.expect(t, !commit(&tx))
	tx = begin()
	tx.data.ui.selected = -1
	testing.expect(t, !commit(&tx))
	tx = begin()
	tx.data.facts.activity[0].move_progress = -1
	testing.expect(t, !commit(&tx))
	testing.expect_value(t, live, before)
	tx = begin()
	tx.data.notice = state.Notice.Saved
	testing.expect(t, commit(&tx))
	testing.expect_value(t, tx.checks, 1)

	tx = begin()
	tx.data.facts.spells[0] = {spell = .Fireball, x = 140, vx = 560}
	testing.expect(t, !commit(&tx) && tx.constraint == SPELLS, "Reject an active effect without lifetime")
	tx = begin()
	tx.data.facts.spells[0].owner = 1
	testing.expect(t, !commit(&tx) && tx.constraint == SPELLS, "Unused effects have one canonical zero representation")
	tx = begin()
	tx.data.facts.battle.phase = .Active
	for &b in tx.data.facts.bodies {b.starting_health = 100}
	tx.data.facts.combatants[0].health = 0
	testing.expect(t, !commit(&tx) && tx.constraint == BATTLE, "Active battles require two living players")
	tx.data.facts.battle.phase = .Player_Won
	testing.expect(t, !commit(&tx), "A terminal outcome must agree with the committed HP")
	tx.data.facts.battle.phase = .Dummy_Won
	testing.expect(t, commit(&tx))
	tx.data.facts.combatants[0].health = 200
	testing.expect(t, !commit(&tx) && tx.constraint == BATTLE, "HP changes invalidate outcome constraints")
}
