local colors = require("colors")
local settings = require("settings")
local hover = require("helpers.hover")

local TS = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
local COLOR_ON = 0xff08f7fe   -- cyan
local COLOR_OFF = colors.grey
local ICON_FONT = { family = "JetBrainsMono Nerd Font", style = "Bold", size = 16.0 }
local GLYPH_SHIELD = "󰸳"       -- connected / off
local GLYPH_EXIT = "󰖟"         -- exit node active (globe)

-- Custom event so the exit-node picker can trigger an immediate refresh.
sbar.add("event", "tailscale_update")

local tailscale = sbar.add("item", "tailscale", {
  position = "right",
  icon = { string = GLYPH_SHIELD, color = COLOR_OFF, font = ICON_FONT },
  label = { drawing = false },
  update_freq = 10,
  popup = { align = "center" },
})

local POPUP = "popup." .. tailscale.name

local status_line = sbar.add("item", {
  position = POPUP,
  icon = { string = "Status:", width = 90, align = "left" },
  label = { string = "…", width = 160, align = "right" },
})
local tailnet_line = sbar.add("item", {
  position = POPUP,
  icon = { string = "Tailnet:", width = 90, align = "left" },
  label = { string = "…", width = 160, align = "right" },
})
local ip_line = sbar.add("item", {
  position = POPUP,
  icon = { string = "IP:", width = 90, align = "left" },
  label = { string = "…", width = 160, align = "right" },
})
local exit_line = sbar.add("item", {
  position = POPUP,
  icon = { string = "Exit node:", width = 90, align = "left" },
  label = { string = "…", width = 160, align = "right", max_chars = 22 },
})

-- Short display name for a peer DNSName ("hetzner-1.tailnet.ts.net." -> "hetzner-1")
local function short_name(dns)
  return (dns or ""):gsub("%.$", ""):gsub("%..*$", "")
end

local function refresh()
  sbar.exec(TS .. " status --json 2>/dev/null", function(out)
    -- SbarLua decodes JSON stdout into a Lua table (not a string).
    local running = type(out) == "table" and out.BackendState == "Running"

    -- Detect an active exit node (a peer with ExitNode = true).
    local exit_active, exit_name = false, nil
    if running and type(out.Peer) == "table" then
      for _, p in pairs(out.Peer) do
        if p.ExitNode then
          exit_active = true
          exit_name = short_name(p.DNSName)
          break
        end
      end
    end

    if running then
      local glyph = exit_active and GLYPH_EXIT or GLYPH_SHIELD
      tailscale:set({ icon = { string = glyph, color = COLOR_ON } })
      status_line:set({ label = "Connected" })
      tailnet_line:set({ drawing = true, label = (out.CurrentTailnet and out.CurrentTailnet.Name) or "?" })
      local ip = out.TailscaleIPs and out.TailscaleIPs[1]
      ip_line:set({ drawing = ip ~= nil, label = ip or "" })
      exit_line:set({ drawing = true, label = exit_active and exit_name or "None" })
    else
      tailscale:set({ icon = { string = GLYPH_SHIELD, color = COLOR_OFF } })
      status_line:set({ label = "Off" })
      tailnet_line:set({ drawing = false })
      ip_line:set({ drawing = false })
      exit_line:set({ drawing = false })
    end
  end)
end

local ts_hover = hover(
  function() tailscale:set({ popup = { drawing = true } }); refresh() end,
  function() tailscale:set({ popup = { drawing = false } }); sbar.remove('/tailscale.exit\\..*/') end
)

-- Build the right-click exit-node picker. Own nodes first (★), then one
-- representative Mullvad server for Belgium / UK / USA, plus "None".
local function show_exit_picker()
  sbar.remove('/tailscale.exit\\..*/')

  local idx = 0
  local function add_entry(label, exit_arg)
    idx = idx + 1
    local entry = sbar.add("item", "tailscale.exit." .. idx, {
      position = POPUP,
      icon = { string = label, align = "left", padding_left = 8, padding_right = 8 },
      label = { drawing = false },
      click_script = TS .. " set --exit-node='" .. exit_arg .. "' >/dev/null 2>&1; "
        .. "sketchybar --set " .. tailscale.name .. " popup.drawing=off "
        .. "--remove '/tailscale.exit\\..*/' --trigger tailscale_update",
    })
    ts_hover.bind(entry)
  end

  add_entry("None (direct)", "")

  sbar.exec(TS .. " exit-node list 2>/dev/null", function(out)
    if type(out) ~= "string" then return end
    local be, gb, us
    for line in out:gmatch("[^\r\n]+") do
      local ip, host = line:match("^%s*(%S+)%s+(%S+)")
      if ip and host and ip:match("^%d") and host ~= "HOSTNAME" then
        if not host:find("mullvad") then
          add_entry("★ " .. short_name(host), ip)
        elseif not be and host:find("^be%-") then
          be = ip
        elseif not gb and host:find("^gb%-") then
          gb = ip
        elseif not us and host:find("^us%-") then
          us = ip
        end
      end
    end
    if be then add_entry("Mullvad: Belgium", be) end
    if gb then add_entry("Mullvad: UK", gb) end
    if us then add_entry("Mullvad: USA", us) end
  end)

  tailscale:set({ popup = { drawing = true } })
end

-- Left-click: toggle the connection up/down.
local function toggle_connection()
  sbar.exec(TS .. " status --json 2>/dev/null", function(out)
    local running = type(out) == "table" and out.BackendState == "Running"
    local cmd = running and (TS .. " down") or (TS .. " up")
    status_line:set({ label = running and "Disconnecting…" or "Connecting…" })
    sbar.exec(cmd .. " 2>/dev/null", function() sbar.delay(1, refresh) end)
  end)
end

tailscale:subscribe({ "routine", "forced", "system_woke", "tailscale_update" }, refresh)

tailscale:subscribe("mouse.entered", ts_hover.enter)
tailscale:subscribe("mouse.exited", ts_hover.leave)
ts_hover.bind(status_line)
ts_hover.bind(tailnet_line)
ts_hover.bind(ip_line)
ts_hover.bind(exit_line)

tailscale:subscribe("mouse.clicked", function(env)
  if env.BUTTON == "right" then
    show_exit_picker()
  else
    toggle_connection()
  end
end)

sbar.add("bracket", "tailscale.bracket", { tailscale.name }, {
  background = { color = colors.bg1 },
})
sbar.add("item", "tailscale.padding", { position = "right", width = settings.group_paddings })
