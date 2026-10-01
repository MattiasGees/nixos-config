local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local hover = require("helpers.hover")
local popup = require("helpers.popup")

-- Execute the event provider binary which provides the event "cpu_update" for
-- the cpu load data, which is fired every 2.0 seconds.
sbar.exec("killall cpu_load >/dev/null; $CONFIG_DIR/helpers/event_providers/cpu_load/bin/cpu_load cpu_update 2.0")

local cpu = sbar.add("graph", "widgets.cpu" , 42, {
  position = "right",
  graph = { color = colors.blue },
  background = {
    height = 22,
    color = { alpha = 0 },
    border_color = { alpha = 0 },
    drawing = true,
  },
  icon = { string = icons.cpu },
  label = {
    string = "cpu ??%",
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
    align = "right",
    padding_right = 0,
    width = 0,
    y_offset = 4
  },
  padding_right = settings.paddings + 6,
  popup = { align = "center" },
})

local c = colors.popup
local TOP_N = 5
local PROC_KEY_W = 190

local header = popup.header(cpu, { glyph = popup.glyph.cpu, title = "CPU", state = "…", state_mono = true })
local header_sep = popup.separator(cpu)
local user_line = popup.row(cpu, "User", { mono = true })
local sys_line = popup.row(cpu, "System", { mono = true })
local load_line = popup.row(cpu, "Load average", { mono = true })
local mem_line = popup.row(cpu, "Memory pressure")
local procs_sep = popup.separator(cpu)
local procs_title = popup.section(cpu, "Top processes")
local procs = {}
for i = 1, TOP_N do
  procs[i] = popup.row(cpu, "", {
    name = "widgets.cpu.proc." .. i,
    mono = true,
    value = "",
    key_width = PROC_KEY_W,
    key_max_chars = 26,
    max_chars = 8,
  })
  procs[i]:set({ icon = { color = c.text }, click_script = "open -a 'Activity Monitor'" })
end
local bottom = popup.spacer(cpu)

-- kern.memorystatus_vm_pressure_level is the level Activity Monitor's memory
-- pressure graph uses; memory_pressure -Q only reports the free percentage.
local PRESSURE = {
  ["1"] = { "Normal", c.text },
  ["2"] = { "Warn", colors.orange },
  ["4"] = { "Critical", colors.red },
}

-- Line 1: load average (braces stripped so sbar.exec doesn't try to read the
-- output as JSON), line 2: pressure level, line 3: free %, then the
-- top processes as "<pcpu> <count> <command>", summed per command name so
-- e.g. five mdworker_shared helpers take one row. ps %CPU is a decaying
-- average, but it answers instantly (top -l 2 needs a second to take two samples).
local DETAILS = "sysctl -n vm.loadavg kern.memorystatus_vm_pressure_level | tr -d '{}';"
  .. " memory_pressure -Q | awk '/percentage/{print $NF}';"
  .. " ps -Aceo pcpu=,comm= | awk '{p=$1; $1=\"\"; sub(/^ /, \"\"); s[$0]+=p; n[$0]++}"
  .. " END{for (k in s) printf \"%.1f %d %s\\n\", s[k], n[k], k}' | sort -rn | head -" .. TOP_N

local is_open = false
local last = { total = "??", user = "??", sys = "??" }

local function set_loads()
  header:set({ label = last.total .. "%" })
  user_line:set({ label = last.user .. "%" })
  sys_line:set({ label = last.sys .. "%" })
end

local function refresh_details()
  sbar.exec(DETAILS, function(out)
    local lines = {}
    for line in (out or ""):gmatch("[^\n]+") do lines[#lines + 1] = line end

    local loadavg = (lines[1] or ""):match("([%d%.]+ [%d%.]+ [%d%.]+)")
    load_line:set({ label = loadavg or "—" })

    local level = PRESSURE[(lines[2] or ""):match("%d+")]
    local free = (lines[3] or ""):match("%d+%%")
    mem_line:set({
      label = {
        string = level and (level[1] .. (free and (" · " .. free .. " free") or "")) or "—",
        color = level and level[2] or c.secondary,
      },
    })

    for i = 1, TOP_N do
      local pcpu, count, comm = (lines[i + 3] or ""):match("^([%d%.]+) (%d+) (.+)$")
      procs[i]:set({
        drawing = comm ~= nil,
        icon = comm and (count == "1" and comm or (comm .. " ×" .. count)) or "",
        label = pcpu and (pcpu .. "%") or "",
      })
    end
  end)
end

cpu:subscribe("cpu_update", function(env)
  last = { total = tonumber(env.total_load), user = tonumber(env.user_load), sys = tonumber(env.sys_load) }
  local load = tonumber(env.total_load)
  cpu:push({ load / 100. })

  local color = colors.blue
  if load > 30 then
    if load < 60 then
      color = colors.yellow
    elseif load < 80 then
      color = colors.orange
    else
      color = colors.red
    end
  end

  cpu:set({
    graph = { color = color },
    label = "cpu " .. env.total_load .. "%",
  })

  if is_open then
    set_loads()
    refresh_details()
  end
end)

cpu:subscribe("mouse.clicked", function(env)
  sbar.exec("open -a 'Activity Monitor'")
end)

local cpu_hover = hover(
  function()
    is_open = true
    set_loads()
    refresh_details()
    cpu:set({ popup = { drawing = true } })
  end,
  function()
    is_open = false
    cpu:set({ popup = { drawing = false } })
  end
)
cpu:subscribe("mouse.entered", cpu_hover.enter)
cpu:subscribe("mouse.exited", cpu_hover.leave)
popup.bind(cpu_hover, { header, header_sep, user_line, sys_line, load_line, mem_line, procs_sep, procs_title, bottom })
popup.bind(cpu_hover, procs, true)

-- Background around the cpu item
sbar.add("bracket", "widgets.cpu.bracket", { cpu.name }, {
  background = { color = colors.bg1 }
})

-- Background around the cpu item
sbar.add("item", "widgets.cpu.padding", {
  position = "right",
  width = settings.group_paddings
})
