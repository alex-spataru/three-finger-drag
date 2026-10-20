-- SPDX-License-Identifier: MIT
--
-- macOS-style three-finger drag for touchpads, as a libinput Lua plugin.
--
-- KWin does not expose libinput's 3fg-drag config option, so this plugin
-- rewrites evdev frames instead: once three fingers are down and the topmost
-- finger has moved past a small threshold, the other two contacts are hidden
-- from libinput and a BTN_LEFT press is injected. libinput then sees an
-- ordinary one-finger click-and-drag. The drag survives fingers lifting as
-- long as one stays down and ends RELEASE_MS after the last finger lifts, or
-- REPOSITION_MS if that lift looked like a mid-stroke reposition. A physical
-- click during a drag takes over the held button, and releasing it ends the
-- drag.
--
-- A three-finger tap without movement is passed through unchanged (middle
-- click). Four- and five-finger gestures are unaffected.
--
-- https://github.com/alex-spataru/three-finger-drag

libinput:register({ 1 })

local THRESHOLD_MM    = 1.5   -- primary finger motion needed to start a drag
local ARM_MS          = 30    -- three contacts must be down this long before a drag may start
local RELEASE_MS      = 50    -- grace after a still lift before the button releases
local REPOSITION_MS   = 250   -- grace after a lift that looks like a reposition
local REPOSITION_MM_S = 25    -- lift speed at or above this counts as a reposition
local EDGE_MM         = 5     -- lifts this close to the pad edge count as repositions
local SPEED_WINDOW_MS = 60    -- window over which the lift speed is measured

local TOOLS = {
  evdev.BTN_TOOL_FINGER,
  evdev.BTN_TOOL_DOUBLETAP,
  evdev.BTN_TOOL_TRIPLETAP,
  evdev.BTN_TOOL_QUADTAP,
  evdev.BTN_TOOL_QUINTTAP,
}

local function log(msg)
  libinput:log_info("3fg-drag: " .. msg)
end

local function is_tool(usage)
  if usage == evdev.BTN_TOUCH then return true end
  for _, t in ipairs(TOOLS) do
    if usage == t then return true end
  end
  return false
end

-- Every per-slot ABS_MT_* axis. ABS_MT_SLOT itself sits just below the range.
local function is_mt(usage)
  return usage >= evdev.ABS_MT_TOUCH_MAJOR and usage <= evdev.ABS_MT_TOOL_Y
end

-- { min, max, res } for one axis, res in units per mm. Pads without a
-- resolution are assumed to be about 100 mm across.
local function axis_info(abs, usage)
  local a = abs and abs[usage]
  if not a then return nil end
  local res = a.resolution
  if not res or res <= 0 then res = (a.maximum - a.minimum) / 100 end
  if res <= 0 then res = 20 end
  return { min = a.minimum, max = a.maximum, res = res }
end

local function geometry(device)
  local abs = device:absinfos()
  local x = axis_info(abs, evdev.ABS_MT_POSITION_X) or { min = 0, max = 0, res = 20 }
  local y = axis_info(abs, evdev.ABS_MT_POSITION_Y) or x
  return x, y
end

