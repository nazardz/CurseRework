--[[
	CurseRework -- table based curse registry for The Binding of Isaac: Repentance
	Version 3.1

	REPENTOGON 1.1.1+ is required. The fallback icon renderer uses Minimap.GetDisplayedSize(),
	Minimap.GetState(), MC_INPUT_ACTION with InputHook, and MC_PRE_ITEM_TEXT_DISPLAY -- all
	REPENTOGON additions. MC_POST_MODS_LOADED is also REPENTOGON; Register() runs the MinimapAPI
	sync too, so the only thing lost without it is map flags for a mod that registered before
	MinimapAPI loaded.

	Vanilla keeps curses in a 32 bit field and already owns 8 of those bits. Once the mods on
	a save have claimed the rest, every further curse silently aliases onto somebody else's bit
	-- it shows a foreign icon and its checks fire on the wrong floor. CurseRework keeps curses
	in a plain table instead, so there is no cap and no cross mod collision.

	Embed this file in your own mod and call .Init(). Do not ship it as a standalone Workshop
	mod: Isaac has no dependency resolution, so a consumer would break the moment a user forgot
	to subscribe. Every host carries its own copy, the highest version present wins, and it
	inherits everything the older copy had registered.

		include("path.to.curse_rework").Init()

	Active curses are derived from the stage seed rather than saved, so they survive a save slot
	being copied, a host mod being disabled, or the elected copy changing hands. Settings and
	manual Add/Remove calls are the only things written to disk.

	Registering a curse:

		CurseRework.Register({
			Id = "eclipsed:void",                       -- required, namespaced, stable forever
			Name = "Curse of the Void!",                -- required, shown to the player
			Description = "Rerolls enemies and grid",   -- optional, for EID / config menus
			Weight = 1.0,                               -- reset value for the player's setting,
			                                            -- or function(def, context) to opt out
			                                            -- of the setting entirely
			DefaultEnabled = true,                      -- optional, defaults to true
			IsAllowed = function(def, context) return context.Stage > 1 end,
			Icon = {sprite, "curses", 0},               -- optional, {Sprite, animation, frame}
			Carrier = "Curse of Eclipsed!",             -- optional, see below
			Mod = myMod,                                -- optional, identifies the owner
			AllowGreedMode = false,                     -- optional, off: skip Greed Mode
			AllowAscent = false,                        -- optional, off: skip the Ascent
			AllowUncursableStages = false,              -- optional, off: skip Home
		})

	Vanilla blocks its own curse roll in Greed Mode, on the Ascent and on Home, so those three are
	off by default here too. On the Ascent it does not even fire MC_POST_CURSE_EVAL, which is why
	the gate lives in eligibility rather than in that hook. Basement 1 is deliberately left
	cursable, unlike vanilla, which forces the chance to 0 there until Everything Is Terrible is
	unlocked.

	Settings and the config menu:

		Enabled and Weight belong to CurseRework, not to you -- you do not have to store them,
		save them, or build a menu for them.

			CurseRework.IsEnabled(id) / SetEnabled(id, bool)
			CurseRework.GetWeight(id) / SetWeight(id, number)
			CurseRework.GetRoll(name) / SetRoll(name, value)   -- "Chance", "MaxCurses", "ExtraChance"
			CurseRework.ResetSettings(filter)                  -- filter(def) -> boolean, optional

		One call builds the whole Mod Config Menu tab -- roll knobs, then an enable toggle and a
		weight slider per curse, under your own MCM category:

			CurseRework.AddConfigMenu({
				ModName = "Eclipsed",                        -- your MCM category
				Category = "Curses",                         -- the tab inside it
				Filter = function(def) return def.Mod == myMod end,  -- optional
				Roll = true,                                 -- optional, roll knobs, on by default
				PerCurse = function(def) ... end,            -- optional, append your own widgets
			})

		By default settings live in CurseRework's own save file, which follows whichever embedded
		copy got elected. A mod with a save system of its own should claim a place for the curses
		it registered -- storage is per mod, so uninstalling one never drops another's settings:

			CurseRework.SetStorage(myMod, {Save = function(encoded) ... end,
			                               Load = function() return encoded end})
			CurseRework.ReloadSettings()   -- if SetStorage ran before that save system was up

	Carriers:

		Curses live in a table, so Level:GetCurses() does not know about them and neither does
		anything built on it -- Black Candle, Level:RemoveCurses, other mods asking whether the
		floor is cursed. Name one vanilla curse from your own content/curses.xml as Carrier and
		its bit is mirrored into the real mask whenever any curse using it is active. One entry
		covers all of your curses, so it costs a single slot rather than one per curse. Give it no
		icon: REPENTOGON reads the "curses" animation of your content/gfx/mapitemicons.anm2 and
		draws nothing for a curse with no frame there, so either leave the frame out or, if the
		file holds icons you use elsewhere, name that animation something other than "curses".
		The carrier stands in for whichever curse actually rolled, so a fixed icon would lie.
		Clearing that bit from outside removes the curses behind it. Use CurseRework.GetCarrierMask() to mask carriers out of your own "is this floor
		already cursed" tests. Everything still works with no carrier, just without the mirror.

	Querying it:

		CurseRework.IsActive("eclipsed:void")
		CurseRework.GetActive()   --> sorted array of ids
		CurseRework.Add(id) / CurseRework.Remove(id)   -- manual, lasts the floor

	Callbacks (REPENTOGON custom callbacks, added on your own mod handle):

		CurseRework.Callbacks.PRE_CURSE_ROLL   (context)
			return false to leave the floor uncursed, a registered id to force that curse, or an
			array of ids to force several.
		CurseRework.Callbacks.POST_CURSE_ROLL  (activeIds, context)
]]

local LOCAL_CURSEREWORK = {}

