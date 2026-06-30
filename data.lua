-- Smart Train Combinator - Data Phase
--
-- Two entities:
--   * MAIN  ("smart-train-combinator")      - the brain. Wired to the train stop
--     and to the "leash" bus. Reads each probe's input network individually,
--     computes per-slot verdicts, sums them, drives the station. Based on the
--     constant-combinator so the script can write its output signal via control
--     behavior sections (same approach as the original Simple Train Combinator).
--   * PROBE ("stc2-buffer-probe")            - a passive, empty 2-connector shell.
--     Input side -> that train slot's chests. Output side -> the leash bus toward
--     the main. It computes NOTHING; it only provides two independent connectors
--     so the main can read this slot's storage in isolation. Based on the
--     arithmetic-combinator purely to reuse its visuals and its input/output
--     connector layout; its own logic is never configured, so it stays silent.

local util = require("util")

local MAIN  = "smart-train-combinator"
local PROBE = "stc2-buffer-probe"

-- A 4-way table of empty sprites, used to blank the leftover overlay layers
-- (activity LED, operator symbols) the cloned vanilla combinators keep drawing.
local function empty4()
  local e = util.empty_sprite()
  return { north = e, east = e, south = e, west = e }
end

-- ---------------------------------------------------------------------------
-- MAIN entity: constant-combinator clone, resized to 2x2 with custom art.
-- (Kept as a constant-combinator so the control behavior / logistic sections we
-- rely on for output + parametrization still work.)
-- ---------------------------------------------------------------------------
local MAIN_SPRITE = "__smart-train-combinator__/graphics/main-2x2.png"

local main = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
main.name                   = MAIN
main.minable.result         = MAIN
main.next_upgrade           = nil
main.fast_replaceable_group  = nil
main.flags = main.flags or {}
table.insert(main.flags, "get-by-unit-number")

-- 2x2 footprint
main.tile_width    = 2
main.tile_height   = 2
main.collision_box = { { -0.9, -0.9 }, { 0.9, 0.9 } }
main.selection_box = { { -1.0, -1.0 }, { 1.0, 1.0 } }

-- Custom 2x2 sprite (same image for all four directions). scale = px*scale/32 tiles;
-- 256 * 0.3 / 32 = 2.4 tiles (body ~2x2, wire stubs overhang like vanilla combinators).
local function main_dir_sprite()
  return { filename = MAIN_SPRITE, width = 256, height = 256, scale = 0.3, shift = { 0, 0 } }
end
main.sprites = { north = main_dir_sprite(), east = main_dir_sprite(), south = main_dir_sprite(), west = main_dir_sprite() }

-- Blank the activity LED so nothing floats over the custom art.
main.activity_led_sprites = empty4()

-- Inventory / map icon from the same art.
main.icon, main.icon_size = nil, nil
main.icons = { { icon = MAIN_SPRITE, icon_size = 256 } }

-- ---------------------------------------------------------------------------
-- MULTI entity: the multi-resource variant ("aiguilleur" / FIFO dispatcher).
-- Same constant-combinator base and 2x2 footprint as MAIN, distinct prototype
-- and cyan art so players tell them apart on the toolbar. Same runtime control
-- file handles both; the variant is keyed off the entity name.
-- ---------------------------------------------------------------------------
local MULTI        = "stc-multi"
local MULTI_SPRITE = "__smart-train-combinator__/graphics/main-multi-2x2.png"

local multi = table.deepcopy(main)
multi.name           = MULTI
multi.minable.result = MULTI
local function multi_dir_sprite()
  return { filename = MULTI_SPRITE, width = 256, height = 256, scale = 0.3, shift = { 0, 0 } }
end
multi.sprites = { north = multi_dir_sprite(), east = multi_dir_sprite(), south = multi_dir_sprite(), west = multi_dir_sprite() }
multi.icon, multi.icon_size = nil, nil
multi.icons = { { icon = MULTI_SPRITE, icon_size = 256 } }

