-- AI genereated examples

--[[
	CurseRework example mod.

	Everything a consumer has to write is in this one file. Three curses, each showing a
	different part of the API:

		example:rust    plain registration -- a fixed weight and an effect
		example:frail   a per floor gate (IsAllowed)
		example:swarm   a dynamic weight (a function instead of a number)

	The lib owns the rest: the roll, the save format, the Enabled/Weight settings, the Mod
	Config Menu entries and the HUD icons. None of that is written here.

	See ../README.md for the full reference.
]]

local mod = RegisterMod("CurseRework Example", 1)
local game = Game()

--- Init() elects the newest copy of the lib across every mod that embeds one and returns it.
--- The winner is the global CurseRework. Always go through the global afterwards -- never hold
--- the return value in an upvalue, or a newer copy taking over would leave you calling a dead
--- one. It is nil-safe to check: a user can have the lib missing entirely.
include("lib.curse_rework").Init()

if not CurseRework then
	print("CurseRework Example: lib is missing, curses are disabled")
	return
end

---------------------------------------------------------------------------
--- Icons
---------------------------------------------------------------------------

--- One sheet for every curse. The lib keeps the Sprite and reframes it per icon, so a single
--- one covers all three -- see resources/gfx/ui/example_curse_icons.anm2.
local icons = Sprite()
icons:Load("gfx/ui/example_curse_icons.anm2", true)

--- Declared in content/curses.xml. One vanilla bit stands in for every curse below, so Black
--- Candle and Level:RemoveCurses keep working without spending a bit per curse.
local CARRIER = "Curse of the Example!"

---------------------------------------------------------------------------
--- Registration
---------------------------------------------------------------------------

--- Register returns the id back, or nil if the config was rejected (the reason is logged).
--- Keep the ids in constants: they are the save keys, so renaming one resets its settings.
local RUST = CurseRework.Register({
	Id      = "example:rust",
	Name    = "Curse of Rust!",       -- shown in the HUD curse text
	Description = "Coins rot away between floors",  -- for EID and the config menu
	Icon    = {icons, "curses", 0},   -- {sprite, animation, frame}
	Carrier = CARRIER,
	Mod     = mod,                    -- keys per mod storage and the config menu Filter
	Weight  = 1.0,                    -- the RESET value; the player's setting owns it after
})

local FRAIL = CurseRework.Register({
	Id      = "example:frail",
	Name    = "Curse of the Frail!",
	Description = "Isaac deals less damage",
	Icon    = {icons, "curses", 1},
	Carrier = CARRIER,
	Mod     = mod,
	Weight  = 1.0,

	--- Per floor gate, asked every time the pool is built. Return false to keep this curse off
	--- this floor. The context table is documented in the README.
	IsAllowed = function(def, context)
		--- nothing this punishing on the first floor
		if context.Stage <= LevelStage.STAGE1_1 then return false end

		--- Optional, and worth copying: stay off floors the game already cursed. Mask out the
		--- carriers first, or our own bit reads as "the game cursed this floor".
		local otherCurses = game:GetLevel():GetCurses() & ~CurseRework.GetCarrierMask()
		return otherCurses == LevelCurse.CURSE_NONE
	end,
})

local SWARM = CurseRework.Register({
	Id      = "example:swarm",
	Name    = "Curse of the Swarm!",
	Description = "Every room has an extra fly",
	Icon    = {icons, "curses", 2},
	Carrier = CARRIER,
	Mod     = mod,

	--- A function weight replaces the player's weight slider entirely -- it becomes the sole
	--- authority, so only use one for a curse whose frequency really is dynamic. Returning 0
	--- takes the curse out of the pool for this floor.
	Weight = function(def, context)
		if context.IsGreedMode then return 0 end
		return 0.5 + context.Stage * 0.25   -- more likely the deeper you go
	end,

	--- Greed Mode, the Ascent and Home are opt-in per curse. Left off here, like vanilla.
	-- AllowGreedMode = true,
	-- AllowAscent = true,
	-- AllowUncursableStages = true,
})

---------------------------------------------------------------------------
--- Settings storage (optional)
---------------------------------------------------------------------------

