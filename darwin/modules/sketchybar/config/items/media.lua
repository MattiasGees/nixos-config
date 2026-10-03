local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local hover = require("helpers.hover")
local popup = require("helpers.popup")

local c = colors.popup

-- Spotify now-playing. sketchybar's media_change event no longer fires on
-- recent macOS, so state comes from Spotify's AppleScript dictionary
-- (helpers/spotify.applescript), refreshed on Spotify's own playback
-- notification and once a second while the popup is open.

local QUERY = 'osascript "$CONFIG_DIR/helpers/spotify.applescript"'
local function spotify(cmd)
  return "osascript -e 'tell application \"Spotify\" to " .. cmd .. "'"
end

local ART_PX = 640            -- Spotify artwork urls are 640x640
local BAR_COVER = 24
local COVER = 56
local INSET = 6               -- matches helpers/popup.lua
local PAD = 10
local ROW_W = popup.ROW_W
local TEXT_X = PAD + COVER + 12
local BAR_INSET = 16          -- progress bar / times inset, like the volume slider
local BAR_W = popup.WIDTH - 2 * BAR_INSET
local CONTROLS_W = 168
local TEXT_PAD = 3            -- padding_left of the bar's title/artist items
local ARTIST_COLOR = colors.with_alpha(colors.white, 0.6)

local tmp = os.getenv("TMPDIR") or "/tmp"
if not tmp:match("/$") then tmp = tmp .. "/" end
local ART_DIR = tmp .. "sketchybar-spotify"

sbar.add("event", "spotify_change", "com.spotify.client.PlaybackStateChanged")

local media_cover = sbar.add("item", {
  position = "right",
  background = {
    image = { scale = BAR_COVER / ART_PX, corner_radius = 5 },
    color = colors.transparent,
  },
  label = { drawing = false },
  icon = { drawing = false },
  drawing = false,
  updates = true,
  popup = { align = "center" },
})

-- Title and artist are both zero-width so they stack on top of each other;
-- media_padding reserves room for the wider of the two while they're shown
-- (see animate_detail).
local media_artist = sbar.add("item", {
  position = "right",
  drawing = false,
  padding_left = TEXT_PAD,
  padding_right = 0,
  width = 0,
  icon = { drawing = false },
  label = {
    width = 0,
    font = { size = 9 },
    color = ARTIST_COLOR,
    max_chars = 18,
    y_offset = 6,
  },
})

local media_title = sbar.add("item", {
  position = "right",
  drawing = false,
  padding_left = TEXT_PAD,
  padding_right = 0,
  width = 0,
  icon = { drawing = false },
  label = {
    font = { size = 11 },
    width = 0,
    max_chars = 16,
    y_offset = -5,
  },
})

local media_padding = sbar.add("item", {
  position = "right",
  drawing = false,
  width = settings.group_paddings + TEXT_PAD,
})

-- Popup rows, top to bottom: cover + title/artist, progress bar, times,
-- transport controls.
local in_popup = "popup." .. media_cover.name

-- Cover is the row's background image (drawn at its left edge); the title
-- (icon) and artist (label) sit to its right, stacked via y_offset. A fixed
-- text width is the text's whole length (paddings are only a draw offset),
-- so the zero-width icon takes no room and both start TEXT_X in.
local track_row = sbar.add("item", {
  position = in_popup,
  width = ROW_W,
  padding_left = INSET,
  padding_right = INSET,
  icon = {
    font = popup.font.title,
    color = c.text,
    width = 0,
    align = "left",
    padding_left = TEXT_X,
    padding_right = 0,
    y_offset = 9,
    max_chars = 24,       -- ~ROW_W - TEXT_X - PAD of SF Pro 13
  },
  label = {
    font = popup.font.body,
    color = c.secondary,
    width = ROW_W,
    align = "left",
    padding_left = TEXT_X,
    padding_right = 0,
    y_offset = -9,
    max_chars = 24,       -- ~ROW_W - TEXT_X - PAD of SF Pro 13
  },
  background = {
    drawing = true,
    color = colors.transparent,
    height = COVER + 20,
    border_width = 0,
    image = { scale = COVER / ART_PX, corner_radius = 6, border_width = 0, padding_left = PAD },
  },
})

