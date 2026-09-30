local settings = require("settings")
local colors = require("colors")

-- Equivalent to the --default domain
sbar.default({
  updates = "when_shown",
  icon = {
    font = {
      family = settings.font.text,
      style = settings.font.style_map["Bold"],
      size = 14.0
    },
    color = colors.white,
    padding_left = settings.paddings,
    padding_right = settings.paddings,
    background = { image = { corner_radius = 9 } },
  },
  label = {
    font = {
      family = settings.font.text,
      style = settings.font.style_map["Semibold"],
      size = 13.0
    },
    color = colors.white,
    padding_left = settings.paddings,
    padding_right = settings.paddings,
  },
  background = {
    height = 28,
    corner_radius = 9,
    border_width = 2,
    border_color = colors.bg2,
    image = {
      corner_radius = 9,
      border_color = colors.grey,
      border_width = 1
    }
  },
  popup = {
    background = {
      border_width = 1,
      corner_radius = 13,
      border_color = colors.popup.border,
      color = colors.popup.bg,
      shadow = { drawing = true, color = 0x66000000, distance = 4 },
    },
    blur_radius = 60,
    y_offset = 4,
    height = 9, -- minimum cell height; popup rows size themselves
  },
  padding_left = 5,
  padding_right = 5,
  scroll_texts = true,
})