-- ---------------------------------------------------------------------------
-- PROBE entity ("Wagon Module"): arithmetic-combinator clone (kept 1x2 + its
-- input/output connectors) with custom art. Empty shell: never configured, so
-- it outputs nothing on its own.
-- ---------------------------------------------------------------------------
local PROBE_NS   = "__smart-train-combinator__/graphics/probe-ns.png"  -- 79x256 (north/south)
local PROBE_EW   = "__smart-train-combinator__/graphics/probe-ew.png"  -- 256x152 (east/west)
local PROBE_ICON = "__smart-train-combinator__/graphics/probe-icon.png"

local probe = table.deepcopy(data.raw["arithmetic-combinator"]["arithmetic-combinator"])
probe.name                  = PROBE
probe.minable.result        = PROBE
probe.next_upgrade          = nil
probe.fast_replaceable_group = nil
probe.flags = probe.flags or {}
table.insert(probe.flags, "get-by-unit-number")

-- scale 0.25: long side 256px -> 2 tiles, matching the 1x2 footprint.
probe.sprites = {
  north = { filename = PROBE_NS, width = 120, height = 256, scale = 0.25, shift = { 0, 0 } },
  south = { filename = PROBE_NS, width = 120, height = 256, scale = 0.25, shift = { 0, 0 } },
  east  = { filename = PROBE_EW, width = 256, height = 109, scale = 0.25, shift = { 0, 0 } },
  west  = { filename = PROBE_EW, width = 256, height = 109, scale = 0.25, shift = { 0, 0 } },
}
probe.icon, probe.icon_size = nil, nil
probe.icons = { { icon = PROBE_ICON, icon_size = 64 } }

-- Blank the activity LED and every operator-symbol layer. An arithmetic
-- combinator always paints its current operation (e.g. the "*" symbol); since
-- the probe is never configured, that symbol would otherwise sit on top of the
-- custom art. We never need any of them.
probe.activity_led_sprites = empty4()
for k in pairs(probe) do
  if type(k) == "string" and k:match("_symbol_sprites$") then
    probe[k] = empty4()
  end
end

data:extend({
  main,
  multi,
  probe,

  -- Items
  {
    type         = "item",
    name         = MAIN,
    icons        = { { icon = MAIN_SPRITE, icon_size = 256 } },
    subgroup     = "circuit-network",
    order        = "c[combinators]-e[smart-train-combinator]-a[main]",
    place_result = MAIN,
    stack_size   = 50,
  },
  {
    type         = "item",
    name         = MULTI,
    icons        = { { icon = MULTI_SPRITE, icon_size = 256 } },
    subgroup     = "circuit-network",
    order        = "c[combinators]-e[smart-train-combinator]-am[multi]",
    place_result = MULTI,
    stack_size   = 50,
  },
  {
    type         = "item",
    name         = PROBE,
    icons        = { { icon = PROBE_ICON, icon_size = 64 } },
    subgroup     = "circuit-network",
    order        = "c[combinators]-e[smart-train-combinator]-b[probe]",
    place_result = PROBE,
    stack_size   = 50,
  },

  -- Recipe (one recipe yields the main; probes via a cheap separate recipe)
  {
    type        = "recipe",
    name        = MAIN,
    enabled     = false,
    ingredients = {
      { type = "item", name = "constant-combinator", amount = 1 },
      { type = "item", name = "rail-signal",         amount = 2 },
      { type = "item", name = "electronic-circuit",  amount = 2 },
    },
    results = { { type = "item", name = MAIN, amount = 1 } },
  },
  {
    type        = "recipe",
    name        = MULTI,
    enabled     = false,
    ingredients = {
      { type = "item", name = "constant-combinator", amount = 1 },
      { type = "item", name = "rail-signal",         amount = 2 },
      { type = "item", name = "electronic-circuit",  amount = 4 },
    },
    results = { { type = "item", name = MULTI, amount = 1 } },
  },
  {
    type        = "recipe",
    name        = PROBE,
    enabled     = false,
    ingredients = {
      { type = "item", name = "arithmetic-combinator", amount = 1 },
    },
    results = { { type = "item", name = PROBE, amount = 1 } },
  },

  -- Technology unlocking both
  {
    type  = "technology",
    name  = MAIN,
    icons = {
      { icon = "__smart-train-combinator__/graphics/tech.png", icon_size = 256 },
    },
    prerequisites = { "advanced-combinators", "automated-rail-transportation" },
    unit = {
      count = 100,
      ingredients = {
        { "automation-science-pack", 1 },
        { "logistic-science-pack",   1 },
        { "chemical-science-pack",   1 },
      },
      time = 30,
    },
    effects = {
      { type = "unlock-recipe", recipe = MAIN },
      { type = "unlock-recipe", recipe = MULTI },
      { type = "unlock-recipe", recipe = PROBE },
    },
  },
})

