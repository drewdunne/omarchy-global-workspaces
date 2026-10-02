-- Global Workspaces: every monitor switches desktops together.
--
-- A desktop is one workspace on each monitor. Workspace IDs encode both:
--
--   id = desktop * 10 + monitor
--
-- Desktops are 0-9 (SUPER+1..9 and SUPER+0). Monitors are numbered 1-9 from
-- left to right the first time they are seen, so workspace 23 is desktop 2 on
-- the third monitor, and desktop 0 is plain workspaces 1-9.
--
-- Monitor numbers are remembered by output name, so unplugging and replugging
-- a screen brings its windows back to the same place.
--
-- Builds on the design and hotplug research by @amacieli in
-- https://github.com/omacom/omarchy/pull/12978.

local M = {}
GlobalWorkspaces = M

local DESKTOPS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 0 } -- keyboard order
local MAX_MONITORS = 9
local HOME_DESKTOP = 1

local state_home = os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")
local STATE_DIR = state_home .. "/omarchy/global-workspaces"
local STATE_FILE = STATE_DIR .. "/monitors"

-- omarchy-menu-keybindings evaluates the Hyprland config against a stub `hl`
-- whose every field is a callable table, just to collect bind descriptions.
-- Iterating stub objects never ends, so live state is only read when the
-- real API is present.
local LIVE = type(hl) == "table" and type(hl.version) == "function"

local digits = {}        -- monitor name -> 1..9
local rules = {}         -- monitor name -> workspace rule handles
local busy = false       -- true while we are switching monitors ourselves
local current_desktop = nil
local previous_desktop = nil

-- Workspace id math ----------------------------------------------------------

function M.desktop_of(id)
  if type(id) ~= "number" then return nil end
  id = math.tointeger(id)
  if not id or id < 1 or id > 99 or id % 10 == 0 then return nil end
  return id // 10, id % 10
end

function M.workspace_id(desktop, digit)
  return desktop * 10 + digit
end

local function valid_desktop(desktop)
  desktop = math.tointeger(tonumber(desktop))
  if desktop and desktop >= 0 and desktop <= 9 then return desktop end
  return nil
end

-- Monitor numbering ----------------------------------------------------------

local function load_digits()
  local loaded = {}
  local file = io.open(STATE_FILE, "r")
  if not file then return loaded end

  for line in file:lines() do
    local name, digit = line:match("^(.+)=([1-9])$")
    if name then loaded[name] = tonumber(digit) end
  end

  file:close()
  return loaded
end

