-- Smart Train Combinator - runtime
--
-- MODEL
--   * 1 PROBE shell = 1 WAGON. Place X probes -> trains here are X wagons long.
--     Probe INPUT side -> that wagon's dedicated buffer chests/tanks.
--     Probe OUTPUT side -> the MAIN ("leash", discovery only).
--   * The MAIN is the only brain. Each refresh:
--       1. walk the leash -> enumerate probes + the train stop;
--       2. read EACH probe's input network in isolation (wagons never sum);
--       3. per wagon: loads = floor(buffer / per_wagon_capacity)   (loading)
--                     loads = floor(free   / per_wagon_capacity)   (unloading)
--       4. trains = MIN(loads over wagons) clamped to [min,max] (your limit).
--   * Output: train count on the configured signal (default signal-L); the stop
--     is driven (train limit / enable).

local flib_gui = require("__flib__.gui")

local MAIN  = "smart-train-combinator"
local MULTI = "stc-multi"
local PROBE = "stc2-buffer-probe"
local TYPED = "stc-typed-probe"  -- resource-pinned probe (multi "independent buffer" mode)
local POWER = "stc2-power"       -- hidden always-on consumer glued onto each main

local MAX_GOODS = 10  -- multi-resource module: max simultaneously tracked goods

local DIRECTION = { LOAD = "load", UNLOAD = "unload" }
local KIND      = { ITEM = "item", FLUID = "fluid" }

-- A main is "multi" (the FIFO multi-resource dispatcher) when its entity is the
-- MULTI prototype. Everything else (the classic single-good main) is not.
local function is_multi(state)
  return state.entity and state.entity.valid and state.entity.name == MULTI
end

local ITEM_STORAGE_TYPES = {
  ["container"]          = true,
  ["logistic-container"] = true,
  ["linked-container"]   = true,
}

local W = defines.wire_connector_id
-- One group per wire COLOUR. The network walk runs one BFS per group and unions
-- the results, so it never hops from a red wire to a green one through an
-- entity: a green wire between two red networks belongs to whoever owns that
-- green network, it is NOT a bridge. This matches Factorio's own semantics
-- (an entity is wired to the main iff it shares a red OR green circuit
-- network with it).
local LEASH_CONNECTORS = {
  { W.circuit_red,   W.combinator_output_red },
  { W.circuit_green, W.combinator_output_green },
}
local INPUT_CONNECTORS = {
  { W.combinator_input_red,   W.circuit_red },
  { W.combinator_input_green, W.circuit_green },
}

-- GUI element names. Three windows:
--   WINDOW  = base config (default, the player.opened one)
--   STOPCFG = train-stop config (naming, signal L, priority + signal P) - toggled
--   MONITOR = per-wagon buffer readout - toggled
local WINDOW   = "stc2-window"
local STOPCFG  = "stc2-stop"
local MONITOR  = "stc2-monitor"
local NETCFG   = "stc2-net"      -- circuit "Condition logique" window (the enable gate)
local CLOSE    = "stc2-close"
local STOP_TOGGLE = "stc2-stop-toggle"
local STOP_CLOSE  = "stc2-stop-close"
local MON_TOGGLE = "stc2-mon-toggle"
local MON_CLOSE  = "stc2-mon-close"
local NET_TOGGLE = "stc2-net-toggle"
local NET_CLOSE  = "stc2-net-close"
local NET_CONN   = "stc2-net-conn"  -- "Connecté à : N" label
-- typed-probe window (pin a resource to a probe)
local TYPEDWIN    = "stc2-typed-win"
local TYPED_ELEM  = "stc2-typed-elem"   -- item picker
local TYPED_FLUID = "stc2-typed-fluid"  -- fluid picker (mutually exclusive with item)
local TYPED_CLOSE = "stc2-typed-close"
local CONTENT  = "stc2-content"
local STATUS   = "stc2-status"
local ST_ICON  = "stc2-status-icon"
local ST_LABEL = "stc2-status-label"
local CONFIG   = "stc2-config"
local TYPE_SW  = "stc2-type"
local ITEMBTN  = "stc2-item"
local FLUIDBTN = "stc2-fluid"
local DIR_SW   = "stc2-dir-switch"
local STORAGE_CHK = "stc2-storage-chk"  -- single module: mark as evacuation->storage (name icon only)
local OUTPUT   = "stc2-output"
local SIGP     = "stc2-prio-signal"
local MAXF     = "stc2-max"
local WAGON    = "stc2-wagon"
local LINKS    = "stc2-links"
local LINK_LIM = "stc2-link-limit"
local LINK_NM  = "stc2-link-name"
local LINK_WC  = "stc2-link-wagon-count"
local LINK_PRIO = "stc2-link-prio"
local PRIO_DD  = "stc2-prio-level"
local PRIO_LBL = "stc2-prio-label"
local NAME_PREVIEW = "stc2-name-preview"
local CAP_LBL  = "stc2-cap-label"
local WAGONS   = "stc2-wagons"
local TRAINS   = "stc2-trains"
-- multi-resource goods picker (base window, bottom block)
local GOODS_FRAME = "stc2-goods-frame"
local GOODS_TABLE = "stc2-goods-table"
local GOOD_BTN    = "stc2-good-"     -- + index 1..MAX_GOODS
local GOODS_HINT  = "stc2-goods-hint"  -- shown in typed mode: "defined by typed probes"
-- enable gate (stop-config window)
local GATE_CHK   = "stc2-gate-chk"
local GATE_SIG   = "stc2-gate-sig"
local GATE_OP    = "stc2-gate-op"
local GATE_RMODE = "stc2-gate-rmode"  -- switch: constant (left) / signal (right)
local GATE_CONST = "stc2-gate-const"
local GATE_SIG2  = "stc2-gate-sig2"
local GATE_REQ   = "stc2-gate-active"  -- monitor: current active request label

-- Global overview screen (lists every module in the game).
local OVERVIEW      = "stc2-overview"          -- root frame (player.gui.screen)
local OV_CLOSE      = "stc2-ov-close"
local OV_LIST       = "stc2-ov-list"           -- scroll-pane holding the rows
local OV_F_TYPE     = "stc2-ov-f-type"         -- filter: type radios (all/item/fluid)
local OV_F_RES      = "stc2-ov-f-res"          -- filter: resource picker (item or fluid, per the Type filter)
local OV_F_DIR      = "stc2-ov-f-dir"          -- filter: direction radios
local OV_F_STORE    = "stc2-ov-f-store"        -- filter: storage radios
local OV_EYE        = "stc2-ov-eye-"           -- + module unit_number
local OV_WAGON      = "stc2-ov-wagon-"         -- + module unit_number
local OV_TYPES      = { "all", "item", "fluid" }
local OV_DIRS       = { "all", "load", "unload" }
local OV_STORES     = { "all", "yes", "no" }

-- Gate operator drop-down order <-> stored gate_op value.
local GATE_OPS     = { "<", ">", "=", ">=", "<=", "!=" }
local GATE_OP_CAPS = { "<", ">", "=", "≥", "≤", "≠" }  -- drop-down captions
local function gate_op_index(op)
  for i, o in ipairs(GATE_OPS) do if o == op then return i end end
  return 1
end

-- ===========================================================================
-- State
-- ===========================================================================
local function ensure_storage()
  storage.mains = storage.mains or {}
  storage.guis  = storage.guis  or {}  -- player_index -> main unit_number (base window open)
  storage.monitor_pref = storage.monitor_pref or {}  -- player_index -> bool: show monitor window
  storage.stopcfg_pref = storage.stopcfg_pref or {}  -- player_index -> bool: show stop-config window
  storage.netcfg_pref  = storage.netcfg_pref  or {}  -- player_index -> bool: show circuit-condition window
  storage.typed      = storage.typed      or {}  -- typed-probe unit_number -> { name, quality } (pinned resource)
  storage.typed_guis = storage.typed_guis or {}  -- player_index -> typed-probe unit_number (its window open)
  storage.win_loc = storage.win_loc or {}  -- player_index -> { [window_name] = {x,y} }: remembered positions
  storage.overview_guis    = storage.overview_guis    or {}  -- player_index -> true when the overview screen is open
  storage.overview_filters = storage.overview_filters or {}  -- player_index -> { type, resource, direction, storage }
  storage.overview_sig     = storage.overview_sig     or {}  -- player_index -> signature of the rows last built (rebuild vs update)
end

local function default_state(entity)
  return {
    entity         = entity,
    kind           = KIND.ITEM,
    direction      = DIRECTION.LOAD,
    storage        = false,      -- single module + loading: add the storage icon to the auto-name (no mechanical change)
    icon           = nil,        -- tracked item/fluid name
    icon_quality   = "normal",   -- quality of the tracked item (items only)
    wagon_type     = nil,        -- chosen rolling-stock prototype name (modded/nullius wagons included)
    wagon_quality  = "normal",
    max_trains     = 1,
    output_signal  = { type = "virtual", name = "signal-L", quality = "normal" },
    link_train_count = true,
    train_stop_name  = true,   -- auto-rename the station by default (with the wagon count)
    name_wagon_count = true,    -- include the wagon (probe) count in the auto-name
    priority_level   = "medium",   -- high / important / medium / low
    link_priority    = false,
    priority_output_signal = { type = "virtual", name = "signal-P", quality = "normal" },
    -- Multi-resource module (MULTI): a list of tracked goods + the FIFO dispatch
    -- state. Empty / unused on the classic single-good main.
    goods          = {},        -- { { name, quality }, ... } up to MAX_GOODS (items); 1 entry for fluids
    request_queue  = {},        -- FIFO of good indices waiting for a train
    active_request = nil,       -- good index currently committed (station named for it, L=1)
    released_train_id = nil,    -- id of the train we already released the active request on
    -- Enable gate ("active si condition") - applies to BOTH modules. While the
    -- condition is false, the module requests 0 trains (the stop stays active).
    gate_enabled   = false,
    gate_signal    = nil,                 -- left operand (signal)
    gate_op        = "<",                 -- one of < > = >= <= !=
    gate_use_const = true,                -- right operand is a constant (else gate_signal2)
    gate_constant  = 0,
    gate_signal2   = nil,                 -- right operand when gate_use_const is false
    -- caches
    probes      = {},
    stops       = {},
    trains_call = nil,
    current_priority = nil,
    eval        = nil,
  }
end

-- Priority band base per level (each band is 50 wide; higher = preferred by trains).
local PRIORITY_BANDS  = { low = 50, medium = 100, important = 150, high = 200 }
local PRIORITY_LEVELS = { "high", "important", "medium", "low" }  -- drop-down order
local function level_index(level)
  for i, l in ipairs(PRIORITY_LEVELS) do if l == level then return i end end
  return 3 -- medium
end

-- Fill in fields added in later versions on states saved by earlier ones, so a
-- main placed before a field existed doesn't carry a nil where code expects a value.
local function migrate_state(state)
  if state.kind == nil             then state.kind = KIND.ITEM end
  if state.direction == nil        then state.direction = DIRECTION.LOAD end
  if state.storage == nil          then state.storage = false end
  if state.icon_quality == nil     then state.icon_quality = "normal" end
  if state.wagon_quality == nil    then state.wagon_quality = "normal" end
  if state.max_trains == nil       then state.max_trains = 1 end
  if state.link_train_count == nil then state.link_train_count = true end
  if state.train_stop_name == nil  then state.train_stop_name = false end
  if state.name_wagon_count == nil then state.name_wagon_count = true end
  state.auto_enable = nil  -- removed feature: clear any leftover from older states
  if state.output_signal == nil    then state.output_signal = { type = "virtual", name = "signal-L", quality = "normal" } end
  if state.output_signal and state.output_signal.quality == nil then state.output_signal.quality = "normal" end
  if state.priority_level == nil   then state.priority_level = "medium" end
  if state.link_priority == nil    then state.link_priority = false end
  if state.priority_output_signal == nil then state.priority_output_signal = { type = "virtual", name = "signal-P", quality = "normal" } end
  if state.priority_output_signal and state.priority_output_signal.quality == nil then state.priority_output_signal.quality = "normal" end
  -- Multi-resource + FIFO fields
  state.goods         = state.goods or {}
  state.request_queue = state.request_queue or {}
  -- Enable gate fields
  if state.gate_enabled == nil   then state.gate_enabled = false end
  if state.gate_op == nil        then state.gate_op = "<" end
  if state.gate_use_const == nil then state.gate_use_const = true end
  if state.gate_constant == nil  then state.gate_constant = 0 end
  state.stop   = nil  -- replaced by stops list
  state.stops  = state.stops or {}
  state.probes = state.probes or {}
end

local function migrate_all()
  ensure_storage()
  for _, state in pairs(storage.mains) do migrate_state(state) end
end

-- Config fields persisted through blueprints / copy-paste (everything the player
-- sets; never the transient caches like probes/stop/eval).
local CONFIG_FIELDS = {
  "kind", "direction", "storage", "icon", "icon_quality", "wagon_type", "wagon_quality",
  "max_trains", "output_signal", "link_train_count", "train_stop_name", "name_wagon_count",
  "priority_level", "link_priority", "priority_output_signal",
  "goods",
  "gate_enabled", "gate_signal", "gate_op", "gate_use_const", "gate_constant", "gate_signal2",
}

local function copy_goods(goods)
  local out = {}
  for i, g in ipairs(goods or {}) do out[i] = { name = g.name, quality = g.quality } end
  return out
end

local function config_of(state)
  local c = {}
  for _, k in pairs(CONFIG_FIELDS) do c[k] = state[k] end
  c.goods = copy_goods(state.goods)  -- detach so copy-paste/blueprint don't alias the live list
  return c
end

local function apply_config(state, cfg)
  if type(cfg) ~= "table" then return end
  for _, k in pairs(CONFIG_FIELDS) do
    if cfg[k] ~= nil then state[k] = cfg[k] end
  end
  state.goods = copy_goods(cfg.goods)  -- detach from the source state's live list
  migrate_state(state)
end

-- ===========================================================================
-- Circuit traversal
-- ===========================================================================
local function walk_network(entity, connector_groups)
  local found, found_set = {}, {}
  for _, connector_ids in pairs(connector_groups) do
    -- `seen` is per colour: an entity already found via red must still relay
    -- the green pass (and vice versa), only `found` is deduplicated.
    local seen = { [entity.unit_number] = true }
    local queue = { entity }
    while #queue > 0 do
      local node = table.remove(queue)
      for _, cid in pairs(connector_ids) do
        local connector = node.get_wire_connector(cid, false)
        if connector then
          for _, conn in pairs(connector.connections) do
            local target = conn.target and conn.target.owner
            if target and target.valid and not seen[target.unit_number] then
              seen[target.unit_number] = true
              if not found_set[target.unit_number] then
                found_set[target.unit_number] = true
                table.insert(found, target)
              end
              table.insert(queue, target)
            end
          end
        end
      end
    end
  end
  return found
end

local function discover(state)
  local probes, typed, stops = {}, {}, {}
  for _, e in pairs(walk_network(state.entity, LEASH_CONNECTORS)) do
    if e.name == PROBE then
      table.insert(probes, e)
    elseif e.name == TYPED then
      table.insert(typed, e)
    elseif e.type == "train-stop" then
      table.insert(stops, e)  -- support several stops wired to one main
    end
  end
  state.probes       = probes
  state.typed_probes = typed
  state.stops        = stops
end

-- A train stop must be driven by exactly ONE main. Walked from the stop's side
-- (both colours), so every main wired to a contested stop sees the conflict —
-- including when the two mains reach it through different wire colours.
local function stops_conflict(state)
  for _, stop in pairs(state.stops or {}) do
    if stop.valid then
      local mains = 0
      for _, e in pairs(walk_network(stop, LEASH_CONNECTORS)) do
        if e.name == MAIN or e.name == MULTI then mains = mains + 1 end
      end
      if mains >= 2 then return true end
    end
  end
  return false
end

