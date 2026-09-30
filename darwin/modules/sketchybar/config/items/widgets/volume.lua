local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local hover = require("helpers.hover")
local popup = require("helpers.popup")

local c = colors.popup
local SLIDER_INSET = 16

local volume_percent = sbar.add("item", "widgets.volume1", {
  position = "right",
  icon = { drawing = false },
  label = {
    string = "??%",
    padding_left = -1,
    font = { family = settings.font.numbers }
  },
})

local volume_icon = sbar.add("item", "widgets.volume2", {
  position = "right",
  padding_right = -1,
  icon = {
    string = icons.volume._100,
    width = 0,
    align = "left",
    color = colors.grey,
    font = {
      style = settings.font.style_map["Regular"],
      size = 14.0,
    },
  },
  label = {
    width = 25,
    align = "left",
    font = {
      style = settings.font.style_map["Regular"],
      size = 14.0,
    },
  },
})

local volume_bracket = sbar.add("bracket", "widgets.volume.bracket", {
  volume_icon.name,
  volume_percent.name
}, {
  background = { color = colors.bg1 },
  popup = { align = "center" }
})

sbar.add("item", "widgets.volume.padding", {
  position = "right",
  width = settings.group_paddings
})

local header = popup.header(volume_bracket, { glyph = popup.glyph.sound, title = "Sound", state = "…", state_mono = true })
local header_sep = popup.separator(volume_bracket)

-- Slim native track: accent fill with a white knob.
local volume_slider = sbar.add("slider", popup.WIDTH - 2 * SLIDER_INSET, {
  position = "popup." .. volume_bracket.name,
  padding_left = SLIDER_INSET,
  padding_right = SLIDER_INSET,
  icon = { drawing = false },
  label = { drawing = false },
  slider = {
    highlight_color = c.accent,
    background = {
      height = 6,
      corner_radius = 3,
      color = 0x33ffffff,
    },
    knob = {
      string = "􀀁",
      drawing = true,
      color = 0xffffffff,
      font = { family = settings.font.text, style = settings.font.style_map["Regular"], size = 17.0 },
      shadow = { drawing = true, color = 0x66000000, distance = 1 },
    },
  },
  background = { drawing = true, color = colors.transparent, height = 34, border_width = 0 },
  click_script = 'osascript -e "set volume output volume $PERCENTAGE"'
})

local output_sep = popup.separator(volume_bracket)
local output_head = popup.section(volume_bracket, "Output")

local function set_volume(volume)
  if not volume then return end
  local icon = icons.volume._0
  if volume > 60 then
    icon = icons.volume._100
  elseif volume > 30 then
    icon = icons.volume._66
  elseif volume > 10 then
    icon = icons.volume._33
  elseif volume > 0 then
    icon = icons.volume._10
  end

  local lead = ""
  if volume < 10 then
    lead = "0"
  end

  volume_icon:set({ label = icon })
  volume_percent:set({ label = lead .. volume .. "%" })
  volume_slider:set({ slider = { percentage = volume } })
  header:set({ label = volume .. "%" })
end

-- The volume_change event only fires on subsequent changes, so query the
-- current output volume on load and on hover to stay in sync with reality.
local function fetch_volume()
  sbar.exec('osascript -e "output volume of (get volume settings)"', function(out)
    set_volume(tonumber((out or ""):match("%d+")))
  end)
end

volume_percent:subscribe("volume_change", function(env)
  set_volume(tonumber(env.INFO))
end)

fetch_volume()

local volume_hover -- forward declaration; assigned after the detail helpers

local function volume_collapse_details()
  local drawing = volume_bracket:query().popup.drawing == "on"
  if not drawing then return end
  volume_bracket:set({ popup = { drawing = false } })
  sbar.remove('/volume.device\\.*/')
end

local current_audio_device = "None"
local function volume_toggle_details(env)
  if env.BUTTON == "right" then
    sbar.exec("open /System/Library/PreferencePanes/Sound.prefpane")
    return
  end

  local should_draw = volume_bracket:query().popup.drawing == "off"
  if should_draw then
    volume_bracket:set({ popup = { drawing = true } })
    sbar.exec("SwitchAudioSource -t output -c", function(result)
      current_audio_device = result:sub(1, -2)
      sbar.exec("SwitchAudioSource -a -t output", function(available)
        local counter = 0

        for device in string.gmatch(available, '[^\r\n]+') do
          local dev = popup.choice(volume_bracket, device, {
            name = "volume.device." .. counter,
            checked = device == current_audio_device,
            click_script = 'SwitchAudioSource -s "' .. device .. '" && sketchybar'
              .. ' --set "/volume\\.device\\.[0-9]+/" icon.color=' .. colors.transparent
              .. ' --set $NAME icon.color=' .. c.accent,
          })
          popup.bind(volume_hover, { dev }, true)
          counter = counter + 1
        end
        -- Named like the devices so the collapse regex cleans it up too.
        popup.bind(volume_hover, { popup.spacer(volume_bracket, "volume.device.end") })
      end)
    end)
  else
    volume_collapse_details()
  end
end

local function volume_scroll(env)
  local delta = env.SCROLL_DELTA
  sbar.exec('osascript -e "set volume output volume (output volume of (get volume settings) + ' .. delta .. ')"')
end

-- Hover reveals the output-device switcher; right-click opens Sound prefs.
local function volume_open_details()
  fetch_volume()
  volume_collapse_details()
  volume_toggle_details({})
end

local function volume_prefs(env)
  if env.BUTTON == "right" then
    sbar.exec("open /System/Library/PreferencePanes/Sound.prefpane")
  end
end

volume_hover = hover(volume_open_details, volume_collapse_details)
volume_icon:subscribe("mouse.entered", volume_hover.enter)
volume_percent:subscribe("mouse.entered", volume_hover.enter)
volume_icon:subscribe("mouse.exited", volume_hover.leave)
volume_percent:subscribe("mouse.exited", volume_hover.leave)
popup.bind(volume_hover, { header, header_sep, volume_slider, output_sep, output_head })
volume_icon:subscribe("mouse.clicked", volume_prefs)
volume_percent:subscribe("mouse.clicked", volume_prefs)
volume_icon:subscribe("mouse.scrolled", volume_scroll)
volume_percent:subscribe("mouse.scrolled", volume_scroll)

