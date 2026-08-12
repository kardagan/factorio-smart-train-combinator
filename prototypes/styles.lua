-- GUI styles for the Smart Train Combinator.
--
-- A table's ruling can ONLY be defined here, in the data stage: LuaStyle exposes
-- cell_padding and column_alignments at runtime, but neither the border nor the
-- row graphical sets. So the monitor's grid has to be a named style rather than a
-- style_mods tweak in control.lua.
local styles = data.raw["gui-style"].default

-- The buffer monitor's readout table, ruled like vanilla's mod-info panel: the
-- `bordered_table` frame (which carries the T-junctions and crosses, so cells are
-- separated in both directions) plus a tinted background on odd rows so a long row
-- of numbers stays easy to follow across six columns.
--
-- Copied from `removed_content_table` / `undelete_space_platforms_table`, the two
-- vanilla tables that do exactly this; {472, 25} in gui-new.png is the neutral dark
-- grey (53, 52, 53) they use for the striping.
styles["stc2_grid_table"] = {
  type = "table_style",
  parent = "bordered_table",
  odd_row_graphical_set = {
    filename = "__core__/graphics/gui-new.png",
    position = { 472, 25 },
    size = 1,
  },
  -- tighter than bordered_table's default: six columns of digits, not prose
  cell_padding = 2,
  left_cell_padding  = 6,
  right_cell_padding = 6,
  column_alignments = {
    -- numbers right-align so digits stack; the resource icon stays left
    { column = 2, alignment = "middle-right" },
    { column = 3, alignment = "middle-right" },
    { column = 4, alignment = "middle-right" },
    { column = 5, alignment = "middle-right" },
    { column = 6, alignment = "middle-right" },
  },
}
