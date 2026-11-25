# Implemented practice gameplay


The practice implementation uses the agreed six stats, Armor, critical/dodge,
relative-Speed cooldown progression, independently held casts, shrinking arena,
and cumulative lava damage. Power scaling, zero-denominator rules, NN control,
and the full Match/economy loop remain deferred.

Scope:
  Pick from five authored Items, each granting one spell.
  Pick any nonempty subset before entering the arena; all five can be picked.
  An empty build shows the pick requirement instead of an unusable Enter arena action.
  Each Item can be owned only once. The stored inventory supports the agreed 16-Item limit.
  The picker marks opponent-owned Items as unavailable instead of offering a rejected pick.
  Picking order does not change a spell's key.
  Items are free in practice; Tokens, simultaneous opponent picking, and Match progression are deferred.
  Player 2 does not move or cast independently; it receives damage and spell knockback normally.
  RestartBattle restores health, positions, cooldowns, and active spells; it preserves picked Items.
  PickItems returns to the picker and preserves ownership. Reset clears the whole prototype.

PracticeSpells:
  Ember Wand / Fireball / Q: Aimed projectile; damage and knockback on impact.
  Storm Rod / Lightning / E: Instant straight strike spanning the square world's diagonal; damage and knockback on intersection.
  Fallen Star / Meteor / R: Mark a location; delayed area damage and outward knockback.
  Rift Stone / Teleport / F: Blink toward the mouse, capped at 240 arena units.
  Mirror Charm / Swap / Space: Aimed projectile; exchange positions on impact.
  The project implements its own small spell set; the numbers are provisional practice tuning.

PracticeControls:
  WASD moves player 1; the camera follows that character and mouse position aims spells.
  Direction follows the cursor even beyond the world boundary; only a cursor at the caster invokes the opponent fallback.
  Meteor ground targets and resulting body positions remain bounded by the world.
  Hold independent spell keys while pointing over the arena view, including its lava area. Keys activate only owned Items.
  F5 saves and F9 loads; S is reserved for movement.
  The sidebar shows keys and remaining cooldowns. The inspector retains simulation-speed selection.
  Battle readouts show both players' HP, Armor, and cumulative lava exposure.
  The selected combatant's inspector shows critical/dodge chances and cooldown progression as percentages;
  undefined zero-stat ratios display "Rule pending" rather than an invented rate.
  Notices appear beside the top controls. The inspector identifies pending Power effects and retained
  Dodges, Misses, and Move progress counters that practice combat does not update; Kills remains live.

PracticeSimulation:
  Fixed 100 Hz ticks, separate from rendering. Unfocused windows pause.
  Frame catch-up is capped at 0.1 seconds before applying simulation speed.
  All six stats reset to 100 each Battle. Starting HP is the saved stat-scale reference.
  Every owned spell starts on full cooldown. Held casts repeat and preserve cooldown overshoot;
  readiness alone does not cast. Relative Speed affects cooldown progression only.
  Actions read beginning-of-Tick values and consolidate all stat, position, and velocity changes before application.
  Critical and dodge are independent per-player rolls shared across the Tick, using the impact Tick for delayed effects.
  Knockback impulses add together. Lava exposure is sampled before movement and Teleport.
  New persistent spell effects begin advancing on the following Tick.
  The arena radius derives from elapsed Battle Ticks and shrinks linearly to zero at 6000 Ticks.
  Lava damage before Armor is `starting_health * 1e-8 * LavaTicks^2`, with a provisional balance coefficient.
  Exposure persists across visits and resets each Battle. The agreed character-center test counts lava
  exposure only when the center is strictly outside the circle; a center on the boundary remains inside.
  Undefined zero-stat ratios pause without changing facts; a notice explains why. No fallback formula is assumed.
  Death is checked after spell and lava effects; simultaneous defeat draws.
  Defeat takes precedence over the time limit. Finished battles stop advancing.
  Active positions, impulses, Items, cooldowns, spells, starting HP, lava exposure, Battle seed, and Tick count are saved facts.
  Saves and development snapshots use version three. Retained v1/v2 migrations preserve compatible legacy values,
  active combat, UI, and notices, add Reflex/Mastery at 100, remove Agility, and clamp old negative stats to zero.
  Legacy Battle seeds and lava exposure begin at zero because neither was previously recorded.
  Original development snapshots are backed up by source version before later captures replace them.


## Combat stat contract

All six stats begin each Battle at 100 and clamp to a minimum of zero once per
Tick after simultaneous effects. Healing can exceed starting HP. Power is stored
and displayed but does not yet scale effects.

Armor uses beginning-of-Tick values:
`Toughness = Armor / (HP + Armor)`,
`ReducedDamage = Damage * (1 - Toughness)`,
`DamageToArmor = ReducedDamage * Toughness`,
`DamageToHP = ReducedDamage - DamageToArmor`.
Lava uses the same reduction but is neither an opponent spell nor a critical effect.

Critical chance is `Mastery / (Mastery + OppReflex)`; dodge chance is
`Reflex / (Reflex + OppMastery)`. Independent per-player rolls are shared across
the Tick, using the impact Tick for delayed effects. Critical alone doubles
numeric combat-stat changes but not movement or utility; dodge alone cancels an
incoming spell completely. Critical and dodge together produce the normal effect.
Equal opposing stats give 50% chances. The lower-Speed player's cooldown rate is
`Speed / OppSpeed`; the other player progresses at baseline. Movement speed is
independent of the Speed stat. Undefined zero-denominator rules pause combat
without advancing or resetting facts.

The implemented storage, replay, transaction and recovery contracts are in
[ARCHITECTURE.md](../ARCHITECTURE.md). [README.md](../README.md) covers running,
controls and verification. Intended features and historical proposals are not
runtime dependencies or additional implemented behavior.
