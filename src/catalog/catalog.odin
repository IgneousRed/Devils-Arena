package catalog

// -------------------------------- Constants --------------------------------

// ---------------- Public ----------------

GAME_TITLE :: "Devil's Arena"

COMBATANT_COUNT :: 2

STARTING_STAT :: f64(100)

// Prototype tuning uses arena units and seconds; damage is a fraction of starting HP.
ARENA_RADIUS :: f64(420)

WORLD_LIMIT :: f64(560)

BODY_RADIUS :: f64(18)

MOVE_SPEED :: f64(230)

TICK_SECONDS :: f64(0.01)

BATTLE_TICKS :: u32(6000)

METEOR_FLASH_SECONDS :: f64(0.18)

ITEM_LIMIT :: 16

EFFECT_LIMIT :: 32

// -------------------------------- Globals --------------------------------

// ---------------- Public ----------------

@(rodata) COMBATANT_NAMES := [COMBATANT_COUNT]string{"Player", "Dummy"}

@(rodata) STAT_NAMES := [6]string{"HP", "Armor", "Power", "Speed", "Reflex", "Mastery"}

@(rodata) SIMULATION_SPEEDS := [?]u8{1, 2, 4, 8}

@(rodata)
SPELLS := [Spell]Spell_Definition{
	.None = {},
	.Fireball = {item = "Ember Wand", name = "Fireball", description = "An aimed fireball. Hit the dummy to push it toward lava.",
		cooldown = 1.4, damage = 0.12, knockback = 260, projectile_speed = 560, radius = 12, lifetime = 1.8},
	.Lightning = {item = "Storm Rod", name = "Lightning", description = "An instant straight strike with a strong push.",
		cooldown = 3, damage = 0.10, knockback = 340, radius = 14, lifetime = 0.16},
	.Meteor = {item = "Fallen Star", name = "Meteor", description = "A marked blast lands after a short delay. Aim ahead.",
		cooldown = 4.5, damage = 0.24, knockback = 420, radius = 90, lifetime = 0.9},
	.Teleport = {item = "Rift Stone", name = "Teleport", description = "Blink toward the cursor, up to 240 arena units.",
		cooldown = 3.5, range = 240, radius = 24, lifetime = 0.25},
	.Swap = {item = "Mirror Charm", name = "Swap", description = "A projectile that exchanges your position with its target.",
		cooldown = 4, projectile_speed = 620, radius = 14, lifetime = 1.8},
}

// -------------------------------- Types --------------------------------

// ---------------- Public ----------------

// Values are persisted identifiers; add values without renumbering existing spells.
Spell :: enum u8 {None = 0, Fireball = 1, Lightning = 2, Meteor = 3, Teleport = 4, Swap = 5}

Spell_Definition :: struct {
	item, name, description: string,
	cooldown, damage, knockback, projectile_speed, range, radius, lifetime: f64,
}