local function save_digits()
  local names = {}
  for name in pairs(digits) do names[#names + 1] = name end
  table.sort(names)

  local tmp = STATE_FILE .. ".tmp"
  local file = io.open(tmp, "w")
  if not file then
    os.execute("mkdir -p '" .. STATE_DIR:gsub("'", "'\\''") .. "'")
    file = io.open(tmp, "w")
    if not file then return end
  end

  for _, name in ipairs(names) do
    file:write(name, "=", digits[name], "\n")
  end

  file:close()
  os.rename(tmp, STATE_FILE)
end

local function monitors_by_position()
  local list = {}
  for _, monitor in ipairs(hl.get_monitors()) do
    if not monitor.is_mirror then list[#list + 1] = monitor end
  end

  table.sort(list, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)

  return list
end

local function assign_digits(monitors)
  local changed = false

  -- A completely different set of screens (another desk, a new GPU) starts
  -- numbering from 1 again instead of inheriting stale numbers.
  local known = false
  for _, monitor in ipairs(monitors) do
    if digits[monitor.name] then known = true end
  end
  if not known and next(digits) ~= nil then
    digits = {}
    changed = true
  end

  local used = {}
  for _, digit in pairs(digits) do used[digit] = true end

  for _, monitor in ipairs(monitors) do
    if not digits[monitor.name] then
      for digit = 1, MAX_MONITORS do
        if not used[digit] then
          digits[monitor.name] = digit
          used[digit] = true
          changed = true
          break
        end
      end
    end
  end

  if changed then save_digits() end
end

-- Pin each monitor's workspaces to it and keep them alive while empty: a
-- monitor can only be switched without stealing focus to a workspace that
-- already exists.
local function ensure_rules(monitor)
  local digit = digits[monitor.name]
  if not digit then return end

  local existing = rules[monitor.name]
  if existing then
    for _, rule in ipairs(existing) do
      pcall(function() rule:set_enabled(true) end)
    end
    return
  end

  local list = {}
  for _, desktop in ipairs(DESKTOPS) do
    list[#list + 1] = hl.workspace_rule({
      workspace = tostring(M.workspace_id(desktop, digit)),
      monitor = monitor.name,
      persistent = true,
    })
  end
  rules[monitor.name] = list
end

-- Stop keeping a disconnected monitor's empty workspaces alive. Workspaces
-- with windows stay put until the monitor returns (or `gather` is used).
local function release_missing_monitors()
  local present = {}
  for _, monitor in ipairs(hl.get_monitors()) do present[monitor.name] = true end

  for name, list in pairs(rules) do
    if not present[name] then
      for _, rule in ipairs(list) do
        pcall(function() rule:set_enabled(false) end)
      end
    end
  end
end

local function prepare(runtime)
  local monitors = monitors_by_position()
  if #monitors == 0 then return nil end

  assign_digits(monitors)
  for _, monitor in ipairs(monitors) do ensure_rules(monitor) end

  -- Rules added after startup only create their workspaces on the next prop
  -- refresh; switching needs them now.
  if runtime then hl.exec_scheduled_prop_refresh_immediately() end

  return monitors
end

-- Move any of our workspaces that ended up on the wrong monitor (first run,
-- reordered screens) back to the monitor its id belongs to.
local function normalize(monitors)
  local home = {}
  for _, monitor in ipairs(monitors) do
    local digit = digits[monitor.name]
    if digit then home[digit] = monitor.name end
  end

  for _, workspace in ipairs(hl.get_workspaces()) do
    local _, digit = M.desktop_of(workspace.id)
    local target = digit and home[digit]
    if target and workspace.monitor and workspace.monitor.name ~= target then
      hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(workspace.id), monitor = target }))
    end
  end
end

-- Switching ------------------------------------------------------------------

local function remember(desktop)
  if desktop ~= current_desktop then
    previous_desktop = current_desktop
    current_desktop = desktop
  end
end

local function show(monitor, desktop)
  local digit = digits[monitor.name]
  if not digit then return end

  local id = M.workspace_id(desktop, digit)
  local active = monitor.active_workspace
  if active and active.id == id then return end

  monitor:set_workspace({ workspace = tostring(id) })
end

-- Bring every monitor except `skip` to `desktop` without moving focus.
local function sync(desktop, skip)
  busy = true
  for _, monitor in ipairs(hl.get_monitors()) do
    if monitor.name ~= skip then pcall(show, monitor, desktop) end
  end
  busy = false
end

-- The desktop shown on the focused monitor.
function M.current()
  local monitor = hl.get_active_monitor()
  local active = monitor and monitor.active_workspace
  local desktop = active and M.desktop_of(active.id)
  if desktop then return desktop end
  return current_desktop or HOME_DESKTOP
end

function M.switch(desktop)
  desktop = valid_desktop(desktop)
  if not desktop then return end

  local focused = hl.get_active_monitor()
  local focused_name = focused and focused.name
  sync(desktop, focused_name)

  -- The focused monitor goes last, through the normal dispatcher, so focus
  -- and the cursor land exactly where they would on a single screen.
  local digit = focused_name and digits[focused_name]
  if digit then
    local id = M.workspace_id(desktop, digit)
    local active = focused.active_workspace
    if not (active and active.id == id) then
      hl.dispatch(hl.dsp.focus({ workspace = tostring(id) }))
    end
  end

  remember(desktop)
end