--- Skip this whole block and the settings live in CurseRework's own save file, which follows
--- whichever embedded copy got elected. Claim them here if your mod has a save system of its
--- own and you would rather they travelled with it.
---
--- Storage is per mod: only the curses registered with Mod = mod are written here, so another
--- mod being uninstalled never takes yours with it, and yours never clobbers theirs.
--[[
CurseRework.SetStorage(mod, {
	Save = function(encoded)        -- encoded is a JSON string
		MySaveSystem.settings.CurseRework = encoded
	end,
	Load = function()
		return MySaveSystem.settings.CurseRework
	end,
})

--- Only needed if SetStorage ran before your save system was up.
CurseRework.ReloadSettings()
]]

---------------------------------------------------------------------------
--- Mod Config Menu
---------------------------------------------------------------------------

--- One call builds the whole tab: the roll knobs, then an enable toggle and a weight slider
--- for every curse the Filter keeps. Nothing per curse to write.
---
--- Roll defaults to true. Leave it on in exactly one place across all your tabs, or the three
--- roll sliders appear twice.
CurseRework.AddConfigMenu({
	ModName  = "CurseRework Example",   -- your MCM category
	Category = "Curses",                -- the tab inside it
	Title    = "Curse rolling",
	Filter   = function(def) return def.Mod == mod end,
})

---------------------------------------------------------------------------
--- Reacting to the roll (optional)
---------------------------------------------------------------------------

--- Custom callback ids, so they go on your own mod handle like any other callback.

mod:AddCallback(CurseRework.Callbacks.PRE_CURSE_ROLL, function(_, context)
	--- return false to leave the floor uncursed
	--- return an id, or an array of ids, to force exactly those and skip the whole roll
	---   (Black Candle included -- forcing means forcing)
	--- return nothing to let the roll proceed
	if context.Stage == LevelStage.STAGE4_3 then return false end   -- never curse Mausoleum II
end)

mod:AddCallback(CurseRework.Callbacks.POST_CURSE_ROLL, function(_, activeIds, context)
	for index = 1, #activeIds do
		print("CurseRework Example: floor rolled " .. activeIds[index])
	end
end)

---------------------------------------------------------------------------
--- The curses themselves
---------------------------------------------------------------------------

--- IsActive(id) is the whole read side of the API. It is cheap -- the roll is cached per floor
--- and derived from the stage seed, so ask it wherever you need it rather than caching it.

mod:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, function()
	if not CurseRework.IsActive(RUST) then return end
	for index = 0, game:GetNumPlayers() - 1 do
		local player = Isaac.GetPlayer(index)
		player:AddCoins(-1)
	end
end)

mod:AddCallback(ModCallbacks.MC_EVALUATE_CACHE, function(_, player, cacheFlag)
	if cacheFlag ~= CacheFlag.CACHE_DAMAGE then return end
	if not CurseRework.IsActive(FRAIL) then return end
	player.Damage = player.Damage * 0.8
end)

--- Curses come and go between floors, so anything cached off them has to be re-evaluated.
mod:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, function()
	for index = 0, game:GetNumPlayers() - 1 do
		local player = Isaac.GetPlayer(index)
		player:AddCacheFlags(CacheFlag.CACHE_DAMAGE)
		player:EvaluateItems()
	end
end)

mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
	if not CurseRework.IsActive(SWARM) then return end
	local room = game:GetRoom()
	if room:IsClear() or room:IsFirstVisit() == false then return end
	Isaac.Spawn(EntityType.ENTITY_FLY, 0, 0, room:GetRandomPosition(40), Vector.Zero, nil)
end)

---------------------------------------------------------------------------
--- Testing
---------------------------------------------------------------------------

--- Add/Remove force a curse on or off for the rest of the floor, on top of whatever rolled.
--- They are persisted and survive a luamod, so ClearOverrides is how you get back to the
--- rolled result. Handy from the REPENTOGON console.
mod:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, command, args)
	if command ~= "excurse" then return end
	if args == "clear" then
		CurseRework.ClearOverrides()
		print("overrides cleared")
	elseif args == "reroll" then
		CurseRework.ForceReroll()
	elseif CurseRework.Get(args) then
		if CurseRework.IsActive(args) then
			CurseRework.Remove(args)
		else
			CurseRework.Add(args)
		end
		print(args .. " is now " .. tostring(CurseRework.IsActive(args)))
	else
		print("usage: excurse <example:rust|example:frail|example:swarm|clear|reroll>")
	end
end)
