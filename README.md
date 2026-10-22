# CurseRework

**Table-based curse registry for The Binding of Isaac: Repentance.**
Version 3.3 · requires REPENTOGON

## Why

Vanilla keeps curses in a 32-bit field and already owns 8 of those bits. Once the mods on a save
have claimed the rest, every further curse silently *aliases* onto somebody else's bit.

CurseRework keeps curses in a plain Lua table instead. No cap, no cross-mod collision.

## Installing

Drop `curse_rework.lua` into your own mod and call `.Init()`:

```lua
include("scripts_yourmod.lib.curse_rework").Init()
```

### Embedding and versions

- **Embed, don't depend.** Ship the file inside your mod. Do not publish CurseRework as a standalone
  Workshop mod: Isaac has no dependency resolution, so your mod would break the moment a user forgot
  to subscribe.
- **Highest version wins.** Every mod carries its own copy. `Init()` elects the newest one present,
  and it inherits everything older copies already registered, so load order does not matter.
- **Always go through the `CurseRework` global.** Never keep the result of `Init()` in a local — a
  newer copy taking over later would leave you calling a dead one.
- **Guard it** if you want your mod to survive without the file: `if not CurseRework then return end`.
- **Active curses are not saved.** They are derived from the stage seed, so they survive copied save
  slots, disabled host mods and the elected copy changing hands. Only settings and manual
  `Add`/`Remove` calls are written to disk.

A complete working mod lives in [`example/`](example/main.lua): three curses showing a fixed weight,
an `IsAllowed` gate and a function weight.

## Quick start

```lua
local mod = RegisterMod("My Mod", 1)
include("scripts_mymod.lib.curse_rework").Init()

local icons = Sprite()
icons:Load("gfx/ui/my_curse_icons.anm2", true)

local VOID = CurseRework.Register({
    Id     = "mymod:void",
    Name   = "Curse of the Void!",
    Icon   = {icons, "curses", 0},
    Weight = 1.0,
    Mod    = mod,   -- needed for the Filter below
})

mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
    if CurseRework.IsActive(VOID) then
        -- do the cursed thing
    end
end)

CurseRework.AddConfigMenu({ModName = "My Mod", Category = "Curses",
                           Filter = function(def) return def.Mod == mod end})
```

## Registering a curse

`Register` returns the id, or `nil` on a bad config (the reason is logged).