local function occupied_desktops()
  local desktops = {}
  for _, workspace in ipairs(hl.get_workspaces()) do
    local desktop = M.desktop_of(workspace.id)
    if desktop and workspace.windows > 0 then desktops[desktop] = true end
  end
  return desktops
end

local function step(direction)
  local current = M.current()
  local occupied = occupied_desktops()

  local position = 1
  for index, desktop in ipairs(DESKTOPS) do
    if desktop == current then position = index end
  end

  for offset = 1, #DESKTOPS - 1 do
    local desktop = DESKTOPS[(position - 1 + direction * offset) % #DESKTOPS + 1]
    if occupied[desktop] then return M.switch(desktop) end
  end
end

function M.next() step(1) end
function M.prev() step(-1) end

function M.former()
  if previous_desktop then M.switch(previous_desktop) end
end

-- Move the active window to `desktop` on the monitor it is already on.
function M.move_window(desktop, follow)
  desktop = valid_desktop(desktop)
  if not desktop then return end

  local window = hl.get_active_window()
  if not window then return end

  local monitor = window.monitor
  local digit = monitor and digits[monitor.name]
  if not digit then return end

  local id = M.workspace_id(desktop, digit)
  if not (window.workspace and window.workspace.id == id) then
    hl.dispatch(hl.dsp.window.move({ window = window, workspace = tostring(id), follow = false }))
  end

  if follow then
    M.switch(desktop)
    hl.dispatch(hl.dsp.focus({ window = window }))
  end
end

-- Pull windows left behind by a disconnected monitor onto the focused
-- monitor, keeping each on its own desktop.
function M.gather()
  local focused = hl.get_active_monitor()
  local digit = focused and digits[focused.name]
  if not digit then return end

  local present = {}
  for _, monitor in ipairs(hl.get_monitors()) do
    local monitor_digit = digits[monitor.name]
    if monitor_digit then present[monitor_digit] = true end
  end

  for _, window in ipairs(hl.get_windows()) do
    local desktop, home = M.desktop_of(window.workspace and window.workspace.id)
    if desktop and not present[home] then
      hl.dispatch(hl.dsp.window.move({
        window = window,
        workspace = tostring(M.workspace_id(desktop, digit)),
        follow = false,
      }))
    end
  end
end

local function adopted_desktop(id, present)
  if id < 1 or id > 99 then return nil end

  local desktop, digit = M.desktop_of(id)
  if desktop and present[digit] then return nil end -- already reachable
  if id <= 10 then return id % 10 end               -- stock workspace N -> desktop N
  return id // 10                                   -- keep the desktop it was on
end

-- Run once on install: windows on workspaces the scheme cannot show (stock
-- workspaces 4-10 on a three-monitor desk, say) get a desktop. Stock
-- workspace N becomes desktop N on the same monitor, 10 becomes desktop 0.
function M.adopt()
  local present = {}
  for _, monitor in ipairs(hl.get_monitors()) do
    local digit = digits[monitor.name]
    if digit then present[digit] = true end
  end

  local focused = hl.get_active_monitor()
  local fallback = focused and digits[focused.name]

  for _, window in ipairs(hl.get_windows()) do
    local workspace = window.workspace
    local desktop = workspace and adopted_desktop(workspace.id, present)
    local digit = window.monitor and digits[window.monitor.name] or fallback

    if desktop and digit then
      hl.dispatch(hl.dsp.window.move({
        window = window,
        workspace = tostring(M.workspace_id(desktop, digit)),
        follow = false,
      }))
    end
  end
end

-- Undo the numbering before uninstalling: desktop N becomes stock workspace
-- N (desktop 0 becomes workspace 10), so no window is left out of reach.
function M.flatten()
  for _, window in ipairs(hl.get_windows()) do
    local desktop = M.desktop_of(window.workspace and window.workspace.id)
    if desktop then
      local target = desktop == 0 and 10 or desktop
      if window.workspace.id ~= target then
        hl.dispatch(hl.dsp.window.move({ window = window, workspace = tostring(target), follow = false }))
      end
    end
  end
end

-- Number the connected monitors left to right again, e.g. after rearranging
-- them in monitors.lua.
function M.renumber()
  digits = {}
  assign_digits(monitors_by_position())
  hl.exec_cmd("hyprctl reload")
end

function M.status()
  local lines = {}
  for _, monitor in ipairs(monitors_by_position()) do
    local active = monitor.active_workspace
    lines[#lines + 1] = string.format("%s: monitor %s, workspace %s",
      monitor.name, digits[monitor.name] or "-", active and active.id or "-")
  end
  lines[#lines + 1] = "desktop " .. M.current()
  return table.concat(lines, "\n")
end

-- Keybindings ----------------------------------------------------------------
-- Registered before hypr/bindings.lua loads, so personal overrides there win.

local function bind(keys, description, action)
  pcall(hl.unbind, keys)
  if type(o) == "table" and o.bind then
    o.bind(keys, description, action)
  else
    hl.bind(keys, action, { description = description })
  end
end

for key = 1, 10 do
  local desktop = key % 10
  local code = "code:" .. (key + 9)

  bind("SUPER + " .. code, "Switch to desktop " .. desktop,
    function() M.switch(desktop) end)
  bind("SUPER + SHIFT + " .. code, "Move window to desktop " .. desktop,
    function() M.move_window(desktop, true) end)
  bind("SUPER + SHIFT + ALT + " .. code, "Move window silently to desktop " .. desktop,
    function() M.move_window(desktop, false) end)
end

bind("SUPER + TAB", "Next desktop", function() M.next() end)
bind("SUPER + SHIFT + TAB", "Previous desktop", function() M.prev() end)
bind("SUPER + CTRL + TAB", "Former desktop", function() M.former() end)
bind("SUPER + mouse_down", "Scroll to next desktop", function() M.next() end)
bind("SUPER + mouse_up", "Scroll to previous desktop", function() M.prev() end)

-- Moving a workspace to another monitor breaks the id scheme, so those binds
-- go away. SUPER + SHIFT + arrows still moves windows between monitors.
for _, direction in ipairs({ "LEFT", "RIGHT", "UP", "DOWN" }) do
  pcall(hl.unbind, "SUPER + SHIFT + ALT + " .. direction)
end

-- Live session ---------------------------------------------------------------

if LIVE then
  digits = load_digits()

  -- Monitors already exist when the config is reloaded inside a running
  -- session; on a fresh start they arrive just before hyprland.start.
  local started = #hl.get_monitors() > 0
  local go_home = false

  if started then prepare(false) end

  local function refresh()
    local desktop = go_home and HOME_DESKTOP or M.current()
    local monitors = prepare(true)
    if not monitors then return end

    go_home = false
    local focused = hl.get_active_monitor()
    local focused_name = focused and focused.name

    busy = true
    pcall(normalize, monitors)
    busy = false

    -- Moving a workspace takes focus along with it; put focus back first so
    -- the switch below keeps the user's monitor.
    local now = hl.get_active_monitor()
    if focused_name and now and now.name ~= focused_name then
      hl.dispatch(hl.dsp.focus({ monitor = focused_name }))
    end

    M.switch(desktop)
  end

  hl.on("hyprland.start", function()
    started = true
    go_home = true
    refresh()
  end)

  hl.on("config.reloaded", function()
    if started then refresh() end
  end)

  hl.on("monitor.added", function()
    if started then refresh() end
  end)

  hl.on("monitor.removed", function()
    release_missing_monitors()
  end)

  -- Anything that changes one monitor's workspace (the stock bar, a window
  -- asking for focus, hyprctl) pulls the other monitors to the same desktop.
  hl.on("workspace.active", function(workspace)
    if busy or not workspace then return end

    local desktop = M.desktop_of(workspace.id)
    if not desktop then return end

    remember(desktop)
    sync(desktop, workspace.monitor and workspace.monitor.name)
  end)
end

return M