-- Click to seek.
local progress = sbar.add("slider", BAR_W, {
  position = in_popup,
  padding_left = BAR_INSET,
  padding_right = BAR_INSET,
  icon = { drawing = false },
  label = { drawing = false },
  slider = {
    highlight_color = c.secondary,
    background = { height = 4, corner_radius = 2, color = 0x33ffffff },
    knob = { drawing = false },
  },
  background = { drawing = true, color = colors.transparent, height = 16, border_width = 0 },
})

local times = sbar.add("item", {
  position = in_popup,
  width = BAR_W,
  padding_left = BAR_INSET,
  padding_right = BAR_INSET,
  icon = {
    font = popup.font.mono,
    color = c.tertiary,
    width = BAR_W / 2,
    align = "left",
    padding_left = 0,
    padding_right = 0,
  },
  label = {
    font = popup.font.mono,
    color = c.tertiary,
    width = BAR_W / 2,
    align = "right",
    padding_left = 0,
    padding_right = 0,
  },
  background = { drawing = true, color = colors.transparent, height = 16, border_width = 0 },
})

-- Popup items each own a full row, so three side-by-side buttons are one
-- invisible slider: the click's PERCENTAGE picks the third that was hit.
-- The glyphs are a zero-width icon (so the slider starts at the same x),
-- centred over the slider: center-aligned on its own length, which counts
-- the paddings, so padding_left = CONTROLS_W lands it mid-slider.
local function controls_glyphs(playing)
  local em = " "
  return icons.media.back .. em .. em .. (playing and icons.media.pause or icons.media.play)
    .. em .. em .. icons.media.forward
end

local controls = sbar.add("slider", CONTROLS_W, {
  position = in_popup,
  padding_left = (popup.WIDTH - CONTROLS_W) / 2,
  padding_right = (popup.WIDTH - CONTROLS_W) / 2,
  icon = {
    string = controls_glyphs(false),
    font = { family = settings.font.text, style = settings.font.style_map["Regular"], size = 18.0 },
    color = c.text,
    width = 0,
    align = "center",
    padding_left = CONTROLS_W,
    padding_right = 0,
  },
  label = { drawing = false },
  slider = {
    highlight_color = colors.transparent,
    background = { height = 30, color = colors.transparent },
    knob = { drawing = false },
  },
  background = { drawing = true, color = colors.transparent, height = 40, border_width = 0 },
})

local bottom = popup.spacer(media_cover, nil, 6)

local function drawn_width(item)
  local w = 0
  for _, rect in pairs(item:query().bounding_rects or {}) do
    w = math.max(w, rect.size[1])
  end
  return w
end

-- sketchybar can't measure text, but a drawn label's bounding rect is its
-- width. While hidden the labels are revealed transparently to measure them;
-- the items are zero-width, so nothing else moves.
local shown = false
local function text_width()
  if not shown then
    for _, item in ipairs({ media_artist, media_title }) do
      item:set({ label = { width = "dynamic", color = colors.transparent } })
    end
  end
  local w = math.max(drawn_width(media_artist), drawn_width(media_title))
  if not shown then
    media_artist:set({ label = { width = 0, color = ARTIST_COLOR } })
    media_title:set({ label = { width = 0, color = colors.white } })
  end
  return w
end

local interrupt = 0
local function animate_detail(detail)
  if (not detail) then interrupt = interrupt - 1 end
  if interrupt > 0 and (not detail) then return end

  local reserve = detail and text_width() or 0
  shown = detail
  sbar.animate("tanh", 30, function()
    media_artist:set({ label = { width = detail and "dynamic" or 0 } })
    media_title:set({ label = { width = detail and "dynamic" or 0 } })
    media_padding:set({ width = settings.group_paddings + TEXT_PAD + reserve })
  end)