-- The main's power tap: a hidden always-on consumer glued onto the main (a
-- constant combinator can't draw power by itself). Created on build, and
-- recreated on demand here so mains from saves made before this feature pick
-- one up on their next refresh.
local function ensure_power(state)
  local p = state.power
  if p and p.valid then return p end
  local e = state.entity
  p = e.surface.find_entities_filtered({ name = POWER, position = e.position, radius = 0.5 })[1]
      or e.surface.create_entity({ name = POWER, position = e.position, force = e.force })
  if p then p.destructible = false end
  state.power = p
  return p
end

-- True if any wired probe (generic or typed) has an empty energy buffer.
local function probes_unpowered(state)
  for _, list in pairs({ state.probes, state.typed_probes }) do
    for _, p in pairs(list or {}) do
      if p.valid and p.energy == 0 then return true end
    end
  end
  return false
end

-- ===========================================================================
-- Capacity + per-probe read
-- ===========================================================================
-- Capacity of one wagon for the tracked good, read from the chosen rolling-stock
-- prototype (so modded/nullius wagons and quality are accounted for). nil until
-- a wagon (and, for items, a tracked item) is configured.
-- Per-wagon capacity for a given good, optionally split across `m` goods.
--   * single-good main: m = 1  -> a full wagon for the tracked good.
--   * multi module (shared buffer): m = #goods -> the wagon's SLOTS are divided
--     evenly so each good gets floor(slots / m) stacks ("autant de fer que de
--     charbon", égalité en stacks). Fluids are never split (a fluid wagon holds
--     a single fluid), so m is ignored for fluid-wagons.
-- nil until a wagon (and, for items, the good) is configured.
local function per_wagon_capacity_for(state, icon, m)
  if not state.wagon_type then return nil end
  local wagon = prototypes.entity[state.wagon_type]
  if not wagon then return nil end
  local q = prototypes.quality[state.wagon_quality or "normal"]
  if wagon.type == "fluid-wagon" then
    return wagon.get_fluid_capacity(q)
  elseif wagon.type == "cargo-wagon" then
    if not icon then return nil end
    local item = prototypes.item[icon]
    if item then
      local slots = wagon.get_inventory_size(defines.inventory.cargo_wagon, q)
      if m and m > 1 then slots = math.floor(slots / m) end
      if slots < 1 then slots = 1 end
      return slots * item.stack_size
    end
  end
end

-- Classic single-good per-wagon capacity (no split).
local function per_wagon_capacity(state)
  return per_wagon_capacity_for(state, state.icon, 1)
end

local function wagon_filter(kind)
  return { { filter = "type", type = (kind == KIND.FLUID) and "fluid-wagon" or "cargo-wagon" } }
end

-- Total buffer SLOTS wired to a probe's input (items), or total tank fluid
-- capacity (fluids). Computed once per probe; per-good capacity is then
-- slots * stack_size(good) for items, or this value directly for fluids.
local function probe_buffer_units(state, probe)
  local units = 0
  for _, e in pairs(walk_network(probe, INPUT_CONNECTORS)) do
    if state.kind == KIND.ITEM and ITEM_STORAGE_TYPES[e.type] then
      units = units + e.prototype.get_inventory_size(defines.inventory.chest, e.quality)
    elseif state.kind == KIND.FLUID and e.type == "storage-tank" then
      units = units + e.prototype.get_fluid_capacity(e.quality)
    end
  end
  return units
end

-- Amount of `icon` stored in a probe's input network (summed across qualities).
local function probe_stored(state, probe, icon)
  if not icon then return 0 end
  local stored = 0
  local want_type = (state.kind == KIND.FLUID) and "fluid" or "item"
  for _, cid in pairs({ W.combinator_input_red, W.combinator_input_green }) do
    local net = probe.get_circuit_network(cid)
    if net and net.signals then
      for _, entry in pairs(net.signals) do
        local s = entry.signal
        if s.name == icon and (s.type or "item") == want_type then
          stored = stored + entry.count
        end
      end
    end
  end
  return stored
end

