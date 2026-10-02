-- Tests for hypr/global-workspaces.lua against a small fake of Hyprland's Lua
-- API. Run from the repository root: lua test/run.lua

local MODULE = "hypr/global-workspaces.lua"

-- Each test gets its own state directory through XDG_STATE_HOME.
local real_getenv = os.getenv
local state_home

local function new_state_home()
  state_home = os.tmpname()
  os.remove(state_home)
  os.execute("mkdir -p '" .. state_home .. "'")
end

os.getenv = function(key)
  if key == "XDG_STATE_HOME" then return state_home end
  return real_getenv(key)
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local content = file:read("a")
  file:close()
  return content
end

-- Fake Hyprland ---------------------------------------------------------------

local function fake_hyprland()
  local env = {
    monitors = {},
    workspaces = {},
    windows = {},
    handlers = {},
    binds = {},
    rules = {},
    execs = {},
    set_workspace_calls = {},
    focused = nil,
    active_window = nil,
    next_unmanaged = 100,
  }

  local function emit(event, ...)
    for _, handler in ipairs(env.handlers[event] or {}) do handler(...) end
  end

  local function monitor_named(name)
    for _, monitor in ipairs(env.monitors) do
      if monitor.name == name then return monitor end
    end
  end

  local function rule_monitor(id)
    for _, rule in ipairs(env.rules) do
      if rule.enabled and rule.spec.workspace == tostring(id) and rule.spec.monitor then
        return monitor_named(rule.spec.monitor)
      end
    end
  end

  local function create_workspace(id, monitor)
    local workspace = { id = id, name = tostring(id), special = false, windows = 0, monitor = monitor }
    env.workspaces[id] = workspace
    return workspace
  end

  local function workspace_for(id)
    id = tonumber(id)
    return env.workspaces[id] or create_workspace(id, rule_monitor(id) or env.focused)
  end

  local function activate(monitor, workspace)
    if monitor.active_workspace ~= workspace then
      monitor.active_workspace = workspace
      emit("workspace.active", workspace)
    end
  end

  function env.add_monitor(name, x, y, workspace_id)
    local monitor = { name = name, x = x, y = y, is_mirror = false }
    function monitor:set_workspace(spec)
      env.set_workspace_calls[#env.set_workspace_calls + 1] = self.name
      local workspace = env.workspaces[tonumber(spec.workspace)]
      if not workspace then return end -- Hyprland ignores missing workspaces
      workspace.monitor = self
      activate(self, workspace)
    end
    env.monitors[#env.monitors + 1] = monitor
    if workspace_id then monitor.active_workspace = create_workspace(workspace_id, monitor) end
    env.focused = env.focused or monitor
    return monitor
  end

  function env.remove_monitor(name)
    local removed
    for index, monitor in ipairs(env.monitors) do
      if monitor.name == name then removed = table.remove(env.monitors, index) break end
    end
    -- Hyprland hands the workspaces to a remaining monitor.
    for _, workspace in pairs(env.workspaces) do
      if workspace.monitor == removed then workspace.monitor = env.monitors[1] end
    end
    for _, window in ipairs(env.windows) do
      if window.monitor == removed then window.monitor = env.monitors[1] end
    end
    if env.focused == removed then env.focused = env.monitors[1] end
    emit("monitor.removed", removed)
  end

  function env.open_window(class, workspace_id)
    local workspace = workspace_for(workspace_id)
    local window = { class = class, workspace = workspace, monitor = workspace.monitor }
    env.windows[#env.windows + 1] = window
    env.active_window = window
    return window
  end

  function env.focus(name)
    env.focused = monitor_named(name)
  end

  function env.showing()
    local shown = {}
    for _, monitor in ipairs(env.monitors) do
      shown[monitor.name] = monitor.active_workspace and monitor.active_workspace.id
    end
    return shown
  end

  env.emit = emit

  local dsp = {
    focus = function(args)
      return function()
        if args.workspace then
          local workspace = workspace_for(args.workspace)
          env.focused = workspace.monitor
          activate(workspace.monitor, workspace)
        elseif args.window then
          env.focused = args.window.monitor
          env.active_window = args.window
        elseif args.monitor then
          env.focused = monitor_named(args.monitor)
        end
      end
    end,
    window = {
      move = function(args)
        return function()
          local window = args.window or env.active_window
          local workspace = workspace_for(args.workspace)
          window.workspace = workspace
          window.monitor = workspace.monitor
          if args.follow ~= false then
            env.focused = workspace.monitor
            activate(workspace.monitor, workspace)
          end
        end
      end,
    },
    workspace = {
      move = function(args)
        return function()
          local workspace = env.workspaces[tonumber(args.workspace)]
          local target = monitor_named(args.monitor)
          local source = workspace.monitor
          workspace.monitor = target
          for _, window in ipairs(env.windows) do
            if window.workspace == workspace then window.monitor = target end
          end
          if source.active_workspace == workspace then
            -- The source monitor falls back to a fresh workspace.
            source.active_workspace = create_workspace(env.next_unmanaged, source)
            env.next_unmanaged = env.next_unmanaged + 1
          end
          -- Like Hyprland, focus follows the moved workspace.
          env.focused = target
          activate(target, workspace)
        end
      end,
    },
  }

  local api = {
    dsp = dsp,
    version = function() return "fake" end,
    get_monitors = function()
      local list = {}
      for index, monitor in ipairs(env.monitors) do
        monitor.focused = monitor == env.focused
        list[index] = monitor
      end
      return list
    end,
    get_active_monitor = function() return env.focused end,
    get_active_window = function() return env.active_window end,
    get_windows = function()
      local list = {}
      for index, window in ipairs(env.windows) do list[index] = window end
      return list
    end,
    get_workspaces = function()
      local list = {}
      for _, workspace in pairs(env.workspaces) do
        workspace.windows = 0
        list[#list + 1] = workspace
      end
      for _, window in ipairs(env.windows) do
        window.workspace.windows = window.workspace.windows + 1
      end
      table.sort(list, function(a, b) return a.id < b.id end)
      return list
    end,
    workspace_rule = function(spec)
      local rule = { spec = spec, enabled = true }
      env.rules[#env.rules + 1] = rule
      local monitor = spec.monitor and monitor_named(spec.monitor)
      local id = tonumber(spec.workspace)
      if spec.persistent and monitor and not env.workspaces[id] then create_workspace(id, monitor) end
      return {
        set_enabled = function(_, enabled) rule.enabled = enabled end,
      }
    end,
    exec_scheduled_prop_refresh_immediately = function() end,
    dispatch = function(dispatcher) dispatcher() end,
    on = function(event, handler)
      env.handlers[event] = env.handlers[event] or {}
      table.insert(env.handlers[event], handler)
    end,
    bind = function(keys, action, opts)
      env.binds[keys] = { action = action, description = opts and opts.description }
    end,
    unbind = function(keys) env.binds[keys] = nil end,
    exec_cmd = function(command) env.execs[#env.execs + 1] = command end,
  }

  return env, api
end

local function load_module(api)
  hl = api
  o = {
    bind = function(keys, description, action)
      hl.bind(keys, action, { description = description })
    end,
  }
  return dofile(MODULE)
end

-- The three-screen desk this was built on: Hyprland handed out workspaces 1-3
-- in detection order, which is not left to right.
local function desk(env)
  env.add_monitor("HDMI-A-1", 2160, 840, 1) -- center, focused
  env.add_monitor("DP-1", 6000, 0, 2)       -- right
  env.add_monitor("DP-2", 0, 0, 3)          -- left
end

-- Tiny test harness ----------------------------------------------------------

local passed, failed = 0, 0

local function check(condition, message)
  if not condition then error(message, 2) end
end

local function same(actual, expected, message)
  for key, value in pairs(expected) do
    if actual[key] ~= value then
      error(string.format("%s: %s is %s, expected %s", message, key, tostring(actual[key]), tostring(value)), 2)
    end
  end
end

local function test(name, fn)
  new_state_home()
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("ok   " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n     " .. tostring(err))
  end
end

-- Tests ----------------------------------------------------------------------

test("workspace ids encode desktop and monitor", function()
  local _, api = fake_hyprland()
  local M = load_module(api)
  local desktop, digit = M.desktop_of(23)
  check(desktop == 2 and digit == 3, "23 is desktop 2, monitor 3")
  desktop, digit = M.desktop_of(1)
  check(desktop == 0 and digit == 1, "1 is desktop 0, monitor 1")
  check(M.desktop_of(10) == nil, "ids ending in 0 are not ours")
  check(M.desktop_of(0) == nil and M.desktop_of(-98) == nil, "special workspaces are not ours")
  check(M.desktop_of(105) == nil, "three-digit ids are not ours")
  check(M.desktop_of(nil) == nil, "nil is not a workspace")
  check(M.workspace_id(9, 2) == 92, "desktop 9 on monitor 2 is 92")
end)

test("first run numbers monitors left to right and remembers them", function()
  local env, api = fake_hyprland()
  desk(env)
  load_module(api)
  env.emit("config.reloaded")

  local saved = read_file(state_home .. "/omarchy/global-workspaces/monitors")
  check(saved == "DP-1=3\nDP-2=1\nHDMI-A-1=2\n", "state file was " .. tostring(saved))
end)

test("first run moves existing workspaces onto their own monitors", function()
  local env, api = fake_hyprland()
  desk(env)
  local terminal = env.open_window("ghostty", 1)
  local browser = env.open_window("firefox", 3)
  env.active_window = terminal
  load_module(api)
  env.emit("config.reloaded")

  same(env.showing(), { ["DP-2"] = 1, ["HDMI-A-1"] = 2, ["DP-1"] = 3 }, "desktop 0 laid out left to right")
  check(terminal.monitor.name == "DP-2", "workspace 1 belongs to the left monitor")
  check(browser.monitor.name == "DP-1", "workspace 3 belongs to the right monitor")
  check(env.focused.name == "HDMI-A-1", "focus stays on the center monitor")
end)

test("switching moves every monitor and keeps focus where it was", function()
  local env, api = fake_hyprland()
  desk(env)
  local M = load_module(api)
  env.emit("config.reloaded")

  env.set_workspace_calls = {}
  M.switch(2)
  same(env.showing(), { ["DP-2"] = 21, ["HDMI-A-1"] = 22, ["DP-1"] = 23 }, "desktop 2")
  check(env.focused.name == "HDMI-A-1", "focus stays on the center monitor")
  for _, name in ipairs(env.set_workspace_calls) do
    check(name ~= "HDMI-A-1", "the focused monitor switches through the dispatcher, not set_workspace")
  end
  check(M.current() == 2, "current desktop is 2")

  env.focus("DP-1")
  M.switch(0)
  same(env.showing(), { ["DP-2"] = 1, ["HDMI-A-1"] = 2, ["DP-1"] = 3 }, "desktop 0")
  check(env.focused.name == "DP-1", "focus stays on the right monitor")
end)

test("switching ignores bad input", function()
  local env, api = fake_hyprland()
  desk(env)
  local M = load_module(api)
  env.emit("config.reloaded")
  local before = env.showing()
  M.switch(10)
  M.switch(-1)
  M.switch("x")
  same(env.showing(), before, "nothing moved")
end)

test("a workspace change from elsewhere pulls the other monitors along", function()
  local env, api = fake_hyprland()
  desk(env)
  load_module(api)
  env.emit("config.reloaded")

  -- e.g. clicking a notification for a window on desktop 3, left monitor
  hl.dispatch(hl.dsp.focus({ workspace = "31" }))
  same(env.showing(), { ["DP-2"] = 31, ["HDMI-A-1"] = 32, ["DP-1"] = 33 }, "desktop 3")
  check(env.focused.name == "DP-2", "focus goes where the request sent it")
end)

test("workspaces outside the scheme do not drag other monitors", function()
  local env, api = fake_hyprland()
  desk(env)
  load_module(api)
  env.emit("config.reloaded")
  local before = env.showing()

  hl.dispatch(hl.dsp.focus({ workspace = "10" }))
  check(env.showing()["DP-1"] == before["DP-1"] and env.showing()["DP-2"] == before["DP-2"],
    "other monitors stayed put")
end)

test("former desktop toggles back and forth", function()
  local env, api = fake_hyprland()
  desk(env)
  local M = load_module(api)
  env.emit("config.reloaded")

  M.switch(4)
  M.switch(7)
  M.former()
  check(M.current() == 4, "back to 4")
  M.former()
  check(M.current() == 7, "and forward to 7")
end)

test("next and previous skip empty desktops and wrap in keyboard order", function()
  local env, api = fake_hyprland()
  desk(env)
  local M = load_module(api)
  env.emit("config.reloaded")
  env.open_window("a", 21)
  env.open_window("b", 53)
  env.open_window("c", 2) -- desktop 0, after 9 in keyboard order

  M.switch(2)
  M.next()
  check(M.current() == 5, "2 -> 5, got " .. M.current())
  M.next()
  check(M.current() == 0, "5 -> 0, got " .. M.current())
  M.next()
  check(M.current() == 2, "0 wraps to 2, got " .. M.current())
  M.prev()
  check(M.current() == 0, "2 back to 0, got " .. M.current())
end)

test("moving a window keeps it on its monitor and follows it", function()
  local env, api = fake_hyprland()
  desk(env)
  local M = load_module(api)
  env.emit("config.reloaded")
  M.switch(1)
  local window = env.open_window("ghostty", 12)

  M.move_window(4, true)
  check(window.workspace.id == 42, "window is on 42, got " .. window.workspace.id)
  same(env.showing(), { ["DP-2"] = 41, ["HDMI-A-1"] = 42, ["DP-1"] = 43 }, "followed to desktop 4")
  check(env.active_window == window, "the moved window keeps focus")
end)

test("moving a window silently leaves the desktop alone", function()
  local env, api = fake_hyprland()
  desk(env)
  local M = load_module(api)
  env.emit("config.reloaded")
  M.switch(1)
  local window = env.open_window("ghostty", 13)

  M.move_window(6, false)
  check(window.workspace.id == 63, "window is on 63, got " .. window.workspace.id)
  check(M.current() == 1, "still on desktop 1")
end)

test("gather pulls windows off a disconnected monitor", function()
  local env, api = fake_hyprland()
  desk(env)
  local M = load_module(api)
  env.emit("config.reloaded")
  local stranded = env.open_window("slack", 33) -- desktop 3, right monitor

  env.remove_monitor("DP-1")
  env.focus("HDMI-A-1")
  M.gather()
  check(stranded.workspace.id == 32, "moved to desktop 3 on the center monitor, got " .. stranded.workspace.id)
end)

test("a monitor plugged back in gets its workspaces and windows back", function()
  local env, api = fake_hyprland()
  desk(env)
  local M = load_module(api)
  env.emit("config.reloaded")
  M.switch(2)
  local window = env.open_window("slack", 23) -- desktop 2, right monitor

  env.remove_monitor("DP-1")
  check(window.monitor.name ~= "DP-1", "Hyprland parked the window elsewhere")

  env.add_monitor("DP-1", 6000, 0)
  env.emit("monitor.added")
  check(window.monitor.name == "DP-1", "window is back on DP-1, got " .. window.monitor.name)
  same(env.showing(), { ["DP-2"] = 21, ["HDMI-A-1"] = 22, ["DP-1"] = 23 }, "still on desktop 2")
end)

test("a disconnected monitor stops keeping its empty workspaces alive", function()
  local env, api = fake_hyprland()
  desk(env)
  load_module(api)
  env.emit("config.reloaded")
  env.remove_monitor("DP-1")

  for _, rule in ipairs(env.rules) do
    if rule.spec.monitor == "DP-1" then check(not rule.enabled, "DP-1 rule still enabled") end
    if rule.spec.monitor == "DP-2" then check(rule.enabled, "DP-2 rule was disabled") end
  end
end)

test("flatten returns windows to stock workspaces", function()
  local env, api = fake_hyprland()
  desk(env)
  local M = load_module(api)
  env.emit("config.reloaded")
  local a = env.open_window("a", 42)
  local b = env.open_window("b", 3)
  local c = env.open_window("c", 105)

  M.flatten()
  check(a.workspace.id == 4, "desktop 4 -> workspace 4")
  check(b.workspace.id == 10, "desktop 0 -> workspace 10")
  check(c.workspace.id == 105, "unmanaged workspaces are left alone")
end)

test("adopt gives windows on unreachable stock workspaces a desktop", function()
  local env, api = fake_hyprland()
  desk(env)
  local M = load_module(api)
  env.emit("config.reloaded")
  local visible = env.open_window("visible", 2)    -- desktop 0, center: reachable
  local five = env.open_window("five", 5)          -- no fifth monitor
  local ten = env.open_window("ten", 10)           -- stock workspace 10
  local stray = env.open_window("stray", 64)       -- desktop 6 of a missing monitor 4
  local high = env.open_window("high", 105)        -- not a workspace we manage
  for _, window in ipairs({ five, ten, stray }) do
    window.workspace.monitor = env.monitors[2]     -- they live on DP-1 (monitor 3)
    window.monitor = env.monitors[2]
  end

  M.adopt()
  check(visible.workspace.id == 2, "reachable windows stay, got " .. visible.workspace.id)
  check(five.workspace.id == 53, "workspace 5 becomes desktop 5 on its monitor, got " .. five.workspace.id)
  check(ten.workspace.id == 3, "workspace 10 becomes desktop 0, got " .. ten.workspace.id)
  check(stray.workspace.id == 63, "a missing monitor's window keeps its desktop, got " .. stray.workspace.id)
  check(high.workspace.id == 105, "unmanaged workspaces are left alone")
end)

test("flatten then adopt brings every window back within reach", function()
  local env, api = fake_hyprland()
  desk(env)
  local M = load_module(api)
  env.emit("config.reloaded")
  local a = env.open_window("a", 42)
  local b = env.open_window("b", 1)

  M.flatten()
  M.adopt()
  check(M.desktop_of(a.workspace.id) == 4, "a is on desktop 4 again, got " .. a.workspace.id)
  check(M.desktop_of(b.workspace.id) == 0, "b is on desktop 0 again, got " .. b.workspace.id)
end)

test("startup lands every monitor on desktop 1", function()
  local env, api = fake_hyprland()
  load_module(api) -- config is evaluated before any monitor exists
  desk(env)
  env.emit("monitor.added") -- ignored until Hyprland has started
  env.emit("hyprland.start")

  same(env.showing(), { ["DP-2"] = 11, ["HDMI-A-1"] = 12, ["DP-1"] = 13 }, "desktop 1")
end)

test("a known monitor keeps its number across restarts", function()
  local env, api = fake_hyprland()
  desk(env)
  load_module(api)
  env.emit("config.reloaded")

  -- Next session the right monitor is unplugged and a new one sits left of everything.
  local env2, api2 = fake_hyprland()
  env2.add_monitor("HDMI-A-1", 2160, 840, 1)
  env2.add_monitor("DP-2", 0, 0, 2)
  env2.add_monitor("DP-3", -3840, 0, 3)
  load_module(api2)
  env2.emit("config.reloaded")

  local saved = read_file(state_home .. "/omarchy/global-workspaces/monitors")
  check(saved == "DP-1=3\nDP-2=1\nDP-3=4\nHDMI-A-1=2\n", "state file was " .. tostring(saved))
end)

test("an entirely new set of monitors is numbered from 1 again", function()
  local env, api = fake_hyprland()
  desk(env)
  load_module(api)
  env.emit("config.reloaded")

  local env2, api2 = fake_hyprland()
  env2.add_monitor("eDP-1", 0, 0, 1)
  load_module(api2)
  env2.emit("config.reloaded")

  local saved = read_file(state_home .. "/omarchy/global-workspaces/monitors")
  check(saved == "eDP-1=1\n", "state file was " .. tostring(saved))
end)

test("renumber starts over from the current layout and reloads", function()
  local env, api = fake_hyprland()
  desk(env)
  local M = load_module(api)
  env.emit("config.reloaded")
  env.monitors[3].x = 9000 -- DP-2 moved from the far left to the far right

  M.renumber()
  local saved = read_file(state_home .. "/omarchy/global-workspaces/monitors")
  check(saved == "DP-1=2\nDP-2=3\nHDMI-A-1=1\n", "state file was " .. tostring(saved))
  check(env.execs[#env.execs] == "hyprctl reload", "reloads Hyprland")
end)

test("binds SUPER+0-9, TAB and scroll, and removes workspace-to-monitor moves", function()
  local env, api = fake_hyprland()
  env.binds["SUPER + SHIFT + ALT + LEFT"] = { description = "Move workspace to left monitor" }
  env.binds["SUPER + SHIFT + LEFT"] = { description = "Move window to the left" }
  load_module(api)

  check(env.binds["SUPER + code:10"].description == "Switch to desktop 1", "SUPER+1")
  check(env.binds["SUPER + code:19"].description == "Switch to desktop 0", "SUPER+0")
  check(env.binds["SUPER + SHIFT + code:12"].description == "Move window to desktop 3", "SUPER+SHIFT+3")
  check(env.binds["SUPER + SHIFT + ALT + code:19"].description == "Move window silently to desktop 0", "SUPER+SHIFT+ALT+0")
  check(env.binds["SUPER + TAB"].description == "Next desktop", "SUPER+TAB")
  check(env.binds["SUPER + mouse_down"].description == "Scroll to next desktop", "scroll")
  check(env.binds["SUPER + SHIFT + ALT + LEFT"] == nil, "workspace move unbound")
  check(env.binds["SUPER + SHIFT + LEFT"] ~= nil, "window move kept")
end)

test("loads under omarchy-menu-keybindings' stub without touching live state", function()
  -- Same shape as the stub in omarchy-menu-keybindings: every unknown field
  -- is a callable table that returns itself.
  local noop
  noop = setmetatable({}, {
    __index = function() return noop end,
    __call = function() return noop end,
  })
  local described = 0
  local touched = {}
  hl = setmetatable({
    dsp = noop,
    bind = function(_, _, opts)
      if opts and opts.description then described = described + 1 end
      return noop
    end,
  }, { __index = function(_, key) touched[key] = true return noop end })
  o = {
    bind = function(keys, description, action)
      hl.bind(keys, action, { description = description })
    end,
  }

  -- Fail instead of hanging if anything iterates a stub object.
  local runner = coroutine.create(function() return dofile(MODULE) end)
  debug.sethook(runner, function() error("stub evaluation did not finish") end, "", 1000000)
  local ok, err = coroutine.resume(runner)
  check(ok, tostring(err))
  check(described == 35, "expected 35 described binds, got " .. described)
  check(read_file(state_home .. "/omarchy/global-workspaces/monitors") == nil, "no state written")
  for key in pairs(touched) do
    check(key == "unbind" or key == "version", "touched hl." .. key .. " outside a live session")
  end
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
