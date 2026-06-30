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
local LEASH_CONNECTORS = {
  W.circuit_red, W.circuit_green,
  W.combinator_output_red, W.combinator_output_green,
}
local INPUT_CONNECTORS = {
  W.combinator_input_red, W.combinator_input_green,
  W.circuit_red, W.circuit_green,
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
-- enable gate (stop-config window)
local GATE_CHK   = "stc2-gate-chk"
local GATE_SIG   = "stc2-gate-sig"
local GATE_OP    = "stc2-gate-op"
local GATE_RMODE = "stc2-gate-rmode"  -- switch: constant (left) / signal (right)
local GATE_CONST = "stc2-gate-const"
local GATE_SIG2  = "stc2-gate-sig2"
local GATE_REQ   = "stc2-gate-active"  -- monitor: current active request label

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
  storage.win_loc = storage.win_loc or {}  -- player_index -> { [window_name] = {x,y} }: remembered positions
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
    train_stop_name  = false,
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
local function walk_network(entity, connector_ids)
  local found, seen = {}, {}
  seen[entity.unit_number] = true
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
            table.insert(found, target)
            table.insert(queue, target)
          end
        end
      end
    end
  end
  return found
end

local function discover(state)
  local probes, stops = {}, {}
  for _, e in pairs(walk_network(state.entity, LEASH_CONNECTORS)) do
    if e.name == PROBE then
      table.insert(probes, e)
    elseif e.type == "train-stop" then
      table.insert(stops, e)  -- support several stops wired to one main
    end
  end
  state.probes = probes
  state.stops  = stops
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
-- For every tracked good, compute per-wagon loads and whether a full train of
-- that good is ready. Capacity per wagon is split ÷M (shared buffer). We cache
-- each probe's buffer units once (one BFS per probe, not per good).
local function evaluate_multi(state)
  local goods = state.goods or {}
  local m = #goods

  local probe_units = {}
  for _, probe in pairs(state.probes) do
    if probe.valid then
      probe_units[#probe_units + 1] = { probe = probe, units = probe_buffer_units(state, probe) }
    end
  end
  local nprobes = #probe_units

  local per_good = {}
  for gi, g in ipairs(goods) do
    local icon = g.name
    local cap  = per_wagon_capacity_for(state, icon, m)
    local item = (state.kind == KIND.ITEM) and icon and prototypes.item[icon] or nil
    local rows, min_loads = {}, nil
    local stored_total, cap_total = 0, 0
    for wi, pu in ipairs(probe_units) do
      local stored   = probe_stored(state, pu.probe, icon)
      local capacity = (state.kind == KIND.FLUID) and pu.units or (item and pu.units * item.stack_size or 0)
      -- Each good owns a 1/M slice of the shared buffer ("autant de fer que de
      -- charbon"). LOAD: ship g once a slice-unit has accumulated. UNLOAD:
      -- request g once its slice has a slice-unit of room free. (cap is the ÷M
      -- per-wagon unit.)
      local share = (m > 1) and (capacity / m) or capacity
      local loads = 0
      if cap and cap > 0 then
        if state.direction == DIRECTION.LOAD then
          loads = math.floor(stored / cap)
        else
          loads = math.floor((share - stored) / cap)
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

  -- enqueue newly-ready goods (preserve FIFO order), drop no-longer-ready ones
  local in_queue = {}
  for _, gi in ipairs(state.request_queue) do in_queue[gi] = true end
  for gi, info in ipairs(pg) do
    if info.ready and gi ~= state.active_request and not in_queue[gi] then
      table.insert(state.request_queue, gi)
      in_queue[gi] = true
    end
  end
  local kept = {}
  for _, gi in ipairs(state.request_queue) do
    if pg[gi] and pg[gi].ready then kept[#kept + 1] = gi end
  end
  state.request_queue = kept

  -- release on train arrival
  local train = stopped_train(state)
  if train then
    if state.active_request and train.id ~= state.released_train_id then
      state.released_train_id = train.id
      state.active_request = nil
    end
  else
    state.released_train_id = nil  -- quay empty: a fresh arrival may release again
  end

  -- commit to the head of the queue if nothing is active
  if not state.active_request then
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
  if state.icon then
    local value = (state.kind == KIND.FLUID)
      and { type = "fluid", name = state.icon }
      or  { type = "item", name = state.icon, quality = state.icon_quality or "normal" }
    -- guard: fluids have no quality; if a quality-trivial filter is rejected we
    -- still keep working (the tag carries the resource as a fallback).
    pcall(function() s.set_slot(1, { value = value, min = 1 }) end)
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
local function wagon_run(state)
  if not state.wagon_type then return "" end
  local tag = "[entity=" .. state.wagon_type .. "]"
  if not state.name_wagon_count then return tag end
  local n = #(state.probes or {})
  if n <= 0 then return "" end
  return string.rep(tag, n)
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
    return icon_tag .. store .. " [virtual-signal=stc2-load]" .. wagons
  else
    return icon_tag .. store .. " " .. wagons .. "[virtual-signal=stc2-unload]"
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

local function refresh(state)
  if not (state.entity and state.entity.valid) then return end
  discover(state)

  if is_multi(state) then
    -- The multi module always drives the stop by name + train-limit (L is 0/1),
    -- and only ever UNLOADS (it requests inbound resources).
    state.direction        = DIRECTION.UNLOAD
    state.train_stop_name  = true
    state.link_train_count = true
    state.name_wagon_count = (state.name_wagon_count ~= false)

    local em = evaluate_multi(state)
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
      state.eval = { cap = nil, rows = {}, raw = 0, stored_total = 0, cap_total = 0 }
      state.trains_call = 0
    end
    if not gate_open(state) then state.trains_call = 0 end
    state.current_priority = compute_priority(state)

    write_output(state)
    drive_station(state)
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
  local has_good = multi and (#(state.goods or {}) > 0) or (not multi and state.icon ~= nil)
  local ok = has_good and state.wagon_type ~= nil and #state.probes > 0
  icon_el.sprite  = ok and "flib_indicator_green" or "flib_indicator_red"
  if not has_good then
    label_el.caption = { "stc2-gui.status-pick-good" }
  elseif not state.wagon_type then
    label_el.caption = { "stc2-gui.status-pick-wagon" }
  elseif #state.probes == 0 then
    label_el.caption = { "stc2-gui.status-need-probes" }
  elseif #(state.stops or {}) == 0 then
    label_el.caption = { "stc2-gui.status-working-nostop" }
  else
    label_el.caption = { "stc2-gui.status-working" }
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
    -- the multi name is dynamic (one good at a time); preview the first configured
    -- good as a sample rather than the transient active request (which is nil idle).
    local goods = state.goods or {}
    if #goods > 0 then
      local si, sq = state.icon, state.icon_quality
      state.icon, state.icon_quality = goods[1].name, goods[1].quality
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
local BASE_W_MONO  = 372
local BASE_W_MULTI = 516
local STOP_W       = 372   -- stop panel width = left glue offset
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
    style_mods = { vertical_spacing = 10, minimal_width = 320 } }
  table.insert(content, { type = "flow", name = STATUS, style = "flib_indicator_flow",
    { type = "sprite", name = ST_ICON, sprite = "flib_indicator_red", style_mods = { size = 16, stretch_image_to_widget_size = true } },
    { type = "label", name = ST_LABEL, caption = "" },
  })
  table.insert(content, { type = "entity-preview", name = "stc2-preview", style_mods = { minimal_height = 100, horizontally_stretchable = true } })
  table.insert(content, config_table)

  if multi then
    local n = is_fluid and 1 or MAX_GOODS
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
    for i = 1, (is_fluid and 1 or MAX_GOODS) do
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
          style_mods = { vertical_spacing = 12, minimal_width = 320 },
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
          style_mods = { vertical_spacing = 8, minimal_width = 300 },
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
  if e.name == PROBE then
    -- passive shell: suppress its vanilla arithmetic GUI
    player.opened = nil
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
  if not (event.element and event.element.valid and event.element.name == WINDOW) then return end
  local player = game.get_player(event.player_index)
  if player then close_gui(player) end
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
  if name == CLOSE then
    local player = game.get_player(event.player_index)
    if player then player.opened = nil end -- triggers on_gui_closed
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
  local state  = gui_state(event)
  if not (player and state) then return end
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
      for i = 1, (is_fluid and 1 or MAX_GOODS) do
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

script.on_event(defines.events.on_gui_checked_state_changed, function(event)
  local player = game.get_player(event.player_index)
  local state  = gui_state(event)
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
  end
end

local function on_removed(event)
  ensure_storage()
  local e = event.entity
  if e and e.valid and (e.name == MAIN or e.name == MULTI) then
    storage.mains[e.unit_number] = nil
  end
end

local filters = { { filter = "name", name = MAIN }, { filter = "name", name = MULTI }, { filter = "name", name = PROBE } }
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
  if dst.name ~= MAIN and dst.name ~= MULTI then return end
  ensure_storage()
  local st = default_state(dst)
  local ss = storage.mains[src.unit_number]
  if ss then apply_config(st, config_of(ss)) end
  storage.mains[dst.unit_number] = st
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
