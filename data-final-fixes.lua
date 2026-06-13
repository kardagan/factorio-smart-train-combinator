-- UltraCube compatibility. UltraCube only *removes* a set of base recipes in
-- its own data-final-fixes (it does not mass-hide technologies), so patching our
-- recipes and technology here is enough. Nullius is handled in data.lua.

if mods["Ultracube"] then
  local function swap_circuit(recipe_name)
    local r = data.raw.recipe[recipe_name]
    if not r then return end
    for i, ing in ipairs(r.ingredients) do
      if ing.name == "electronic-circuit" then
        r.ingredients[i] = { type = "item", name = "cube-electronic-circuit", amount = 1 }
      end
    end
  end

  swap_circuit("smart-train-combinator")
  swap_circuit("stc2-buffer-probe")

  local tech = data.raw.technology["smart-train-combinator"]
  if tech then
    tech.prerequisites = { "cube-advanced-combinatorics", "cube-rail-signals" }
    tech.unit = {
      count = 120,
      ingredients = {
        { "cube-basic-contemplation-unit",       1 },
        { "cube-fundamental-comprehension-card", 1 },
        { "cube-abstract-interrogation-card",    1 },
      },
      time = 40,
    }
  end
end