-- Icon for the Monitor toggle button in the settings window titlebar.
data:extend({
  {
    type     = "sprite",
    name     = "stc2-monitor-icon",
    filename = "__smart-train-combinator__/graphics/monitor-icon.png",
    size     = 64,
    flags    = { "gui-icon" },
  },
})

-- Virtual signals so the load/unload icon can be embedded in train-stop names
-- (rich text can reference [virtual-signal=...] but not custom sprite prototypes).
data:extend({
  { type = "item-subgroup", name = "stc2-signals", group = "signals", order = "zzz-stc2" },
  {
    type = "virtual-signal", name = "stc2-load",
    icon = "__smart-train-combinator__/graphics/arrow-load.png", icon_size = 64,
    subgroup = "stc2-signals", order = "a",
  },
  {
    type = "virtual-signal", name = "stc2-unload",
    icon = "__smart-train-combinator__/graphics/arrow-unload.png", icon_size = 64,
    subgroup = "stc2-signals", order = "b",
  },
  {
    type = "virtual-signal", name = "stc2-storage",
    icon = "__smart-train-combinator__/graphics/storage-icon.png", icon_size = 64,
    subgroup = "stc2-signals", order = "c",
  },
})

-- ---------------------------------------------------------------------------
-- Nullius compatibility (data phase) - same proven approach as the STC 1.0.3
-- port: rename recipe + technology with the "nullius-" prefix BEFORE Nullius's
-- hidden.lua (data-updates) runs, so they (and the items they produce) are
-- spared from hiding.
-- ---------------------------------------------------------------------------
if mods["nullius"] then
  local function nullius_recipe(name)
    local r = data.raw.recipe[name]
    for i, ing in ipairs(r.ingredients) do
      if ing.name == "electronic-circuit" then
        r.ingredients[i] = { type = "item", name = "arithmetic-combinator", amount = 1 }
      end
    end
    r.localised_name = { "recipe-name." .. name }
    r.name = "nullius-" .. name
    data.raw.recipe["nullius-" .. name] = r
    data.raw.recipe[name] = nil
    return "nullius-" .. name
  end

  local main_recipe  = nullius_recipe(MAIN)
  local multi_recipe = nullius_recipe(MULTI)
  local probe_recipe = nullius_recipe(PROBE)

  local tech = data.raw.technology[MAIN]
  tech.localised_name        = { "technology-name." .. MAIN }
  tech.localised_description = { "technology-description." .. MAIN }
  tech.prerequisites = { "nullius-computation", "nullius-traffic-control" }
  tech.unit = {
    count = 30,
    ingredients = {
      { "nullius-climatology-pack", 1 },
      { "nullius-mechanical-pack",  1 },
      { "nullius-electrical-pack",  1 },
    },
    time = 25,
  }
  tech.order = "nullius-df-z"
  tech.ignore_tech_cost_multiplier = true
  tech.effects = {
    { type = "unlock-recipe", recipe = main_recipe },
    { type = "unlock-recipe", recipe = multi_recipe },
    { type = "unlock-recipe", recipe = probe_recipe },
  }
  tech.name = "nullius-" .. MAIN
  data.raw.technology["nullius-" .. MAIN] = tech
  data.raw.technology[MAIN] = nil
end