local function setup(device)
  local props = device:udev_properties()
  if props.ID_INPUT_TOUCHPAD ~= "1" then return end
  log("enabled on " .. tostring(device:name()))

  local ax, ay = geometry(device)

  local function dist_mm(x0, y0, x1, y1)
    local dx, dy = (x1 - x0) / ax.res, (y1 - y0) / ay.res
    return math.sqrt(dx * dx + dy * dy)
  end

  local function near_edge(x, y)
    return (x - ax.min) / ax.res < EDGE_MM or (ax.max - x) / ax.res < EDGE_MM
        or (y - ay.min) / ay.res < EDGE_MM or (ay.max - y) / ay.res < EDGE_MM
  end

  local st = {
    cur = 0,            -- kernel's currently selected slot
    out = 0,            -- slot libinput currently believes is selected
    active = {},        -- slot -> true while the kernel reports a contact
    pos = {},           -- slot -> { x, y }
    hidden = {},        -- slot -> true while hidden from libinput
    shown = 0,          -- finger count libinput was last told
    phys = false,       -- physical button state
    skip_press = false, -- next physical press is already held by the drag
    pending = nil,      -- { slot, x, y, t } while waiting for drag motion
    dragging = false,
    primary = nil,      -- slot libinput sees as the dragging finger
    release_at = nil,   -- timestamp (us) at which a lifted drag releases
    last = nil,         -- { slot, x, y } last known primary position
    moves = {},         -- { t, mm } recent primary motion increments
    fake_id = 60000,    -- tracking id for fingers re-shown to libinput
  }

  local function count_active()
    local n = 0
    for _ in pairs(st.active) do n = n + 1 end
    return n
  end

  local function count_shown()
    local n = 0
    for s in pairs(st.active) do
      if not st.hidden[s] then n = n + 1 end
    end
    return n
  end

  -- The finger highest on the pad. The thumb tends to sit lowest, and a
  -- finger resting in a clickpad's bottom button area neither moves the
  -- pointer nor produces a left click when the button is pressed.
  local function topmost(slots)
    local best, besty
    for s in pairs(slots) do
      local p = st.pos[s]
      local y = p and p.y or math.huge
      if not best or y < besty or (y == besty and s < best) then
        best, besty = s, y
      end
    end
    return best
  end

  local function select_slot(out, s)
    if st.out ~= s then
      out[#out + 1] = { usage = evdev.ABS_MT_SLOT, value = s }
      st.out = s
    end
  end

  local function emit_tools(out)
    local n = count_shown()
    if n == st.shown then return end
    local function bits(k)
      local b = {}
      for i = 1, #TOOLS do b[i] = (k == i or (i == #TOOLS and k > #TOOLS)) and 1 or 0 end
      return b
    end
    local old, new = bits(st.shown), bits(n)
    for i, t in ipairs(TOOLS) do
      if old[i] ~= new[i] then out[#out + 1] = { usage = t, value = new[i] } end
    end
    if (st.shown > 0) ~= (n > 0) then
      out[#out + 1] = { usage = evdev.BTN_TOUCH, value = n > 0 and 1 or 0 }
    end
    st.shown = n
  end

  local function cancel_timer()
    st.release_at = nil
    libinput:timer_cancel()
  end

  local function end_drag(out)
    st.dragging = false
    st.primary = nil
    st.last = nil
    st.moves = {}
    cancel_timer()
    if not st.phys then
      out[#out + 1] = { usage = evdev.BTN_LEFT, value = 0 }
    end
  end

  -- Record the primary finger's motion so a lift can be classified.
  local function track(time)
    local s = st.primary
    local p = s and st.pos[s]
    if not (p and p.x and p.y) then return end
    local l = st.last
    if l and l.slot == s then
      local mm = dist_mm(l.x, l.y, p.x, p.y)
      if mm > 0 then st.moves[#st.moves + 1] = { t = time, mm = mm } end
    end
    st.last = { slot = s, x = p.x, y = p.y }
    local cutoff = time - SPEED_WINDOW_MS * 1000
    while st.moves[1] and st.moves[1].t < cutoff do table.remove(st.moves, 1) end
  end

  local function lift_speed(time)
    local mm = 0
    for _, m in ipairs(st.moves) do
      if m.t >= time - SPEED_WINDOW_MS * 1000 then mm = mm + m.mm end
    end
    return mm / (SPEED_WINDOW_MS / 1000)
  end

  -- All fingers are up: a finger that was still moving, or lifted at the
  -- pad edge, most likely ran out of room and is about to land again.
  local function start_release(time)
    local ms = RELEASE_MS
    local l = st.last
    if l and (lift_speed(time) >= REPOSITION_MM_S or near_edge(l.x, l.y)) then
      ms = REPOSITION_MS
    end
    st.release_at = time + ms * 1000
    libinput:timer_set_relative(ms * 1000)
  end

  -- Show a finger libinput believes has lifted, as a fresh touch at its
  -- current position. Relative motion continues from there, so the pointer
  -- does not jump.
  local function reveal(out, s)
    st.hidden[s] = nil
    local p = st.pos[s]
    select_slot(out, s)
    st.fake_id = st.fake_id + 1
    if st.fake_id > 65000 then st.fake_id = 60000 end
    out[#out + 1] = { usage = evdev.ABS_MT_TRACKING_ID, value = st.fake_id }
    if p and p.x then out[#out + 1] = { usage = evdev.ABS_MT_POSITION_X, value = p.x } end
    if p and p.y then out[#out + 1] = { usage = evdev.ABS_MT_POSITION_Y, value = p.y } end
  end

  device:connect("evdev-frame", function(_, frame, time)
    -- Pre-pass: simulate the frame to learn the post-frame contact state.
    local before = {}
    for s in pairs(st.active) do before[s] = true end
    local cur = st.cur
    local phys_down = false
    for _, ev in ipairs(frame) do
      local u, v = ev.usage, ev.value
      if u == evdev.ABS_MT_SLOT then
        cur = v
      elseif u == evdev.ABS_MT_TRACKING_ID then
        if v == -1 then st.active[cur] = nil; st.pos[cur] = nil
        else st.active[cur] = true; st.pos[cur] = st.pos[cur] or {} end
      elseif u == evdev.ABS_MT_POSITION_X then
        st.pos[cur] = st.pos[cur] or {}; st.pos[cur].x = v
      elseif u == evdev.ABS_MT_POSITION_Y then
        st.pos[cur] = st.pos[cur] or {}; st.pos[cur].y = v
      elseif u == evdev.BTN_LEFT then
        if v == 1 then phys_down = true end
      end
    end
    local n = count_active()
    local out = {}

    -- Decide state transitions.
    if st.dragging then
      if phys_down then
        -- A real click takes over the held button; its release ends the drag.
        st.dragging = false; st.primary = nil; st.last = nil; st.moves = {}
        st.skip_press = true
        cancel_timer()
      else
        if st.primary and not st.active[st.primary] then st.primary = nil end
        if not st.primary then
          -- Prefer a finger that landed this frame (fingers placed back down
          -- during the grace period); otherwise promote a hidden finger that
          -- is still on the pad so the drag survives a partial lift.
          local fresh, held = {}, {}
          for s in pairs(st.active) do
            if before[s] then held[s] = true else fresh[s] = true end
          end
          local s = topmost(fresh)
          if s then
            st.primary = s
            st.hidden[s] = nil
          else
            s = topmost(held)
            if s then
              st.primary = s
              reveal(out, s)
            end
          end
        end
        if st.primary then
          if st.release_at then cancel_timer() end
        elseif not st.release_at then
          start_release(time)
        end
      end
    elseif st.pending then
      local p = st.pending
      local pos = st.pos[p.slot]
      if n ~= 3 or not st.active[p.slot] or phys_down then
        st.pending = nil
      elseif pos and pos.x and pos.y then
        if not (p.x and p.y) then p.x, p.y = pos.x, pos.y end
        if time - p.t >= ARM_MS * 1000 and
           dist_mm(p.x, p.y, pos.x, pos.y) >= THRESHOLD_MM then
          st.pending = nil
          st.dragging = true
          st.primary = p.slot
          st.last = nil
          st.moves = {}
          for s in pairs(st.active) do
            if s ~= p.slot then
              st.hidden[s] = true
              if before[s] then
                select_slot(out, s)
                out[#out + 1] = { usage = evdev.ABS_MT_TRACKING_ID, value = -1 }
              end
            end
          end
          out[#out + 1] = { usage = evdev.BTN_LEFT, value = 1 }
        end
      end
    elseif n == 3 and not st.phys and not phys_down then
      local s = topmost(st.active)
      local pos = st.pos[s] or {}
      st.pending = { slot = s, x = pos.x, y = pos.y, t = time }
    end

    if st.dragging then track(time) end

    -- Main pass: forward events, dropping hidden slots and the kernel's
    -- BTN_TOUCH / BTN_TOOL_* bits, which emit_tools regenerates below from
    -- the visible finger count.
    for _, ev in ipairs(frame) do
      local u, v = ev.usage, ev.value
      if u == evdev.ABS_MT_SLOT then
        st.cur = v
      elseif is_mt(u) then
        local s = st.cur
        if u == evdev.ABS_MT_TRACKING_ID and v ~= -1 and st.dragging and s ~= st.primary then
          st.hidden[s] = true       -- new touches during a drag stay hidden
        end
        if st.hidden[s] then
          if u == evdev.ABS_MT_TRACKING_ID and v == -1 then st.hidden[s] = nil end
        else
          select_slot(out, s)
          out[#out + 1] = ev
        end
      elseif u == evdev.BTN_LEFT then
        st.phys = (v == 1)
        if st.skip_press and v == 1 then
          st.skip_press = false     -- button is already down from the drag
        elseif not st.dragging then
          out[#out + 1] = ev
        end
      elseif not is_tool(u) then
        out[#out + 1] = ev
      end
    end

    if st.dragging and st.release_at and time >= st.release_at then
      end_drag(out)
    end

    emit_tools(out)
    return out
  end)

  -- Release a lifted drag even if no further frames arrive.
  libinput:connect("timer-expired", function()
    if st.dragging and st.release_at then
      local out = {}
      end_drag(out)
      device:append_frame(out)
    end
  end)
end

libinput:connect("new-evdev-device", setup)
