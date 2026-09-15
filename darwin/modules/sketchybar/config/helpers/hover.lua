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
--
-- When several bar items share one popup (volume/wifi), reuse the same `h` on
-- each so they share the over-state.

local OPEN_DELAY = 0.35
local CLOSE_DELAY = 0.35

return function(open_fn, close_fn)
  local over = false

  local function try_open()
    if over then open_fn() end
  end

  local function try_close()
    if not over then close_fn() end
  end

  local function enter()
    over = true
    sbar.delay(OPEN_DELAY, try_open)
  end

  local function leave()
    over = false
    sbar.delay(CLOSE_DELAY, try_close)
  end

  local api = { enter = enter, leave = leave }

  -- Keep the popup alive while the pointer is over one of its own items.
  function api.bind(item)
    item:subscribe("mouse.entered", function() over = true end)
    item:subscribe("mouse.exited", leave)
  end

  return api
end