-- Stored + buffer capacity of one probe for a given good (capacity in that
-- good's units). Generalises the old read_probe to an arbitrary good.
local function read_probe_good(state, probe, icon)
  local stored = probe_stored(state, probe, icon)
  local units  = probe_buffer_units(state, probe)
  local capacity
  if state.kind == KIND.FLUID then
    capacity = units
  else
    local item = icon and prototypes.item[icon]
    capacity = item and (units * item.stack_size) or 0
  end
  return stored, capacity
end

local function read_probe(state, probe)
  return read_probe_good(state, probe, state.icon)
end

--- Evaluate every wagon. Returns { cap, rows = { {stored,capacity,loads} }, bottleneck_idx, raw }.
local function evaluate(state)
  local cap = per_wagon_capacity(state)
  local rows, best_loads, best_idx = {}, nil, nil
  local stored_total, cap_total = 0, 0
  local i = 0
  for _, probe in pairs(state.probes) do
    if probe.valid then
      i = i + 1
      local stored, capacity = read_probe(state, probe)
      local loads = 0
      if cap and cap > 0 then
        if state.direction == DIRECTION.LOAD then
          loads = math.floor(stored / cap)
        else
          loads = math.floor((capacity - stored) / cap)
        end
        if loads < 0 then loads = 0 end
      end
      rows[i] = { stored = stored, capacity = capacity, loads = loads }
      stored_total = stored_total + stored
      cap_total    = cap_total + capacity
      if best_loads == nil or loads < best_loads then best_loads = loads; best_idx = i end
    end
  end
  return {
    cap = cap, rows = rows, bottleneck_idx = best_idx, raw = best_loads or 0,
    stored_total = stored_total, cap_total = cap_total,
  }
end

-- === Multi-resource evaluation =============================================
-- For every tracked good, per wagon: LOAD -> ship once a FULL wagon of the good
-- has accumulated; UNLOAD -> request once there's room for a FULL wagon. A train
-- is mono-resource so the unit is a whole wagon (no ÷M - that under-filled/over-
-- called trains). Because the buffer is SHARED, "free room" is the bay's real
-- free SLOTS (all goods counted), not (this-good-capacity - this-good-stored).
local function evaluate_multi(state)
  local goods   = state.goods or {}
  local m       = #goods
  local is_item = (state.kind == KIND.ITEM)

  local probe_units = {}
  for _, probe in pairs(state.probes) do
    if probe.valid then
      probe_units[#probe_units + 1] = { probe = probe, units = probe_buffer_units(state, probe) }
    end
  end
  local nprobes = #probe_units

  -- Per bay: each good's stored amount (read once) + the real free slot count
  -- (items) after ALL goods are accounted for.
  local bay_stored, bay_free = {}, {}
  for wi, pu in ipairs(probe_units) do
    bay_stored[wi] = {}
    local occupied = 0
    for gi, g in ipairs(goods) do
      local s = probe_stored(state, pu.probe, g.name)
      bay_stored[wi][gi] = s
      if is_item then
        local it = prototypes.item[g.name]
        if it and it.stack_size > 0 then occupied = occupied + math.ceil(s / it.stack_size) end
      end
    end
    bay_free[wi] = math.max(0, pu.units - occupied)
  end

  local per_good = {}
  for gi, g in ipairs(goods) do
    local icon = g.name
    local cap  = per_wagon_capacity_for(state, icon, 1)  -- a full wagon of this good
    local item = is_item and prototypes.item[icon] or nil
    local wagon_slots = (item and cap and item.stack_size > 0) and (cap / item.stack_size) or nil
    local rows, min_loads = {}, nil
    local stored_total, cap_total = 0, 0
    for wi, pu in ipairs(probe_units) do
      local stored   = bay_stored[wi][gi]
      local capacity = (state.kind == KIND.FLUID) and pu.units or (item and pu.units * item.stack_size or 0)
      local loads = 0
      if cap and cap > 0 then
        if state.direction == DIRECTION.LOAD then
          loads = math.floor(stored / cap)
        elseif is_item and wagon_slots then
          loads = math.floor(bay_free[wi] / wagon_slots)  -- room for N full wagons (shared slots)
        else
          loads = math.floor((capacity - stored) / cap)   -- fluids: own tank, not shared
        end
        if loads < 0 then loads = 0 end
      end
      rows[wi] = { stored = stored, capacity = capacity, loads = loads }
      stored_total = stored_total + stored
      cap_total    = cap_total + capacity
      if min_loads == nil or loads < min_loads then min_loads = loads end
    end
    if nprobes == 0 then min_loads = 0 end
    per_good[gi] = {
      icon = icon, quality = g.quality, cap = cap, rows = rows,
      ready_loads = min_loads or 0, ready = (min_loads or 0) >= 1,
      stored_total = stored_total, cap_total = cap_total,
    }
  end
  return { m = m, per_good = per_good, nprobes = nprobes }
end

-- === Typed-probe evaluation (independent buffer) ===========================
-- Each typed probe pins ONE resource. Per resource: its wagons are its typed
-- probes (so train length varies per resource), each a FULL wagon (no ÷M). The
-- goods list is DERIVED from the wired typed probes (sorted by name for a stable
-- FIFO order).
local function evaluate_typed(state)
  local groups, order = {}, {}
  local main_fluid = (state.kind == KIND.FLUID)
  for _, probe in pairs(state.typed_probes or {}) do
    if probe.valid then
      local r = storage.typed[probe.unit_number]
      -- only probes whose pinned kind matches the main's Type (a leftover from a
      -- different Type is ignored, not misread -> reactivates if you switch back)
      if r and r.name and ((r.fluid and true or false) == main_fluid) then
        local g = groups[r.name]
        if not g then
          g = { icon = r.name, quality = r.quality or "normal", probes = {} }
          groups[r.name] = g
          order[#order + 1] = r.name
        end
        table.insert(g.probes, probe)
      end
    end
  end
  table.sort(order)

  local per_good = {}
  for gi, name in ipairs(order) do
    local g    = groups[name]
    local icon = g.icon
    local cap  = per_wagon_capacity_for(state, icon, 1)  -- full wagon, no ÷M
    local item = (state.kind == KIND.ITEM) and prototypes.item[icon] or nil
    local rows, min_loads = {}, nil
    local stored_total, cap_total = 0, 0
    for wi, probe in ipairs(g.probes) do
      local stored   = probe_stored(state, probe, icon)
      local units    = probe_buffer_units(state, probe)
      local capacity = (state.kind == KIND.FLUID) and units or (item and units * item.stack_size or 0)
      local loads = 0
      if cap and cap > 0 then
        if state.direction == DIRECTION.LOAD then
          loads = math.floor(stored / cap)
        else
          loads = math.floor((capacity - stored) / cap)
        end
        if loads < 0 then loads = 0 end
      end
      rows[wi] = { stored = stored, capacity = capacity, loads = loads }
      stored_total = stored_total + stored
      cap_total    = cap_total + capacity
      if min_loads == nil or loads < min_loads then min_loads = loads end
    end
    per_good[gi] = {
      icon = icon, quality = g.quality, cap = cap, rows = rows,
      ready_loads = min_loads or 0, ready = (min_loads or 0) >= 1,
      stored_total = stored_total, cap_total = cap_total,
    }
  end
  return { m = #order, per_good = per_good, nprobes = #(state.typed_probes or {}), typed = true, keys = order }
end

-- A train currently stopped at any wired stop (nil if the quay is empty).
local function stopped_train(state)
  for _, stop in pairs(state.stops or {}) do
    if stop.valid then
      local t = stop.get_stopped_train()
      if t and t.valid then return t end
    end
  end
  return nil
end

-- FIFO dispatch: maintain request_queue (good indices) + active_request, commit
-- to one good at a time, release it the moment a train ARRIVES at the quay
-- (rename-on-arrival; we remember that train's id so we don't cascade the whole
-- queue while it still sits there). Returns the active good index, or nil.
local function dispatch_fifo(state, em)
  local pg = em.per_good

  -- guard: a stale active index (goods list shrank via edit/paste) would never
  -- clear and would deadlock the dispatch -> drop it.
  if state.active_request and not pg[state.active_request] then
    state.active_request = nil
  end

  -- Release the active good when its train ARRIVES (rename-on-arrival), but
  -- remember it as `last_served` while that train is still at the quay so it is
  -- NEVER re-queued while being served (no two demands for the same resource).
  -- Once the quay clears, the good is eligible again (round-robin).
  local train = stopped_train(state)
  if train then
    if state.active_request and train.id ~= state.released_train_id then
      state.released_train_id = train.id
      state.last_served       = state.active_request
      state.active_request    = nil
    end
  else
    state.released_train_id = nil
    state.last_served       = nil
  end

  -- Queue = the ready goods that are neither active nor currently being served,
  -- each present at most once (FIFO order preserved, served good re-added at tail).
  local in_queue = {}
  for _, gi in ipairs(state.request_queue) do in_queue[gi] = true end
  for gi, info in ipairs(pg) do
    if info.ready and gi ~= state.active_request and gi ~= state.last_served and not in_queue[gi] then
      table.insert(state.request_queue, gi)
      in_queue[gi] = true
    end
  end
  local kept = {}
  for _, gi in ipairs(state.request_queue) do
    if pg[gi] and pg[gi].ready and gi ~= state.last_served then kept[#kept + 1] = gi end
  end
  state.request_queue = kept

  -- Commit to the head of the queue only when the quay is EMPTY. Waiting for the
  -- previous train to leave means the buffer reflects its cargo, so readiness
  -- (esp. free room when unloading) is evaluated on the real state -> we never
  -- request a train that won't fit / can't be filled.
  if not state.active_request and not train then
    while #state.request_queue > 0 do
      local gi = table.remove(state.request_queue, 1)
      if pg[gi] and pg[gi].ready then state.active_request = gi; break end
    end
  end

  return state.active_request
end

-- === Enable gate ("active si condition") ===================================
-- Reads the named signal from the main's own circuit network (red+green summed)
-- and compares it to a constant or a second signal. While the condition is
-- false the module requests 0 trains. Applies to BOTH modules.
local function read_signal_on_main(state, sig)
  if not sig then return 0 end
  local total = 0
  for _, cid in pairs({ W.circuit_red, W.circuit_green }) do
    local net = state.entity.get_circuit_network(cid)
    if net then total = total + net.get_signal(sig) end
  end
  return total
end

local function gate_open(state)
  if not state.gate_enabled then return true end
  if not state.gate_signal then return true end  -- misconfigured: don't block
  local lhs = read_signal_on_main(state, state.gate_signal)
  local rhs = state.gate_constant or 0  -- right operand: constant only
  local op = state.gate_op or "<"
  if     op == "<"  then return lhs <  rhs
  elseif op == ">"  then return lhs >  rhs
  elseif op == "="  then return lhs == rhs
  elseif op == ">=" then return lhs >= rhs
  elseif op == "<=" then return lhs <= rhs
  elseif op == "!=" then return lhs ~= rhs end
  return true
end

-- Priority value: band base (by level) + position within the 50-wide band from
-- the station fill ratio. Unloading: emptier -> higher (served first). Loading:
-- fuller -> higher. Higher Factorio priority = preferred destination.
local function compute_priority(state)
  local base = PRIORITY_BANDS[state.priority_level or "medium"] or 100
  local eval = state.eval
  local ratio = 0
  if eval and eval.cap_total and eval.cap_total > 0 then
    local fill = eval.stored_total / eval.cap_total
    if fill < 0 then fill = 0 elseif fill > 1 then fill = 1 end
    ratio = (state.direction == DIRECTION.LOAD) and fill or (1 - fill)
  end
  local p = base + math.floor(ratio * 49 + 0.5)
  if p < 0 then p = 0 elseif p > 255 then p = 255 end
  return p
end

-- ===========================================================================
-- In-world overlay (alt-mode)
-- ===========================================================================
-- The main is a constant-combinator, so vanilla alt-mode would only show its
-- bare output signals ("L" = train limit, "P" = priority). We hide that
-- (hide-alt-info flag, data.lua) and draw our own: the tracked resource icon
-- and a load/unload arrow, both only_in_alt_mode. Sprites are (re)built only
-- when the desired picture changes (ov_sig), so the per-tick refresh is cheap.
-- Overlay layout (tile offsets relative to the entity centre; +y is DOWN).
-- Tweak these four to reposition/resize the whole badge.
local OV_Y     = -0.38   -- lift the badge above the body centre (negative = up)
local OV_DX    = 0.32    -- half the gap between the two icons (smaller = closer)
local OV_SCALE = 0.42    -- icon size (x_scale = y_scale)
local OV_BG    = "utility/entity_info_dark_background"

local function clear_overlay(state)
  if state.ov_bg    and state.ov_bg.valid    then state.ov_bg.destroy()    end
  if state.ov_icon  and state.ov_icon.valid  then state.ov_icon.destroy()  end
  if state.ov_arrow and state.ov_arrow.valid then state.ov_arrow.destroy() end
  state.ov_bg, state.ov_icon, state.ov_arrow = nil, nil, nil
end

local function update_overlay(state)
  local e = state.entity
  if not (e and e.valid) then return end

  -- Tracked resource. state.icon holds the active good; a multi module clears it
  -- while idle between FIFO dispatches, so fall back to its first configured good
  -- (state.kind is the multi's type) — the badge should never lose its resource.
  local icon_name = state.icon
  if not icon_name and is_multi(state) then
    -- generic multi keeps its goods in state.goods; the typed multi derives them
    -- from the wired probes (eval_multi.per_good). Prefer whichever is populated.
    local g = (state.goods or {})[1]
    if g and g.name then
      icon_name = g.name
    else
      local pg = state.eval_multi and state.eval_multi.per_good
      icon_name = pg and pg[1] and pg[1].icon or nil
    end
  end
  -- Guard the path: another mod could have removed the prototype.
  local icon_sprite
  if icon_name then
    local path = (state.kind == KIND.FLUID) and ("fluid/" .. icon_name)
                                             or  ("item/"  .. icon_name)
    if helpers.is_valid_sprite_path(path) then icon_sprite = path end
  end
  local arrow_sprite = (state.direction == DIRECTION.UNLOAD)
    and "virtual-signal/stc2-unload" or "virtual-signal/stc2-load"

  -- Only rebuild when the picture actually changed. The layout constants are
  -- part of the signature too, so tweaking them (+ /reload) forces a redraw
  -- even though the resource/direction are unchanged.
  local sig = table.concat({ icon_sprite or "-", arrow_sprite,
    OV_Y, OV_DX, OV_SCALE, OV_BG }, "|")
  if sig == state.ov_sig and state.ov_arrow and state.ov_arrow.valid then return end
  state.ov_sig = sig
  clear_overlay(state)

  local surface = e.surface
  -- Dark pill behind the icons (same style as the vanilla alt-info background).
  -- Drawn first so the icons sit on top of it within the same render layer.
  if helpers.is_valid_sprite_path(OV_BG) then
    state.ov_bg = rendering.draw_sprite({
      sprite = OV_BG, surface = surface,
      target = { entity = e, offset = { 0, OV_Y } },
      x_scale = 1.15, y_scale = 0.72,
      render_layer = "entity-info-icon", only_in_alt_mode = true,
    })
  end
  -- Resource icon on the LEFT, load/unload arrow on the RIGHT, tightly grouped.
  if icon_sprite then
    state.ov_icon = rendering.draw_sprite({
      sprite = icon_sprite, surface = surface,
      target = { entity = e, offset = { -OV_DX, OV_Y } },
      x_scale = OV_SCALE, y_scale = OV_SCALE,
      render_layer = "entity-info-icon", only_in_alt_mode = true,
    })
  end
  state.ov_arrow = rendering.draw_sprite({
    sprite = arrow_sprite, surface = surface,
    target = { entity = e, offset = { OV_DX, OV_Y } },
    x_scale = OV_SCALE, y_scale = OV_SCALE,
    render_layer = "entity-info-icon", only_in_alt_mode = true,
  })
end

-- ===========================================================================
-- Output + station driving
-- ===========================================================================
local function write_output(state)
  local cb = state.entity.get_or_create_control_behavior()
  if not cb then return end
  local section = (cb.sections_count == 0) and cb.add_section() or cb.get_section(1)
  section.clear_slot(1)
  section.clear_slot(2)
  if type(state.trains_call) == "number" then
    local s = state.output_signal
    -- A logistic-section slot needs a quality-pinned (trivial) filter to carry a
    -- non-zero count; normalize here so states saved before this fix also work.
    local value = { type = s.type or "item", name = s.name, quality = s.quality or "normal" }
    section.set_slot(1, { value = value, min = state.trains_call })
  end
  if state.link_priority and type(state.current_priority) == "number" then
    local p = state.priority_output_signal
    local pv = { type = p.type or "virtual", name = p.name, quality = p.quality or "normal" }
    section.set_slot(2, { value = pv, min = state.current_priority })
  end
  update_overlay(state)  -- keep the alt-mode overlay in sync with resource/direction
end

-- Store the tracked good as a signal in an INACTIVE section (#2) of the main.
-- An inactive section emits nothing on the network, but its signals are stored
-- in the entity and the blueprint -> so Factorio's blueprint *parametrization*
-- can substitute the resource. We read it back on build (read_tracked_signal).
local function write_tracked_signal(state)
  local cb = state.entity.get_or_create_control_behavior()
  if not cb then return end
  while cb.sections_count < 2 do cb.add_section() end
  local s = cb.get_section(2)
  s.active = false
  s.clear_slot(1)
  -- Only write a good the current mod set still knows about. state.icon can hold a
  -- name from a blueprint parameter or a save made with a different mod set (item
  -- renamed/removed); set_slot on an unknown prototype is an unrecoverable error.
  local is_fluid = (state.kind == KIND.FLUID)
  local known = state.icon and (is_fluid
    and prototypes.fluid[state.icon] ~= nil
    or  prototypes.item[state.icon]  ~= nil)
  if known then
    -- Like write_output: a slot with a non-zero count needs a quality-pinned
    -- (trivial) filter — including fluids, whose signal still carries a quality.
    local value = is_fluid
      and { type = "fluid", name = state.icon, quality = "normal" }
      or  { type = "item", name = state.icon, quality = state.icon_quality or "normal" }
    s.set_slot(1, { value = value, min = 1 })
  end
end

-- Read the tracked good back from section #2 (set by the blueprint, possibly
-- substituted by a parameter) and override the resource in state.
local function read_tracked_signal(state)
  local cb = state.entity.get_control_behavior()
  if not cb or cb.sections_count < 2 then return end
  local f = cb.get_section(2).get_slot(1)
  local v = f and f.value
  if v and v.name then
    if v.type == "fluid" then
      state.kind = KIND.FLUID; state.icon = v.name; state.icon_quality = "normal"
    else
      state.kind = KIND.ITEM; state.icon = v.name; state.icon_quality = v.quality or "normal"
    end
  end
end

-- The wagon-icon run for the station name (chosen wagon type's icon):
--   name_wagon_count ON  -> one icon per wired probe (so a 1-wagon bay never
--                           shares a name with a 3-wagon bay);
--   name_wagon_count OFF -> exactly one icon.
-- Empty if no wagon type is chosen yet (can't render its icon).
-- How many wagons the CURRENT resource (state.icon) represents in the name:
--   single / generic multi -> the generic probes;
--   typed multi -> the typed probes of that resource (its per-good rows).
local function wagon_count_for(state)
  if is_multi(state) and state.eval_multi and state.icon then
    for _, info in ipairs(state.eval_multi.per_good or {}) do
      if info.icon == state.icon then return #(info.rows or {}) end
    end
  end
  return #(state.probes or {})
end

-- The rich-text tag for the wagon icon in the station name. We use the wagon's
-- ITEM tag ([item=...]), not its entity tag ([entity=...]): the two look identical
-- but are different strings, and Factorio's rich-text icon picker (used when a
-- player rebuilds the name by hand for a train interrupt) inserts the ITEM form.
-- Station matching is a byte-for-byte string compare, so writing [item=...] lets a
-- hand-typed interrupt target match the auto-name. Falls back to the entity tag if
-- the prototype has no placement item (shouldn't happen for a rolling-stock).
-- Resolve the wagon's placement item name (so the name uses [item=...], the form
-- the rich-text picker inserts). Several fallbacks because modded wagons (e.g.
-- Nullius) don't all declare items_to_place_this:
--   1. items_to_place_this[1].item  (2.0 field is `.item`, not 1.1's `.name`)
--   2. the mining result item (mineable_properties.products, first type=="item")
--   3. an item sharing the entity's name (Nullius item-with-entity-data does this)
local function wagon_item_name(proto, entity_name)
  local place = proto.items_to_place_this
  if place and place[1] and place[1].item then return place[1].item end
  local mp = proto.mineable_properties
  if mp and mp.products then
    for _, p in ipairs(mp.products) do
      if p.type == "item" and p.name then return p.name end
    end
  end
  if prototypes.item[entity_name] then return entity_name end
  return nil
end

local function wagon_icon_tag(state)
  local proto = prototypes.entity[state.wagon_type]
  if not proto then return "[entity=" .. state.wagon_type .. "]" end
  local item = wagon_item_name(proto, state.wagon_type)
  return item and ("[item=" .. item .. "]") or ("[entity=" .. state.wagon_type .. "]")
end

-- Wagon run in the station name. name_wagon_count OFF: a single icon.
-- ON: up to WAGON_ICON_MAX (5) repeated icons — UNCHANGED historical format, so
-- existing stations/interrupts keep matching (STC is already published; we must
-- not break saves). Beyond 5, switch to a compact "icon×N" form: N repeated icons
-- would otherwise overflow the ~200-char backer_name limit and get truncated
-- mid-rich-text-tag (raw "[item=nullius-car…"). Consumers must build the SAME string.
local WAGON_ICON_MAX = 5
local function wagon_run(state)
  if not state.wagon_type then return "" end
  local tag = wagon_icon_tag(state)
  if not state.name_wagon_count then return tag end
  local n = wagon_count_for(state)
  if n <= 0 then return "" end
  if n <= WAGON_ICON_MAX then return string.rep(tag, n) end
  return tag .. "×" .. n
end

-- Build the train-stop name. The arrow colour AND its position relative to the
-- wagon icons encode the direction:
--   loading   -> "[good] [green-arrow][wagon][wagon]..."  (good flows INTO the wagons)
--   unloading -> "[good] [wagon][wagon]...[red-arrow]"     (good flows OUT of the wagons)
local function build_station_name(state)
  local is_fluid = (state.kind == KIND.FLUID)
  local icon_tag = is_fluid and ("[fluid=" .. state.icon .. "]") or ("[item=" .. state.icon .. "]")
  local wagons   = wagon_run(state)
  -- storage flag: the warehouse icon sits right after the good (forming a
  -- "this good, storage variant" group), marking BOTH the evacuation source
  -- (loading) and the storage depot (unloading). The arrow+wagons run is unchanged.
  local store = state.storage and "[virtual-signal=stc2-storage]" or ""
  if state.direction == DIRECTION.LOAD then
    return icon_tag .. store .. "[virtual-signal=stc2-load]" .. wagons
  else
    return icon_tag .. store .. wagons .. "[virtual-signal=stc2-unload]"
  end
end

local function drive_station(state)
  local name = (state.train_stop_name and state.icon) and build_station_name(state) or nil
  for _, stop in pairs(state.stops or {}) do
    if stop.valid then
      local cb = stop.get_or_create_control_behavior()
      if cb then
        if name then stop.backer_name = name end
        cb.set_trains_limit = state.link_train_count and true or false
        if state.link_train_count then cb.trains_limit_signal = state.output_signal end
        cb.set_priority = state.link_priority and true or false
        if state.link_priority then cb.priority_signal = state.priority_output_signal end
      end
    end
  end
end

-- Empty eval/eval_multi shells used when a module is in an error/idle state.
local function blank_eval() return { cap = nil, rows = {}, raw = 0, stored_total = 0, cap_total = 0 } end

local function refresh(state)
  if not (state.entity and state.entity.valid) then return end
  discover(state)
  state.error = nil
  local has_gen   = #(state.probes or {}) > 0
  local has_typed = #(state.typed_probes or {}) > 0

  -- Power first: a dead brain can't compute anything. The hidden tap draws the
  -- main's power (and paints the vanilla no-electricity icon on it); the probes
  -- are electric on their own. Either one out -> report and request 0 trains
  -- (the L=0 output still reaches the stop, so no train gets called).
  local power = ensure_power(state)
  if power and power.energy == 0 then
    state.error = "no-power"
    state.eval, state.eval_multi = blank_eval(), { per_good = {} }
    state.trains_call = 0
    write_output(state); drive_station(state)
    return
  end
  if probes_unpowered(state) then
    state.error = "probe-no-power"
    state.eval, state.eval_multi = blank_eval(), { per_good = {} }
    state.trains_call = 0
    write_output(state); drive_station(state)
    return
  end

  -- A wired stop shared with another main: both mains flag the error, request
  -- 0 trains and DON'T drive the stop (renaming/limiting it from two brains at
  -- once is the very fight we're preventing).
  if stops_conflict(state) then
    state.error = "stop-conflict"
    state.eval, state.eval_multi = blank_eval(), { per_good = {} }
    state.trains_call = 0
    write_output(state)
    return
  end

  if is_multi(state) then
    -- The multi module always drives the stop by name + train-limit (L is 0/1),
    -- and only ever UNLOADS (it requests inbound resources).
    state.direction        = DIRECTION.UNLOAD
    state.train_stop_name  = true
    state.link_train_count = true
    state.name_wagon_count = (state.name_wagon_count ~= false)

    -- Probe types are mutually exclusive on the multi module.
    if has_gen and has_typed then
      state.error = "mix"
      state.eval, state.eval_multi = blank_eval(), { per_good = {} }
      state.trains_call = 0
      write_output(state); drive_station(state)
      return
    end

    local typed_mode = has_typed
    state.typed_mode = typed_mode
    local em = typed_mode and evaluate_typed(state) or evaluate_multi(state)
    -- Typed goods are derived from the wired probes; if that set changes, the
    -- FIFO indices are stale -> reset the dispatch.
    if typed_mode then
      local sig = table.concat(em.keys or {}, ",")
      if sig ~= state.typed_sig then
        state.request_queue, state.active_request, state.released_train_id = {}, nil, nil
        state.typed_sig = sig
      end
    end
    state.eval_multi = em
    local active = dispatch_fifo(state, em)
    if active and em.per_good[active] then
      local info = em.per_good[active]
      state.icon         = info.icon
      state.icon_quality = info.quality or "normal"
      state.eval = { cap = info.cap, rows = info.rows, raw = info.ready_loads,
                     stored_total = info.stored_total, cap_total = info.cap_total }
      state.trains_call = 1
    else
      state.icon = nil  -- nothing active -> don't leave a stale good for the name
      state.eval = blank_eval()
      state.trains_call = 0
    end
    if not gate_open(state) then state.trains_call = 0 end
    state.current_priority = compute_priority(state)

    write_output(state)
    drive_station(state)
    return
  end

  -- Single module: typed probes are not supported here.
  if has_typed then
    state.error = "typed-on-single"
    state.eval = blank_eval()
    state.trains_call = 0
    write_output(state); write_tracked_signal(state); drive_station(state)
    return
  end

  local eval = evaluate(state)
  state.eval = eval

  local trains = eval.raw
  if state.max_trains and state.max_trains ~= -1 then trains = math.min(trains, state.max_trains) end
  if not gate_open(state) then trains = 0 end
  state.trains_call = trains
  state.current_priority = compute_priority(state)

  write_output(state)
  write_tracked_signal(state)
  drive_station(state)
end

-- ===========================================================================
-- Public model export (remote interface)
-- ---------------------------------------------------------------------------
-- Exposes the distinct train "shapes" a main describes, for other mods (Train
-- Foundry) to reconstruct a matching schedule. A shape is the tuple that decides
-- a station name segment: (kind, wagon_type, wagon_quality, wagon count, group).
-- The RESOURCE is deliberately NOT part of a shape: consumers pick it themselves.
--
-- The "group" is the free segment a station name carries between the resource and
-- the load/unload marker: today it is "" or the storage icon, but it is meant to
-- generalise to arbitrary custom signals/text later. We return it already rendered
-- as a string so a consumer never has to interpret it.

-- The group segment for a state's auto-name. v1: derived from the storage flag
-- (which has no mechanical role in this mod - name only). This is the single seam
-- to widen when custom group segments land.
local function group_segment(state)
  return state.storage and "[virtual-signal=stc2-storage]" or ""
end

-- Append one shape to `out`, deduped by signature. `wagons` is the wagon count of
-- that shape (varies per resource on a typed-multi main, constant otherwise).
local function push_shape(out, seen, state, wagons)
  if not state.wagon_type then return end          -- no chosen rolling-stock -> no shape
  if not (wagons and wagons > 0) then return end
  local group = group_segment(state)
  local sig = table.concat({ state.kind, state.wagon_type, state.wagon_quality or "normal",
                             wagons, group }, "\0")
  if seen[sig] then return end
  seen[sig] = true
  out[#out + 1] = {
    kind          = state.kind,
    wagon_type    = state.wagon_type,
    wagon_quality = state.wagon_quality or "normal",
    wagons        = wagons,
    group         = group,          -- already-rendered station-name segment; do not interpret
    storage       = not not state.storage,  -- kept for a readable interrupt label on the consumer side
  }
end

-- Collect every distinct shape a single main contributes into `out`.
--   single       -> 1 shape, #probes wagons
--   multi shared -> 1 shape, #probes wagons (all goods share the generic probes)
--   multi typed  -> 1 shape PER resource, #typed-probes-of-that-resource wagons
--
-- READ-ONLY: we must not drive stations or write outputs here (this runs when
-- another mod queries us, not on our tick). So we call discover() for the wire
-- topology and, for a typed-multi, evaluate_typed() (pure reads) - never
-- refresh(), which renames stops and writes signals.
local function collect_models(state, out, seen)
  if not (state.entity and state.entity.valid) then return end
  discover(state)  -- refresh probes/typed_probes/stops from the live wire network
  local has_gen   = #(state.probes or {}) > 0
  local has_typed = #(state.typed_probes or {}) > 0
  if is_multi(state) and has_typed and not has_gen then
    -- purely-typed multi: one shape per typed resource (each has its own wagon
    -- count). A multi wired with BOTH generic and typed probes is the "mix" error
    -- state (refresh() requests 0 trains and doesn't drive the stop), so we expose
    -- no shape for it either - matching the runtime rather than inventing shapes.
    local em = evaluate_typed(state)  -- pure: reads buffers/prototypes, mutates nothing
    for _, info in ipairs(em.per_good or {}) do
      push_shape(out, seen, state, #(info.rows or {}))
    end
  elseif not (is_multi(state) and has_typed) then
    -- single, or shared-buffer multi: all wagons are the generic probes.
    -- (A mix multi falls through to nothing.)
    push_shape(out, seen, state, #(state.probes or {}))
  end
end

remote.add_interface("smart-train-combinator", {
  -- Distinct train shapes described by every main on `surface_index`.
  -- Returns a list of { kind, wagon_type, wagon_quality, wagons, group, storage }.
  get_models = function(surface_index)
    ensure_storage()  -- a freshly-loaded save may not have ticked yet
    local out, seen = {}, {}
    for _, state in pairs(storage.mains) do
      if state.entity and state.entity.valid
         and state.entity.surface.index == surface_index then
        collect_models(state, out, seen)
      end
    end
    -- Stable, readable order for consumers' pickers: kind (item first), then wagon
    -- count, then storage, then wagon type. storage.mains iteration order is not
    -- meaningful on its own.
    table.sort(out, function(a, b)
      if a.kind ~= b.kind then return a.kind < b.kind end            -- "fluid" < "item"
      if a.wagons ~= b.wagons then return a.wagons < b.wagons end
      if a.storage ~= b.storage then return b.storage end            -- non-storage first
      if a.wagon_type ~= b.wagon_type then return a.wagon_type < b.wagon_type end
      return (a.wagon_quality or "") < (b.wagon_quality or "")
    end)
    return out
  end,
})

-- ===========================================================================
-- GUI
-- ===========================================================================
local function fmt(n) return tostring(math.floor(n)) end

local function good_caption(state)
  if not state.icon then return "" end
  return state.kind == KIND.FLUID and ("[fluid=" .. state.icon .. "] ") or ("[item=" .. state.icon .. "] ")
end

--- Refresh the live bits of the BASE window (status line + direction icon).
local function update_base(player, state)
  local window = player.gui.screen[WINDOW]
  if not (window and window.valid) then return end
  local content = window["stc2-body"][CONTENT]

  local icon_el  = content[STATUS][ST_ICON]
  local label_el = content[STATUS][ST_LABEL]
  local multi    = is_multi(state)

  -- error states take priority
  if state.error == "mix" then
    icon_el.sprite = "flib_indicator_red"; label_el.caption = { "stc2-gui.status-err-mix" }; return
  elseif state.error == "typed-on-single" then
    icon_el.sprite = "flib_indicator_red"; label_el.caption = { "stc2-gui.status-err-typed" }; return
  elseif state.error == "stop-conflict" then
    icon_el.sprite = "flib_indicator_red"; label_el.caption = { "stc2-gui.status-err-stop-conflict" }; return
  elseif state.error == "no-power" then
    icon_el.sprite = "flib_indicator_red"; label_el.caption = { "stc2-gui.status-err-no-power" }; return
  elseif state.error == "probe-no-power" then
    icon_el.sprite = "flib_indicator_red"; label_el.caption = { "stc2-gui.status-err-probe-power" }; return
  end

  local typed = multi and state.typed_mode
  if multi then
    local gf = content[GOODS_FRAME]
    local gt = gf and gf[GOODS_TABLE]
    if gf and gf[GOODS_HINT] then gf[GOODS_HINT].visible = typed and true or false end
    local is_fluid = (state.kind == KIND.FLUID)
    local n = MAX_GOODS
    if gt and typed then
      -- show the detected resources (read-only) and grey the slots
      local pg = (state.eval_multi or {}).per_good or {}
      for i = 1, n do
        local b = gt[GOOD_BTN .. i]
        if b then
          b.enabled = false
          local g = pg[i]
          if is_fluid then
            b.elem_value = (g and g.icon and prototypes.fluid[g.icon]) and g.icon or nil
          else
            b.elem_value = (g and g.icon and prototypes.item[g.icon]) and { name = g.icon, quality = g.quality or "normal" } or nil
          end
        end
      end
      state.grid_forced = true
    elseif gt then
      for i = 1, n do
        if gt[GOOD_BTN .. i] then gt[GOOD_BTN .. i].enabled = true end
      end
      -- after leaving typed mode, restore the player's own goods into the grid
      if state.grid_forced then
        for i = 1, n do
          local b, g = gt[GOOD_BTN .. i], state.goods[i]
          if b then
            if is_fluid then
              b.elem_value = (g and g.name and prototypes.fluid[g.name]) and g.name or nil
            else
              b.elem_value = (g and g.name and prototypes.item[g.name]) and { name = g.name, quality = g.quality or "normal" } or nil
            end
          end
        end
        state.grid_forced = false
      end
    end
  end

  local nprobes  = typed and #(state.typed_probes or {}) or #(state.probes or {})
  local has_good
  if typed then        has_good = nprobes > 0
  elseif multi then    has_good = #(state.goods or {}) > 0
  else                 has_good = state.icon ~= nil end

  local ok = has_good and state.wagon_type ~= nil and nprobes > 0
  icon_el.sprite = ok and "flib_indicator_green" or "flib_indicator_red"
  if not has_good then
    label_el.caption = typed and { "stc2-gui.status-typed-need" } or { "stc2-gui.status-pick-good" }
  elseif not state.wagon_type then
    label_el.caption = { "stc2-gui.status-pick-wagon" }
  elseif nprobes == 0 then
    label_el.caption = { "stc2-gui.status-need-probes" }
  elseif #(state.stops or {}) == 0 then
    label_el.caption = { "stc2-gui.status-working-nostop" }
  else
    label_el.caption = typed and { "stc2-gui.status-working-typed" } or { "stc2-gui.status-working" }
  end
end

--- Refresh the STOP window's live name preview. No-op if it's closed.
local function update_stop(player, state)
  local win = player.gui.screen[STOPCFG]
  if not (win and win.valid) then return end
  local nf = win["stc2-stop-body"]["stc2-stop-flow"]["stc2-name-frame"]["stc2-name-flow"]
  nf[LINK_WC].enabled = not not state.train_stop_name  -- grey out unless auto-naming is on
  if nf[STORAGE_CHK] then nf[STORAGE_CHK].enabled = not not state.train_stop_name end
  nf[NAME_PREVIEW].visible = not not state.train_stop_name  -- hide preview when auto-naming is off
  if not state.train_stop_name then return end
  if is_multi(state) then
    -- the multi name is dynamic (one good at a time); preview the first evaluated
    -- good as a sample (works for both shared and typed-probe modes).
    local pg = (state.eval_multi or {}).per_good or {}
    if pg[1] and pg[1].icon then
      local si, sq = state.icon, state.icon_quality
      state.icon, state.icon_quality = pg[1].icon, pg[1].quality
      nf[NAME_PREVIEW].caption = { "stc2-gui.name-preview-multi", build_station_name(state) }
      state.icon, state.icon_quality = si, sq
    else
      nf[NAME_PREVIEW].caption = { "stc2-gui.name-preview-unset" }
    end
    return
  end
  if state.icon then
    nf[NAME_PREVIEW].caption = { "stc2-gui.name-preview", build_station_name(state) }
  else
    nf[NAME_PREVIEW].caption = { "stc2-gui.name-preview-unset" }
  end
end

--- Refresh the MONITOR window (per-wagon buffer readout). No-op if it's closed.
local function update_monitor(player, state)
  local mon = player.gui.screen[MONITOR]
  if not (mon and mon.valid) then return end
  local content = mon["stc2-mon-body"]["stc2-mon-content"]

  -- Multi module: per-good readiness + the active request + the FIFO queue.
  if is_multi(state) then
    local em = state.eval_multi or { per_good = {} }
    local active = state.active_request
    if active and em.per_good[active] then
      content[CAP_LBL].caption = { "stc2-gui.multi-active", good_caption(state) }
    else
      content[CAP_LBL].caption = { "stc2-gui.multi-idle" }
    end
    local qpos = {}
    for p, gi in ipairs(state.request_queue or {}) do qpos[gi] = p end
    local wagons = content[WAGONS]
    wagons.clear()
    for gi, info in ipairs(em.per_good) do
      local icon = (state.kind == KIND.FLUID) and ("[fluid=" .. (info.icon or "") .. "]")
                                              or  ("[item="  .. (info.icon or "") .. "]")
      local status
      if gi == active then status = { "stc2-gui.multi-row-active" }
      elseif qpos[gi] then status = { "stc2-gui.multi-row-queued", tostring(qpos[gi]) }
      elseif info.ready then status = { "stc2-gui.multi-row-ready" }
      else status = { "stc2-gui.multi-row-idle" } end
      local row_ls = { "stc2-gui.multi-row", icon, status }
      local caption = (gi == active) and { "", "[color=255,200,0]", row_ls, "[/color]" } or row_ls
      wagons.add({ type = "label", caption = caption })
    end
    if #em.per_good == 0 then
      wagons.add({ type = "label", caption = { "", "[color=180,180,180]", { "stc2-gui.no-goods" }, "[/color]" } })
    end
    content[TRAINS].caption = { "stc2-gui.multi-l", tostring(state.trains_call or 0) }
    content[PRIO_LBL].visible = false
    return
  end

  local eval = state.eval or { rows = {}, cap = nil, raw = 0 }

  -- Per-wagon capacity header
  if eval.cap then
    local icon = (state.kind == KIND.FLUID) and "" or good_caption(state)
    content[CAP_LBL].caption = { "stc2-gui.cap-per-wagon", fmt(eval.cap), icon }
  else
    content[CAP_LBL].caption = { "stc2-gui.cap-per-wagon-unset" }
  end

  -- Per-wagon rows
  local wagons = content[WAGONS]
  wagons.clear()
  for i, row in ipairs(eval.rows) do
    local row_ls
    if state.direction == DIRECTION.LOAD then
      row_ls = { "stc2-gui.wagon-load", i, good_caption(state), fmt(row.stored), fmt(row.capacity), row.loads }
    else
      row_ls = { "stc2-gui.wagon-unload", i, good_caption(state), fmt(row.capacity - row.stored), fmt(row.capacity), row.loads }
    end
    local caption = row_ls
    if i == eval.bottleneck_idx then
      caption = { "", "[color=255,200,0]", row_ls, { "stc2-gui.min-suffix" }, "[/color]" }
    end
    wagons.add({ type = "label", caption = caption })
  end
  if #eval.rows == 0 then
    wagons.add({ type = "label", caption = { "", "[color=180,180,180]", { "stc2-gui.no-probes" }, "[/color]" } })
  end

  content[TRAINS].caption = { "stc2-gui.trains-called", tostring(state.trains_call or 0), tostring(state.max_trains) }

  local prio_lbl = content[PRIO_LBL]
  if state.link_priority then
    local lvl_ls = { "stc2-gui.prio-" .. (state.priority_level or "medium") }
    local key = (state.direction == DIRECTION.LOAD) and "stc2-gui.priority-load" or "stc2-gui.priority-unload"
    prio_lbl.caption = { key, tostring(state.current_priority or 0), lvl_ls }
    prio_lbl.visible = true
  else
    prio_lbl.visible = false
  end
end

--- Refresh the NET ("Condition logique") window: connected count + gate row grey.
local function update_net(player, state)
  local win = player.gui.screen[NETCFG]
  if not (win and win.valid) then return end
  local content = win["stc2-net-body"]["stc2-net-content"]
  -- circuit network id(s) the main is wired to, coloured by wire (red / green)
  local parts = {}
  local rn = state.entity.get_circuit_network(W.circuit_red)
  local gn = state.entity.get_circuit_network(W.circuit_green)
  if rn then parts[#parts + 1] = "[color=255,90,90]" .. rn.network_id .. "[/color]" end
  if gn then parts[#parts + 1] = "[color=90,220,90]" .. gn.network_id .. "[/color]" end
  content[NET_CONN].caption = { "stc2-gui.net-connected", (#parts > 0) and table.concat(parts, "  ") or "—" }
  local row = content["stc2-gate-row"]
  local en = not not state.gate_enabled
  for _, nm in ipairs({ GATE_SIG, GATE_OP, GATE_CONST }) do
    if row[nm] then row[nm].enabled = en end
  end
end

--- Refresh whatever STC windows the player has open. (The stop-config window has
--- no live data, so it needs no update.)
local function update_open(player, state)
  update_base(player, state)
  update_stop(player, state)
  update_monitor(player, state)
  update_net(player, state)
end

-- Secondary windows have NO free position: they are glued to the base window
-- (stop-config on its left, monitor on its right) and follow it when it moves.
-- Called every update tick (self-correcting) and on each base drag. The offset
-- approximates a panel width; exact pixel widths aren't exposed by the API.
-- Approx widths (unscaled px): the stop panel (left) is narrower than the base
-- (right). With a short window title the base no longer balloons, so these clear
-- without overlap. Exact pixel widths aren't exposed by the API.
-- Fixed panel widths so the glued side panels sit flush (deterministic). The
-- multi module is wider to fit its 10 requested-resource slots on a single row.
-- Base window width. The single title ("Combinateur de gare intelligent" in FR)
-- plus the four titlebar action buttons overflowed the old 372, pushing the close
-- (X) button out of the frame; 416 gives the title room to breathe. The glued side
-- panels follow automatically: reposition_secondaries reads base_w for the right
-- column, and the left stop panel is offset by its own width (STOP_W), not base_w.
local BASE_W_MONO  = 416
local BASE_W_MULTI = 516
local STOP_W       = 372   -- stop panel width = left glue offset (independent of base_w)
local NET_H        = 182   -- "Condition logique" panel height (fixed content); monitor stacks below it
local function reposition_secondaries(player)
  local base = player.gui.screen[WINDOW]
  if not (base and base.valid) then return end
  local un = storage.guis[player.index]
  local st = un and storage.mains[un]
  local base_w = (st and is_multi(st)) and BASE_W_MULTI or BASE_W_MONO
  local scale = player.display_scale or 1
  local bx, by = base.location.x, base.location.y
  local stop = player.gui.screen[STOPCFG]
  if stop and stop.valid then stop.location = { x = bx - math.floor(STOP_W * scale), y = by } end
  -- Right column: "Condition logique" on TOP (fixed height), monitor stacked
  -- BELOW it (or at the top if the condition panel is closed).
  local right_x = bx + math.floor(base_w * scale)
  local net = player.gui.screen[NETCFG]
  local net_open = net and net.valid
  if net_open then net.location = { x = right_x, y = by } end
  local mon = player.gui.screen[MONITOR]
  if mon and mon.valid then
    mon.location = { x = right_x, y = by + (net_open and math.floor(NET_H * scale) or 0) }
  end
end

local function destroy_win(player, name)
  local w = player.gui.screen[name]
  if w and w.valid then w.destroy() end
end

-- WINDOW 1 - Base config: what to track + how many trains. The default window
-- (player.opened). Its titlebar carries the toggles for the two other windows.
-- Two layouts: the classic single-good main, and the multi module (no single
-- good chooser, no Max field; a "requested resources" block sits at the bottom).
local function build_base_gui(player, state)
  destroy_win(player, WINDOW)
  local multi    = is_multi(state)
  local is_fluid = (state.kind == KIND.FLUID)

  -- Rows of the 2-column config table.
  local config_table = { type = "table", name = CONFIG, column_count = 2,
    style_mods = { horizontal_spacing = 16, vertical_spacing = 10, top_padding = 4 } }
  table.insert(config_table, { type = "label", caption = { "stc2-gui.lbl-type" } })
  table.insert(config_table, { type = "switch", name = TYPE_SW, switch_state = is_fluid and "right" or "left",
    left_label_caption = { "stc2-gui.sw-solid" }, right_label_caption = { "stc2-gui.sw-liquid" } })
  if not multi then
    table.insert(config_table, { type = "label", caption = { "stc2-gui.lbl-good" } })
    table.insert(config_table, { type = "flow", name = "stc2-good-flow", direction = "horizontal",
      { type = "choose-elem-button", name = ITEMBTN,  elem_type = "item-with-quality" },
      { type = "choose-elem-button", name = FLUIDBTN, elem_type = "fluid" },
    })
  end
  if not multi then
    -- the multi module is always unloading (it requests inbound resources), so it
    -- has no direction switch. The single module keeps Load/Unload + a Storage flag.
    table.insert(config_table, { type = "label", caption = { "stc2-gui.lbl-direction" } })
    table.insert(config_table, { type = "switch", name = DIR_SW, switch_state = (state.direction == DIRECTION.UNLOAD) and "right" or "left",
      left_label_caption = { "stc2-gui.sw-load" }, right_label_caption = { "stc2-gui.sw-unload" } })
  end
  table.insert(config_table, { type = "label", caption = { "stc2-gui.lbl-wagon" } })
  table.insert(config_table, { type = "choose-elem-button", name = WAGON, elem_type = "entity-with-quality",
    elem_filters = wagon_filter(state.kind) })
  if not multi then
    table.insert(config_table, { type = "label", caption = { "stc2-gui.lbl-max" } })
    table.insert(config_table, { type = "textfield", name = MAXF, numeric = true, allow_decimal = false, allow_negative = false,
      text = tostring(state.max_trains), style_mods = { width = 60 } })
  end

  -- Body content children (status indicator, preview, config table[, goods]).
  local content = { type = "flow", name = CONTENT, direction = "vertical",
    style_mods = { vertical_spacing = 10, minimal_width = 320, minimal_height = 400 } }
  table.insert(content, { type = "flow", name = STATUS, style = "flib_indicator_flow",
    { type = "sprite", name = ST_ICON, sprite = "flib_indicator_red", style_mods = { size = 16, stretch_image_to_widget_size = true } },
    { type = "label", name = ST_LABEL, caption = "" },
  })
  table.insert(content, { type = "entity-preview", name = "stc2-preview", style_mods = { minimal_height = 100, horizontally_stretchable = true } })
  table.insert(content, config_table)

  if multi then
    local n = MAX_GOODS
    local goods_table = { type = "table", name = GOODS_TABLE, column_count = MAX_GOODS,
      style_mods = { horizontal_spacing = 4, vertical_spacing = 4 } }
    for i = 1, n do
      table.insert(goods_table, { type = "choose-elem-button", name = GOOD_BTN .. i,
        elem_type = is_fluid and "fluid" or "item-with-quality" })
    end
    table.insert(content, {
      type = "frame", name = GOODS_FRAME, style = "bordered_frame", direction = "vertical",
      style_mods = { horizontally_stretchable = true, top_padding = 6 },
      { type = "label", style = "caption_label", caption = { "stc2-gui.sec-goods" } },
      { type = "label", name = GOODS_HINT, caption = { "stc2-gui.goods-typed-hint" }, visible = false,
        style_mods = { single_line = false, maximal_width = 480, font_color = { 1, 0.85, 0.4 } } },
      goods_table,
    })
  end

  flib_gui.add(player.gui.screen, {
    {
      type = "frame", name = WINDOW, direction = "vertical",
      -- fixed width so glued side panels line up; the multi module is wider to fit
      -- its 10 requested-resource slots on a single row.
      style_mods = { width = multi and BASE_W_MULTI or BASE_W_MONO },
      tags = { main = state.entity.unit_number },
      { -- titlebar
        type = "flow", style = "flib_titlebar_flow", drag_target = WINDOW,
        { type = "label", style = "frame_title", caption = { multi and "stc2-gui.win-title-multi" or "stc2-gui.win-title" }, ignored_by_interaction = true },
        { type = "empty-widget", style = "flib_titlebar_drag_handle", ignored_by_interaction = true },
        { type = "sprite-button", name = STOP_TOGGLE, style = "frame_action_button",
          sprite = "item/train-stop", tooltip = { "stc2-gui.tip-stop" } },
        { type = "sprite-button", name = MON_TOGGLE, style = "frame_action_button",
          sprite = "stc2-monitor-icon", tooltip = { "stc2-gui.tip-monitor" } },
        { type = "sprite-button", name = NET_TOGGLE, style = "frame_action_button",
          sprite = "utility/circuit_network_panel", tooltip = { "stc2-gui.tip-net" } },
        { type = "sprite-button", name = CLOSE, style = "frame_action_button", sprite = "utility/close" },
      },
      { -- body
        type = "frame", name = "stc2-body", style = "inside_shallow_frame", direction = "vertical",
        style_mods = { padding = 12 },
        content,
      },
    },
  })

  local window   = player.gui.screen[WINDOW]
  local body_flow = window["stc2-body"][CONTENT]
  -- Guard against a good / wagon whose prototype no longer exists (mod removed
  -- or disabled): assigning an unknown name to elem_value raises a hard crash.
  if not multi then
    local good_flow = body_flow[CONFIG]["stc2-good-flow"]
    good_flow[ITEMBTN].visible  = not is_fluid
    good_flow[FLUIDBTN].visible = is_fluid
    local item_ok  = (not is_fluid) and state.icon and prototypes.item[state.icon] ~= nil
    local fluid_ok = is_fluid and state.icon and prototypes.fluid[state.icon] ~= nil
    good_flow[ITEMBTN].elem_value  = item_ok  and { name = state.icon, quality = state.icon_quality or "normal" } or nil
    good_flow[FLUIDBTN].elem_value = fluid_ok and state.icon or nil
  else
    local gt = body_flow[GOODS_FRAME][GOODS_TABLE]
    for i = 1, (MAX_GOODS) do
      local btn, g = gt[GOOD_BTN .. i], state.goods[i]
      if btn and g and g.name then
        if is_fluid and prototypes.fluid[g.name] then
          btn.elem_value = g.name
        elseif (not is_fluid) and prototypes.item[g.name] then
          btn.elem_value = { name = g.name, quality = g.quality or "normal" }
        end
      end
    end
  end
  local wagon_ok = state.wagon_type and prototypes.entity[state.wagon_type] ~= nil
  body_flow[CONFIG][WAGON].elem_value = wagon_ok and { name = state.wagon_type, quality = state.wagon_quality or "normal" } or nil
  body_flow["stc2-preview"].entity    = state.entity
  window.force_auto_center()
  player.opened = window
end

-- WINDOW 2 - Train-stop config: auto-naming, train-limit signal (L), priority
-- level + priority signal (P). Free-floating; parked left of the base window.
local function build_stop_gui(player, state, base_fresh)
  destroy_win(player, STOPCFG)

  flib_gui.add(player.gui.screen, {
    {
      type = "frame", name = STOPCFG, direction = "vertical",
      style_mods = { width = 372 },
      { -- titlebar (no drag_target: this panel is glued to the base, not free)
        type = "flow", style = "flib_titlebar_flow",
        { type = "label", style = "frame_title", caption = { "stc2-gui.stop-title" }, ignored_by_interaction = true },
        { type = "empty-widget", style = "flib_titlebar_drag_handle", ignored_by_interaction = true },
        { type = "sprite-button", name = STOP_CLOSE, style = "frame_action_button", sprite = "utility/close" },
      },
      {
        type = "frame", name = "stc2-stop-body", style = "inside_shallow_frame", direction = "vertical",
        style_mods = { padding = 12 },
        { type = "flow", name = "stc2-stop-flow", direction = "vertical",
          style_mods = { vertical_spacing = 12, minimal_width = 320, minimal_height = 400 },
          -- TOP section: automatic naming + live preview.
          { type = "frame", name = "stc2-name-frame", style = "bordered_frame", direction = "vertical",
            style_mods = { horizontally_stretchable = true },
            { type = "flow", name = "stc2-name-flow", direction = "vertical", style_mods = { vertical_spacing = 8 },
              { type = "label", style = "caption_label", caption = { "stc2-gui.sec-naming" } },
              { type = "checkbox", name = LINK_NM, state = not not state.train_stop_name,  caption = { "stc2-gui.chk-name" } },
              { type = "checkbox", name = LINK_WC, state = not not state.name_wagon_count, caption = { "stc2-gui.chk-wagon-count" },
                enabled = not not state.train_stop_name },
              { type = "checkbox", name = STORAGE_CHK, state = not not state.storage, caption = { "stc2-gui.chk-storage" },
                tooltip = { "stc2-gui.chk-storage-tip" }, enabled = not not state.train_stop_name },
              { type = "label", name = NAME_PREVIEW, caption = "" },
            },
          },
          -- BOTTOM section: how the stop is driven.
          { type = "frame", name = "stc2-drive-frame", style = "bordered_frame", direction = "vertical",
            style_mods = { horizontally_stretchable = true },
            { type = "flow", name = "stc2-drive-flow", direction = "vertical", style_mods = { vertical_spacing = 8 },
              { type = "label", style = "caption_label", caption = { "stc2-gui.sec-driving" } },
              { type = "checkbox", name = LINK_LIM, state = not not state.link_train_count, caption = { "stc2-gui.chk-limit" } },
              { type = "table", name = "stc2-limit-tbl", column_count = 2,
                style_mods = { horizontal_spacing = 12, vertical_spacing = 6, left_padding = 24 },
                { type = "label", caption = { "stc2-gui.lbl-output" } },
                { type = "choose-elem-button", name = OUTPUT, elem_type = "signal" },
              },
              { type = "line" },
              { type = "checkbox", name = LINK_PRIO, state = not not state.link_priority, caption = { "stc2-gui.chk-priority" } },
              { type = "table", name = "stc2-prio-tbl", column_count = 2,
                style_mods = { horizontal_spacing = 12, vertical_spacing = 6, left_padding = 24 },
                { type = "label", caption = { "stc2-gui.lbl-priority" } },
                { type = "drop-down", name = PRIO_DD,
                  items = { { "stc2-gui.prio-high" }, { "stc2-gui.prio-important" }, { "stc2-gui.prio-medium" }, { "stc2-gui.prio-low" } },
                  selected_index = level_index(state.priority_level) },
                { type = "label", caption = { "stc2-gui.lbl-prio-signal" } },
                { type = "choose-elem-button", name = SIGP, elem_type = "signal" },
              },
            },
          },
        },
      },
    },
  })

  local stopflow = player.gui.screen[STOPCFG]["stc2-stop-body"]["stc2-stop-flow"]
  local drive = stopflow["stc2-drive-frame"]["stc2-drive-flow"]
  drive["stc2-limit-tbl"][OUTPUT].elem_value = state.output_signal
  drive["stc2-prio-tbl"][SIGP].elem_value    = state.priority_output_signal
  -- multi module: auto-naming is mandatory -> lock the naming checkbox on
  if is_multi(state) then
    local nf = stopflow["stc2-name-frame"]["stc2-name-flow"]
    nf[LINK_NM].state   = true
    nf[LINK_NM].enabled = false
    nf[STORAGE_CHK].visible = false  -- storage marker is single-module only
  end
  reposition_secondaries(player)
end

-- WINDOW 3 - Monitor: the per-wagon buffer readout. Free-floating; parked right
-- of the base window. Toggled via the titlebar button.
local function build_monitor_gui(player, state, base_fresh)
  destroy_win(player, MONITOR)

  flib_gui.add(player.gui.screen, {
    {
      type = "frame", name = MONITOR, direction = "vertical",
      style_mods = { width = 332 },
      { -- titlebar (no drag_target: glued to the base, not free)
        type = "flow", style = "flib_titlebar_flow",
        { type = "label", style = "frame_title", caption = { "stc2-gui.monitor-title" }, ignored_by_interaction = true },
        { type = "empty-widget", style = "flib_titlebar_drag_handle", ignored_by_interaction = true },
        { type = "sprite-button", name = MON_CLOSE, style = "frame_action_button", sprite = "utility/close" },
      },
      {
        type = "frame", name = "stc2-mon-body", style = "inside_shallow_frame", direction = "vertical",
        style_mods = { padding = 12 },
        { type = "flow", name = "stc2-mon-content", direction = "vertical",
          style_mods = { vertical_spacing = 8, minimal_width = 300, minimal_height = 218 },
          { type = "label", name = CAP_LBL, style = "caption_label", caption = "" },
          { type = "flow", name = WAGONS, direction = "vertical", style_mods = { vertical_spacing = 4, left_padding = 4 } },
          { type = "line" },
          { type = "label", name = TRAINS, caption = "" },
          { type = "label", name = PRIO_LBL, caption = "" },
        },
      },
    },
  })

  reposition_secondaries(player)
end

-- WINDOW 4 - "Condition logique": the circuit enable gate in its own panel
-- (vanilla style). Toggled by the network button; glued to the right of the
-- monitor (or the base). Applies to BOTH modules.
local function build_net_gui(player, state, base_fresh)
  destroy_win(player, NETCFG)

  flib_gui.add(player.gui.screen, {
    {
      type = "frame", name = NETCFG, direction = "vertical",
      style_mods = { width = 332 },  -- same width as the monitor (they stack)
      { -- titlebar (no drag_target: glued to the base, not free)
        type = "flow", style = "flib_titlebar_flow",
        { type = "label", style = "frame_title", caption = { "stc2-gui.net-title" }, ignored_by_interaction = true },
        { type = "empty-widget", style = "flib_titlebar_drag_handle", ignored_by_interaction = true },
        { type = "sprite-button", name = NET_CLOSE, style = "frame_action_button", sprite = "utility/close" },
      },
      {
        type = "frame", name = "stc2-net-body", style = "inside_shallow_frame", direction = "vertical",
        style_mods = { padding = 12 },
        { type = "flow", name = "stc2-net-content", direction = "vertical",
          style_mods = { vertical_spacing = 10, minimal_width = 276 },
          { type = "label", name = NET_CONN, caption = "" },
          { type = "line" },
          { type = "checkbox", name = GATE_CHK, state = not not state.gate_enabled, caption = { "stc2-gui.chk-gate" } },
          -- left operand (signal slot) | comparator | right operand (constant).
          { type = "flow", name = "stc2-gate-row", direction = "horizontal",
            style_mods = { vertical_align = "center", horizontal_spacing = 6 },
            { type = "choose-elem-button", name = GATE_SIG, elem_type = "signal" },
            { type = "drop-down", name = GATE_OP, items = GATE_OP_CAPS, selected_index = gate_op_index(state.gate_op), style_mods = { minimal_width = 48 } },
            { type = "textfield", name = GATE_CONST, numeric = true, allow_decimal = false, allow_negative = true,
              text = tostring(state.gate_constant or 0), style_mods = { width = 70 } },
          },
        },
      },
    },
  })

  local content = player.gui.screen[NETCFG]["stc2-net-body"]["stc2-net-content"]
  local row = content["stc2-gate-row"]
  row[GATE_SIG].elem_value = state.gate_signal
  local en = not not state.gate_enabled
  for _, nm in ipairs({ GATE_SIG, GATE_OP, GATE_CONST }) do
    if row[nm] then row[nm].enabled = en end
  end
  reposition_secondaries(player)
end

-- The kind (item/fluid) of the MAIN this probe is wired to, so the typed probe
-- offers the matching picker (you can't pin the wrong kind). nil if not wired yet.
local function probe_main_kind(probe)
  for _, e in pairs(walk_network(probe, LEASH_CONNECTORS)) do
    if e.name == MAIN or e.name == MULTI then
      local st = storage.mains[e.unit_number]
      if st then return st.kind end
    end
  end
end

-- Typed-probe window: pin ONE resource to this probe (item or fluid, matching
-- the wired main's Type). Its own little window (the probe is a passive shell).
local function build_typed_gui(player, probe)
  local un = probe.unit_number
  destroy_win(player, TYPEDWIN)
  local r = storage.typed[un] or {}
  local is_fluid_kind = (probe_main_kind(probe) == KIND.FLUID)

  local row = { type = "flow", name = "stc2-typed-row", direction = "horizontal",
    style_mods = { vertical_align = "center", horizontal_spacing = 8 } }
  table.insert(row, { type = "label", caption = { "stc2-gui.typed-resource" } })
  if is_fluid_kind then
    table.insert(row, { type = "choose-elem-button", name = TYPED_FLUID, elem_type = "fluid" })
  else
    table.insert(row, { type = "choose-elem-button", name = TYPED_ELEM, elem_type = "item-with-quality" })
  end

  flib_gui.add(player.gui.screen, {
    {
      type = "frame", name = TYPEDWIN, direction = "vertical",
      { type = "flow", style = "flib_titlebar_flow", drag_target = TYPEDWIN,
        { type = "label", style = "frame_title", caption = { "entity-name.stc-typed-probe" }, ignored_by_interaction = true },
        { type = "empty-widget", style = "flib_titlebar_drag_handle", ignored_by_interaction = true },
        { type = "sprite-button", name = TYPED_CLOSE, style = "frame_action_button", sprite = "utility/close" },
      },
      { type = "frame", name = "stc2-typed-body", style = "inside_shallow_frame", direction = "vertical",
        style_mods = { padding = 12 },
        { type = "flow", name = "stc2-typed-content", direction = "vertical", style_mods = { vertical_spacing = 10, minimal_width = 260 },
          { type = "label", caption = { "stc2-gui.typed-help" }, style_mods = { single_line = false, maximal_width = 260 } },
          row,
        },
      },
    },
  })

  local r_row = player.gui.screen[TYPEDWIN]["stc2-typed-body"]["stc2-typed-content"]["stc2-typed-row"]
  if is_fluid_kind then
    if r.name and prototypes.fluid[r.name] then r_row[TYPED_FLUID].elem_value = r.name end
  elseif r.name and prototypes.item[r.name] then
    r_row[TYPED_ELEM].elem_value = { name = r.name, quality = r.quality or "normal" }
  end
  local win = player.gui.screen[TYPEDWIN]
  win.force_auto_center()
  player.opened = win
end

-- ===========================================================================
-- GUI helpers
-- ===========================================================================
local function gui_state(event)
  local un = storage.guis[event.player_index]
  return un and storage.mains[un] or nil
end

local function refresh_and_update(player, state)
  refresh(state)
  update_open(player, state)
end

-- ===========================================================================
-- Global overview screen
--
-- A screen-anchored window listing every STC module in the game: one row per
-- module (icons, an inline-editable wagon picker, up to 4 per-probe fill bars,
-- and a station-call dot), a left filter column (type / resource / direction /
-- storage), and a per-row "eye" that closes the overview, focuses the module
-- and opens its GUI. Read-only except the wagon picker. Data source is
-- storage.mains (unit_number -> state); refreshed by the tick loop while open.
-- ===========================================================================

-- The player's current filter selection, with sane defaults.
local function ov_filters(pi)
  local f = storage.overview_filters[pi]
  if not f then
    f = { type = "all", resource = nil, direction = "all", storage = "all" }
    storage.overview_filters[pi] = f
  end
  return f
end

-- The good name(s) a module tracks: the single main's icon, or the multi's goods.
local function module_goods(state)
  if is_multi(state) then
    local out = {}
    for _, g in ipairs(state.goods or {}) do if g.name then out[#out + 1] = g.name end end
    return out
  end
  return state.icon and { state.icon } or {}
end

-- Does `state` pass the player's filters?
local function ov_matches(state, f)
  local skind = (state.kind == KIND.FLUID) and "fluid" or "item"
  if f.type ~= "all" and f.type ~= skind then return false end
  if f.direction ~= "all" and state.direction ~= f.direction then return false end
  if f.storage == "yes" and not state.storage then return false end
  if f.storage == "no"  and state.storage then return false end
  if f.resource then
    local hit = false
    for _, name in ipairs(module_goods(state)) do if name == f.resource then hit = true; break end end
    if not hit then return false end
  end
  return true
end

-- Modules passing the filters, sorted by unit_number for a stable row order.
local function ov_filtered_modules(f)
  local list = {}
  for un, state in pairs(storage.mains) do
    if state.entity and state.entity.valid and ov_matches(state, f) then
      list[#list + 1] = { un = un, state = state }
    end
  end
  table.sort(list, function(a, b) return a.un < b.un end)
  return list
end

-- Bars shown on a module row, as a list of { ratio, name, kind }:
--   * multi module -> one bar PER REQUESTED RESOURCE (aggregate fill across its
--     probes), so all tracked goods are visible at once, not just the FIFO-active
--     one. Data comes from state.eval_multi.per_good (refresh computes every good).
--   * single module -> one bar PER PROBE (each probe is one wagon of the single
--     good), from state.eval.rows (dense over state.probes).
-- ratio = stored/capacity (LOAD) or free/capacity (UNLOAD), clamped [0..1].
local function ov_bars_view(state)
  if is_multi(state) then
    local em = state.eval_multi or {}
    local kind = state.kind
    local list = {}
    for _, g in ipairs(em.per_good or {}) do
      local stored, capt = g.stored_total or 0, g.cap_total or 0
      local ratio = 0
      if capt > 0 then
        local amount = (state.direction == DIRECTION.LOAD) and stored or math.max(0, capt - stored)
        ratio = math.min(1, amount / capt)
      end
      -- keyed by resource name for a stable order (goods list order is stable too)
      list[#list + 1] = { key = g.icon or "", ratio = ratio, name = g.icon, kind = kind }
    end
    return list
  end

  -- single: one bar per probe, sorted by probe unit_number (stable display order).
  local eval = state.eval or {}
  local rows, cap = eval.rows or {}, eval.cap
  local name, kind = state.icon, state.kind
  local list = {}
  local idx = 0
  for _, probe in ipairs(state.probes or {}) do
    if probe.valid then
      idx = idx + 1
      local r = rows[idx]
      if r then
        local ratio = 0
        if cap and cap > 0 then
          local amount = (state.direction == DIRECTION.LOAD) and (r.stored or 0)
                           or math.max(0, (r.capacity or 0) - (r.stored or 0))
          ratio = math.min(1, amount / cap)
        end
        list[#list + 1] = { key = probe.unit_number, ratio = ratio, name = name, kind = kind }
      end
    end
  end
  table.sort(list, function(a, b) return a.key < b.key end)
  return list
end

local function ov_bar_color(ratio)
  return (ratio >= 0.999) and { 0.3, 0.8, 0.3 } or { 0.9, 0.7, 0.2 }
end

-- Rich-text icon tag for a probe's resource (nil -> a neutral dash).
local function ov_probe_icon(entry)
  if not entry.name then return "[color=140,140,140]—[/color]" end
  return (entry.kind == KIND.FLUID) and ("[fluid=" .. entry.name .. "]") or ("[item=" .. entry.name .. "]")
end

-- Station-call indicator sprite + tooltip for a module's current state.
local function ov_call_dot(state)
  if state.error then
    return "flib_indicator_red", { "stc2-gui.ov-call-error" }
  elseif (state.trains_call or 0) > 0 then
    return "flib_indicator_green", { "stc2-gui.ov-call-yes" }
  end
  return "flib_indicator_black", { "stc2-gui.ov-call-no" }  -- neutral (no "empty" color in flib)
end

-- The resource whose train is being summoned right now (multi FIFO active request),
-- as a rich-text icon; "" when idle or not a multi module. state.icon holds the
-- active good and is cleared by refresh when nothing is active.
local function ov_active_caption(state)
  if not (is_multi(state) and (state.trains_call or 0) > 0 and state.icon) then return "" end
  return (state.kind == KIND.FLUID) and ("[fluid=" .. state.icon .. "]") or ("[item=" .. state.icon .. "]")
end

-- Build one module row inside the list. Read-only except the wagon picker.
local function ov_add_row(parent, entry)
  local state, un = entry.state, entry.un
  local multi = is_multi(state)

  local row = parent.add({ type = "frame", style = "bordered_frame", direction = "horizontal",
    name = "stc2-ov-row-" .. un })
  row.style.horizontally_stretchable = true
  row.style.vertical_align = "center"
  row.style.padding = 4

  -- Eye: focus the module + open its GUI.
  row.add({ type = "sprite-button", name = OV_EYE .. un, style = "tool_button",
    sprite = "utility/search_icon", tooltip = { "stc2-gui.ov-tip-eye" } })

  -- Storage marker: the warehouse icon only when the module is flagged as one
  -- (single-good, loading). Nothing otherwise. No more "Single/Multi/Storage" text.
  local mark = row.add({ type = "label", name = "stc2-ov-mark-" .. un,
    caption = state.storage and "[virtual-signal=stc2-storage]" or "" })
  mark.style.minimal_width = 24

  -- Direction arrow (load / unload). The multi module is always unloading.
  row.add({ type = "label", caption = (state.direction == DIRECTION.UNLOAD)
    and "[virtual-signal=stc2-unload]" or "[virtual-signal=stc2-load]",
    tooltip = (state.direction == DIRECTION.UNLOAD) and { "stc2-gui.ov-dir-unload" } or { "stc2-gui.ov-dir-load" } })

  -- (No standalone resource-icon block here: it duplicated the icons shown under
  -- each fill bar on the right. The per-probe columns already carry the resource.)

  -- Inline-editable wagon picker (the only editable control on this screen).
  local wagon_ok = state.wagon_type and prototypes.entity[state.wagon_type] ~= nil
  local wbtn = row.add({ type = "choose-elem-button", name = OV_WAGON .. un,
    elem_type = "entity-with-quality", elem_filters = wagon_filter(state.kind),
    tooltip = { "stc2-gui.ov-tip-wagon" } })
  wbtn.elem_value = wagon_ok and { name = state.wagon_type, quality = state.wagon_quality or "normal" } or nil

  -- Per-probe fill: one column per probe = a thin fill bar on top of that probe's
  -- resource icon. All probes fit side by side (up to 10), so nothing is hidden.
  -- The bar is stored/one-wagon-capacity (or free/capacity when unloading).
  local bars_flow = row.add({ type = "flow", direction = "horizontal", name = "stc2-ov-bars-" .. un })
  bars_flow.style.horizontal_spacing = 3
  bars_flow.style.vertical_align = "bottom"

  local view = ov_bars_view(state)
  if #view == 0 then
    bars_flow.add({ type = "label", caption = { "stc2-gui.ov-no-probe" } })
  else
    for i, e in ipairs(view) do
      local col = bars_flow.add({ type = "flow", direction = "vertical", name = "stc2-ov-col-" .. un .. "-" .. i })
      col.style.horizontal_align = "center"
      col.style.vertical_spacing = 1
      local pb = col.add({ type = "progressbar", name = "stc2-ov-bar-" .. un .. "-" .. i, value = e.ratio })
      pb.style.width = 28
      pb.style.color = ov_bar_color(e.ratio)
      col.add({ type = "label", caption = ov_probe_icon(e) })
    end
  end

  -- Spacer so the "calling" marker + dot sit on the right.
  local spacer = row.add({ type = "empty-widget" })
  spacer.style.horizontally_stretchable = true

  -- Which train is being called right now: on a multi module the active FIFO
  -- request names the resource whose train is summoned. Show its icon next to the
  -- dot (empty when idle / not a multi). Updated in place each tick.
  local act = row.add({ type = "label", name = "stc2-ov-active-" .. un, caption = ov_active_caption(state),
    tooltip = { "stc2-gui.ov-active" } })
  act.style.minimal_width = 20

  -- Station-call dot: green when calling a train, red on error, grey otherwise.
  local dot, tip = ov_call_dot(state)
  row.add({ type = "sprite", name = "stc2-ov-dot-" .. un, sprite = dot, tooltip = tip,
    style_mods = { size = 16, stretch_image_to_widget_size = true } })
end

-- Update only the volatile bits of an existing row in place (fill bar values and
-- the call dot), WITHOUT destroying the row or its wagon picker. Called every tick
-- while open, so it must never touch the choose-elem-button. The per-probe icons
-- and the probe count are structural -> a change there bumps the signature and
-- triggers a full rebuild instead.
local function ov_update_row(row, entry)
  local state, un = entry.state, entry.un
  local bars = row["stc2-ov-bars-" .. un]
  if bars and bars.valid then
    local view = ov_bars_view(state)
    for i, e in ipairs(view) do
      local col = bars["stc2-ov-col-" .. un .. "-" .. i]
      local pb  = col and col.valid and col["stc2-ov-bar-" .. un .. "-" .. i]
      if pb and pb.valid then
        pb.value = e.ratio
        pb.style.color = ov_bar_color(e.ratio)
      end
    end
  end
  local act = row["stc2-ov-active-" .. un]
  if act and act.valid then act.caption = ov_active_caption(state) end
  local dot = row["stc2-ov-dot-" .. un]
  if dot and dot.valid then
    local sprite, tip = ov_call_dot(state)
    dot.sprite = sprite
    dot.tooltip = tip
  end
end

-- A stable signature of the rows currently displayed. When it changes (module
-- added/removed, probe count changed, a probe's resource changed, direction or
-- storage flag flipped), the list is rebuilt; otherwise a cheap in-place value
-- update is enough. Includes everything ov_add_row lays out structurally.
local function ov_signature(modules)
  local parts = {}
  for _, e in ipairs(modules) do
    local view = ov_bars_view(e.state)
    local names = {}
    for _, p in ipairs(view) do names[#names + 1] = p.name or "-" end
    parts[#parts + 1] = e.un .. ":" .. (e.state.direction or "") .. ":"
      .. (e.state.storage and "s" or "") .. ":" .. table.concat(names, ",")
  end
  return table.concat(parts, "|")
end

-- Refresh the list: rebuild it only when the displayed set/shape changed (so an
-- open wagon picker and the scroll position survive the per-tick refresh);
-- otherwise update the volatile fields of the existing rows in place.
local function ov_populate(player)
  local win = player.gui.screen[OVERVIEW]
  if not (win and win.valid) then return end
  local list = win["stc2-ov-body"]["stc2-ov-cols"]["stc2-ov-right"][OV_LIST]
  if not (list and list.valid) then return end
  local f = ov_filters(player.index)
  local modules = ov_filtered_modules(f)
  local sig = ov_signature(modules)

  if storage.overview_sig[player.index] == sig and list["stc2-ov-row-" .. (modules[1] and modules[1].un or 0)] then
    for _, entry in ipairs(modules) do
      local row = list["stc2-ov-row-" .. entry.un]
      if row and row.valid then ov_update_row(row, entry) end
    end
    return
  end

  storage.overview_sig[player.index] = sig
  list.clear()
  if #modules == 0 then
    list.add({ type = "label", caption = { "stc2-gui.ov-empty" } })
    return
  end
  for _, entry in ipairs(modules) do ov_add_row(list, entry) end
end

-- Which picker the resource filter shows, driven by the Type filter above: "item"
-- when Type=Solid, "fluid" when Type=Liquid, "none" when Type=All (no strictly
-- typed picker can exclude virtual signals for a mixed set, so the picker is hidden
-- until the player narrows the type).
local function ov_res_picker_kind(f)
  if f.type == "fluid" then return "fluid" end
  if f.type == "item"  then return "item"  end
  return "none"
end

-- Preselect value for the item picker (nil unless the stored resource is an item).
local function ov_res_item_value(f)
  return (f.resource and prototypes.item[f.resource]) and { name = f.resource, quality = "normal" } or nil
end

-- Preselect value for the fluid picker (nil unless the stored resource is a fluid).
local function ov_res_fluid_value(f)
  return (f.resource and prototypes.fluid[f.resource]) and f.resource or nil
end

local function build_overview_gui(player)
  destroy_win(player, OVERVIEW)
  local f = ov_filters(player.index)

  local function radio_row(parent_children, name, options, current, cap_prefix)
    local flow = { type = "flow", name = name, direction = "vertical",
      style_mods = { vertical_spacing = 2 } }
    for _, opt in ipairs(options) do
      flow[#flow + 1] = { type = "radiobutton", name = name .. "-" .. opt, state = (current == opt),
        caption = { cap_prefix .. opt } }
    end
    parent_children[#parent_children + 1] = flow
  end

  local left_children = {}
  left_children[#left_children + 1] = { type = "label", style = "caption_label", caption = { "stc2-gui.ov-f-type" } }
  radio_row(left_children, OV_F_TYPE, OV_TYPES, f.type, "stc2-gui.ov-type-")
  left_children[#left_children + 1] = { type = "line" }
  left_children[#left_children + 1] = { type = "label", style = "caption_label", caption = { "stc2-gui.ov-f-res" } }
  -- Resource picker, shown ONLY once a Type is chosen (Solid -> item picker,
  -- Liquid -> fluid picker). With Type=All there is no single strictly-typed picker
  -- that excludes virtual signals, so we hide it and prompt to pick a type first.
  -- Empty picker = all resources of that type.
  local rkind = ov_res_picker_kind(f)
  if rkind == "item" or rkind == "fluid" then
    left_children[#left_children + 1] = { type = "flow", direction = "horizontal",
      style_mods = { vertical_align = "center", horizontal_spacing = 6 },
      { type = "choose-elem-button", name = OV_F_RES,
        elem_type = (rkind == "item") and "item-with-quality" or "fluid",
        elem_value = (rkind == "item") and ov_res_item_value(f) or ov_res_fluid_value(f) },
      { type = "label", caption = { "stc2-gui.ov-res-hint" }, style_mods = { font_color = { 0.7, 0.7, 0.7 } } },
    }
  else
    left_children[#left_children + 1] = { type = "label", caption = { "stc2-gui.ov-res-pick-type" },
      style_mods = { font_color = { 0.6, 0.6, 0.6 }, single_line = false, maximal_width = 170 } }
  end
  left_children[#left_children + 1] = { type = "line" }
  left_children[#left_children + 1] = { type = "label", style = "caption_label", caption = { "stc2-gui.ov-f-dir" } }
  radio_row(left_children, OV_F_DIR, OV_DIRS, f.direction, "stc2-gui.ov-dir-")
  left_children[#left_children + 1] = { type = "line" }
  left_children[#left_children + 1] = { type = "label", style = "caption_label", caption = { "stc2-gui.ov-f-store" } }
  radio_row(left_children, OV_F_STORE, OV_STORES, f.storage, "stc2-gui.ov-store-")

  -- A frame can't carry vertical_spacing (that is a Flow/Table style prop); wrap
  -- the filter controls in a vertical flow inside the frame instead.
  local left_flow = { type = "flow", name = "stc2-ov-left-flow", direction = "vertical",
    style_mods = { vertical_spacing = 6 } }
  for _, c in ipairs(left_children) do left_flow[#left_flow + 1] = c end
  local left = { type = "frame", name = "stc2-ov-left", style = "inside_shallow_frame_with_padding",
    direction = "vertical", style_mods = { width = 190 },
    left_flow }

  flib_gui.add(player.gui.screen, {
    {
      type = "frame", name = OVERVIEW, direction = "vertical",
      style_mods = { maximal_height = 760 },
      { -- titlebar
        type = "flow", style = "flib_titlebar_flow", drag_target = OVERVIEW,
        { type = "label", style = "frame_title", caption = { "stc2-gui.ov-title" }, ignored_by_interaction = true },
        { type = "empty-widget", style = "flib_titlebar_drag_handle", ignored_by_interaction = true },
        { type = "sprite-button", name = OV_CLOSE, style = "frame_action_button", sprite = "utility/close" },
      },
      {
        type = "frame", name = "stc2-ov-body", style = "inside_shallow_frame", direction = "vertical",
        style_mods = { padding = 8 },
        {
          type = "flow", name = "stc2-ov-cols", direction = "horizontal",
          style_mods = { horizontal_spacing = 8 },
          left,
          {
            type = "frame", name = "stc2-ov-right", style = "deep_frame_in_shallow_frame",
            direction = "vertical", style_mods = { width = 620 },
            {
              type = "scroll-pane", name = OV_LIST, direction = "vertical",
              horizontal_scroll_policy = "never", vertical_scroll_policy = "auto",
              style_mods = { padding = 6, vertically_stretchable = true, minimal_height = 300 },
            },
          },
        },
      },
    },
  })

  local win = player.gui.screen[OVERVIEW]
  storage.overview_guis[player.index] = true
  ov_populate(player)
  -- Grow the window with the module count (no native drag-resize in 2.0): cap at
  -- ~88% of the player's screen height; the scroll-pane takes over beyond that.
  local res = player.display_resolution
  local scale = player.display_scale or 1
  local screen_h = res and (res.height / scale) or 900
  win.style.maximal_height = math.floor(screen_h * 0.88)
  win.force_auto_center()
  player.opened = win  -- let ESC close it (the wagon picker's own picker is handled in on_gui_closed)
end

local function close_overview(player)
  storage.overview_guis[player.index] = nil
  storage.overview_sig[player.index] = nil  -- next open rebuilds from scratch
  destroy_win(player, OVERVIEW)
end

local function toggle_overview(player)
  ensure_storage()
  if player.gui.screen[OVERVIEW] then
    close_overview(player)
  else
    build_overview_gui(player)
  end
end

-- ===========================================================================
-- GUI events
-- ===========================================================================
local function close_gui(player)
  storage.guis[player.index] = nil
  destroy_win(player, WINDOW)
  destroy_win(player, STOPCFG)
  destroy_win(player, MONITOR)
  destroy_win(player, NETCFG)
end

script.on_event(defines.events.on_gui_opened, function(event)
  ensure_storage()
  local player = game.get_player(event.player_index)
  if not player then return end
  local e = event.entity
  if not (e and e.valid) then return end
  -- Ghosts (blueprint / copy-paste / planned builds) are "entity-ghost", not our
  -- prototypes; the real name is in ghost_name. Opening one would otherwise show
  -- the vanilla combinator GUI. We carry all config through blueprint tags and
  -- rebuild state on revive, so a ghost has nothing to configure: just close it.
  if e.name == "entity-ghost" then
    local gn = e.ghost_name
    if gn == MAIN or gn == MULTI or gn == PROBE or gn == TYPED then
      player.opened = nil
    end
    return
  end
  if e.name == PROBE then
    -- passive shell: suppress its vanilla arithmetic GUI
    player.opened = nil
    return
  end
  if e.name == TYPED then
    storage.typed_guis[player.index] = e.unit_number
    build_typed_gui(player, e)
    return
  end
  if e.name ~= MAIN and e.name ~= MULTI then return end
  local state = storage.mains[e.unit_number]
  if not state then return end
  migrate_state(state)
  storage.guis[player.index] = e.unit_number
  build_base_gui(player, state)
  -- Secondary windows are opt-in and remembered per player (default: closed).
  if storage.stopcfg_pref[player.index] then build_stop_gui(player, state, true) end
  if storage.monitor_pref[player.index] then build_monitor_gui(player, state, true) end
  if storage.netcfg_pref[player.index]  then build_net_gui(player, state, true) end
  refresh_and_update(player, state)
end)

script.on_event(defines.events.on_gui_closed, function(event)
  -- Ignore spurious closes (e.g. a choose-elem-button opening its picker swaps
  -- player.opened and fires on_gui_closed with a non-custom gui_type).
  if event.gui_type ~= defines.gui_type.custom then return end
  if not (event.element and event.element.valid) then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  if event.element.name == WINDOW then
    close_gui(player)
  elseif event.element.name == TYPEDWIN then
    storage.typed_guis[player.index] = nil
    destroy_win(player, TYPEDWIN)
  elseif event.element.name == OVERVIEW then
    close_overview(player)
  end
end)

-- Open / toggle the overview from the shortcut-bar button or the custom key.
script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name ~= "stc2-open-overview" then return end
  local player = game.get_player(event.player_index)
  if player then toggle_overview(player) end
end)
script.on_event("stc2-open-overview", function(event)
  local player = game.get_player(event.player_index)
  if player then toggle_overview(player) end
end)

-- Remember where the player drags the secondary windows, so they reopen in place
-- instead of jumping back to a default spot.
-- When the base window is dragged, the glued secondary windows follow it.
script.on_event(defines.events.on_gui_location_changed, function(event)
  local el = event.element
  if not (el and el.valid and el.name == WINDOW) then return end
  local player = game.get_player(event.player_index)
  if player then reposition_secondaries(player) end
end)

script.on_event(defines.events.on_gui_click, function(event)
  local name = event.element.name
  -- Overview: close button, or a per-row "eye" (focus module + open its GUI).
  if name == OV_CLOSE then
    local player = game.get_player(event.player_index)
    if player then close_overview(player) end
    return
  elseif name:sub(1, #OV_EYE) == OV_EYE then
    local player = game.get_player(event.player_index)
    local un = tonumber(name:sub(#OV_EYE + 1))
    local state = un and storage.mains[un]
    if player and state and state.entity and state.entity.valid then
      close_overview(player)
      player.centered_on = state.entity   -- focus the module (handles other surfaces)
      player.opened = state.entity         -- open its GUI via on_gui_opened
    end
    return
  end
  if name == CLOSE then
    local player = game.get_player(event.player_index)
    if player then player.opened = nil end -- triggers on_gui_closed
  elseif name == TYPED_CLOSE then
    local player = game.get_player(event.player_index)
    if player then player.opened = nil end -- triggers on_gui_closed (TYPEDWIN)
  elseif name == STOP_TOGGLE then
    local player = game.get_player(event.player_index)
    local state  = gui_state(event)
    if player and state then
      if player.gui.screen[STOPCFG] then
        destroy_win(player, STOPCFG)
        storage.stopcfg_pref[player.index] = false
      else
        build_stop_gui(player, state)
        storage.stopcfg_pref[player.index] = true
        update_stop(player, state)
      end
    end
  elseif name == STOP_CLOSE then
    local player = game.get_player(event.player_index)
    if player then
      destroy_win(player, STOPCFG)
      storage.stopcfg_pref[player.index] = false
    end
  elseif name == MON_TOGGLE then
    local player = game.get_player(event.player_index)
    local state  = gui_state(event)
    if player and state then
      if player.gui.screen[MONITOR] then
        destroy_win(player, MONITOR)
        storage.monitor_pref[player.index] = false
      else
        build_monitor_gui(player, state)
        storage.monitor_pref[player.index] = true
        update_monitor(player, state)
      end
    end
  elseif name == MON_CLOSE then
    local player = game.get_player(event.player_index)
    if player then
      destroy_win(player, MONITOR)
      storage.monitor_pref[player.index] = false
    end
  elseif name == NET_TOGGLE then
    local player = game.get_player(event.player_index)
    local state  = gui_state(event)
    if player and state then
      if player.gui.screen[NETCFG] then
        destroy_win(player, NETCFG)
        storage.netcfg_pref[player.index] = false
      else
        build_net_gui(player, state)
        storage.netcfg_pref[player.index] = true
        update_net(player, state)
      end
    end
  elseif name == NET_CLOSE then
    local player = game.get_player(event.player_index)
    if player then
      destroy_win(player, NETCFG)
      storage.netcfg_pref[player.index] = false
    end
  end
end)

script.on_event(defines.events.on_gui_selection_state_changed, function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  local state  = gui_state(event)
  if not (player and state) then return end
  if event.element.name == PRIO_DD then
    state.priority_level = PRIORITY_LEVELS[event.element.selected_index] or "medium"
  elseif event.element.name == GATE_OP then
    state.gate_op = GATE_OPS[event.element.selected_index] or "<"
  else
    return
  end
  refresh_and_update(player, state)
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  -- Overview: resource filter picker (item when Type=Solid, fluid when Type=Liquid).
  -- Empty value = all resources of that type.
  if event.element.name == OV_F_RES then
    local v = event.element.elem_value
    local f = ov_filters(player.index)
    f.resource = v and (type(v) == "table" and v.name or v) or nil
    storage.overview_sig[player.index] = nil  -- filter changed -> force a full rebuild
    ov_populate(player)
    local win = player.gui.screen[OVERVIEW]
    if win and win.valid then player.opened = win end  -- restore ESC-to-close
    return
  end
  -- Overview: inline wagon picker on a module row (the only editable control).
  if event.element.name:sub(1, #OV_WAGON) == OV_WAGON then
    local un = tonumber(event.element.name:sub(#OV_WAGON + 1))
    local state = un and storage.mains[un]
    if state then
      local v = event.element.elem_value
      state.wagon_type    = v and v.name or nil
      state.wagon_quality = v and v.quality or "normal"
      refresh(state)
      -- Picking in the choose-elem-button stole player.opened from the overview;
      -- restore it so ESC still closes the overview.
      local win = player.gui.screen[OVERVIEW]
      if win and win.valid then player.opened = win end
      -- If this module's GUI is open for some player, keep it in sync.
      for pi, gun in pairs(storage.guis) do
        if gun == un then
          local p = game.get_player(pi)
          if p and p.valid then update_open(p, state) end
        end
      end
    end
    return
  end
  -- typed-probe resource picker (its own window, no main state). Item OR fluid,
  -- mutually exclusive: picking one clears the other.
  if event.element.name == TYPED_ELEM or event.element.name == TYPED_FLUID then
    local un = storage.typed_guis[player.index]
    if un then
      local win = player.gui.screen[TYPEDWIN]
      local row = win and win["stc2-typed-body"]["stc2-typed-content"]["stc2-typed-row"]
      local v = event.element.elem_value
      if event.element.name == TYPED_ELEM then
        storage.typed[un] = v and { name = v.name, quality = v.quality or "normal", fluid = false } or {}
        if row and row[TYPED_FLUID] then row[TYPED_FLUID].elem_value = nil end
      else
        storage.typed[un] = v and { name = (type(v) == "table" and v.name or v), quality = "normal", fluid = true } or {}
        if row and row[TYPED_ELEM] then row[TYPED_ELEM].elem_value = nil end
      end
    end
    return
  end
  local state = gui_state(event)
  if not state then return end
  local name = event.element.name
  if name == ITEMBTN then
    local v = event.element.elem_value  -- { name, quality } or nil
    state.icon         = v and v.name or nil
    state.icon_quality = (v and v.quality) or "normal"
    refresh_and_update(player, state)
  elseif name == FLUIDBTN then
    local v = event.element.elem_value  -- fluid name string (or table) or nil
    state.icon         = v and (type(v) == "table" and v.name or v) or nil
    state.icon_quality = "normal"
    refresh_and_update(player, state)
  elseif name == WAGON then
    local v = event.element.elem_value
    state.wagon_type    = v and v.name or nil
    state.wagon_quality = v and v.quality or "normal"
    refresh_and_update(player, state)
  elseif name == OUTPUT then
    local v = event.element.elem_value
    if v then
      -- Normalize: a logistic-section slot needs a trivial (quality-pinned) filter
      -- to carry a non-zero count, otherwise set_slot rejects it.
      state.output_signal = { type = v.type or "item", name = v.name, quality = v.quality or "normal" }
      refresh_and_update(player, state)
    end
  elseif name == SIGP then
    local v = event.element.elem_value
    if v then
      state.priority_output_signal = { type = v.type or "item", name = v.name, quality = v.quality or "normal" }
      refresh_and_update(player, state)
    end
  elseif name == GATE_SIG then
    local v = event.element.elem_value
    state.gate_signal = v and { type = v.type or "item", name = v.name, quality = v.quality or "normal" } or nil
    refresh_and_update(player, state)
  elseif name == GATE_SIG2 then
    local v = event.element.elem_value
    state.gate_signal2 = v and { type = v.type or "item", name = v.name, quality = v.quality or "normal" } or nil
    refresh_and_update(player, state)
  elseif name:sub(1, #GOOD_BTN) == GOOD_BTN then
    -- Rebuild the goods list from the whole grid (compact, preserve order).
    -- Editing the goods invalidates the FIFO indices, so reset the dispatch.
    local win = player.gui.screen[WINDOW]
    local gt  = win and win["stc2-body"][CONTENT][GOODS_FRAME]
    gt = gt and gt[GOODS_TABLE]
    if gt then
      local is_fluid = (state.kind == KIND.FLUID)
      local goods = {}
      for i = 1, (MAX_GOODS) do
        local el = gt[GOOD_BTN .. i]
        local v = el and el.elem_value
        if v then
          if is_fluid then
            goods[#goods + 1] = { name = (type(v) == "table" and v.name or v), quality = "normal" }
          else
            goods[#goods + 1] = { name = v.name, quality = v.quality or "normal" }
          end
        end
      end
      state.goods = goods
      state.request_queue = {}
      state.active_request = nil
      state.released_train_id = nil
    end
    refresh_and_update(player, state)
  end
end)

script.on_event(defines.events.on_gui_switch_state_changed, function(event)
  local player = game.get_player(event.player_index)
  local state  = gui_state(event)
  if not (player and state) then return end
  if event.element.name == DIR_SW then
    state.direction = (event.element.switch_state == "right") and DIRECTION.UNLOAD or DIRECTION.LOAD
    refresh_and_update(player, state)
    return
  end
  if event.element.name ~= TYPE_SW then return end
  do
    local new_kind = (event.element.switch_state == "right") and KIND.FLUID or KIND.ITEM
    if new_kind ~= state.kind then
      local is_fluid = (new_kind == KIND.FLUID)
      state.kind = new_kind
      state.icon = nil  -- an item is not a fluid; clear the previous good
      state.icon_quality = "normal"
      -- drop a now-incompatible wagon
      if state.wagon_type then
        local proto = prototypes.entity[state.wagon_type]
        local want  = is_fluid and "fluid-wagon" or "cargo-wagon"
        if not proto or proto.type ~= want then state.wagon_type = nil end
      end
      if is_multi(state) then
        -- the goods block changes shape (item grid <-> single fluid): rebuild.
        state.goods = {}
        state.request_queue = {}
        state.active_request = nil
        state.released_train_id = nil
        build_base_gui(player, state)
        refresh_and_update(player, state)
        return
      end
      -- single-good: swap chooser + retarget wagon picker in place
      local good_flow = player.gui.screen[WINDOW]["stc2-body"][CONTENT][CONFIG]["stc2-good-flow"]
      good_flow[ITEMBTN].visible  = not is_fluid
      good_flow[FLUIDBTN].visible = is_fluid
      good_flow[ITEMBTN].elem_value  = nil
      good_flow[FLUIDBTN].elem_value = nil
      local wagon_btn = player.gui.screen[WINDOW]["stc2-body"][CONTENT][CONFIG][WAGON]
      wagon_btn.elem_filters = wagon_filter(new_kind)
      if not state.wagon_type then wagon_btn.elem_value = nil end
    end
    refresh_and_update(player, state)
  end
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
  local player = game.get_player(event.player_index)
  local state  = gui_state(event)
  if not (player and state) then return end
  if event.element.name == MAXF then
    local n = tonumber(event.element.text)
    if n then state.max_trains = math.max(0, math.floor(n)) end
  elseif event.element.name == GATE_CONST then
    local n = tonumber(event.element.text)
    state.gate_constant = n and math.floor(n) or 0
  else
    return
  end
  refresh_and_update(player, state)
end)

-- Overview filter radio groups: name is "<group>-<option>". Selecting one clears
-- the group's siblings, updates the filter, and repopulates the list.
local OV_RADIO_GROUPS = {
  [OV_F_TYPE]  = { options = OV_TYPES,  key = "type" },
  [OV_F_DIR]   = { options = OV_DIRS,   key = "direction" },
  [OV_F_STORE] = { options = OV_STORES, key = "storage" },
}

script.on_event(defines.events.on_gui_checked_state_changed, function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  -- Overview filter radios first (no main state involved).
  local nm = event.element.name
  for group, def in pairs(OV_RADIO_GROUPS) do
    if nm:sub(1, #group + 1) == group .. "-" then
      local chosen = nm:sub(#group + 2)
      local win = player.gui.screen[OVERVIEW]
      local col = win and win["stc2-ov-body"]["stc2-ov-cols"]["stc2-ov-left"]["stc2-ov-left-flow"]
      local flow = col and col[group]
      if flow then
        for _, opt in ipairs(def.options) do
          local rb = flow[group .. "-" .. opt]
          if rb then rb.state = (opt == chosen) end
        end
      end
      local f = ov_filters(player.index)
      f[def.key] = chosen
      storage.overview_sig[player.index] = nil  -- filter changed -> force a full rebuild
      if group == OV_F_TYPE then
        -- The resource picker's kind depends on Type (and the item/fluid switch is
        -- only shown for Type=all); rebuild the whole window to reshape the left column.
        f.resource = nil
        build_overview_gui(player)
      else
        ov_populate(player)
      end
      return
    end
  end
  local state = gui_state(event)
  if not (player and state) then return end
  if event.element.name == LINK_LIM then
    state.link_train_count = event.element.state
  elseif event.element.name == LINK_NM then
    state.train_stop_name = event.element.state
  elseif event.element.name == LINK_WC then
    state.name_wagon_count = event.element.state
  elseif event.element.name == LINK_PRIO then
    state.link_priority = event.element.state
  elseif event.element.name == STORAGE_CHK then
    state.storage = event.element.state
  elseif event.element.name == GATE_CHK then
    state.gate_enabled = event.element.state  -- update_net re-greys the condition row
  else
    return
  end
  refresh_and_update(player, state)
end)

-- ===========================================================================
-- Tick: each main is refreshed ~once/second, but the work is SPREAD across 4
-- sub-cycles (bucket by unit_number) so a big base doesn't burst all the BFS
-- in one tick. A main whose GUI is open is refreshed every sub-cycle (4/s) for
-- responsiveness.
-- ===========================================================================
local BUCKETS = 4
local SUBTICK = 15  -- BUCKETS * SUBTICK = 60 ticks = 1 s per full pass
script.on_nth_tick(SUBTICK, function(event)
  ensure_storage()
  local bucket = math.floor(event.tick / SUBTICK) % BUCKETS
  local open = {}
  for _, un in pairs(storage.guis) do open[un] = true end

  for un, state in pairs(storage.mains) do
    if not (state.entity and state.entity.valid) then
      storage.mains[un] = nil
    elseif open[un] or (un % BUCKETS == bucket) then
      refresh(state)
    end
  end

  for player_index, un in pairs(storage.guis) do
    local player = game.get_player(player_index)
    local state  = storage.mains[un]
    if player and player.valid and state then
      update_open(player, state)
      reposition_secondaries(player)  -- keep glued (self-correcting, fixes first-open placement)
    else
      storage.guis[player_index] = nil
    end
  end

  -- Refresh the overview list for anyone who has it open (fill bars + call dot
  -- evolve). state.eval / trains_call are kept fresh by the mains loop above.
  for player_index in pairs(storage.overview_guis) do
    local player = game.get_player(player_index)
    if player and player.valid and player.gui.screen[OVERVIEW] then
      ov_populate(player)
    else
      storage.overview_guis[player_index] = nil
    end
  end
end)

-- ===========================================================================
-- Entity lifecycle
-- ===========================================================================
local function on_built(event)
  ensure_storage()
  local e = event.entity or event.created_entity
  if not (e and e.valid) then return end
  if e.name == MAIN or e.name == MULTI then
    local st = default_state(e)
    if event.tags and event.tags.stc2 then apply_config(st, event.tags.stc2) end
    if e.name == MAIN then
      read_tracked_signal(st)  -- a parametrized blueprint substitutes the resource here
    end
    storage.mains[e.unit_number] = st
    ensure_power(st)
    update_overlay(st)  -- show the arrow (and resource, if a blueprint set one) at once
  elseif e.name == TYPED then
    local r = event.tags and event.tags.stc2_typed
    storage.typed[e.unit_number] = (type(r) == "table" and r.name) and { name = r.name, quality = r.quality, fluid = r.fluid } or {}
  end
end

local function on_removed(event)
  ensure_storage()
  local e = event.entity
  if e and e.valid then
    if e.name == MAIN or e.name == MULTI then
      local st = storage.mains[e.unit_number]
      local tap = (st and st.power and st.power.valid) and st.power
        or e.surface.find_entities_filtered({ name = POWER, position = e.position, radius = 0.5 })[1]
      if tap then tap.destroy() end
      if st then clear_overlay(st) end
      storage.mains[e.unit_number] = nil
    elseif e.name == TYPED then
      storage.typed[e.unit_number] = nil
    end
  end
end

local filters = { { filter = "name", name = MAIN }, { filter = "name", name = MULTI }, { filter = "name", name = PROBE }, { filter = "name", name = TYPED } }
script.on_event(defines.events.on_built_entity,                on_built, filters)
script.on_event(defines.events.on_robot_built_entity,          on_built, filters)
script.on_event(defines.events.on_space_platform_built_entity, on_built, filters)
script.on_event(defines.events.script_raised_built,            on_built)
script.on_event(defines.events.script_raised_revive,           on_built)

script.on_event(defines.events.on_player_mined_entity, on_removed)
script.on_event(defines.events.on_robot_mined_entity,  on_removed)
script.on_event(defines.events.on_entity_died,         on_removed)
script.on_event(defines.events.script_raised_destroy,  on_removed)

script.on_init(ensure_storage)
script.on_configuration_changed(migrate_all)

-- ===========================================================================
-- Blueprint: write each main's config into its blueprint entity tags so it can
-- be restored on build (read back in on_built via event.tags).
-- ===========================================================================
local function event_blueprint(event)
  local player = game.get_player(event.player_index)
  if not player then return nil end
  local bp = player.blueprint_to_setup
  if bp and bp.valid_for_read then return bp end
  local cs = player.cursor_stack
  if cs and cs.valid_for_read and cs.is_blueprint then return cs end
  return nil
end

script.on_event(defines.events.on_player_setup_blueprint, function(event)
  local bp = event_blueprint(event)
  if not bp then return end
  local entities = bp.get_blueprint_entities()
  if not entities then return end
  local mapping = event.mapping and event.mapping.valid and event.mapping.get() or nil
  if not mapping then return end
  ensure_storage()
  for i, _ in ipairs(entities) do
    local source = mapping[i]
    if source and source.valid and (source.name == MAIN or source.name == MULTI) then
      local st = storage.mains[source.unit_number]
      if st then bp.set_blueprint_entity_tag(i, "stc2", config_of(st)) end
    elseif source and source.valid and source.name == TYPED then
      local r = storage.typed[source.unit_number]
      if r and r.name then bp.set_blueprint_entity_tag(i, "stc2_typed", { name = r.name, quality = r.quality, fluid = r.fluid }) end
    end
  end
end)

-- Copy-paste of entity settings (shift-RClick / shift-LClick) between two mains.
script.on_event(defines.events.on_entity_settings_pasted, function(event)
  local src, dst = event.source, event.destination
  if not (src and dst and src.valid and dst.valid) then return end
  -- only paste between two combinators of the SAME kind
  if not ((src.name == MAIN and dst.name == MAIN) or (src.name == MULTI and dst.name == MULTI)) then return end
  ensure_storage()
  local ss, ds = storage.mains[src.unit_number], storage.mains[dst.unit_number]
  if ss and ds then
    apply_config(ds, config_of(ss))
    ds.request_queue, ds.active_request, ds.released_train_id = {}, nil, nil
    refresh(ds)
  end
end)

-- Cloning (editor clone, space platform, etc.) carries config to the new main.
script.on_event(defines.events.on_entity_cloned, function(event)
  local src, dst = event.source, event.destination
  if not (src and dst and src.valid and dst.valid) then return end
  ensure_storage()
  if dst.name == TYPED then
    local r = storage.typed[src.unit_number]
    storage.typed[dst.unit_number] = (r and r.name) and { name = r.name, quality = r.quality, fluid = r.fluid } or {}
    return
  end
  if dst.name ~= MAIN and dst.name ~= MULTI then return end
  local st = default_state(dst)
  local ss = storage.mains[src.unit_number]
  if ss then apply_config(st, config_of(ss)) end
  storage.mains[dst.unit_number] = st
  ensure_power(st)  -- adopts an area-cloned tap if one landed here, else creates one
end)

-- ===========================================================================
-- /stc-debug : hover a main and run it to print everything the mod computes
-- (handy to spot-check fluid stations and the per-wagon numbers in-game).
-- Does not disable achievements (unlike the /c console).
-- ===========================================================================
commands.add_command("stc-debug", "Print Smart Train Combinator values for the hovered unit", function(cmd)
  local player = game.get_player(cmd.player_index)
  if not player then return end
  local e = player.selected
  if not (e and e.valid and e.name == MAIN) then
    player.print("[STC] Hover over a Smart Train Combinator (the main unit), then run /stc-debug.")
    return
  end
  ensure_storage()
  local st = storage.mains[e.unit_number]
  if not st then player.print("[STC] no state for this unit"); return end
  refresh(st)
  local ev = st.eval or {}
  player.print(("[STC] %s %s | good=%s q=%s wagon=%s(%s) | trains=%s prio=%s | stored=%s cap=%s | probes=%d stops=%d"):format(
    tostring(st.kind), tostring(st.direction), tostring(st.icon), tostring(st.icon_quality),
    tostring(st.wagon_type), tostring(st.wagon_quality),
    tostring(st.trains_call), tostring(st.current_priority),
    tostring(ev.stored_total), tostring(ev.cap_total), #(st.probes or {}), #(st.stops or {})))
  player.print(("[STC] per-wagon capacity = %s"):format(tostring(ev.cap)))
  for i, r in ipairs(ev.rows or {}) do
    player.print(("   wagon %d: stored=%d  cap=%d  loads=%d%s"):format(
      i, r.stored, r.capacity, r.loads, (i == ev.bottleneck_idx) and "   <- min" or ""))
  end
end)

-- Exercise the public get_models interface on the caller's surface (the exact
-- path Train Foundry uses), and print the distinct shapes it returns.
commands.add_command("stc-models", "List the distinct train shapes get_models exposes for this surface", function(cmd)
  local player = game.get_player(cmd.player_index)
  if not player then return end
  local models = remote.call("smart-train-combinator", "get_models", player.surface.index)
  player.print(("[STC] get_models -> %d shape(s) on %s"):format(#models, player.surface.name))
  for i, m in ipairs(models) do
    player.print(("  #%d  kind=%s wagon=%s(%s) x%d  group=%q  storage=%s"):format(
      i, m.kind, m.wagon_type, m.wagon_quality, m.wagons, m.group, tostring(m.storage)))
  end
end)