| Field | Type | Required | Meaning |
|---|---|---|---|
| `Id` | `string` | **yes** | Namespaced, stable forever — it is the save key |
| `Name` | `string` | **yes** | Shown to the player |
| `Description` | `string` | no | For EID / config menus |
| `Weight` | `number` \| `function` | no | Relative pick weight, see below |
| `DefaultEnabled` | `boolean` | no | Defaults to `true` |
| `IsAllowed` | `fun(def, context) -> boolean` | no | Per-floor gate |
| `Icon` | `{Sprite, string, integer}` | no | `{sprite, animation, frame}` |
| `Carrier` | `string` | no | Vanilla curse name to mirror into the real mask, see [Carriers](#carriers) |
| `Mod` | `table` \| `string` | no | Owning mod handle; keys storage and `Filter` |
| `AllowGreedMode` | `boolean` | no | Off by default — curses skip Greed Mode |
| `AllowAscent` | `boolean` | no | Off by default — curses skip the Ascent, which vanilla never curses |
| `AllowUncursableStages` | `boolean` | no | Off by default — curses skip Home (`STAGE8`) |

- **The `Id` is the save key.** Renaming one resets that curse's saved settings.
- **Registering the same `Id` again replaces** the earlier definition.
- **Only the fields above are kept.** Extra keys you pass (say `Group = "Blessings"`) are dropped, so
  `Filter` and other callbacks cannot see them — group curses by `Id` instead.
- **Without an `Icon`**, a curse shows no HUD icon and never appears in [cursed trapdoors](#cursed-trapdoors).
- **Errors are contained.** An `IsAllowed` or `Weight` function that errors is logged and treated as
  "not allowed" / weight `0`.

### Weights

A **number** is only the *reset* value: from then on the player's setting owns it.

A **function** `(def, context) -> number` is for a curse whose frequency is dynamic. It opts the
curse out of the player's weight setting entirely and is the sole authority. Returning `0` — or
erroring, which is logged and treated as `0` — takes the curse out of the pool.

### The context table

Handed to `IsAllowed`, function weights, and both callbacks:

```lua
{
    Stage      = level:GetStage(),
    StageType  = level:GetStageType(),
    IsAscent   = level:IsAscent(),
    IsGreedMode= game:IsGreedMode(),
    Player     = game:GetPlayer(0),   -- nil when there is no player yet
    ChallengeCurseFilter = 0,         -- curses the active challenge bans, 0 when there is none
}
```

## How a floor rolls

Deterministic from `Seeds:GetStageSeed(stage)`, so the same seed always produces the same curses.
In order:

1. **Cursed trapdoor mods.** If Accursed! or Isaac Reflourished is installed, the floor roll is
   skipped entirely — curses only arrive through [cursed trapdoors](#cursed-trapdoors). A curse
   granted by a trapdoor also replaces the roll on the floor it leads to.
2. **`PRE_CURSE_ROLL`.** `false` leaves the floor uncursed. Returning ids forces them and ends the
   roll — forced curses skip every check below, they only need to be registered.
3. **Black Candle.** If any player holds it, nothing rolls.
4. **Pool.** Every curse with a weight above `0` that passes, in this order: enabled → Greed Mode →
   Ascent → the active challenge's curse filter (applied to the curse's carrier bit) → Home →
   `IsAllowed`.
5. **`Chance`.** One roll decides whether the floor is cursed at all.
6. **First curse**, picked from the pool by weight.
7. **Extra curses.** While fewer than `MaxCurses` are active, each further curse needs its own
   `ExtraChance` roll and is picked from what is left of the pool. The first failed roll stops it.

The roll is separate from vanilla's: a floor can carry a vanilla curse and a CurseRework curse at
once. Use `IsAllowed` with [`GetCarrierMask()`](#carriers) if you want your curses to stay off floors
the game already cursed. Unlike vanilla, Basement 1 is cursable.

## Settings

### Roll knobs

| Name | Default | Meaning |
|---|---|---|
| `Chance` | `0.33` | Chance a floor gets cursed at all |
| `MaxCurses` | `1` | How many curses one floor may roll |
| `ExtraChance` | `0` | Chance of each curse after the first |

**Shared across every consumer**, unlike `Enabled`/`Weight` which are per curse. `SetRoll` writes
one global value and the last writer wins, so don't call it to pin them where your mod would like
them — they belong to the player. `AddConfigMenu` already emits a slider for all three, so there is
nothing to build. Defaults reproduce vanilla behaviour: at most one curse per floor.

### Mod Config Menu

One call builds a whole tab — roll knobs, then for each curse a heading, its description, an enable
toggle and a weight slider — under your own MCM category:

```lua
CurseRework.AddConfigMenu({
    ModName  = "Eclipsed",                                  -- your MCM category
    Category = "Curses",                                    -- the tab inside it
    Filter   = function(def) return def.Mod == myMod end,   -- optional
    Title    = "Curse rolling",                             -- optional, heading above the knobs
    Roll     = true,                                        -- optional, roll knobs, on by default
    PerCurse = function(def) ... end,                       -- optional, append your own widgets
})
```

| Field | Required | Meaning |
|---|---|---|
| `ModName` | **yes** | MCM category (the entry in the mod list) |
| `Category` | **yes** | Tab inside that category |
| `Filter` | no | `fun(def) -> boolean`, which curses this tab lists. **Without it, the tab lists every curse of every mod using CurseRework** |
| `Roll` | no | `false` hides the roll knobs. On by default |
| `Title` | no | Heading above the roll knobs; not shown when `Roll = false` |
| `PerCurse` | no | `fun(def)`, called once per listed curse to add your own widgets, see below |

Returns `true` when the tab was built, `false` when Mod Config Menu is missing, the config is
invalid, or the tab was already built.

**Rules that trip people up:**

- **One call per tab.** Each `ModName` + `Category` pair is built once; any later call for the same
  pair is ignored and returns `false`. You cannot add curses to a tab with a second call — one call,
  one `Filter` that accepts everything the tab should hold.
- **Register first.** The tab lists the curses registered *at the moment of the call*. Call it after
  your `Register` calls; to include curses from other mods, call it in `MC_POST_MODS_LOADED`.
- **Order is by `Id`**, not registration order.
- **Restart the game after changing menu code.** MCM cannot remove entries, so a `luamod` reload
  keeps the old tab (the "already built" flag survives the reload on purpose, or every entry would
  double).
- **The roll knobs are global.** Every tab with `Roll` on shows the same three sliders. Keep them on
  one tab and pass `Roll = false` everywhere else.
- **No weight slider** for a curse whose `Weight` is a function — the player's number would be
  ignored. Sliders run from `0` to `5` in steps of `0.1`.

#### Filter

`Filter` receives the curse's definition: `Id`, `Name`, `Description`, `Mod`, `Weight`,
`DefaultEnabled`, `Carrier`, … — the [registration fields](#registering-a-curse), nothing else.

```lua
Filter = function(def) return def.Mod == mod end                   -- every curse your mod registered
Filter = function(def) return def.Id:find("^mymod:room_") ~= nil end  -- by id prefix
Filter = function(def) return false end                            -- no curses: a roll-knobs-only tab
```

#### Several tabs

One call per tab, each with its own `Filter`, roll knobs on only one of them:

```lua
local tabs = {
    Rooms   = { ["mymod:void"] = true, ["mymod:fool"] = true },
    Enemies = { ["mymod:pride"] = true },
}

CurseRework.AddConfigMenu({ModName = "My Mod", Category = "General",
                           Filter = function(def) return false end})   -- roll knobs only

for _, category in ipairs({"Rooms", "Enemies"}) do                     -- ipairs keeps tab order
    local ids = tabs[category]
    CurseRework.AddConfigMenu({
        ModName  = "My Mod",
        Category = category,
        Roll     = false,
        Filter   = function(def) return ids[def.Id] end,
    })
end
```

Ids containing `:` must be written as `["mymod:void"] = true` — a bare `"mymod:void" = true` is a
Lua syntax error. Keeping the value `Register` returns in a local and writing `[VOID] = true` avoids
typos altogether.

#### PerCurse

Called for each listed curse after its weight slider and before the spacer, so whatever it adds sits
under that curse. It only receives `def` — pass your own `ModName`/`Category` to the MCM calls:

```lua
local MOD_NAME, TAB = "My Mod", "Curses"

CurseRework.AddConfigMenu({
    ModName  = MOD_NAME,
    Category = TAB,
    Filter   = function(def) return def.Mod == mod end,
    PerCurse = function(def)
        if def.Id ~= VOID then return end   -- only the void curse has an extra knob
        ModConfigMenu.AddSetting(MOD_NAME, TAB, {
            Type = ModConfigMenu.OptionType.NUMBER,
            CurrentSetting = function() return mySettings.VoidChance end,
            Minimum = 0, Maximum = 100,
            Display = function() return "Room reroll chance: " .. mySettings.VoidChance .. "%" end,
            OnChange = function(n) mySettings.VoidChance = n end,
        })
    end,
})
```

Settings added this way are yours to save; CurseRework only stores `Enabled`, `Weight` and the roll
knobs.

### Storage

Settings are written in two kinds of store:

| Store | Holds | Claimed with |
|---|---|---|
| Per mod | `Enabled`/`Weight` of the curses registered with that `Mod` | `SetStorage(owner, storage)` |
| Default | The roll knobs, manual `Add`/`Remove` overrides, and settings of curses whose owner claimed nothing | `SetDefaultStorage(storage)` |

Both take the same `storage` table and both are first-caller-wins. Storage is per mod, so
uninstalling one mod never takes another mod's settings with it. The roll knobs are mirrored into
every store; on load the default store wins.

An unclaimed store falls back to CurseRework's own `SaveData`. **That is your mod's save file.**
Isaac keys mod data by the folder `RegisterMod` ran from, and the lib registers from inside your
mod. `SaveData` also replaces the file whole, so:

- **Your mod has no save system of its own:** skip both calls, the lib's file is yours to lend.
- **Your mod writes its own save file** (a save manager, `mod:SaveData`, anything): claim
  **both** stores. Otherwise the two of you overwrite each other's file, and whenever the lib
  happens to write last, all of your mod's saved data is gone.

```lua
local function Store(key)
    return {
        Save = function(encoded) mySave.settings[key] = encoded; mySave:Flush() end,   -- encoded is a JSON string
        Load = function() return mySave.settings[key] end,                             -- nil when nothing was saved
    }
end

CurseRework.SetStorage(mod, Store("CurseRework"))
CurseRework.SetDefaultStorage(Store("CurseReworkDefault"))
CurseRework.ReloadSettings()   -- only needed if you claimed them before your save was loaded
```

Flush to disk inside `Save`: the lib saves when a setting changes in the config menu and when the
game closes, and save systems commonly skip their own auto-save while on the title or Mods menu.

## Carriers

Curses live in a table, so `Level:GetCurses()` does not know about them — and neither does anything
built on it: Black Candle, `Level:RemoveCurses`, other mods asking whether the floor is cursed.

Name one vanilla curse from your own `content/curses.xml` as `Carrier` and its bit is mirrored into
the real mask whenever any curse using it is active. **One entry covers all of your curses**, so it
costs a single one of the game's ~24 custom slots rather than one per curse. A name that does not
resolve to a usable slot is logged and the curse runs table-only.

- **Give the carrier no icon.** It stands in for whichever curse actually rolled, so a fixed icon
  would lie. REPENTOGON reads the `"curses"` animation of your `content/gfx/OUT_mapitemicons.anm2`
  and draws nothing for a curse with no frame there — leave the frame out, or name that animation
  something else if the file holds icons you use elsewhere.
- **Clearing the bit removes the curses.** The carrier is a mirror, except in one direction: if
  something else clears it (Black Candle, `Level:RemoveCurses`), the curses behind it go too.
- **Mask carriers out of your own checks.** `Level:GetCurses()` now includes your carrier bit, so
  "is this floor already cursed by the game" needs `GetCurses() & ~CurseRework.GetCarrierMask()`.
- **No carrier is fine too** — everything works, just without the mirror.


### Sharing one between mods

`Carrier` is resolved with `Isaac.GetCurseIdByName`, which searches every loaded mod's
`content/curses.xml` — not just yours. So a consumer may name **another mod's** carrier:

```lua
CurseRework.Register({
    Id = "mymod:foo",
    Name = "Curse of Foo!",
    Carrier = "Curse of Eclipsed!",   -- Curse from Eclipsed mod
})
```

That is the cheap way out of the slot shortage: any number of mods can share one bit instead of
spending one each out of the ~24 the game has left. It works because CurseRework's registry is
shared — the elected copy holds every mod's registrations.

**It is a soft dependency.** The curse is declared in the *other* mod's `curses.xml`. Uninstall
  that mod and the lookup fails, which is logged, and your curses run table-only — degraded, not
  broken. Declare your own carrier if you would rather not depend on anyone.

## Cursed trapdoors

Nothing to wire up. If **Accursed!** or **Isaac Reflourished** is installed, the lib registers
**one trapdoor entry per carrier bit**, so a mod spends one of the provider's slots rather than one
per curse. Any curse registered with an `Icon` takes part.

**Each trapdoor shows its own curse**, keyed on its spawn seed, so a floor with three trapdoors
offers three choices. Which provider is installed is detected automatically, and both give the full
behaviour.

**While a provider is installed, the normal floor roll is off.** Those mods replace the vanilla curse
roll themselves, so rolling ours on top would give unrelated double curses. CurseRework curses then
arrive only through trapdoors, and `Chance` / `MaxCurses` / `ExtraChance` have no effect.

```lua
CurseRework.Trapdoor.Weight   = 3    -- pool weight for the entry; it stands in for many curses
CurseRework.Trapdoor.RngShift = 36   -- shift for the per-trapdoor candidate draw
```

Shared across consumers. (last-writer-wins)

## Rendering

```lua
CurseRework.Render.Icons   = true   -- one icon per active curse
CurseRework.Render.Anchor  = function() return Vector(x, y) end
CurseRework.Render.Step    = Vector(-16, 0)   -- between icons in a row
CurseRework.Render.PerRow  = 7                -- icons before wrapping
CurseRework.Render.RowStep = Vector(0, 16)    -- between rows
```

With **MinimapAPI** present, icons sit under the map next to the vanilla ones and stack properly.
Without it, CurseRework draws its own fallback strip below the minimap.

Shared across consumers. (last-writer-wins)

## Callbacks

```lua
mod:AddCallback(CurseRework.Callbacks.PRE_CURSE_ROLL, function(selfRef, context)
    if context.Stage == 1 then return false end        -- no curse this floor
 -- return "mymod:void"                                 -- force one
 -- return {"mymod:void", "mymod:fool"}                 -- force several
end)

mod:AddCallback(CurseRework.Callbacks.POST_CURSE_ROLL, function(selfRef, activeIds, context)
    -- activeIds: sorted array
end)
```

| Callback | Handler receives | Return |
|---|---|---|
| `PRE_CURSE_ROLL` | `(selfRef, context)` | `false`, an id, an array of ids, or nothing |
| `POST_CURSE_ROLL` | `(selfRef, activeIds, context)` | ignored |

Dispatch stops at the first non-`nil` return. Unregistered ids in a forced return are dropped; if
none survive, the roll proceeds normally.

## API reference

### Registry

| Call | Returns |
|---|---|
| `Register(config)` | `id` or `nil` |
| `Get(id)` | definition table or `nil` |
| `GetRegistered()` | every registered id, sorted |

### State

| Call | Returns |
|---|---|
| `IsActive(id)` | `boolean` |
| `GetActive()` | ids active on the current floor, sorted |
| `Add(id)` / `Remove(id)` | forces a curse on/off for the rest of the floor |
| `ClearOverrides()` | drops every manual override, leaving the rolled result |
| `ForceReroll()` | re-rolls the current floor and fires `POST_CURSE_ROLL` (debug commands) |
| `GetCarrierMask()` | every registered carrier bit OR'd together; resolves the registry first, so it is complete before the first roll |
| `VanillaHasIcons()` | `boolean` — whether the game is drawing anything in its own icon row |

### Settings

| Call | Returns |
|---|---|
| `IsEnabled(id)` / `SetEnabled(id, bool)` | |
| `GetWeight(id)` / `SetWeight(id, number)` | |
| `GetRoll(name)` / `SetRoll(name, value)` | `"Chance"`, `"MaxCurses"`, `"ExtraChance"` |
| `ResetSettings(filter)` | back to registered defaults; `filter(def)` optional |
| `SetStorage(owner, storage)` | `boolean` — claims the store for `owner`'s curses, see [Storage](#storage) |
| `SetDefaultStorage(storage)` | `boolean` — claims the default store, see [Storage](#storage) |
| `ReloadSettings()` | re-reads every store |
| `AddConfigMenu(config)` | `boolean` built |

### Tables

| Field | Meaning |
|---|---|
| `CurseRework.Version` | Number (`3.3`), compared for the election |
| `CurseRework.Trapdoor` | Cursed trapdoor settings (`Weight`, `RngShift`) |
| `CurseRework.Callbacks` | Callback id constants |
| `CurseRework.RollDefaults` | Reset values for the roll knobs |
| `CurseRework.Render` | Icon and layout settings (`Icons`, `Anchor`, `Step`, `PerRow`, `RowStep`) |
| `CurseRework.Internal` | Live state. Read it for debugging; do not write to it |

## REPENTOGON dependency (WHY)

- **`Minimap.GetDisplayedSize()`** / **`Minimap.GetState()`** — the fallback icon strip has to sit
  under the map at whatever height it is actually drawn.
- **`MC_INPUT_ACTION`** with **`InputHook`** — tracks the map button per controller, so the fallback
  icon strip follows the expanded map.
- **`MC_PRE_ITEM_TEXT_DISPLAY`** — the HUD would otherwise announce the carrier's name instead of
  the curse that actually rolled.
- **`MC_POST_MODS_LOADED`** — MinimapAPI may load after you register, so the flags need a re-sync.
- **`MC_PRE_MOD_UNLOAD`**'s `ShuttingDown` argument — settings would be lost on a disable or
  reload without a flush.
