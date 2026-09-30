local colors = require("colors")
local settings = require("settings")
local hover = require("helpers.hover")
local popup = require("helpers.popup")

local CACHE = "/tmp/sketchybar_location_cache"

local rain = sbar.add("graph", "widgets.rain", 128, {
  position = "right",
  graph = { color = colors.blue, fill_color = colors.with_alpha(colors.blue, 0.3), line_width = 2 },
  background = { height = 22, color = { alpha = 0 }, drawing = true },
  icon = { string = "󰖗", color = colors.blue, padding_left = 8, font = { family = "JetBrainsMono Nerd Font", style = "Bold", size = 16.0 } },
  label = { drawing = false },
  update_freq = 120,
  padding_right = settings.paddings + 6,
  popup = { align = "center" },
})

local c = colors.popup
local header = popup.header(rain, { glyph = popup.glyph.rain, title = "Rain", state = "…" })
local header_sep = popup.separator(rain)
local loc_line = popup.row(rain, "Location", { max_chars = 20 })
local max_line = popup.row(rain, "Peak, next 8h", { mono = true })
local upd_line = popup.row(rain, "Updated", { mono = true })
local bottom = popup.spacer(rain)

-- Shell pipeline: resolve location (CoreLocationCLI -> cache) then Open-Meteo,
-- emit "CITY|<32 space-separated precip values>" or "NOLOC" on stdout.
-- Uses CoreLocationCLI's --format (not --json): the JSON output embeds raw,
-- unescaped newlines in the reverse-geocoded "address" field, which breaks
-- jq's parser unpredictably depending on key order.
local FETCH = [[
sh -c '
LAT=""; LON=""; CITY="Location unavailable"
if command -v CoreLocationCLI >/dev/null 2>&1; then
  LOC=$(CoreLocationCLI -f "%latitude|%longitude|%locality" 2>/dev/null)
  LAT=$(echo "$LOC" | cut -d"|" -f1); LON=$(echo "$LOC" | cut -d"|" -f2)
  CITY=$(echo "$LOC" | cut -d"|" -f3); [ -z "$CITY" ] && CITY="Unknown"
  [ -n "$LAT" ] && [ -n "$LON" ] && echo "$LAT,$LON,$CITY" > ]] .. CACHE .. "\n" .. [[fi
if { [ -z "$LAT" ] || [ -z "$LON" ]; } && [ -f ]] .. CACHE .. [[ ]; then
  IFS=, read LAT LON CITY < ]] .. CACHE .. [[; CITY="$CITY (cached)"
fi
if [ -z "$LAT" ] || [ -z "$LON" ]; then echo "NOLOC"; exit 0; fi
URL="https://api.open-meteo.com/v1/forecast?latitude=$LAT&longitude=$LON&minutely_15=precipitation&forecast_days=2&timezone=auto"
W=$(curl -s "$URL")
H=$(date +%H); M=$(date +%M); MR=$(( M - (M % 15) ))
T=$(date +"%Y-%m-%dT$H"):$(printf "%02d" $MR)
IDX=$(echo "$W" | jq ".minutely_15.time | index(\"$T\")"); [ "$IDX" = "null" ] && IDX=0
VALS=$(echo "$W" | jq -r ".minutely_15.precipitation[$IDX:$((IDX+32))] | @tsv")
echo "$CITY|$VALS"
'
]]

local function bucket(v) -- precip mm -> normalized graph level
  if v == 0 then return 0.0 elseif v < 0.1 then return 0.10
  elseif v < 0.3 then return 0.25 elseif v < 0.8 then return 0.50 else return 0.80 end
end

local function refresh()
  sbar.exec(FETCH, function(out)
    out = out or ""
    if out:find("NOLOC") then
      rain:set({ icon = { color = colors.grey }, graph = { color = colors.grey, fill_color = colors.with_alpha(colors.grey, 0.3) } })
      header:set({ label = { string = "No location", color = c.secondary } })
      loc_line:set({ label = { string = "Unavailable", color = c.secondary } })
      max_line:set({ label = "—" }); upd_line:set({ label = os.date("%H:%M") })
      for _ = 1, 128 do rain:push({ 0.0 }) end
      return
    end
    local city, vals = out:match("^([^|]*)|(.*)$")
    local precip = {}
    if vals then for n in vals:gmatch("[%-%d%.]+") do precip[#precip + 1] = tonumber(n) or 0 end end
    local maxr = 0
    for i = 1, 32 do
      local v = precip[i] or 0
      if v > maxr then maxr = v end
      local lvl = bucket(v)
      for _ = 1, 4 do rain:push({ lvl }) end
    end
    local color = colors.yellow
    if maxr > 0.8 then color = colors.red elseif maxr > 0.3 then color = colors.orange elseif maxr >= 0.1 then color = colors.green end
    local raining = (precip[1] or 0) >= 0.1
    rain:set({ icon = { color = color }, graph = { color = color, fill_color = colors.with_alpha(color, 0.3) } })
    header:set({ label = { string = raining and "Raining" or (maxr >= 0.1 and "Rain soon" or "Dry"), color = c.secondary } })
    loc_line:set({ label = { string = (city ~= "" and city or "Unknown"), color = c.text } })
    max_line:set({ label = string.format("%.2f mm", maxr) })
    upd_line:set({ label = os.date("%H:%M") })
  end)
end

rain:subscribe({ "routine", "forced" }, refresh)

local rain_hover = hover(
  function() rain:set({ popup = { drawing = true } }) end,
  function() rain:set({ popup = { drawing = false } }) end
)
rain:subscribe("mouse.entered", rain_hover.enter)
rain:subscribe("mouse.exited", rain_hover.leave)
popup.bind(rain_hover, { header, header_sep, loc_line, max_line, upd_line, bottom })

sbar.add("bracket", "widgets.rain.bracket", { rain.name }, { background = { color = colors.bg1 } })
sbar.add("item", "widgets.rain.padding", { position = "right", width = settings.group_paddings })
