local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local hover = require("helpers.hover")

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

local remaining_time = sbar.add("item", {
  position = "popup." .. battery.name,
  icon = {
    string = "Time remaining:",
    width = 100,
    align = "left"
  },
  label = {
    string = "??:??h",
    width = 100,
    align = "right"
  },
})

local charging_wattage = sbar.add("item", {
  position = "popup." .. battery.name,
  icon = { string = "Charging:", width = 100, align = "left" },
  label = { string = "—", width = 100, align = "right" },
})

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
    local found, _, remaining = batt_info:find(" (%d+:%d+) remaining")
    remaining_time:set({ label = found and remaining .. "h" or "No estimate" })
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
battery_hover.bind(remaining_time)
battery_hover.bind(charging_wattage)

sbar.add("bracket", "widgets.battery.bracket", { battery.name }, {
  background = { color = colors.bg1 }
})

sbar.add("item", "widgets.battery.padding", {
  position = "right",
  width = settings.group_paddings
})
