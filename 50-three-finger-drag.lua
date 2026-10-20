-- SPDX-License-Identifier: MIT
--
-- macOS-style three-finger drag for touchpads, as a libinput Lua plugin.
--
-- KWin does not expose libinput's 3fg-drag config option, so this plugin
-- rewrites evdev frames instead: once three fingers are down and the first
-- finger has moved past a small threshold, the other two contacts are hidden
-- from libinput and a BTN_LEFT press is injected. libinput then sees an
-- ordinary one-finger click-and-drag. The drag ends RELEASE_MS after the
-- fingers lift, or immediately on a physical click.
--
-- A three-finger tap without movement is passed through unchanged (middle
-- click). Four- and five-finger gestures are unaffected.
--
-- https://github.com/alex-spataru/three-finger-drag

libinput:register({ 1 })

local THRESHOLD_MM = 1.5   -- primary finger motion needed to start a drag
local RELEASE_MS   = 50    -- grace period after lifting before button release

local TOOLS = {
  evdev.BTN_TOOL_FINGER,
  evdev.BTN_TOOL_DOUBLETAP,
  evdev.BTN_TOOL_TRIPLETAP,
  evdev.BTN_TOOL_QUADTAP,
  evdev.BTN_TOOL_QUINTTAP,
}

local function log(msg)
  pcall(function() libinput:log_info("3fg-drag: " .. msg) end)
end

local function is_tool(usage)
  if usage == evdev.BTN_TOUCH then return true end
  for _, t in ipairs(TOOLS) do
    if usage == t then return true end
  end
  return false
end

local function is_mt(usage)
  -- Every per-slot ABS_MT_* axis (ABS_MT_SLOT itself sits just below the range)
  return usage >= evdev.ABS_MT_TOUCH_MAJOR and usage <= evdev.ABS_MT_TOOL_Y
end

local function threshold_units(device)
  local ok, abs = pcall(function() return device:absinfos() end)
  if ok and abs then
    local x = abs[evdev.ABS_MT_POSITION_X]
    if x then
      if x.resolution and x.resolution > 0 then
        return THRESHOLD_MM * x.resolution
      end
      return (x.maximum - x.minimum) * 0.01
    end
  end
  return 30
end

local function setup(device)
  local props = device:udev_properties()
  if props.ID_INPUT_TOUCHPAD ~= "1" then return end
  local okn, nm = pcall(function() return device:name() end)
  log("enabled on " .. tostring(okn and nm or "touchpad"))

  local threshold = threshold_units(device)

  local st = {
    cur = 0,            -- kernel's currently selected slot
    out = 0,            -- slot libinput currently believes is selected
    active = {},        -- slot -> true while the kernel reports a contact
    pos = {},           -- slot -> { x, y }
    hidden = {},        -- slot -> true while hidden from libinput
    shown = 0,          -- finger count libinput was last told
    phys = false,       -- physical button state
    pending = nil,      -- { slot, x, y } while waiting for drag motion
    dragging = false,
    primary = nil,
    release_at = nil,   -- timestamp (us) at which a lifted drag releases
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

  local function lowest_active()
    local best
    for s in pairs(st.active) do
      if not best or s < best then best = s end
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

  local function end_drag(out)
    st.dragging = false
    st.primary = nil
    st.release_at = nil
    pcall(function() libinput:timer_cancel() end)
    if not st.phys then
      out[#out + 1] = { usage = evdev.BTN_LEFT, value = 0 }
    end
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
        st.dragging = false; st.primary = nil; st.release_at = nil
        st.skip_press = true
        pcall(function() libinput:timer_cancel() end)
      else
        if st.primary and not st.active[st.primary] then st.primary = nil end
        if not st.primary then
          -- Fingers placed back down during the grace period continue the drag.
          for s in pairs(st.active) do
            if not before[s] then st.primary = s; st.hidden[s] = nil; break end
          end
        end
        if st.primary then
          if st.release_at then
            st.release_at = nil
            pcall(function() libinput:timer_cancel() end)
          end
        elseif not st.release_at then
          st.release_at = time + RELEASE_MS * 1000
          pcall(function() libinput:timer_set_relative(RELEASE_MS * 1000) end)
        end
      end
    elseif st.pending then
      local p = st.pending
      local pos = st.pos[p.slot]
      if n ~= 3 or not st.active[p.slot] or phys_down then
        st.pending = nil
      elseif pos and pos.x and pos.y and p.x and p.y and
             math.abs(pos.x - p.x) + math.abs(pos.y - p.y) >= threshold then
        st.pending = nil
        st.dragging = true
        st.primary = p.slot
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
    elseif n == 3 and not st.phys and not phys_down then
      local s = lowest_active()
      local pos = st.pos[s] or {}
      st.pending = { slot = s, x = pos.x, y = pos.y }
    end

    -- Main pass: forward events, dropping hidden slots and kernel tool bits.
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
      elseif is_tool(u) then
        -- regenerated from the visible finger count below
      elseif u == evdev.BTN_LEFT then
        st.phys = (v == 1)
        if st.skip_press and v == 1 then
          st.skip_press = false     -- button is already down from the drag
        elseif not st.dragging then
          out[#out + 1] = ev
        end
      else
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
  libinput:connect("timer-expired", function(_)
    if st.dragging and st.release_at then
      local out = {}
      end_drag(out)
      device:append_frame(out)
    end
  end)
end

libinput:connect("new-evdev-device", setup)
