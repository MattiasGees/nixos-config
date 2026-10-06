local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local hover = require("helpers.hover")
local popup = require("helpers.popup")

-- Execute the event provider binary which provides the event "network_update"
-- for the network interface "en0", which is fired every 5.0 seconds.
sbar.exec("killall network_load >/dev/null; $CONFIG_DIR/helpers/event_providers/network_load/bin/network_load en0 network_update 5.0")

local wifi_up = sbar.add("item", "widgets.wifi1", {
  position = "right",
  padding_left = -5,
  width = 0,
  icon = {
    padding_right = 0,
    font = {
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
    string = icons.wifi.upload,
  },
  label = {
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
    color = colors.red,
    string = "??? Bps",
  },
  y_offset = 4,
})

local wifi_down = sbar.add("item", "widgets.wifi2", {
  position = "right",
  padding_left = -5,
  icon = {
    padding_right = 0,
    font = {
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
    string = icons.wifi.download,
  },
  label = {
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
    color = colors.blue,
    string = "??? Bps",
  },
  y_offset = -4,
})

local wifi = sbar.add("item", "widgets.wifi.padding", {
  position = "right",
  label = { drawing = false },
})

-- Background around the item
local wifi_bracket = sbar.add("bracket", "widgets.wifi.bracket", {
  wifi.name,
  wifi_up.name,
  wifi_down.name
}, {
  background = { color = colors.bg1 },
  popup = { align = "center" }
})

local c = colors.popup
local header = popup.header(wifi_bracket, { glyph = popup.glyph.wifi, title = "Wi‑Fi", state = "…" })
local header_sep = popup.separator(wifi_bracket)
local ip = popup.row(wifi_bracket, "IP address", { mono = true })
local mask = popup.row(wifi_bracket, "Subnet mask", { mono = true })
local router = popup.row(wifi_bracket, "Router", { mono = true })
local signal = popup.row(wifi_bracket, "Signal")
local bottom = popup.spacer(wifi_bracket)

-- RSSI for the current network only: the first "Signal / Noise" line precedes
-- the "Other Local Wi-Fi Networks" section in system_profiler's output.
local SIGNAL_CMD = "system_profiler SPAirPortDataType 2>/dev/null | grep -m1 'Signal / Noise' | awk -F': ' '{print $2}' | awk '{print $1}'"

local function refresh_signal()
  sbar.exec(SIGNAL_CMD, function(result)
    local rssi = tonumber(result)
    if not rssi then
      signal:set({ label = "Unknown" })
      return
    end
    local quality = "Poor"
    if rssi >= -50 then quality = "Excellent"
    elseif rssi >= -60 then quality = "Good"
    elseif rssi >= -70 then quality = "Fair"
    end
    signal:set({ label = string.format("%s, %d dBm", quality, rssi) })
  end)
end

refresh_signal()

sbar.add("item", { position = "right", width = settings.group_paddings })

wifi_up:subscribe("network_update", function(env)
  local up_color = (env.upload == "000 Bps") and colors.grey or colors.red
  local down_color = (env.download == "000 Bps") and colors.grey or colors.blue
  wifi_up:set({
    icon = { color = up_color },
    label = {
      string = env.upload,
      color = up_color
    }
  })
  wifi_down:set({
    icon = { color = down_color },
    label = {
      string = env.download,
      color = down_color
    }
  })
end)

wifi:subscribe({"wifi_change", "system_woke"}, function(env)
  sbar.exec("ipconfig getifaddr en0", function(ip)
    local connected = not (ip == "")
    wifi:set({
      icon = {
        string = connected and icons.wifi.connected or icons.wifi.disconnected,
        color = connected and colors.white or colors.red,
      },
    })
  end)
  refresh_signal()
end)

-- Tracked here rather than queried: a query is a blocking round trip to
-- sketchybar.
local is_open = false

local function hide_details()
  is_open = false
  wifi_bracket:set({ popup = { drawing = false } })
end

-- Hover reveals the network details popup. Moving between the up/down/wifi
-- items while it is open leaves it untouched.
local function show_details()
  if is_open then return end
  is_open = true
  wifi_bracket:set({ popup = { drawing = true }})
  sbar.exec("ipconfig getifaddr en0", function(result)
    result = (result or ""):gsub("%s+$", "")
    local connected = result ~= ""
    header:set({ label = {
      string = connected and "Connected" or "Not connected",
      color = connected and c.green or c.secondary,
    } })
    ip:set({ label = connected and result or "—" })
  end)
  sbar.exec("networksetup -getinfo Wi-Fi | awk -F 'Subnet mask: ' '/^Subnet mask: / {print $2}'", function(result)
    mask:set({ label = result })
  end)
  sbar.exec("networksetup -getinfo Wi-Fi | awk -F 'Router: ' '/^Router: / {print $2}'", function(result)
    router:set({ label = result })
  end)
end

local wifi_hover = hover(show_details, hide_details)
wifi_up:subscribe("mouse.entered", wifi_hover.enter)
wifi_down:subscribe("mouse.entered", wifi_hover.enter)
wifi:subscribe("mouse.entered", wifi_hover.enter)
wifi_up:subscribe("mouse.exited", wifi_hover.leave)
wifi_down:subscribe("mouse.exited", wifi_hover.leave)
wifi:subscribe("mouse.exited", wifi_hover.leave)
popup.bind(wifi_hover, { header, header_sep, signal, bottom })
-- Addresses copy on click.
popup.bind(wifi_hover, { ip, mask, router }, true)

local function copy_label_to_clipboard(env)
  local label = sbar.query(env.NAME).label.value
  if label == "" or label == "—" or label == "…" or label:find("Copied") then return end
  sbar.exec("printf %s \"" .. label .. "\" | pbcopy")
  sbar.set(env.NAME, { label = { string = popup.glyph.copied .. " Copied", color = c.accent, font = popup.font.body } })
  sbar.delay(1, function()
    sbar.set(env.NAME, { label = { string = label, color = c.text, font = popup.font.mono } })
  end)
end

ip:subscribe("mouse.clicked", copy_label_to_clipboard)
mask:subscribe("mouse.clicked", copy_label_to_clipboard)
router:subscribe("mouse.clicked", copy_label_to_clipboard)
