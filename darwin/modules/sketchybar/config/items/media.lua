local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local hover = require("helpers.hover")

local whitelist = { ["Spotify"] = true,
                    ["Music"] = true    };

local media_cover = sbar.add("item", {
  position = "right",
  background = {
    image = {
      string = "media.artwork",
      scale = 0.85,
    },
    color = colors.transparent,
  },
  label = { drawing = false },
  icon = { drawing = false },
  drawing = false,
  updates = true,
  popup = {
    align = "center",
    horizontal = true,
  }
})

local media_artist = sbar.add("item", {
  position = "right",
  drawing = false,
  padding_left = 3,
  padding_right = 0,
  width = 0,
  icon = { drawing = false },
  label = {
    width = 0,
    font = { size = 9 },
    color = colors.with_alpha(colors.white, 0.6),
    max_chars = 18,
    y_offset = 6,
  },
})

local media_title = sbar.add("item", {
  position = "right",
  drawing = false,
  padding_left = 3,
  padding_right = 0,
  icon = { drawing = false },
  label = {
    font = { size = 11 },
    width = 0,
    max_chars = 16,
    y_offset = -5,
  },
})

-- Transport controls: round buttons that light up under the pointer.
local function control(icon, size, script, pad_l, pad_r)
  return sbar.add("item", {
    position = "popup." .. media_cover.name,
    padding_left = pad_l or 0,
    padding_right = pad_r or 0,
    icon = {
      string = icon,
      font = { family = settings.font.text, style = settings.font.style_map["Regular"], size = size },
      color = colors.popup.text,
      width = 40,
      align = "center",
      padding_left = 0,
      padding_right = 0,
      background = { drawing = true, color = colors.transparent, height = 34, corner_radius = 17 },
    },
    label = { drawing = false },
    background = { drawing = true, color = colors.transparent, height = 46, border_width = 0 },
    click_script = script,
  })
end

local media_back = control(icons.media.back, 15.0, "nowplaying-cli previous", 8, 2)
local media_playpause = control(icons.media.play_pause, 19.0, "nowplaying-cli togglePlayPause", 2, 2)
local media_forward = control(icons.media.forward, 15.0, "nowplaying-cli next", 2, 8)

local interrupt = 0
local function animate_detail(detail)
  if (not detail) then interrupt = interrupt - 1 end
  if interrupt > 0 and (not detail) then return end

  sbar.animate("tanh", 30, function()
    media_artist:set({ label = { width = detail and "dynamic" or 0 } })
    media_title:set({ label = { width = detail and "dynamic" or 0 } })
  end)
end

media_cover:subscribe("media_change", function(env)
  if whitelist[env.INFO.app] then
    local drawing = (env.INFO.state == "playing")
    media_artist:set({ drawing = drawing, label = env.INFO.artist, })
    media_title:set({ drawing = drawing, label = env.INFO.title, })
    media_cover:set({ drawing = drawing })

    if drawing then
      animate_detail(true)
      interrupt = interrupt + 1
      sbar.delay(5, animate_detail)
    else
      media_cover:set({ popup = { drawing = false } })
    end
  end
end)

local media_hover = hover(
  function() media_cover:set({ popup = { drawing = true } }) end,
  function() media_cover:set({ popup = { drawing = false } }) end
)

media_cover:subscribe("mouse.entered", function(env)
  interrupt = interrupt + 1
  animate_detail(true)
  media_hover.enter()
end)

media_cover:subscribe("mouse.exited", function(env)
  animate_detail(false)
  media_hover.leave()
end)

local function lit(on)
  return function(env)
    sbar.set(env.NAME, { icon = { background = { color = on and colors.popup.hover or colors.transparent } } })
  end
end
for _, control_item in ipairs({ media_back, media_playpause, media_forward }) do
  media_hover.bind(control_item, lit(true), lit(false))
end
