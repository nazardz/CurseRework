# CurseRework

**Table-based curse registry for The Binding of Isaac: Repentance.**
Version 3.1· requires REPENTOGON

## Why

Vanilla keeps curses in a 32-bit field and already owns 8 of those bits. Once the mods on a save
have claimed the rest, every further curse silently *aliases* onto somebody else's bit.

CurseRework keeps curses in a plain Lua table instead. No cap, no cross-mod collision.

## Installing

Drop `curse_rework.lua` into your own mod and call `.Init()`:

```lua
include("scripts_yourmod.lib.curse_rework").Init()
```

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

One call builds the whole tab — roll knobs, then an enable toggle and a weight slider per curse —
under your own MCM category:

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

## Carriers

Curses live in a table, so `Level:GetCurses()` does not know about them — and neither does anything
built on it: Black Candle, `Level:RemoveCurses`, other mods asking whether the floor is cursed.

Name one vanilla curse from your own `content/curses.xml` as `Carrier` and its bit is mirrored into
the real mask whenever any curse using it is active. **One entry covers all of your curses**, so it
costs a single one of the game's ~24 custom slots rather than one per curse. A name that does not
resolve to a usable slot is logged and the curse runs table-only.


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
| `SetStorage(owner, storage)` | `boolean` |
| `ReloadSettings()` | re-reads every store |
| `AddConfigMenu(config)` | `boolean` built |

### Tables

| Field | Meaning |
|---|---|
| `CurseRework.Version` | Integer, for the election |
| `CurseRework.Callbacks` | Callback id constants |
| `CurseRework.RollDefaults` | Reset values for the roll knobs |
| `CurseRework.Render` | Icon and layout settings (`Icons`, `Anchor`, `Step`, `PerRow`, `RowStep`) |
| `CurseRework.Internal` | Live state. Read it for debugging; do not write to it |

## REPENTOGON dependency (WHY)

- **`Minimap.GetDisplayedSize()`** / **`Minimap.GetState()`** — the fallback icon strip has to sit
  under the map at whatever height it is actually drawn.
- **`MC_PRE_ITEM_TEXT_DISPLAY`** — the HUD would otherwise announce the carrier's name instead of
  the curse that actually rolled.
- **`MC_POST_MODS_LOADED`** — MinimapAPI may load after you register, so the flags need a re-sync.
- **`MC_PRE_MOD_UNLOAD`**'s `ShuttingDown` argument — settings would be lost on a disable or
  reload without a flush.

