-- SPDX-License-Identifier: MIT
--
-- Offline test harness for 50-three-finger-drag.lua.
--
-- Stubs the libinput plugin API, loads the plugin, and feeds it synthetic
-- evdev frames. Run from the repository root:
--
--   luajit tests/run.lua
--
-- Exits non-zero when a check fails.

local PLUGIN = arg[1] or "50-three-finger-drag.lua"

local function usage(ev_type, code)
  return ev_type * 0x10000 + code
end

local EV_KEY, EV_ABS = 1, 3

evdev = {
  ABS_X                = usage(EV_ABS, 0x00),
  ABS_Y                = usage(EV_ABS, 0x01),
  ABS_MT_SLOT          = usage(EV_ABS, 0x2f),
  ABS_MT_TOUCH_MAJOR   = usage(EV_ABS, 0x30),
  ABS_MT_POSITION_X    = usage(EV_ABS, 0x35),
  ABS_MT_POSITION_Y    = usage(EV_ABS, 0x36),
  ABS_MT_TRACKING_ID   = usage(EV_ABS, 0x39),
  ABS_MT_TOOL_Y        = usage(EV_ABS, 0x3d),
  BTN_LEFT             = usage(EV_KEY, 0x110),
  BTN_TOUCH            = usage(EV_KEY, 0x14a),
  BTN_TOOL_FINGER      = usage(EV_KEY, 0x145),
  BTN_TOOL_QUINTTAP    = usage(EV_KEY, 0x148),
  BTN_TOOL_DOUBLETAP   = usage(EV_KEY, 0x14d),
  BTN_TOOL_TRIPLETAP   = usage(EV_KEY, 0x14e),
  BTN_TOOL_QUADTAP     = usage(EV_KEY, 0x14f),
}

local names = {}
for k, v in pairs(evdev) do names[v] = k end

local handlers = { libinput = {}, device = {} }
local timer = { relative = nil, cancelled = 0 }
local appended = {}

libinput = {
  register = function(_, versions) return versions[1] end,
  connect = function(_, name, fn) handlers.libinput[name] = fn end,
  log_debug = function() end,
  log_info = function() end,
  log_error = function(_, msg) error("plugin logged an error: " .. msg) end,
  now = function() return 0 end,
  timer_set_relative = function(_, us) timer.relative = us end,
  timer_set_absolute = function() error("timer_set_absolute is not expected") end,
  timer_cancel = function() timer.relative = nil; timer.cancelled = timer.cancelled + 1 end,
}

