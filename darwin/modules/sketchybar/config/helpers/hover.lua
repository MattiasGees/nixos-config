-- Uniform hover-to-reveal behaviour for popups.
--
-- Opens a popup after a short delay when the pointer is over the item
-- (cancelled if it leaves first, so brushing past does not pop it open), and
-- closes it after a short grace delay once the pointer is over neither the
-- item nor the popup. The grace period + binding the popup's own items lets
-- you move down into an interactive popup (device switcher, exit-node picker,
-- speed test, media controls) without it closing under you — we do NOT rely
-- on mouse.exited.global, which is unreliable here.
--
--   local hover = require("helpers.hover")
--   local h = hover(open_fn, close_fn)   -- open_fn opens+populates; close_fn hides
--   item:subscribe("mouse.entered", h.enter)
--   item:subscribe("mouse.exited",  h.leave)
--   h.bind(popup_child)                  -- for every popup item you can mouse onto
--   h.bind(row, on_enter, on_exit)       -- optionally with extra hover callbacks
--
-- When several bar items share one popup (volume/wifi), reuse the same `h` on
-- each so they share the over-state.

local OPEN_DELAY = 0.35
local CLOSE_DELAY = 0.35

return function(open_fn, close_fn)
  local over = false
  -- sbar.delay can't be cancelled, so only the most recently scheduled timer
  -- acts; sweeping the pointer along the bar would otherwise run open/close
  -- once per item crossed.
  local latest = 0

  local function schedule(delay, fn)
    latest = latest + 1
    local id = latest
    sbar.delay(delay, function()
      if id == latest then fn() end
    end)
  end

  local function try_open()
    if over then open_fn() end
  end

  local function try_close()
    if not over then close_fn() end
  end

  local function enter()
    over = true
    schedule(OPEN_DELAY, try_open)
  end

  local function leave()
    over = false
    schedule(CLOSE_DELAY, try_close)
  end

  local api = { enter = enter, leave = leave }

  -- Keep the popup alive while the pointer is over one of its own items.
  -- Optional on_enter/on_exit(env) run alongside (e.g. a row highlight);
  -- SbarLua keeps one callback per item+event, so they must share this one.
  function api.bind(item, on_enter, on_exit)
    item:subscribe("mouse.entered", function(env)
      over = true
      if on_enter then on_enter(env) end
    end)
    item:subscribe("mouse.exited", function(env)
      leave()
      if on_exit then on_exit(env) end
    end)
  end

  return api
end
