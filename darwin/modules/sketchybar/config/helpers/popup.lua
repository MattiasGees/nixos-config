-- Shared building blocks for the hover popups, styled after macOS menu-bar
-- menus / Control Center modules: a semibold header with the state on the
-- right, hairline separators, key/value rows and checkable choice rows.
--
--   local popup = require("helpers.popup")
--   local head = popup.header(parent, { glyph = popup.glyph.wifi, title = "Wi‑Fi" })
--   popup.separator(parent)
--   local ip = popup.row(parent, "IP address", { mono = true })
--   popup.spacer(parent)
--   popup.bind(h, { head, ip, ... })     -- h from helpers.hover
--
-- Every builder takes the parent item and appends to its popup, so call them
-- in display order. Dynamic rows accept a `name` so they can be removed later.

local colors = require("colors")
local settings = require("settings")

local c = colors.popup

local M = {}

M.WIDTH = 272
local INSET = 6                    -- row inset from the popup edge (hover pill)
local PAD = 10                     -- text inset inside a row
local ROW_W = M.WIDTH - 2 * INSET
local KEY_W = 112                  -- key column of key/value rows
local CHECK_W = 22                 -- checkmark column of choice rows
local HEADER_H = 34
local ROW_H = 24

M.ROW_W = ROW_W

-- SF Symbols (SF Pro private-use codepoints)
M.glyph = {
  check = "􀆅",
  tailscale = "􀙨",      -- shield.lefthalf.filled
  kube = "􀐪",           -- helm
  rain = "􀇇",           -- cloud.rain.fill
  wifi = "􀙇",
  sound = "􀊩",
  battery = "􀛨",
  copied = "􀉄",
}

local function font(style, size, family)
  return {
    family = family or settings.font.text,
    style = settings.font.style_map[style],
    size = size,
  }
end

M.font = {
  title = font("Bold", 13.0),
  body = font("Regular", 13.0),
  mono = font("Regular", 12.0, settings.font.numbers),
  section = font("Semibold", 11.0),
}

-- Transparent item background: fixes the cell height and doubles as the
-- hover highlight for interactive rows.
local function cell(height)
  return {
    drawing = true,
    color = colors.transparent,
    height = height,
    corner_radius = 6,
    border_width = 0,
  }
end

local function base(parent, name, props)
  props.position = "popup." .. parent.name
  props.width = props.width or ROW_W
  props.padding_left = props.padding_left or INSET
  props.padding_right = props.padding_right or INSET
  if name then return sbar.add("item", name, props) end
  return sbar.add("item", props)
end

-- Title row: glyph + title on the left, state on the right.
function M.header(parent, opts)
  local title = opts.glyph and (opts.glyph .. "  " .. opts.title) or opts.title
  return base(parent, opts.name, {
    icon = {
      string = title,
      font = M.font.title,
      color = c.text,
      width = ROW_W - 120,
      padding_left = PAD,
      padding_right = 0,
      align = "left",
    },
    label = {
      string = opts.state or "",
      font = opts.state_mono and M.font.mono or M.font.body,
      color = opts.state_color or c.secondary,
      width = 120,
      padding_left = 0,
      padding_right = PAD,
      align = "right",
      max_chars = 16,
    },
    background = cell(HEADER_H),
  })
end

-- Hairline rule, aligned with the text column.
function M.separator(parent, name)
  return base(parent, name, {
    width = M.WIDTH - 2 * (INSET + PAD),
    padding_left = INSET + PAD,
    padding_right = INSET + PAD,
    icon = { drawing = false },
    label = { drawing = false },
    background = {
      drawing = true,
      color = c.separator,
      height = 1,
      corner_radius = 0,
      border_width = 0,
    },
  })
end

-- Small grey section heading ("Output", "Exit node").
function M.section(parent, title, name)
  return base(parent, name, {
    icon = {
      string = title,
      font = M.font.section,
      color = c.tertiary,
      padding_left = PAD,
      padding_right = 0,
    },
    label = { drawing = false },
    background = cell(22),
  })
end

-- Key/value row. opts: value, mono, max_chars, value_color, name.
function M.row(parent, key, opts)
  opts = opts or {}
  return base(parent, opts.name, {
    icon = {
      string = key,
      font = M.font.body,
      color = c.secondary,
      width = KEY_W,
      padding_left = PAD,
      padding_right = 0,
      align = "left",
    },
    label = {
      string = opts.value or "…",
      font = opts.mono and M.font.mono or M.font.body,
      color = opts.value_color or c.text,
      width = ROW_W - KEY_W,
      padding_left = 0,
      padding_right = PAD,
      align = "right",
      max_chars = opts.max_chars or 22,
    },
    background = cell(ROW_H),
  })
end

-- Checkable row (exit node, output device). opts: checked, name, click_script.
function M.choice(parent, text, opts)
  opts = opts or {}
  return base(parent, opts.name, {
    icon = {
      string = M.glyph.check,
      font = M.font.title,
      color = opts.checked and c.accent or colors.transparent,
      width = CHECK_W + PAD,
      padding_left = PAD,
      padding_right = 0,
      align = "left",
    },
    label = {
      string = text,
      font = M.font.body,
      color = c.text,
      width = ROW_W - CHECK_W - PAD,
      padding_left = 0,
      padding_right = PAD,
      align = "left",
      max_chars = 30,
    },
    background = cell(ROW_H),
    click_script = opts.click_script,
  })
end

-- Empty breathing room (bottom of a popup).
function M.spacer(parent, name, height)
  return base(parent, name, {
    icon = { drawing = false },
    label = { drawing = false },
    background = cell(height or 8),
  })
end

-- Hover-bind popup children; `interactive` rows also get the highlight pill.
local function highlight(on)
  return function(env)
    sbar.set(env.NAME, { background = { color = on and c.hover or colors.transparent } })
  end
end
local hl_on, hl_off = highlight(true), highlight(false)

function M.bind(h, items, interactive)
  for _, item in ipairs(items) do
    if interactive then h.bind(item, hl_on, hl_off) else h.bind(item) end
  end
end

return M