-- 100 x 60 mm pad at 50 units/mm.
local RES = 50
local device = {
  udev_properties = function() return { ID_INPUT_TOUCHPAD = "1" } end,
  name = function() return "Test Touchpad" end,
  absinfos = function()
    return {
      [evdev.ABS_MT_POSITION_X] = { minimum = 0, maximum = 100 * RES, resolution = RES, fuzz = 0, flat = 0 },
      [evdev.ABS_MT_POSITION_Y] = { minimum = 0, maximum = 60 * RES, resolution = RES, fuzz = 0, flat = 0 },
    }
  end,
  connect = function(_, name, fn) handlers.device[name] = fn end,
  append_frame = function(_, frame) appended[#appended + 1] = frame end,
}

assert(loadfile(PLUGIN))()
assert(handlers.libinput["new-evdev-device"], "plugin did not connect new-evdev-device")
handlers.libinput["new-evdev-device"](device)
local on_frame = assert(handlers.device["evdev-frame"], "plugin did not connect evdev-frame")
local on_timer = assert(handlers.libinput["timer-expired"], "plugin did not connect timer-expired")

-- Frame builder -------------------------------------------------------------

local function mm(v) return v * RES end

local kernel = { slots = {}, next_id = 1 }

local function tool_bits(n)
  local map = { evdev.BTN_TOOL_FINGER, evdev.BTN_TOOL_DOUBLETAP,
                evdev.BTN_TOOL_TRIPLETAP, evdev.BTN_TOOL_QUADTAP,
                evdev.BTN_TOOL_QUINTTAP }
  local out = {}
  for i, u in ipairs(map) do out[#out + 1] = { usage = u, value = (n == i) and 1 or 0 } end
  out[#out + 1] = { usage = evdev.BTN_TOUCH, value = n > 0 and 1 or 0 }
  return out
end

-- changes: list of { slot = s, x = mm, y = mm } or { slot = s, lift = true }
local function build(changes, extra)
  local frame = {}
  for _, c in ipairs(changes) do
    frame[#frame + 1] = { usage = evdev.ABS_MT_SLOT, value = c.slot }
    if c.lift then
      kernel.slots[c.slot] = nil
      frame[#frame + 1] = { usage = evdev.ABS_MT_TRACKING_ID, value = -1 }
    else
      if not kernel.slots[c.slot] then
        kernel.slots[c.slot] = true
        frame[#frame + 1] = { usage = evdev.ABS_MT_TRACKING_ID, value = kernel.next_id }
        kernel.next_id = kernel.next_id + 1
      end
      frame[#frame + 1] = { usage = evdev.ABS_MT_POSITION_X, value = mm(c.x) }
      frame[#frame + 1] = { usage = evdev.ABS_MT_POSITION_Y, value = mm(c.y) }
    end
  end
  local n = 0
  for _ in pairs(kernel.slots) do n = n + 1 end
  for _, ev in ipairs(tool_bits(n)) do frame[#frame + 1] = ev end
  for _, ev in ipairs(extra or {}) do frame[#frame + 1] = ev end
  return frame
end

-- The plugin only emits ABS_MT_SLOT when the selected slot changes, so the
-- slot in effect at the start of each output frame is remembered here.
local now, out_slot, frame_start_slot = 0, 0, {}
local function send(changes, dt_ms, extra)
  now = now + (dt_ms or 10) * 1000
  local out = on_frame(device, build(changes, extra), now) or {}
  frame_start_slot[out] = out_slot
  for _, ev in ipairs(out) do
    if ev.usage == evdev.ABS_MT_SLOT then out_slot = ev.value end
  end
  return out
end

-- Assertions ----------------------------------------------------------------

local failures, checks = 0, 0

local function describe(frame)
  local parts = {}
  for _, ev in ipairs(frame) do
    parts[#parts + 1] = (names[ev.usage] or tostring(ev.usage)) .. "=" .. tostring(ev.value)
  end
  return "[" .. table.concat(parts, " ") .. "]"
end

local function has(frame, u, v)
  for _, ev in ipairs(frame) do
    if ev.usage == u and (v == nil or ev.value == v) then return true end
  end
  return false
end

local function slot_events(frame, slot)
  local cur, found = frame_start_slot[frame], {}
  for _, ev in ipairs(frame) do
    if ev.usage == evdev.ABS_MT_SLOT then cur = ev.value
    elseif cur == slot and ev.usage >= evdev.ABS_MT_TOUCH_MAJOR and ev.usage <= evdev.ABS_MT_TOOL_Y then
      found[#found + 1] = ev
    end
  end
  return found
end

local current_test = ""
local function check(cond, what, frame)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    io.stderr:write(string.format("FAIL %s: %s%s\n", current_test, what,
      frame and ("\n     frame " .. describe(frame)) or ""))
  end
end

local function test(name, fn)
  current_test = name
  kernel.slots, kernel.next_id = {}, 1
  timer.relative, timer.cancelled = nil, 0
  appended = {}
  fn()
end

local function reset_pad()
  local lifts = {}
  for s in pairs(kernel.slots) do lifts[#lifts + 1] = { slot = s, lift = true } end
  if #lifts > 0 then send(lifts, 10) end
  if timer.relative then on_timer(now + timer.relative) end
  now = now + 1000 * 1000
end

-- Helpers shared by tests: three fingers, slot 0 is the topmost.
local function three_down()
  return send({ { slot = 0, x = 50, y = 20 }, { slot = 1, x = 40, y = 40 }, { slot = 2, x = 60, y = 42 } }, 10)
end

local function start_drag()
  three_down()
  send({}, 40)
  return send({ { slot = 0, x = 52, y = 20 } }, 10)
end

-- Tests ---------------------------------------------------------------------

test("one finger passes through with regenerated tool bits", function()
  local out = send({ { slot = 0, x = 50, y = 30 } }, 10)
  check(has(out, evdev.ABS_MT_TRACKING_ID, 1), "tracking id forwarded", out)
  check(has(out, evdev.BTN_TOOL_FINGER, 1), "BTN_TOOL_FINGER regenerated", out)
  check(has(out, evdev.BTN_TOUCH, 1), "BTN_TOUCH regenerated", out)
  check(not has(out, evdev.BTN_LEFT), "no button injected", out)
  out = send({ { slot = 0, x = 55, y = 30 } }, 10)
  check(not has(out, evdev.BTN_TOOL_FINGER), "unchanged tool bits are not repeated", out)
  reset_pad()
end)

test("three-finger tap without motion is untouched", function()
  local out = three_down()
  check(has(out, evdev.BTN_TOOL_TRIPLETAP, 1), "TRIPLETAP regenerated", out)
  check(not has(out, evdev.BTN_LEFT), "no button on touch", out)
  out = send({ { slot = 0, lift = true }, { slot = 1, lift = true }, { slot = 2, lift = true } }, 60)
  check(not has(out, evdev.BTN_LEFT), "no button on lift", out)
  check(has(out, evdev.BTN_TOOL_TRIPLETAP, 0), "TRIPLETAP cleared", out)
  check(timer.relative == nil, "no release timer armed")
  reset_pad()
end)

test("motion before ARM_MS does not start a drag", function()
  three_down()
  local out = send({ { slot = 0, x = 55, y = 20 } }, 5)
  check(not has(out, evdev.BTN_LEFT), "no button before arming", out)
  reset_pad()
end)

test("drag starts after threshold motion of the topmost finger", function()
  local out = start_drag()
  check(has(out, evdev.BTN_LEFT, 1), "BTN_LEFT pressed", out)
  check(#slot_events(out, 1) == 1 and slot_events(out, 1)[1].value == -1, "slot 1 hidden", out)
  check(#slot_events(out, 2) == 1 and slot_events(out, 2)[1].value == -1, "slot 2 hidden", out)
  check(has(out, evdev.BTN_TOOL_TRIPLETAP, 0) and has(out, evdev.BTN_TOOL_FINGER, 1), "one visible finger", out)
  out = send({ { slot = 1, x = 41, y = 41 }, { slot = 0, x = 54, y = 21 } }, 10)
  check(#slot_events(out, 1) == 0, "hidden slot motion dropped", out)
  check(#slot_events(out, 0) == 2, "primary motion forwarded", out)
  reset_pad()
end)

test("motion of a non-topmost finger does not start a drag", function()
  three_down()
  send({}, 40)
  local out = send({ { slot = 1, x = 45, y = 40 } }, 10)
  check(not has(out, evdev.BTN_LEFT), "thumb motion ignored", out)
  reset_pad()
end)

test("still lift releases after RELEASE_MS via the timer", function()
  start_drag()
  send({}, 200)
  local out = send({ { slot = 0, lift = true }, { slot = 1, lift = true }, { slot = 2, lift = true } }, 10)
  check(not has(out, evdev.BTN_LEFT), "button still held on lift", out)
  check(has(out, evdev.BTN_TOUCH, 0), "BTN_TOUCH cleared", out)
  check(timer.relative == 50 * 1000, "50 ms timer armed, got " .. tostring(timer.relative))
  on_timer(now + timer.relative)
  check(#appended == 1 and has(appended[1], evdev.BTN_LEFT, 0), "BTN_LEFT released by timer")
  reset_pad()
end)

test("moving lift gets the reposition grace", function()
  start_drag()
  for i = 1, 5 do send({ { slot = 0, x = 52 + i * 2, y = 20 } }, 10) end
  send({ { slot = 0, lift = true }, { slot = 1, lift = true }, { slot = 2, lift = true } }, 10)
  check(timer.relative == 250 * 1000, "250 ms timer armed, got " .. tostring(timer.relative))
  reset_pad()
end)

test("edge lift gets the reposition grace", function()
  start_drag()
  send({ { slot = 0, x = 98, y = 20 } }, 10)
  send({}, 200)
  send({ { slot = 0, lift = true }, { slot = 1, lift = true }, { slot = 2, lift = true } }, 10)
  check(timer.relative == 250 * 1000, "250 ms timer armed, got " .. tostring(timer.relative))
  reset_pad()
end)

test("fingers placed back down during the grace continue the drag", function()
  start_drag()
  send({}, 200)
  send({ { slot = 0, lift = true }, { slot = 1, lift = true }, { slot = 2, lift = true } }, 10)
  check(timer.relative ~= nil, "timer armed")
  local out = send({ { slot = 0, x = 30, y = 30 }, { slot = 1, x = 20, y = 45 } }, 20)
  check(timer.relative == nil, "timer cancelled on re-land")
  check(not has(out, evdev.BTN_LEFT), "button still held", out)
  check(#slot_events(out, 0) == 3, "new primary forwarded", out)
  check(#slot_events(out, 1) == 0, "other new finger hidden", out)
  check(has(out, evdev.BTN_TOOL_FINGER, 1), "one visible finger", out)
  out = send({ { slot = 0, x = 35, y = 30 } }, 10)
  check(#slot_events(out, 0) == 2 and not has(out, evdev.BTN_LEFT), "drag continues", out)
  reset_pad()
end)

test("partial lift promotes a hidden finger without a pointer jump", function()
  start_drag()
  local out = send({ { slot = 0, lift = true } }, 10)
  check(not has(out, evdev.BTN_LEFT), "button still held", out)
  local evs = slot_events(out, 1)
  check(#evs == 3 and evs[1].usage == evdev.ABS_MT_TRACKING_ID and evs[1].value >= 0
        and evs[2].value == mm(40) and evs[3].value == mm(40), "slot 1 revealed at its position", out)
  check(#slot_events(out, 2) == 0, "slot 2 stays hidden", out)
  check(has(out, evdev.BTN_TOOL_FINGER) == false, "finger count unchanged", out)
  check(timer.relative == nil, "no release timer")
  out = send({ { slot = 1, x = 42, y = 40 } }, 10)
  check(#slot_events(out, 1) == 2, "promoted finger drives the drag", out)
  reset_pad()
end)

test("new touches during a drag stay hidden", function()
  start_drag()
  local out = send({ { slot = 3, x = 10, y = 50 } }, 10)
  check(#slot_events(out, 3) == 0, "fourth finger hidden", out)
  check(not has(out, evdev.BTN_TOOL_DOUBLETAP), "finger count unchanged", out)
  out = send({ { slot = 3, lift = true } }, 10)
  check(#slot_events(out, 3) == 0, "its lift is hidden too", out)
  reset_pad()
end)

test("physical click takes over the drag", function()
  start_drag()
  local out = send({}, 10, { { usage = evdev.BTN_LEFT, value = 1 } })
  check(not has(out, evdev.BTN_LEFT), "duplicate press dropped", out)
  check(timer.relative == nil, "no timer")
  out = send({}, 10, { { usage = evdev.BTN_LEFT, value = 0 } })
  check(has(out, evdev.BTN_LEFT, 0), "release forwarded", out)
  out = send({ { slot = 0, x = 60, y = 20 } }, 10)
  check(not has(out, evdev.BTN_LEFT), "no button after the click ends the drag", out)
  reset_pad()
end)

test("no drag while the button is physically held", function()
  send({}, 10, { { usage = evdev.BTN_LEFT, value = 1 } })
  three_down()
  send({}, 40)
  local out = send({ { slot = 0, x = 55, y = 20 } }, 10)
  check(not has(out, evdev.BTN_LEFT), "no injected press", out)
  send({}, 10, { { usage = evdev.BTN_LEFT, value = 0 } })
  reset_pad()
end)

test("four fingers never start a drag", function()
  send({ { slot = 0, x = 50, y = 20 }, { slot = 1, x = 40, y = 40 },
         { slot = 2, x = 60, y = 42 }, { slot = 3, x = 70, y = 44 } }, 10)
  send({}, 40)
  local out = send({ { slot = 0, x = 60, y = 20 } }, 10)
  check(not has(out, evdev.BTN_LEFT), "no button", out)
  check(#slot_events(out, 0) == 2, "motion forwarded", out)
  reset_pad()
end)

test("non-touchpad devices are ignored", function()
  local saved = handlers.device
  handlers.device = {}
  handlers.libinput["new-evdev-device"]({
    udev_properties = function() return { ID_INPUT_MOUSE = "1" } end,
    name = function() return "Mouse" end,
    absinfos = function() return {} end,
    connect = function(_, name, fn) handlers.device[name] = fn end,
    append_frame = function() end,
  })
  check(next(handlers.device) == nil, "no handlers connected for a mouse")
  handlers.device = saved
end)

io.stdout:write(string.format("%d checks, %d failures\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
