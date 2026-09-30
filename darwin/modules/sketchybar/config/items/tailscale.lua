local colors = require("colors")
local settings = require("settings")
local hover = require("helpers.hover")
local popup = require("helpers.popup")

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

local c = colors.popup

local header = popup.header(tailscale, { glyph = popup.glyph.tailscale, title = "Tailscale", state = "…" })
local header_sep = popup.separator(tailscale)
local tailnet_line = popup.row(tailscale, "Tailnet", { max_chars = 20 })
local ip_line = popup.row(tailscale, "IP address", { mono = true })
local exit_line = popup.row(tailscale, "Exit node", { max_chars = 20 })
local bottom = popup.spacer(tailscale)

-- Current exit node, remembered for the picker's checkmark.
local current_exit = nil

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
      header:set({ label = { string = "Connected", color = c.green } })
      header_sep:set({ drawing = true })
      tailnet_line:set({ drawing = true, label = (out.CurrentTailnet and out.CurrentTailnet.Name) or "Unknown" })
      local ip = out.TailscaleIPs and out.TailscaleIPs[1]
      ip_line:set({ drawing = ip ~= nil, label = ip or "" })
      exit_line:set({
        drawing = true,
        label = { string = exit_active and exit_name or "None", color = exit_active and c.text or c.secondary },
      })
      current_exit = exit_active and exit_name or nil
    else
      tailscale:set({ icon = { string = GLYPH_SHIELD, color = COLOR_OFF } })
      header:set({ label = { string = "Off", color = c.secondary } })
      header_sep:set({ drawing = false })
      tailnet_line:set({ drawing = false })
      ip_line:set({ drawing = false })
      exit_line:set({ drawing = false })
      current_exit = nil
    end
  end)
end

local ts_hover = hover(
  function()
    bottom:set({ drawing = true })
    tailscale:set({ popup = { drawing = true } })
    refresh()
  end,
  function() tailscale:set({ popup = { drawing = false } }); sbar.remove('/tailscale.exit\\..*/') end
)

-- Build the right-click exit-node picker below the status rows: "None" and
-- own nodes, then one representative Mullvad server for Belgium / UK / USA.
-- The active node gets a checkmark (Mullvad matched by country prefix).
local MULLVAD = {
  { prefix = "be", label = "Belgium" },
  { prefix = "gb", label = "United Kingdom" },
  { prefix = "us", label = "United States" },
}

local function show_exit_picker()
  sbar.remove('/tailscale.exit\\..*/')
  bottom:set({ drawing = false })

  local idx = 0
  local function add_entry(label, exit_arg, checked)
    idx = idx + 1
    local entry = popup.choice(tailscale, label, {
      name = "tailscale.exit." .. idx,
      checked = checked,
      click_script = TS .. " set --exit-node='" .. exit_arg .. "' >/dev/null 2>&1; "
        .. "sketchybar --set " .. tailscale.name .. " popup.drawing=off "
        .. "--remove '/tailscale.exit\\..*/' --trigger tailscale_update",
    })
    popup.bind(ts_hover, { entry }, true)
  end
  local function add_static(item) popup.bind(ts_hover, { item }) end

  add_static(popup.separator(tailscale, "tailscale.exit.sep1"))
  add_static(popup.section(tailscale, "Exit node", "tailscale.exit.head1"))
  add_entry("None", "", current_exit == nil)

  sbar.exec(TS .. " exit-node list 2>/dev/null", function(out)
    if type(out) ~= "string" then
      add_static(popup.spacer(tailscale, "tailscale.exit.end"))
      return
    end
    local mullvad = {}
    for line in out:gmatch("[^\r\n]+") do
      local ip, host = line:match("^%s*(%S+)%s+(%S+)")
      if ip and host and ip:match("^%d") and host ~= "HOSTNAME" then
        local name = short_name(host)
        if not host:find("mullvad") then
          add_entry(name, ip, name == current_exit)
        else
          local cc = host:match("^(%a%a)%-")
          if cc and not mullvad[cc] then mullvad[cc] = ip end
        end
      end
    end

    local cur_cc = current_exit and current_exit:match("^(%a%a)%-.*wg")
    local any = false
    for _, m in ipairs(MULLVAD) do
      if mullvad[m.prefix] then
        if not any then
          add_static(popup.separator(tailscale, "tailscale.exit.sep2"))
          add_static(popup.section(tailscale, "Mullvad", "tailscale.exit.head2"))
          any = true
        end
        add_entry(m.label, mullvad[m.prefix], cur_cc == m.prefix)
      end
    end
    add_static(popup.spacer(tailscale, "tailscale.exit.end"))
  end)

  tailscale:set({ popup = { drawing = true } })
end

-- Left-click: toggle the connection up/down.
local function toggle_connection()
  sbar.exec(TS .. " status --json 2>/dev/null", function(out)
    local running = type(out) == "table" and out.BackendState == "Running"
    local cmd = running and (TS .. " down") or (TS .. " up")
    header:set({ label = { string = running and "Disconnecting…" or "Connecting…", color = c.secondary } })
    sbar.exec(cmd .. " 2>/dev/null", function() sbar.delay(1, refresh) end)
  end)
end

tailscale:subscribe({ "routine", "forced", "system_woke", "tailscale_update" }, refresh)

tailscale:subscribe("mouse.entered", ts_hover.enter)
tailscale:subscribe("mouse.exited", ts_hover.leave)
popup.bind(ts_hover, { header, header_sep, tailnet_line, ip_line, exit_line, bottom })

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