end

local function clock(s)
  return string.format("%d:%02d", s // 60, s % 60)
end

-- Artwork is fetched once per track into a per-track file (sketchybar caches
-- images by path) and the previous track's file is removed.
local art_track
local function load_artwork(id, url)
  if id == art_track then return end
  art_track = id
  if url == "" then return end

  local file = ART_DIR .. "/" .. id:gsub("[^%w]", "_") .. ".jpg"
  sbar.exec("mkdir -p '" .. ART_DIR .. "' && find '" .. ART_DIR .. "' -name '*.jpg' ! -path '" .. file .. "' -delete; "
    .. "[ -s '" .. file .. "' ] || { curl -sfL --max-time 10 -o '" .. file .. ".part' '" .. url .. "' && mv '" .. file .. ".part' '" .. file .. "'; }; "
    .. "[ -s '" .. file .. "' ] && echo ok", function(out)
    if art_track ~= id or not (out or ""):match("ok") then return end
    media_cover:set({ background = { image = { string = file } } })
    track_row:set({ background = { image = { string = file } } })
  end)
end

local track
local duration = 0
local open_gen = 0 -- bumped when the popup closes; stops the refresh loop
local function render(out)
  local f = {}
  for line in (((type(out) == "string" and out) or "") .. "\n"):gmatch("(.-)\n") do f[#f + 1] = line end
  local state = f[1]

  if state ~= "playing" and state ~= "paused" then
    track = nil
    open_gen = open_gen + 1
    for _, item in ipairs({ media_cover, media_artist, media_title, media_padding }) do
      item:set({ drawing = false })
    end
    media_cover:set({ popup = { drawing = false } })
    return
  end

  local title, artist, url, id = f[2] or "", f[3] or "", f[4] or "", f[7] or ""
  local position = tonumber(f[5]) or 0
  duration = tonumber(f[6]) or 0

  media_cover:set({ drawing = true })
  media_padding:set({ drawing = true })
  media_artist:set({ drawing = true, label = artist })
  media_title:set({ drawing = true, label = title })
  track_row:set({ icon = title, label = artist })
  controls:set({ icon = controls_glyphs(state == "playing") })
  progress:set({ slider = { percentage = duration > 0 and math.floor(position * 100 / duration) or 0 } })
  times:set({ icon = clock(position), label = clock(duration) })
  load_artwork(id, url)

  -- Flash the title/artist in the bar when a new track starts.
  if id ~= track then
    track = id
    if state == "playing" then
      animate_detail(true)
      interrupt = interrupt + 1
      sbar.delay(5, animate_detail)
    end
  end
end

local function refresh()
  sbar.exec(QUERY, render)
end

media_cover:subscribe("spotify_change", refresh)
refresh()

progress:subscribe("mouse.clicked", function(env)
  local pct = tonumber(env.PERCENTAGE)
  if not pct or duration <= 0 then return end
  sbar.exec(spotify("set player position to " .. math.floor(duration * pct / 100)), refresh)
end)

controls:subscribe("mouse.clicked", function(env)
  local pct = tonumber(env.PERCENTAGE) or 50
  local cmd = pct < 100 / 3 and "previous track" or pct < 200 / 3 and "playpause" or "next track"
  sbar.exec(spotify(cmd), refresh)
end)

-- Keep the progress bar moving while the popup is open.
local function tick(gen)
  if gen ~= open_gen then return end
  refresh()
  sbar.delay(1, function() tick(gen) end)
end

local media_hover = hover(
  function()
    if media_cover:query().popup.drawing == "on" then return end
    open_gen = open_gen + 1
    media_cover:set({ popup = { drawing = true } })
    tick(open_gen)
  end,
  function()
    open_gen = open_gen + 1
    media_cover:set({ popup = { drawing = false } })
  end
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

popup.bind(media_hover, { track_row, progress, times, controls, bottom })
