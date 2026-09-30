local colors = require("colors")
local settings = require("settings")
local hover = require("helpers.hover")
local popup = require("helpers.popup")

local ICON = "󱃾"
local MAXLEN = 12
local ENV = 'export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"; '
  .. 'export PATH="/etc/profiles/per-user/mattias/bin:/opt/homebrew/bin:${KREW_ROOT:-$HOME/.krew}/bin:$PATH"; '

local kube = sbar.add("item", "kube", {
  position = "right",
  icon = { string = ICON, color = colors.grey, font = { family = "JetBrainsMono Nerd Font", style = "Bold", size = 16.0 } },
  label = { string = "…", color = colors.grey, max_chars = MAXLEN },
  update_freq = 30,
  popup = { align = "center" },
})

local c = colors.popup
local header = popup.header(kube, { glyph = popup.glyph.kube, title = "Kubernetes", state = "…" })
local header_sep = popup.separator(kube)
local ctx_line = popup.row(kube, "Context", { max_chars = 20 })
local server_line = popup.row(kube, "API server", { mono = true, max_chars = 20 })
local bottom = popup.spacer(kube)

local function refresh()
  sbar.exec(ENV .. "kubectl config current-context 2>/dev/null", function(ctx)
    ctx = (ctx or ""):gsub("%s+$", "")
    if ctx == "" then
      kube:set({ icon = { color = colors.grey }, label = { string = "none", color = colors.grey } })
      header:set({ label = { string = "No context", color = c.secondary } })
      ctx_line:set({ label = { string = "None", color = c.secondary } })
      server_line:set({ drawing = false })
      return
    end
    local short = ctx:sub(1, MAXLEN) .. (#ctx > MAXLEN and "…" or "")
    ctx_line:set({ label = { string = ctx, color = c.text } })
    sbar.exec(ENV .. "kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null", function(server)
      server = (server or ""):gsub("%s+$", "")
      server_line:set({ drawing = server ~= "", label = server })
    end)
    sbar.exec(ENV .. "kubectl get --raw /healthz --request-timeout=2s 2>/dev/null", function(health)
      local ok = (health or ""):gsub("%s+", "") == "ok"
      local color = ok and colors.green or colors.red
      kube:set({ icon = { color = color }, label = { string = short, color = colors.grey } })
      header:set({ label = { string = ok and "Connected" or "Unreachable", color = ok and c.green or c.red } })
    end)
  end)
end

kube:subscribe({ "routine", "forced", "system_woke" }, refresh)

local kube_hover = hover(
  function() kube:set({ popup = { drawing = true } }); refresh() end,
  function() kube:set({ popup = { drawing = false } }) end
)
kube:subscribe("mouse.entered", kube_hover.enter)
kube:subscribe("mouse.exited", kube_hover.leave)
popup.bind(kube_hover, { header, header_sep, ctx_line, server_line, bottom })

sbar.add("bracket", "kube.bracket", { kube.name }, { background = { color = colors.bg1 } })
sbar.add("item", "kube.padding", { position = "right", width = settings.group_paddings })
