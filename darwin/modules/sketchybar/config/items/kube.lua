local colors = require("colors")
local settings = require("settings")
local hover = require("helpers.hover")

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

local ctx_line = sbar.add("item", {
  position = "popup." .. kube.name,
  icon = { string = "Context:", width = 80, align = "left" },
  label = { string = "…", width = 220, align = "right", max_chars = 30 },
})
local status_line = sbar.add("item", {
  position = "popup." .. kube.name,
  icon = { string = "Status:", width = 80, align = "left" },
  label = { string = "…", width = 220, align = "right" },
})
local server_line = sbar.add("item", {
  position = "popup." .. kube.name,
  icon = { string = "Server:", width = 80, align = "left" },
  label = { string = "…", width = 220, align = "right", max_chars = 30 },
})

local function refresh()
  sbar.exec(ENV .. "kubectl config current-context 2>/dev/null", function(ctx)
    ctx = (ctx or ""):gsub("%s+$", "")
    if ctx == "" then
      kube:set({ icon = { color = colors.grey }, label = { string = "none", color = colors.grey } })
      ctx_line:set({ label = "None" }); status_line:set({ label = "No context" }); server_line:set({ drawing = false })
      return
    end
    local short = ctx:sub(1, MAXLEN) .. (#ctx > MAXLEN and "…" or "")
    ctx_line:set({ label = ctx })
    sbar.exec(ENV .. "kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null", function(server)
      server = (server or ""):gsub("%s+$", "")
      server_line:set({ drawing = server ~= "", label = server })
    end)
    sbar.exec(ENV .. "kubectl get --raw /healthz --request-timeout=2s 2>/dev/null", function(health)
      local ok = (health or ""):gsub("%s+", "") == "ok"
      local color = ok and colors.green or colors.red
      kube:set({ icon = { color = color }, label = { string = short, color = colors.grey } })
      status_line:set({ label = ok and "Connected" or "Disconnected", color = color })
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
kube_hover.bind(ctx_line)
kube_hover.bind(status_line)
kube_hover.bind(server_line)

sbar.add("bracket", "kube.bracket", { kube.name }, { background = { color = colors.bg1 } })
sbar.add("item", "kube.padding", { position = "right", width = settings.group_paddings })