function LOCAL_CURSEREWORK.Init()
	local LOCAL_VERSION = 3

	local inheritedRegistry, inheritedOrder, inheritedSettings, inheritedRoll
	local inheritedStorages, inheritedConfigBuilt
	local inheritedOverrides, inheritedOverrideKey, inheritedAnnouncedKey
	local inheritedTrapdoors
	if CurseRework then
		if CurseRework.Version and CurseRework.Version > LOCAL_VERSION then
			return CurseRework
		end
		if CurseRework.Internal then
			--- a newer copy takes over the callbacks but keeps every curse the old one knew about,
			--- otherwise mods that loaded before us would lose their registrations. Settings and
			--- the menu built flag come along too, or a reload would double every MCM entry.
			inheritedRegistry = CurseRework.Internal.Registry
			inheritedOrder = CurseRework.Internal.Order
			inheritedSettings = CurseRework.Internal.Settings
			inheritedRoll = CurseRework.Internal.Roll
			inheritedStorages = CurseRework.Internal.Storages
			inheritedConfigBuilt = CurseRework.Internal.ConfigBuilt
			--- luamod re-runs the file mid run. The rolled curses come back on their own, being
			--- derived from the stage seed, but manual Add/Remove would not: they are saved, yet
			--- only read back by Load(true) on a continue, and that does not happen here. The
			--- announce key rides along too, or the floor's curse text fires a second time.
			inheritedOverrides = CurseRework.Internal.Overrides
			inheritedOverrideKey = CurseRework.Internal.OverrideKey
			inheritedAnnouncedKey = CurseRework.Internal.AnnouncedKey
			--- Accursed keeps the Sprite objects we handed it and renders them itself, so the
			--- entries have to come along or a reload would leave us reframing sprites nobody
			--- draws. Doubles as the "already registered" guard: Accursed cannot drop an entry.
			inheritedTrapdoors = CurseRework.Internal.Trapdoors
			if CurseRework.Internal.RemoveCallbacks then
				CurseRework.Internal.RemoveCallbacks()
			end
		end
	end

	CurseRework = RegisterMod("CurseRework", 1)
	CurseRework.Version = LOCAL_VERSION

	local game = Game()
	local jsonOk, json = pcall(require, "json")
	if not jsonOk then json = nil end

	--- shift index handed to RNG:SetSeed, any value in 0..80 works
	local RNG_SHIFT = 35
	--- Home has no curses in vanilla and nothing sensible to curse
	local UNCURSABLE_STAGES = {
		[LevelStage.STAGE8] = true,
	}

	--- chance that a floor gets cursed at all. Shared across every consumer -- last writer wins,
	--- so treat it as a user facing setting rather than something a single mod owns.
	--- MaxCurses / ExtraChance say how many curses one floor may roll and the chance of each one
	--- after the first. Defaults keep the old behaviour: at most a single curse per floor. Manual
	--- Add stacks regardless, and every active curse gets its own icon either way.
	--- Read and write these with CurseRework.GetRoll / SetRoll -- they are persisted.
	CurseRework.RollDefaults = {
		Chance = 0.33,
		MaxCurses = 1,
		ExtraChance = 0,
	}

	CurseRework.Callbacks = {
		PRE_CURSE_ROLL = "CURSEREWORK_PRE_CURSE_ROLL",
		POST_CURSE_ROLL = "CURSEREWORK_POST_CURSE_ROLL",
	}

	--- per-frame cache so Anchor does not re-scan the room list every render tick.
	--- large tracks the resolved isLarge value so the cache can invalidate on mode changes.
	local minimapHeightCache = {height = 80, frame = -1, large = false}
	--- frames the map key has been held this update cycle; mirrors MinimapAPI's mapheldframes.
	--- Tracked in MC_INPUT_ACTION so it uses the actual player controller index.
	local mapheldframes = 0
	--- sticky large-map mode. Toggled on key RELEASE when it was a short tap (≤8 frames),
	--- matching MinimapAPI's NextMapDisplayMode trigger. Hold longer = show-while-held only.
	local minimapLarge = false

	--- Vanilla already draws a strip under the map: one icon per curse, plus the map items
	--- (Compass, Blue Map, Treasure Map, Restock, Mind), growing leftwards in 16px steps.
	--- Nothing reports how many, and Minimap.GetDisplayedSize() covers the map box only, so
	--- count them and start our own strip after the last one. Conditions mirror MinimapAPI's.
	local function AnyPlayerHasCollectible(item)
		for index = 0, game:GetNumPlayers() - 1 do
			local player = game:GetPlayer(index)
			if player and player:HasCollectible(item) then return true end
		end
		return false
	end

	---@param stateFlag LevelStateFlag the level keeps the flag when a card or pill granted it
	local function MapItemShown(stateFlag, item)
		return game:GetLevel():GetStateFlag(stateFlag) or AnyPlayerHasCollectible(item)
	end

	---Whether the game is drawing anything in its own strip under the map. Only ever asked as a
	---yes/no: our icons start on the row below it, so the exact number does not matter -- which
	---also keeps us clear of the 7 entry cap in REPENTOGON's Minimap::render_icons hook
	---(Patches/CustomModManager.cpp, AddModdedCurseIcons) and of having to guess whether another
	---mod's curses ship icon frames at all.
	---@return boolean
	local function VanillaHasIcons()
		--- any curse bit means a slot, carriers included: the modded curse hook gates on the
		--- owning mod's mapitemicons.anm2 having loaded, not on it holding a "curses" animation,
		--- so our carrier claims a slot and renders blank rather than nothing at all.
		if game:GetLevel():GetCurses() ~= 0 then return true end
		--- Mind replaces the other three with one icon, which does not matter for a yes/no
		if MapItemShown(LevelStateFlag.STATE_FULL_MAP_EFFECT, CollectibleType.COLLECTIBLE_MIND) then return true end
		if MapItemShown(LevelStateFlag.STATE_COMPASS_EFFECT, CollectibleType.COLLECTIBLE_COMPASS) then return true end
		if MapItemShown(LevelStateFlag.STATE_BLUE_MAP_EFFECT, CollectibleType.COLLECTIBLE_BLUE_MAP) then return true end
		if MapItemShown(LevelStateFlag.STATE_MAP_EFFECT, CollectibleType.COLLECTIBLE_TREASURE_MAP) then return true end
		if game:IsGreedMode() or AnyPlayerHasCollectible(CollectibleType.COLLECTIBLE_RESTOCK) then return true end
		return false
	end
	CurseRework.VanillaHasIcons = VanillaHasIcons

	--- how active curses are shown. Shared across consumers, same last writer wins caveat as
	--- RollChance -- treat it as a user setting, not something a single mod owns.
	CurseRework.Render = {
		Icons = true,    --- draw one icon per active curse
		---where the fallback icon strip starts, and which way it grows. Only used when MinimapAPI
		---is absent -- with MinimapAPI the icons sit under the map next to the vanilla ones.
		---X/Y origin matches MinimapAPI: GetScreenTopRight = (W - off*2.2, off*1.2), PositionX=6.
		---Height: REPENTOGON Minimap.GetDisplayedSize().Y when available; otherwise row-counting.
		Anchor = function()
			local hudOffset = (Options and Options.HUDOffset or 0) * 10
			local mapHeight
			if Minimap and Minimap.GetDisplayedSize then
				--- REPENTOGON: actual rendered minimap height, updates instantly on expand/collapse
				mapHeight = Minimap.GetDisplayedSize().Y
				--print('CurseRework Anchor: GetDisplayedSize().Y=', mapHeight)
			else
				--- fallback: count grid rows × MinimapAPI's pixel-per-row constants (8 small, 15 large)
				local f = game:GetFrameCount()
				local isLarge = minimapLarge or mapheldframes > 0
				if f ~= minimapHeightCache.frame or isLarge ~= minimapHeightCache.large then
					minimapHeightCache.frame = f
					minimapHeightCache.large = isLarge
					local level = game:GetLevel()
					local rooms = level and level:GetRooms()
					local minY, maxY = math.huge, -math.huge
					if rooms then
						for i = 0, #rooms - 1 do
							local room = rooms:Get(i)
							if room and room.SafeGridIndex >= 0 then
								local gridY = math.floor(room.SafeGridIndex / 13)
								if gridY >= 0 then
									if gridY < minY then minY = gridY end
									if gridY > maxY then maxY = gridY end
								end
							end
						end
					end
					local rows = (minY ~= math.huge) and (maxY - minY + 1) or 5
					minimapHeightCache.height = rows * (isLarge and 15 or 8)
				end
				mapHeight = minimapHeightCache.height
			end
			local x = Isaac.GetScreenWidth() - hudOffset * 2.2 - 6  --- MinimapAPI PositionX=6
			local y = hudOffset * 1.2 + 4 + mapHeight + 8            --- map top + height + gap
			--- own row below the game's, rather than sharing it
			local position = Vector(x, y)
			if VanillaHasIcons() then
				position = position + CurseRework.Render.RowStep
			end
			return position
		end,
		Step = Vector(-16, 0),
		---icons per row before wrapping onto the next one. 7 matches the cap the game puts on
		---its own strip, so our rows line up with its row rather than running past it.
		PerRow = 7,
		RowStep = Vector(0, 16),
	}

	local Internal = {
		Registry = inheritedRegistry or {}, --- [id] = definition
		Order = inheritedOrder or {},       --- sorted array of ids, keeps the roll deterministic
		Callbacks = {},                     --- what we registered, so a takeover can unhook it
		Active = {},                        --- [id] = true, rolled for the current floor
		Overrides = inheritedOverrides or {}, --- [id] = true/false, manual Add/Remove this floor
		Key = nil,                          --- level identity Active was rolled for
		OverrideKey = inheritedOverrideKey, --- level identity Overrides belong to
		MapFlagIds = {},                    --- ids handed to MinimapAPI, so a takeover can drop them
		UsingMinimapAPI = false,
		AnnouncedKey = inheritedAnnouncedKey, --- level identity we already announced a curse for
		Trapdoors = inheritedTrapdoors or {}, --- [carrier bit] = {Sprite = Sprite} for Accursed
		TrapdoorCandidates = {},            --- [spawn seed] = curse id that trapdoor offers
		TrapdoorSeed = nil,                 --- seed of the trapdoor/heaven door the player is on
		TrapdoorProvider = nil,             --- "accursed" or "reflourished", they render differently
		TrapdoorIconCallback = false,       --- provider supports PRE_RENDER_CURSE_ICON
		TrapdoorPerEntity = false,          --- provider can show a different icon per trapdoor
		TrapdoorHooks = false,              --- this copy registered the shared trapdoor hooks
		TrapdoorHooked = {},                --- [carrier bit] = this copy registered its per bit ones
		PendingTrapdoorGrant = nil,         --- curse id a taken cursed trapdoor owes this floor
		Carriers = {},                      --- [curse name] = vanilla bit, 0 when unusable
		CarrierApplied = {},                --- [bit] = level identity we set that bit for
		EvalMask = 0,                       --- carrier bits returned from MC_POST_CURSE_EVAL and
		                                    --- not yet accounted for in CarrierApplied
		Settings = inheritedSettings or {}, --- [id] = {Enabled = bool, Weight = number}
		Roll = inheritedRoll or {},         --- persisted roll knobs, see CurseRework.RollDefaults
		Storages = inheritedStorages or {}, --- [owner mod name] = consumer persistence
		ConfigBuilt = inheritedConfigBuilt or {}, --- [modName.."/"..category] = true
	}
	CurseRework.Internal = Internal

	local function LOG(str)
		local message = "[CurseRework] " .. str
		print(message)
		Isaac.DebugString(message)
	end

	---------------------------------------------------------------------------
	--- callback bookkeeping
	---------------------------------------------------------------------------

	local function AddCallback(callbackId, fn, param, priority)
		--- nil on a vanilla build that does not have this callback, see MC_POST_MODS_LOADED below
		if callbackId == nil then return end
		--- AddPriorityCallback is REPENTOGON; fall back rather than hard error without it, the
		--- caller only loses ordering
		if priority and CurseRework.AddPriorityCallback then
			CurseRework:AddPriorityCallback(callbackId, priority, fn, param)
		else
			CurseRework:AddCallback(callbackId, fn, param)
		end
		Internal.Callbacks[#Internal.Callbacks + 1] = {ID = callbackId, Fn = fn}
	end

	function Internal.RemoveCallbacks()
		for index = 1, #Internal.Callbacks do
			local entry = Internal.Callbacks[index]
			CurseRework:RemoveCallback(entry.ID, entry.Fn)
		end
		Internal.Callbacks = {}
		--- the flags close over this copy's IsActive, so a newer copy has to re register them
		if MinimapAPI and MinimapAPI.RemoveMapFlag then
			for index = 1, #Internal.MapFlagIds do
				pcall(MinimapAPI.RemoveMapFlag, MinimapAPI, Internal.MapFlagIds[index])
			end
		end
		Internal.MapFlagIds = {}
	end

	---------------------------------------------------------------------------
	--- persistence -- manual overrides only, the roll itself is reproducible
	---------------------------------------------------------------------------

	--- Every mod's curse settings are stored separately: a consumer registers storage for its own
	--- mod with CurseRework.SetStorage(myMod, ...) and only its own curses are written there, so
	--- one mod being uninstalled never takes another mod's settings with it. Curses whose owner
	--- registered nothing fall back to CurseRework's own save file, which follows whichever
	--- embedded copy got elected -- which is exactly why a mod with a real save system should
	--- claim its own. The roll knobs belong to nobody in particular, so they are mirrored into
	--- every store and the first one found on load wins.

	---@return string owner key for a curse definition, "" when it has no identifiable owner
	local function OwnerKey(def)
		if not def then return "" end
		local owner = def.Mod
		if type(owner) == "table" and type(owner.Name) == "string" then return owner.Name end
		if type(owner) == "string" then return owner end
		return ""
	end

	local function StoreWrite(ownerKey, encoded)
		local storage = Internal.Storages[ownerKey]
		if storage then
			pcall(storage.Save, encoded)
			return
		end
		pcall(CurseRework.SaveData, CurseRework, encoded)
	end

	---@return table|nil decoded
	local function StoreRead(ownerKey)
		if not json then return nil end
		local encoded
		local storage = Internal.Storages[ownerKey]
		if storage then
			local ok, value = pcall(storage.Load)
			encoded = ok and value or nil
		elseif CurseRework:HasData() then
			local ok, value = pcall(CurseRework.LoadData, CurseRework)
			encoded = ok and value or nil
		end
		if type(encoded) ~= "string" then return nil end
		local ok, decoded = pcall(json.decode, encoded)
		if not ok or type(decoded) ~= "table" then return nil end
		return decoded
	end

	local function Save()
		if not json then return end

		--- one bucket per owner, plus "" for the default store, which also carries the overrides
		local buckets = {[""] = {Settings = {}}}
		for ownerKey in pairs(Internal.Storages) do
			buckets[ownerKey] = buckets[ownerKey] or {Settings = {}}
		end
		for id, entry in pairs(Internal.Settings) do
			local ownerKey = OwnerKey(Internal.Registry[id])
			if not Internal.Storages[ownerKey] then ownerKey = "" end
			buckets[ownerKey] = buckets[ownerKey] or {Settings = {}}
			buckets[ownerKey].Settings[id] = entry
		end

		for ownerKey, data in pairs(buckets) do
			data.Roll = Internal.Roll
			if ownerKey == "" then
				data.Key = Internal.OverrideKey
				data.Overrides = Internal.Overrides
			end
			local ok, encoded = pcall(json.encode, data)
			if ok then
				StoreWrite(ownerKey, encoded)
			end
		end
	end
	Internal.Save = Save

	---@param includeOverrides boolean|nil overrides only make sense when continuing the same run
	local function Load(includeOverrides)
		if not json then return end
		local rollLoaded = false

		local function absorb(decoded)
			if not decoded then return end
			if type(decoded.Settings) == "table" then
				--- a store only ever holds its own owner's ids, so merging cannot clobber
				for id, entry in pairs(decoded.Settings) do
					if type(entry) == "table" then
						Internal.Settings[id] = entry
					end
				end
			end
			if not rollLoaded and type(decoded.Roll) == "table" then
				Internal.Roll = decoded.Roll
				rollLoaded = true
			end
		end

		local default = StoreRead("")
		absorb(default)
		if default and includeOverrides and type(default.Overrides) == "table" then
			Internal.Overrides = default.Overrides
			Internal.OverrideKey = default.Key
		end

		for ownerKey in pairs(Internal.Storages) do
			absorb(StoreRead(ownerKey))
		end
	end
	Internal.Load = Load

	---Gives a mod its own place to keep the settings of the curses it registered. First caller for
	---a given mod wins. Without this a mod's settings live in CurseRework's own save, which is
	---tied to whichever embedded copy got elected.
	---@param owner table|string the mod handle passed as `Mod` when registering, or its name
	---@param storage {Save: fun(encoded: string), Load: fun(): string|nil}
	function CurseRework.SetStorage(owner, storage)
		local ownerKey = OwnerKey({Mod = owner})
		if ownerKey == "" then
			LOG("SetStorage needs the mod handle (or name) that owns the curses")
			return false
		end
		if Internal.Storages[ownerKey] then return false end
		if type(storage) ~= "table" or type(storage.Save) ~= "function" or type(storage.Load) ~= "function" then
			LOG("SetStorage needs a table with Save and Load functions")
			return false
		end
		Internal.Storages[ownerKey] = storage
		Load(false)
		return true
	end

	---Re reads settings from every store. Call it once the consumer's save system is actually up,
	---if SetStorage ran before that.
	function CurseRework.ReloadSettings()
		Load(false)
	end

	---------------------------------------------------------------------------
	--- per curse settings
	---------------------------------------------------------------------------

	local function SettingsFor(id)
		local entry = Internal.Settings[id]
		if not entry then
			entry = {}
			Internal.Settings[id] = entry
		end
		return entry
	end

	---@return boolean
	function CurseRework.IsEnabled(id)
		local def = Internal.Registry[id]
		if not def then return false end
		local stored = Internal.Settings[id] and Internal.Settings[id].Enabled
		--- ~= false rather than a plain read, so a def inherited from an older copy of the lib
		--- that predates DefaultEnabled still counts as enabled
		if stored == nil then return def.DefaultEnabled ~= false end
		return stored == true
	end

	function CurseRework.SetEnabled(id, enabled)
		if not Internal.Registry[id] then return false end
		SettingsFor(id).Enabled = enabled and true or false
		Internal.Key = nil --- eligibility changed, next floor re rolls
		Internal.TrapdoorCandidates = {} --- the trapdoor pool changed with it
		Save()
		return true
	end

	---@return number
	function CurseRework.GetWeight(id)
		local def = Internal.Registry[id]
		if not def then return 0 end
		local stored = Internal.Settings[id] and Internal.Settings[id].Weight
		if type(stored) ~= "number" then return def.DefaultWeight or 1.0 end
		return stored
	end

	function CurseRework.SetWeight(id, weight)
		if not Internal.Registry[id] then return false end
		SettingsFor(id).Weight = tonumber(weight) or Internal.Registry[id].DefaultWeight or 1.0
		Internal.Key = nil
		Internal.TrapdoorCandidates = {}
		Save()
		return true
	end

	---Puts every curse (or the ones `filter` accepts) back to its registered defaults.
	function CurseRework.ResetSettings(filter)
		for index = 1, #Internal.Order do
			local id = Internal.Order[index]
			if not filter or filter(Internal.Registry[id]) then
				Internal.Settings[id] = nil
			end
		end
		Internal.Key = nil
		Internal.TrapdoorCandidates = {} --- the trapdoor pool changed with it
		Save()
	end

	---@param name "Chance" | "MaxCurses" | "ExtraChance"
	function CurseRework.GetRoll(name)
		local stored = Internal.Roll[name]
		if type(stored) ~= "number" then return CurseRework.RollDefaults[name] end
		return stored
	end

	function CurseRework.SetRoll(name, value)
		if CurseRework.RollDefaults[name] == nil then return false end
		Internal.Roll[name] = tonumber(value) or CurseRework.RollDefaults[name]
		Internal.Key = nil
		Save()
		return true
	end

	---------------------------------------------------------------------------
	--- rolling
	---------------------------------------------------------------------------

	local function GetLevelKey()
		local level = game:GetLevel()
		local stage = level:GetStage()
		return table.concat({
			stage,
			level:GetStageType(),
			game:GetSeeds():GetStageSeed(stage),
			level:IsAscent() and 1 or 0,
		}, ":")
	end

	--- defined further down, next to the rest of the carrier code, but eligibility needs it
	local CarrierBit

	---@return integer mask of LevelCurse the active challenge forbids, 0 when there is none
	local function ChallengeCurseFilter()
		if game.Challenge == nil or game.Challenge == Challenge.CHALLENGE_NULL then return 0 end
		local ok, params = pcall(game.GetChallengeParams, game)
		if not ok or not params or not params.GetCurseFilter then return 0 end
		local gotFilter, filter = pcall(params.GetCurseFilter, params)
		return (gotFilter and type(filter) == "number") and filter or 0
	end

	local function BuildContext()
		local level = game:GetLevel()
		return {
			Stage = level:GetStage(),
			StageType = level:GetStageType(),
			IsAscent = level:IsAscent(),
			IsGreedMode = game:IsGreedMode(),
			Player = game:GetNumPlayers() > 0 and game:GetPlayer(0) or nil,
			--- curses the current challenge bans. Vanilla ANDs this out of the mask in its own
			--- post processing, so a curse riding a filtered carrier would be stripped anyway --
			--- better to never roll it than to roll it and have the bit vanish underneath.
			ChallengeCurseFilter = ChallengeCurseFilter(),
		}
	end

	local function AnyPlayerHasBlackCandle()
		for index = 0, game:GetNumPlayers() - 1 do
			local player = game:GetPlayer(index)
			if player and player:HasCollectible(CollectibleType.COLLECTIBLE_BLACK_CANDLE) then
				return true
			end
		end
		return false
	end

	local function IsEligible(def, context)
		if not CurseRework.IsEnabled(def.Id) then return false end
		if context.IsGreedMode and not def.AllowGreedMode then return false end
		--- vanilla blocks the whole curse roll on the backwards path, so a curse appearing during
		--- the Ascent would be ours alone. Its MC_POST_CURSE_EVAL does not even fire there, which
		--- is why this has to be caught here rather than left to the eval gate.
		if context.IsAscent and not def.AllowAscent then return false end
		--- a challenge that bans a curse bans whatever rides on its bit too
		local filter = context.ChallengeCurseFilter or 0
		if filter ~= 0 then
			local bit = CarrierBit(def)
			if bit ~= 0 and filter & bit ~= 0 then return false end
		end
		if UNCURSABLE_STAGES[context.Stage] and not def.AllowUncursableStages then return false end
		if def.IsAllowed then
			local ok, allowed = pcall(def.IsAllowed, def, context)
			if not ok then
				LOG("IsAllowed errored for " .. def.Id .. ": " .. tostring(allowed))
				return false
			end
			if not allowed then return false end
		end
		return true
	end

	local function GetWeight(def, context)
		if type(def.Weight) == "function" then
			local ok, value = pcall(def.Weight, def, context)
			if not ok then
				LOG("Weight errored for " .. def.Id .. ": " .. tostring(value))
				return 0
			end
			return tonumber(value) or 0
		end
		return CurseRework.GetWeight(def.Id)
	end

	---everything eligible right now, minus what is already picked, with running weight totals
	local function BuildPool(context, taken)
		local pool, total = {}, 0
		for index = 1, #Internal.Order do
			local id = Internal.Order[index]
			local def = Internal.Registry[id]
			if def and not taken[id] then
				local weight = GetWeight(def, context)
				if weight > 0 and IsEligible(def, context) then
					total = total + weight
					pool[#pool + 1] = {Id = id, Acc = total}
				end
			end
		end
		return pool, total
	end

	local function PickFrom(pool, total, rng)
		local pick = rng:RandomFloat() * total
		for index = 1, #pool do
			if pick < pool[index].Acc then return pool[index].Id end
		end
	end

	local function Roll(context)
		local active = {}
		--- a cursed trapdoor curse replaces the floor's roll instead of stacking on top of it
		if Internal.PendingTrapdoorGrant then return active end

		local forced = Isaac.RunCallback(CurseRework.Callbacks.PRE_CURSE_ROLL, context)
		if forced == false then return active end
		if type(forced) == "string" and Internal.Registry[forced] then
			active[forced] = true
			return active
		end
		if type(forced) == "table" then
			for index = 1, #forced do
				if Internal.Registry[forced[index]] then
					active[forced[index]] = true
				end
			end
			if next(active) ~= nil then return active end
		end

		if AnyPlayerHasBlackCandle() then return active end

		local pool, total = BuildPool(context, active)
		if total <= 0 then return active end

		local seed = game:GetSeeds():GetStageSeed(context.Stage)
		if seed == 0 then seed = 1 end --- RNG:SetSeed rejects a zero seed
		local rng = RNG()
		rng:SetSeed(seed, RNG_SHIFT)

		if rng:RandomFloat() >= CurseRework.GetRoll("Chance") then return active end

		local picked = PickFrom(pool, total, rng)
		if not picked then return active end
		active[picked] = true

		--- every further curse costs its own roll, and the pool shrinks as they are taken
		local count = 1
		local maxCurses = CurseRework.GetRoll("MaxCurses")
		local extraChance = CurseRework.GetRoll("ExtraChance")
		while count < maxCurses and extraChance > 0 do
			if rng:RandomFloat() >= extraChance then break end
			pool, total = BuildPool(context, active)
			if total <= 0 then break end
			local extra = PickFrom(pool, total, rng)
			if not extra then break end
			active[extra] = true
			count = count + 1
		end
		return active
	end

	---------------------------------------------------------------------------
	--- carrier bits
	---
	--- A curse may name one vanilla curse from its own mod's curses.xml as a "carrier". While
	--- that curse is active we set the carrier's bit in the real curse mask, which buys back
	--- everything that leaving the mask cost us: Black Candle, Level:RemoveCurses, and every
	--- other mod that asks "is this floor cursed" through Level:GetCurses(). Many curses can
	--- share one carrier, so a mod spends one of the game's ~24 custom slots, not one per curse.
	---
	--- The carrier is a mirror, never the source of truth -- except in one direction: if
	--- something else clears the bit, that is a removal, and we drop the curses behind it.
	---------------------------------------------------------------------------

	--- current state without forcing a roll, so the carrier code can call it from inside Refresh
	local function ActiveNow(id)
		local override = Internal.Overrides[id]
		if override ~= nil then return override == true end
		return Internal.Active[id] == true
	end

	function CarrierBit(def)
		if not def or not def.Carrier then return 0 end
		local cached = Internal.Carriers[def.Carrier]
		if cached ~= nil then return cached end
		local bit = 0
		local id = Isaac.GetCurseIdByName(def.Carrier)
		if id and id > 0 and id <= 32 then
			bit = 1 << (id - 1)
		else
			LOG('carrier "' .. def.Carrier .. '" has no usable curse slot, running table only')
		end
		Internal.Carriers[def.Carrier] = bit
		return bit
	end

	---@return integer every carrier bit resolved so far, OR'd together
	function CurseRework.GetCarrierMask()
		--- Internal.Carriers fills lazily, as CarrierBit is asked for each curse, so before the
		--- first roll of a run it can still be empty. Resolve the whole registry first or the
		--- mask is only as complete as whatever happened to be looked up so far -- callers use
		--- this to mask carriers out of "is this floor cursed" tests, and a short mask lets our
		--- own bit read as somebody else's curse.
		for index = 1, #Internal.Order do
			CarrierBit(Internal.Registry[Internal.Order[index]])
		end
		local mask = 0
		for name, bit in pairs(Internal.Carriers) do
			mask = mask | bit
		end
		return mask
	end

	--- pushes the table state into the real curse mask: sets bits for active curses, clears the
	--- ones we set that nothing needs any more. Never touches a bit we did not set ourselves.
	local function SyncCarriers()
		local wanted = 0
		for index = 1, #Internal.Order do
			local id = Internal.Order[index]
			if ActiveNow(id) then
				wanted = wanted | CarrierBit(Internal.Registry[id])
			end
		end

		local level = game:GetLevel()
		local current = level:GetCurses()

		local missing = wanted & ~current
		if missing ~= 0 then
			level:AddCurse(missing, false) --- false: we do our own announcing
		end
		for bit, key in pairs(Internal.CarrierApplied) do
			if wanted & bit == 0 then
				if current & bit ~= 0 then
					level:RemoveCurses(bit)
				end
				Internal.CarrierApplied[bit] = nil
			elseif key ~= Internal.Key then
				Internal.CarrierApplied[bit] = Internal.Key
			end
		end
		local remaining = wanted
		while remaining ~= 0 do
			local bit = remaining & -remaining
			Internal.CarrierApplied[bit] = Internal.Key
			remaining = remaining ~ bit
		end
	end
	Internal.SyncCarriers = SyncCarriers

	--- somebody else cleared a bit we set -- Black Candle, Level:RemoveCurses, FiendFolio's
	--- Black Lantern replacing the whole mask -- so the curses behind it are gone for this floor
	local function ReconcileCarriers()
		if next(Internal.CarrierApplied) == nil then return end
		local curses = game:GetLevel():GetCurses()
		local changed = false
		for bit, key in pairs(Internal.CarrierApplied) do
			if key == Internal.Key and curses & bit == 0 then
				for index = 1, #Internal.Order do
					local id = Internal.Order[index]
					if CarrierBit(Internal.Registry[id]) == bit and ActiveNow(id) then
						Internal.Overrides[id] = false
						changed = true
					end
				end
				Internal.CarrierApplied[bit] = nil
			end
		end
		if changed then Save() end
	end

	---@param deferCarriers boolean skip the carrier sync. MC_POST_CURSE_EVAL runs while the game
	---is between levels, where Level may still describe the previous floor -- writing the mask
	---there is pointless at best. MC_POST_NEW_LEVEL syncs once the level is real.
	local function Refresh(force, deferCarriers)
		local key = GetLevelKey()
		if not force and Internal.Key == key then return false end
		Internal.Key = key
		if Internal.OverrideKey ~= key then
			Internal.Overrides = {}
			Internal.OverrideKey = key
		end
		Internal.Active = Roll(BuildContext())
		--- the mask resets with the floor, so anything we set for the old one is gone
		Internal.CarrierApplied = {}
		--- except what MC_POST_CURSE_EVAL already handed the game. Adopt those bits so
		--- SyncCarriers can clear them again if this roll no longer wants them -- otherwise a
		--- re-roll would strand a lit carrier bit with no curse behind it.
		local pending = Internal.EvalMask
		while pending ~= 0 do
			local bit = pending & -pending
			Internal.CarrierApplied[bit] = key
			pending = pending ~ bit
		end
		Internal.EvalMask = 0
		if not deferCarriers then SyncCarriers() end
		return true
	end
	Internal.Refresh = Refresh

	---------------------------------------------------------------------------
	--- icons and announcements
	---------------------------------------------------------------------------

	--- MinimapAPI already draws vanilla curse icons under the map and stacks them properly, so
	--- when it is around we just hand it a flag per curse and let it place them. AddMapFlag drops
	--- any flag with the same id first, so calling this again is safe.
	local function SyncMapFlags()
		if not MinimapAPI or not MinimapAPI.AddMapFlag then return end
		Internal.UsingMinimapAPI = true
		Internal.MapFlagIds = {} --- rebuilt every sync, AddMapFlag replaces a flag of the same id
		for index = 1, #Internal.Order do
			local id = Internal.Order[index]
			local def = Internal.Registry[id]
			if def and def.Icon then
				local condition = function()
					return CurseRework.Render.Icons and CurseRework.IsActive(id)
				end
				local ok = pcall(MinimapAPI.AddMapFlag, MinimapAPI, id, condition, def.Icon[1], def.Icon[2], def.Icon[3])
				if ok then
					Internal.MapFlagIds[#Internal.MapFlagIds + 1] = id
				end
			end
		end
	end
	Internal.SyncMapFlags = SyncMapFlags

	--- fallback strip for players without MinimapAPI. Positioned just below the minimap.
	--- game:IsPaused() is intentionally not checked: it returns true during room transitions.
	--- frame-dedup is intentionally absent: GetFrameCount() stalls during transitions, so a
	--- dedup keyed on frame would block rendering for the whole transition.
	--- one Color per opacity value rather than one per rendered frame
	local iconColorCache = {}
	local function IconColor(opacity)
		local cached = iconColorCache[opacity]
		if not cached then
			cached = Color(1, 1, 1, opacity, 0, 0, 0)
			iconColorCache[opacity] = cached
		end
		return cached
	end

	local function RenderIcons()
		if Internal.UsingMinimapAPI then return end
		if not CurseRework.Render.Icons then return end
		if game:GetFrameCount() < 1 then return end --- menus, nothing to be cursed yet
		--- hide during boss showcases: the HUD is not visible then (same reason
		--- MC_POST_HUD_RENDER does not fire during them). HUD:IsVisible is REPENTOGON.
		if not game:GetHUD():IsVisible() then return end

		local active = CurseRework.GetActive()
		if #active == 0 then return end

		local ok, anchor = pcall(CurseRework.Render.Anchor)
		if not ok or not anchor then return end
		local step = CurseRework.Render.Step
		local rowStep = CurseRework.Render.RowStep or Vector.Zero
		local perRow = CurseRework.Render.PerRow
		if type(perRow) ~= "number" or perRow < 1 then perRow = 7 end

		--- opacity: fully opaque while map is expanded (Tab held or sticky large mode), otherwise
		--- use the game's MapOpacity setting (matches the vanilla minimap transparency behaviour).
		--- REPENTOGON: Minimap.GetState() reflects the real current state including sticky toggle.
		local isExpanded = (Minimap and Minimap.GetState and Minimap.GetState() ~= MinimapState.NORMAL)
		                   or mapheldframes > 0
		local opacity = isExpanded and 1.0 or (Options and Options.MapOpacity or 0.5)
		local iconColor = IconColor(opacity)

		local drawn = 0
		for index = 1, #active do
			local def = Internal.Registry[active[index]]
			if def and def.Icon then
				local row = drawn // perRow
				local column = drawn % perRow
				local position = anchor + Vector(column * step.X + row * rowStep.X,
				                                column * step.Y + row * rowStep.Y)
				local sprite = def.Icon[1]
				sprite.Color = iconColor
				sprite:SetFrame(def.Icon[2], def.Icon[3] or 0)
				sprite:Render(position, Vector.Zero, Vector.Zero)
				drawn = drawn + 1
			end
		end
	end

	---------------------------------------------------------------------------
	--- public API
	---------------------------------------------------------------------------

	---Registers a curse. Re registering the same Id overwrites it, so luamod is safe.
	---@return string|nil id
	function CurseRework.Register(config)
		if type(config) ~= "table" then
			LOG("Register expects a table")
			return nil
		end
		if type(config.Id) ~= "string" or config.Id == "" then
			LOG("Register needs a string Id")
			return nil
		end
		if type(config.Name) ~= "string" or config.Name == "" then
			LOG("Register needs a string Name (" .. config.Id .. ")")
			return nil
		end

		local def = {
			Id = config.Id,
			Name = config.Name,
			Description = config.Description,
			--- Weight may be a function for curses whose frequency is dynamic. When it is not,
			--- the player's setting takes over and this is only the reset value.
			Weight = config.Weight,
			DefaultWeight = type(config.Weight) == "number" and config.Weight or 1.0,
			DefaultEnabled = config.DefaultEnabled ~= false,
			IsAllowed = config.IsAllowed,
			Icon = config.Icon,
			Carrier = config.Carrier,
			Mod = config.Mod,
			AllowGreedMode = config.AllowGreedMode,
			AllowAscent = config.AllowAscent,
			AllowUncursableStages = config.AllowUncursableStages,
		}

		if not Internal.Registry[def.Id] then
			Internal.Order[#Internal.Order + 1] = def.Id
			table.sort(Internal.Order) --- id order, not load order, so the roll matches across installs
		end
		Internal.Registry[def.Id] = def
		Internal.Key = nil --- registry changed, re roll on the next query
		Internal.TrapdoorCandidates = {} --- the trapdoor pool changed with it
		Internal.SyncMapFlags() --- no op until MinimapAPI is around, re run on every mods loaded

		return def.Id
	end

	---@return table|nil definition
	function CurseRework.Get(id)
		return Internal.Registry[id]
	end

	---@return string[] every registered id, sorted
	function CurseRework.GetRegistered()
		local ids = {}
		for index = 1, #Internal.Order do
			ids[index] = Internal.Order[index]
		end
		return ids
	end

	---@return boolean
	function CurseRework.IsActive(id)
		if not Internal.Registry[id] then return false end
		Refresh()
		return ActiveNow(id)
	end

	---@return string[] ids active on the current floor, sorted
	function CurseRework.GetActive()
		Refresh()
		local ids = {}
		for index = 1, #Internal.Order do
			local id = Internal.Order[index]
			if CurseRework.IsActive(id) then
				ids[#ids + 1] = id
			end
		end
		return ids
	end

	---Forces a curse on for the rest of the floor.
	---@return boolean applied
	function CurseRework.Add(id)
		if not Internal.Registry[id] then return false end
		Refresh()
		Internal.Overrides[id] = true
		SyncCarriers()
		Save()
		return true
	end

	---Forces a curse off for the rest of the floor.
	---@return boolean removed
	function CurseRework.Remove(id)
		if not Internal.Registry[id] then return false end
		Refresh()
		Internal.Overrides[id] = false
		SyncCarriers()
		Save()
		return true
	end

	---Drops every manual override, leaving the rolled result.
	function CurseRework.ClearOverrides()
		Refresh()
		Internal.Overrides = {}
		SyncCarriers()
		Save()
	end

	---Re rolls the current floor. Mostly for debug commands.
	function CurseRework.ForceReroll()
		Internal.Overrides = {}
		Refresh(true)
		Save()
		Isaac.RunCallback(CurseRework.Callbacks.POST_CURSE_ROLL, CurseRework.GetActive(), BuildContext())
	end

	---------------------------------------------------------------------------
	--- Accursed! (CursedTrapdoorsMod)
	---
	--- Accursed keys its pool by vanilla bitmask and applies the pick with Level:AddCurse, so it
	--- can only offer curses that own a bit. Table curses share a carrier, so one trapdoor entry
	--- per carrier stands in for every curse behind it -- one slot rather than one per curse.
	---
	--- To keep that entry honest a candidate is drawn per floor from the stage seed: the trapdoor
	--- shows that curse's icon and taking it grants exactly that curse. Every trapdoor on a floor
	--- offers the same one, and it changes as you descend.
	---------------------------------------------------------------------------

	--- shared across consumers, same last writer wins caveat as Render and RollDefaults
	CurseRework.Trapdoor = {
		Weight = 3,     --- one entry stands in for many curses, so it gets a nudge. Balance call.
		RngShift = 36,  --- kept clear of RNG_SHIFT, which the floor roll uses
	}

	---Curses behind one carrier that could be offered right now, in registry order.
	---Best effort: the candidate is drawn while the player is still on the previous floor, so the
	---gates that depend on where they land -- IsAllowed, the Ascent and uncursable stage checks --
	---are being asked about the wrong floor. The run wide ones (enabled, Greed Mode, the challenge
	---filter) are already right here, and ApplyTrapdoorGrant re-checks the rest once the
	---destination floor is real, so an offer that turns out illegal is dropped rather than forced.
	local function TrapdoorPool(bit)
		local pool = {}
		local context = BuildContext()
		for index = 1, #Internal.Order do
			local id = Internal.Order[index]
			local def = Internal.Registry[id]
			if def and def.Icon and CarrierBit(def) == bit and IsEligible(def, context) then
				pool[#pool + 1] = def
			end
		end
		return pool
	end

	---Two mods provide the CursedTrapdoorsMod API. Which one is loaded decides how the icon a
	---trapdoor shows can be chosen, since AddCurse keeps exactly one Sprite per curse bit and the
	---trapdoor is not part of that lookup:
	---  Accursed!          renders each trapdoor immediately, from TSIL's POST_GRID_ENTITY_RENDER
	---                     loop over grid entities. Reframing the shared Sprite EARLY lands right
	---                     before that one trapdoor is drawn, so every trapdoor can show its own.
	---  Isaac Reflourished queues {curse, iconFrame, position} during
	---                     MC_POST_GRID_ENTITY_TRAPDOOR_RENDER and drains the whole queue at
	---                     MC_POST_RENDER. Nothing runs between two draws, so reframing cannot
	---                     work there -- but it ships PRE_RENDER_CURSE_ICON, which is asked per
	---                     icon at draw time and so does not care how draws are batched.
	---@return "accursed"|"reflourished"
	local function TrapdoorProvider()
		--- Reflourished publishes CurseDefinitions; Accursed keeps it file local
		if CursedTrapdoorsMod.CurseDefinitions ~= nil then return "reflourished" end
		return "accursed"
	end

	---The curse a trapdoor offers. Keyed on that trapdoor's own spawn seed -- the same key
	---Accursed rolls its own per trapdoor curse from -- or on the stage seed where per trapdoor
	---icons are not possible, see TrapdoorSeedFor. Cached per key; the pool only changes when a
	---setting does, which clears the cache.
	---@return table|nil def
	local function TrapdoorCandidate(bit, seed)
		local cached = Internal.TrapdoorCandidates[seed]
		if cached ~= nil then
			return cached ~= false and Internal.Registry[cached] or nil
		end
		local pool = TrapdoorPool(bit)
		if #pool == 0 then
			Internal.TrapdoorCandidates[seed] = false
			return nil
		end
		local rng = RNG()
		rng:SetSeed(seed ~= 0 and seed or 1, CurseRework.Trapdoor.RngShift) --- SetSeed rejects 0
		local def = pool[rng:RandomInt(#pool) + 1]
		Internal.TrapdoorCandidates[seed] = def.Id
		return def
	end

	---The trapdoor or heaven door standing at a world position, as its own seed.
	---@return integer|nil
	local function SeedAtWorldPos(position)
		local grid = game:GetRoom():GetGridEntityFromPos(position)
		if grid and grid:GetType() == GridEntityType.GRID_TRAPDOOR then
			local state = grid:GetSaveState()
			if state then return state.SpawnSeed end
		end
		for _, door in ipairs(Isaac.FindByType(EntityType.ENTITY_EFFECT, EffectVariant.HEAVEN_LIGHT_DOOR, 0)) do
			if door.Position:DistanceSquared(position) < 1 then return door.InitSeed end
		end
		return nil
	end

	---@return integer seed the candidate for this trapdoor should be keyed on
	local function TrapdoorSeedFor(spawnSeed)
		--- Only a provider that both queues its draws and lacks PRE_RENDER_CURSE_ICON has no way
		--- to tell two trapdoors apart, and falls back to one candidate for the whole floor.
		if not Internal.TrapdoorPerEntity then
			return game:GetSeeds():GetStageSeed(game:GetLevel():GetStage())
		end
		return spawnSeed
	end

	---Reframe path, for a provider without PRE_RENDER_CURSE_ICON. The Sprite behind a curse bit is
	---global state read at the moment of render, so the only lever is to set the frame late enough
	---that it still holds when this one trapdoor is drawn. TSIL dispatches POST_GRID_ENTITY_RENDER
	---through Isaac.GetCallbacks, which REPENTOGON orders by priority, so registering EARLY lands
	---this immediately before Accursed's own draw.
	local function ReframeForEntity(bit, seed)
		local entry = Internal.Trapdoors[bit]
		if not entry or not entry.Sprite then return end
		local def = TrapdoorCandidate(bit, seed)
		if not def or not def.Icon then return end
		entry.Sprite:SetFrame(def.Icon[2] or "curses", def.Icon[3] or 0)
	end

	--- Called from MC_POST_NEW_LEVEL, where the destination floor finally is the current one, so
	--- this is the first point the floor dependent gates can be judged honestly. A trapdoor is a
	--- deliberate choice, but it is not an exemption: a curse the floor would refuse is dropped
	--- here rather than forced through, the same as if the roll had produced it.
	local function ApplyTrapdoorGrant()
		local id = Internal.PendingTrapdoorGrant
		--- the trapdoor it came from is behind us either way, so the recorded seed is spent.
		--- Only read while the provider says one of our trapdoors was taken, but leaving a stale
		--- one lying around is the kind of thing that bites when a provider sets its
		--- curseNextFloor by some route other than the player standing on the trapdoor.
		Internal.TrapdoorSeed = nil
		if not id then return end
		local def = Internal.Registry[id]
		if def and not IsEligible(def, BuildContext()) then
			LOG(id .. " was offered by a trapdoor but is not allowed on this floor, dropping it")
			Internal.PendingTrapdoorGrant = nil
			return
		end
		--- cleared after the Add, so Roll stays suppressed while the grant is going in
		CurseRework.Add(id)
		Internal.PendingTrapdoorGrant = nil
	end

	local function RegisterTrapdoors()
		if not CursedTrapdoorsMod or not CursedTrapdoorsMod.AddCurse then return end
		if not CursedTrapdoorsMod.Enums or not CursedTrapdoorsMod.Enums.CustomCallback then return end
		local callbacks = CursedTrapdoorsMod.Enums.CustomCallback
		Internal.TrapdoorProvider = TrapdoorProvider()
		--- current Reflourished ships PRE_RENDER_CURSE_ICON, Accursed does not, so the reframe
		--- path below is still what carries Accursed
		Internal.TrapdoorIconCallback = callbacks.PRE_RENDER_CURSE_ICON ~= nil
		Internal.TrapdoorPerEntity = Internal.TrapdoorIconCallback
			or Internal.TrapdoorProvider == "accursed"

		for index = 1, #Internal.Order do
			local def = Internal.Registry[Internal.Order[index]]
			local bit = (def and def.Icon and def.Icon[1]) and CarrierBit(def) or 0
			if bit ~= 0 and not Internal.Trapdoors[bit] then
				--- its own instance: Icon's Sprite is shared between curses and reframed every
				--- rendered frame by the icon strip, so handing that one over would fight it.
				--- Sprite:GetFilename() is vanilla, so the path comes from the sprite itself.
				local okName, path = pcall(def.Icon[1].GetFilename, def.Icon[1])
				if okName and type(path) == "string" and path ~= "" then
					local sprite = Sprite()
					local okLoad = pcall(sprite.Load, sprite, path, true)
					if okLoad then
						pcall(sprite.Play, sprite, def.Icon[2] or "curses", true)
						Internal.Trapdoors[bit] = {Sprite = sprite}
						CursedTrapdoorsMod:AddCurse(bit, sprite)
					end
				else
					LOG("no anm2 path behind the icon of " .. def.Id .. ", no trapdoor entry")
				end
			end
		end

		--- Entries survive a takeover -- Accursed holds the Sprites and cannot drop one -- but the
		--- hooks do not, since RemoveCallbacks tears them off the old handle. So the guard is
		--- whether THIS copy registered them, not whether an entry exists. TrapdoorHooked is
		--- per bit because a mod that registers its curses late adds an entry after the shared
		--- hooks are already up.
		for bit in pairs(Internal.Trapdoors) do
			if not Internal.TrapdoorHooked[bit] then
				Internal.TrapdoorHooked[bit] = true
				AddCallback(callbacks.PRE_GET_CURSE_WEIGHT, function()
					--- out of the pool entirely while every curse behind it is off
					return #TrapdoorPool(bit) > 0 and CurseRework.Trapdoor.Weight or 0
				end, bit)
				--- Exact wherever it exists: the provider hands over the world position of the
				--- icon it is about to draw, so the trapdoor is looked up rather than inferred and
				--- the answer applies to that draw alone. Returns a frame index into the sheet the
				--- curse's own icon sprite already uses.
				if Internal.TrapdoorIconCallback then
					AddCallback(callbacks.PRE_RENDER_CURSE_ICON, function(selfRef, curse, basePos)
						local seed = SeedAtWorldPos(basePos)
						if not seed then return end
						local candidate = TrapdoorCandidate(curse, seed)
						if not candidate or not candidate.Icon then return end
						return candidate.Icon[3] or 0
					end, bit)
				end
			end
		end

		if Internal.TrapdoorHooks or next(Internal.Trapdoors) == nil then return end
		Internal.TrapdoorHooks = true

		--- Reframe just before the trapdoor is drawn. Only for a provider without
		--- PRE_RENDER_CURSE_ICON: where the callback exists it already answers per icon, and
		--- reframing underneath it would be two paths writing the same Sprite.
		if not Internal.TrapdoorIconCallback then
			local function ReframeFor(selfRef, gridEntity)
				local state = gridEntity:GetSaveState()
				if not state then return end
				local seed = TrapdoorSeedFor(state.SpawnSeed)
				for bit in pairs(Internal.Trapdoors) do
					ReframeForEntity(bit, seed)
				end
			end
			if Internal.TrapdoorProvider == "reflourished" then
				AddCallback(ModCallbacks.MC_POST_GRID_ENTITY_TRAPDOOR_RENDER, ReframeFor,
					nil, CallbackPriority and CallbackPriority.EARLY)
			elseif TSIL and TSIL.Enums and TSIL.Enums.CustomCallback then
				AddCallback(TSIL.Enums.CustomCallback.POST_GRID_ENTITY_RENDER, ReframeFor,
					GridEntityType.GRID_TRAPDOOR, CallbackPriority and CallbackPriority.EARLY)
			end
		end

		--- which trapdoor the player is standing on, mirroring Accursed's own check, so the grant
		--- matches the icon that trapdoor was showing rather than some other one on the floor
		AddCallback(ModCallbacks.MC_POST_PLAYER_UPDATE, function(selfRef, player)
			--- an unopened trapdoor is not being taken, so standing on one does not count
			local grid = game:GetRoom():GetGridEntityFromPos(player.Position)
			if grid and grid:GetType() == GridEntityType.GRID_TRAPDOOR and grid.State == 0 then
				return
			end
			local seed = SeedAtWorldPos(player.Position)
			if seed then Internal.TrapdoorSeed = seed end
		end)

		--- fires from MC_POST_CURSE_EVAL, before our own roll
		AddCallback(callbacks.POST_SET_LEVEL_CURSES, function(selfRef, curses, curseFromTrapdoor)
			if not curseFromTrapdoor then return end
			local seed = Internal.TrapdoorSeed
			if not seed then return end
			seed = TrapdoorSeedFor(seed)
			for bit in pairs(Internal.Trapdoors) do
				if curseFromTrapdoor & bit ~= 0 then
					local def = TrapdoorCandidate(bit, seed)
					if def then Internal.PendingTrapdoorGrant = def.Id end
					return
				end
			end
		end)
	end

	---------------------------------------------------------------------------
	--- Mod Config Menu
	---
	--- Consumers do not have to write any of this: hand AddConfigMenu the category and tab you
	--- want the curses to appear under and it emits an enable toggle and a weight slider for
	--- each, plus the roll knobs. Everything reaches through the CurseRework global rather than
	--- capturing upvalues, so a newer embedded copy taking over is invisible to the widgets.
	---------------------------------------------------------------------------

	local WEIGHT_STEP = 10   --- MCM sliders are integers, weights are not
	local WEIGHT_MAX = 5

	---@param config {ModName: string, Category: string, Filter: fun(def): boolean, Roll: boolean, PerCurse: fun(def), Title: string}
	---@return boolean built
	function CurseRework.AddConfigMenu(config)
		if not ModConfigMenu then return false end
		if type(config) ~= "table" or type(config.ModName) ~= "string" or type(config.Category) ~= "string" then
			LOG("AddConfigMenu needs ModName and Category")
			return false
		end

		--- MCM appends and cannot drop a single setting, so building twice would double the tab
		local builtKey = config.ModName .. "/" .. config.Category
		if Internal.ConfigBuilt[builtKey] then return false end
		Internal.ConfigBuilt[builtKey] = true

		local modName, category = config.ModName, config.Category

		if config.Roll ~= false then
			ModConfigMenu.AddTitle(modName, category, config.Title or "Curse rolling")
			ModConfigMenu.AddSetting(modName, category, {
				Type = ModConfigMenu.OptionType.NUMBER,
				CurrentSetting = function() return math.floor(CurseRework.GetRoll("Chance") * 100 + 0.5) end,
				Minimum = 0,
				Maximum = 100,
				Display = function()
					return "Curse chance: " .. math.floor(CurseRework.GetRoll("Chance") * 100 + 0.5) .. "%"
				end,
				OnChange = function(n) CurseRework.SetRoll("Chance", n / 100) end,
				Info = { "Chance for a floor to get a curse at all",
					"Default: " .. math.floor(CurseRework.RollDefaults.Chance * 100 + 0.5) .. "%" },
			})
			ModConfigMenu.AddSetting(modName, category, {
				Type = ModConfigMenu.OptionType.NUMBER,
				CurrentSetting = function() return CurseRework.GetRoll("MaxCurses") end,
				Minimum = 1,
				Maximum = 4,
				Display = function() return "Max curses per floor: " .. CurseRework.GetRoll("MaxCurses") end,
				OnChange = function(n) CurseRework.SetRoll("MaxCurses", n) end,
				Info = { "How many curses one floor may roll", "Default: " .. CurseRework.RollDefaults.MaxCurses },
			})
			ModConfigMenu.AddSetting(modName, category, {
				Type = ModConfigMenu.OptionType.NUMBER,
				CurrentSetting = function() return math.floor(CurseRework.GetRoll("ExtraChance") * 100 + 0.5) end,
				Minimum = 0,
				Maximum = 100,
				Display = function()
					return "Extra curse chance: " .. math.floor(CurseRework.GetRoll("ExtraChance") * 100 + 0.5) .. "%"
				end,
				OnChange = function(n) CurseRework.SetRoll("ExtraChance", n / 100) end,
				Info = { "Chance of each curse after the first", "Ignored while max curses is 1",
					"Default: " .. math.floor(CurseRework.RollDefaults.ExtraChance * 100 + 0.5) .. "%" },
			})
			ModConfigMenu.AddSpace(modName, category)
		end

		for index = 1, #Internal.Order do
			local id = Internal.Order[index]
			local def = Internal.Registry[id]
			if def and (not config.Filter or config.Filter(def)) then
				ModConfigMenu.AddTitle(modName, category, def.Name)
				if def.Description then
					ModConfigMenu.AddText(modName, category, def.Description)
				end
				ModConfigMenu.AddSetting(modName, category, {
					Type = ModConfigMenu.OptionType.BOOLEAN,
					CurrentSetting = function() return CurseRework.IsEnabled(id) end,
					Display = function()
						return "Enabled: " .. (CurseRework.IsEnabled(id) and "true" or "false")
					end,
					OnChange = function(enabled) CurseRework.SetEnabled(id, enabled) end,
					Info = { "Default: " .. (def.DefaultEnabled and "enabled" or "disabled") },
				})
				--- a curse with a dynamic weight function ignores the player's number, so no slider
				if type(def.Weight) ~= "function" then
					ModConfigMenu.AddSetting(modName, category, {
						Type = ModConfigMenu.OptionType.NUMBER,
						CurrentSetting = function()
							return math.floor(CurseRework.GetWeight(id) * WEIGHT_STEP + 0.5)
						end,
						Minimum = 0,
						Maximum = WEIGHT_MAX * WEIGHT_STEP,
						Display = function() return "Weight: " .. CurseRework.GetWeight(id) end,
						OnChange = function(n) CurseRework.SetWeight(id, n / WEIGHT_STEP) end,
						Info = { "Relative frequency against the other curses",
							"2.0 is twice as likely as 1.0", "Default: " .. def.DefaultWeight },
					})
				end
				if config.PerCurse then
					config.PerCurse(def)
				end
				ModConfigMenu.AddSpace(modName, category)
			end
		end

		return true
	end

	---------------------------------------------------------------------------
	--- callbacks
	---------------------------------------------------------------------------

	AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function(selfRef, isContinued)
		Internal.Key = nil
		if isContinued then
			Load(true)
		else
			Internal.Overrides = {}
			Internal.OverrideKey = nil
			Load(false) --- settings persist across runs, overrides do not
			Save()
		end
	end)

	--- On uncursed floors, run the roll immediately so custom curses participate in the game's
	--- own curse evaluation. Returns the carrier mask to claim the floor; MC_POST_NEW_LEVEL then
	--- finds the key already set and skips re-rolling. On already-cursed floors this does nothing
	--- -- mods gate that through IsAllowed, same as the MC_POST_NEW_LEVEL path.
	AddCallback(ModCallbacks.MC_POST_CURSE_EVAL, function(selfRef, vanilla)
		if vanilla ~= LevelCurse.CURSE_NONE then return end
		--- carriers deferred: Level is not the new floor yet, so writing the mask here does
		--- nothing useful. Returning the mask is what actually claims the floor.
		Refresh(true, true)
		local mask = 0
		for index = 1, #Internal.Order do
			local id = Internal.Order[index]
			if ActiveNow(id) then
				mask = mask | CarrierBit(Internal.Registry[id])
			end
		end
		--- remembered so the next Refresh can retract it if that roll disagrees
		Internal.EvalMask = mask
		if mask == 0 then return end
		return mask
	end)

	AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, function()
		--- Reflourished only builds its global CursedTrapdoorsMod table from its own
		--- POST_DATA_LOAD (run start), which lands after MC_POST_MODS_LOADED -- the provider
		--- was not there yet the one time RegisterTrapdoors ran. Retrying here is cheap once it
		--- has succeeded: every bit is already in Internal.Trapdoors and the hook guards are set,
		--- so nothing registers twice.
		RegisterTrapdoors()
		--- before the roll: a taken cursed trapdoor owes this floor a specific curse
		ApplyTrapdoorGrant()
		--- entries are keyed on a seed and re-derived on demand, so dropping them costs nothing
		--- and keeps the table bounded by the floor rather than by the whole run
		Internal.TrapdoorCandidates = {}
		Refresh()
		--- keyed off the level rather than off Refresh returning true: something querying
		--- IsActive during level init would otherwise roll the floor and swallow the announcement
		if Internal.AnnouncedKey == Internal.Key then return end
		Internal.AnnouncedKey = Internal.Key
		local active = CurseRework.GetActive()
		Isaac.RunCallback(CurseRework.Callbacks.POST_CURSE_ROLL, active, BuildContext())
	end)

	--- MC_POST_MODS_LOADED is REPENTOGON. Register() also syncs, so the only cost of missing
	--- this callback is map flags for a mod that registered before MinimapAPI loaded.
	AddCallback(ModCallbacks.MC_POST_MODS_LOADED, function()
		SyncMapFlags() --- MinimapAPI may have loaded after the curses registered
		RegisterTrapdoors() --- same for Accursed
	end)

	--- MC_POST_RENDER fires on every rendered frame unconditionally: room transitions,
	--- boss showcases, pause, and regular gameplay. Using it exclusively (rather than
	--- MC_POST_HUD_RENDER) avoids edge cases where the HUD is temporarily not drawn.
	AddCallback(ModCallbacks.MC_POST_RENDER, RenderIcons)

	AddCallback(ModCallbacks.MC_POST_UPDATE, ReconcileCarriers)

	--- Mirror MinimapAPI's mapheldframes tracking: count how long the map key is held, then on
	--- release toggle minimapLarge if it was a short tap (≤8 frames), matching the game's own
	--- "tap=toggle, hold=show-temporarily" contract. InputHook.IS_ACTION_PRESSED makes the
	--- callback fire every frame the button state changes, with no action-eaten risk.
	if ModCallbacks.MC_INPUT_ACTION and InputHook then
		AddCallback(ModCallbacks.MC_INPUT_ACTION, function(_, entity, _, buttonAction)
			if entity and buttonAction == ButtonAction.ACTION_MAP then
				local player = entity:ToPlayer()
				if player then
					if Input.IsActionPressed(ButtonAction.ACTION_MAP, player.ControllerIndex) then
						mapheldframes = mapheldframes + 1
					elseif mapheldframes > 0 then
						if mapheldframes <= 8 then
							minimapLarge = not minimapLarge
						end
						mapheldframes = 0
					end
				end
			end
		end, InputHook.IS_ACTION_PRESSED)
	end

	--- Replace the carrier curse name (e.g. "Curse of Eclipsed!") in the HUD text streak with
	--- the real active custom curse names. Pattern from real-world mods: call ShowItemText with
	--- the replacement then return false to cancel the original display.
	--- Callback signature: (selfRef, title, subtitle, isSticky, isCurseDisplay).
	--- HUD:ShowItemText(main, secondary, IsCurseDisplay) -- the third argument is the curse
	--- flag, not stickiness, and this replacement is always a curse.
	if ModCallbacks.MC_PRE_ITEM_TEXT_DISPLAY then
		AddCallback(ModCallbacks.MC_PRE_ITEM_TEXT_DISPLAY, function(selfRef, title, subtitle, isSticky, isCurseDisplay)
			if not isCurseDisplay then return end
			local isCarrier = false
			for _, def in pairs(Internal.Registry) do
				if def.Carrier and subtitle == def.Carrier then
					isCarrier = true
					break
				end
			end
			if not isCarrier then return end
			local active = CurseRework.GetActive()
			if #active == 0 then return end
			local names = {}
			for _, id in ipairs(active) do
				local d = Internal.Registry[id]
				if d and d.Name then names[#names + 1] = d.Name end
			end
			if #names == 0 then return end
			for key, name in ipairs(names) do
				Isaac.CreateTimer(function ()
					-- idk what is StackUp text does
					game:GetHUD():ShowItemText(title, name, true, true)
				end, 22*(key-1), 1, false)
			end
			return false
		end)
	end

	AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, function()
		Save()
	end)

	--- Flush before a mod goes away, which MC_PRE_GAME_EXIT does not cover: a mod disabled or
	--- reloaded mid run, where nothing else writes the overrides out. Fires once per mod, so the
	--- shutdown pass is deduplicated. REPENTOGON both added the ShuttingDown argument and moved
	--- the shutdown firing earlier, while Game is still alive and Save() can run safely.
	AddCallback(ModCallbacks.MC_PRE_MOD_UNLOAD, function(selfRef, modRef, shuttingDown)
		if shuttingDown then
			if Internal.SavedForShutdown then return end
			Internal.SavedForShutdown = true
		end
		Save()
	end)

	return CurseRework
end

return LOCAL_CURSEREWORK
