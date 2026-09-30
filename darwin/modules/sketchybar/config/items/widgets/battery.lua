local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local hover = require("helpers.hover")
local popup = require("helpers.popup")

local battery = sbar.add("item", "widgets.battery", {
  position = "right",
  icon = {
    font = {
      style = settings.font.style_map["Regular"],
      size = 19.0,
    }
  },
  label = { font = { family = settings.font.numbers } },
  update_freq = 180,
  popup = { align = "center" }
})

local c = colors.popup
local header = popup.header(battery, { glyph = popup.glyph.battery, title = "Battery", state = "…", state_mono = true })
local header_sep = popup.separator(battery)
local source_line = popup.row(battery, "Power source")
local remaining_time = popup.row(battery, "Time remaining", { mono = true })
local charging_wattage = popup.row(battery, "Charger", { mono = true, value = "—" })
local bottom = popup.spacer(battery)

battery:subscribe({"routine", "power_source_change", "system_woke"}, function()
  sbar.exec("pmset -g batt", function(batt_info)
    local icon = "!"
    local label = "?"

    local found, _, charge = batt_info:find("(%d+)%%")
    if found then
      charge = tonumber(charge)
      label = charge .. "%"
    end

    local color = colors.green
    local charging, _, _ = batt_info:find("AC Power")

    if charging then
      icon = icons.battery.charging
    else
      if found and charge > 80 then
        icon = icons.battery._100
      elseif found and charge > 60 then
        icon = icons.battery._75
      elseif found and charge > 40 then
        icon = icons.battery._50
      elseif found and charge > 20 then
        icon = icons.battery._25
        color = colors.orange
      else
        icon = icons.battery._0
        color = colors.red
      end
    end

    local lead = ""
    if found and charge < 10 then
      lead = "0"
    end

    battery:set({
      icon = {
        string = icon,
        color = color
      },
      label = { string = lead .. label },
    })
  end)
end)

local function battery_open()
  battery:set({ popup = { drawing = true } })
  sbar.exec("pmset -g batt", function(batt_info)
    local on_ac = batt_info:find("AC Power") ~= nil
    local charge = batt_info:match("(%d+)%%")
    local charging = batt_info:find("; charging") ~= nil
    header:set({ label = charge and (charge .. "%") or "—" })
    source_line:set({ label = on_ac and "Power adapter" or "Battery" })
    local found, _, remaining = batt_info:find(" (%d+:%d+) remaining")
    local done = on_ac and not charging
    remaining_time:set({
      drawing = not done,
      icon = charging and "Until full" or "Time remaining",
      label = found and { string = remaining, color = c.text, font = popup.font.mono }
        or { string = "Calculating…", color = c.secondary, font = popup.font.body },
    })
  end)
  sbar.exec("pmset -g batt | grep -q 'AC Power' && system_profiler SPPowerDataType 2>/dev/null | awk -F': ' '/Wattage \\(W\\)/{print $2; found=1} END{if(!found) print \"\"}'", function(w)
    w = (w or ""):gsub("%s+", "")
    charging_wattage:set({ drawing = w ~= "", label = (w ~= "" and (w .. " W") or "") })
  end)
end

local battery_hover = hover(
  battery_open,
  function() battery:set({ popup = { drawing = false } }) end
)
battery:subscribe("mouse.entered", battery_hover.enter)
battery:subscribe("mouse.exited", battery_hover.leave)
popup.bind(battery_hover, { header, header_sep, source_line, remaining_time, charging_wattage, bottom })

sbar.add("bracket", "widgets.battery.bracket", { battery.name }, {
  background = { color = colors.bg1 }
})

sbar.add("item", "widgets.battery.padding", {
  position = "right",
  width = settings.group_paddings
})
