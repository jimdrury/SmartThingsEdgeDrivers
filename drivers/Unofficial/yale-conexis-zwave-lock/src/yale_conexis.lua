-- Copyright 2026 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

-- Yale Conexis L1/L2 (Yale Z-Wave module) extras: tamper profile and lock settings.
-- Parameter numbers follow the Z-Wave JS device config for 0x0129/0x6600/0x0002 (SD-L1000-CH).

local capabilities = require "st.capabilities"
--- @type st.zwave.CommandClass
local cc = require "st.zwave.CommandClass"
--- @type st.zwave.CommandClass.Configuration
local Configuration = (require "st.zwave.CommandClass.Configuration")({ version = 1 })
--- @type st.zwave.CommandClass.DoorLock
local DoorLock = (require "st.zwave.CommandClass.DoorLock")({ version = 1 })
local LockDefaults = require "st.zwave.defaults.lock"

local YaleConexis = {}

local YALE_MFR = 0x0129
local CONEXIS_PRODUCT_TYPE = 0x6600
local TAMPER_PROFILE = "base-lock-tamper"
-- give the lock time to settle after start-up before asking for its settings
local SETTINGS_READ_DELAY_S = 15
-- The lock sends a plain Door Lock Operation Report about 1s before the alarm report that says how it
-- was operated. Hold the plain event this long so the detailed one can replace it. (The stock delay
-- grows by 0.5s every time no alarm follows, which happens after every follow-up OperationGet.)
local LOCK_EVENT_HOLD_S = 2
local HELD_LOCK_EVENT_TIMER = "yaleHeldLockEventTimer"
-- the lock sends no alarm for a remote lock, so a matching report this soon after our own command
-- is attributed to it
local LAST_LOCK_COMMAND = "yaleLastLockCommand"
local COMMAND_WINDOW_S = 20
-- custom capability (CLI-created) whose History text is "<device>: <value>"
local LOCK_ACTIVITY_ID = "aboutartist00260.lockActivity"

-- all parameters are 1 byte
YaleConexis.PARAMETERS = {
  { number = 1, preference = "yaleVolume",         label = "Volume (1 silent, 2 low, 3 high)" },
  { number = 2, preference = "yaleAutoRelock",     label = "Auto relock (0 off, 255 on)" },
  { number = 3, preference = "yaleAutoRelockTime", label = "Auto relock time (s)" },
  { number = 4, preference = "yaleWrongTagLimit",  label = "Wrong tag limit" },
  { number = 7, preference = "yaleWrongTagLockout", label = "Wrong tag lockout time (s)" },
}

function YaleConexis.is_conexis(device)
  return device.zwave_manufacturer_id == YALE_MFR and device.zwave_product_type == CONEXIS_PRODUCT_TYPE
end

--- Name for a key tag slot from the "Tag names" preference, written as "3=Alex, 1=Sam".
--- @return string|nil
function YaleConexis.tag_name(device, slot)
  local names = device.preferences and device.preferences.yaleTagNames
  if type(names) ~= "string" or slot == nil then return nil end
  for entry in names:gmatch("[^,;]+") do
    local entry_slot, name = entry:match("^%s*(%d+)%s*=%s*(.-)%s*$")
    if tonumber(entry_slot) == tonumber(slot) and name ~= "" then return name end
  end
end

local function find_parameter(number)
  for _, param in ipairs(YaleConexis.PARAMETERS) do
    if param.number == number then return param end
  end
end

-- Configuration v1 values are signed, so 255 has to go over the air as -1
local function to_signed_byte(value)
  if value > 127 then return value - 256 end
  return value
end

local function to_unsigned_byte(value)
  if value < 0 then return value + 256 end
  return value
end

function YaleConexis.read_settings(device)
  for _, param in ipairs(YaleConexis.PARAMETERS) do
    device:send(Configuration:Get({ parameter_number = param.number }))
  end
end

function YaleConexis.init(device)
  if not YaleConexis.is_conexis(device) then return end
  -- devices joined before the fingerprint moved to the tamper profile need switching over
  if device:supports_capability(capabilities.lockCodes) and not device:supports_capability(capabilities.tamperAlert) then
    device.log.info("Switching to the " .. TAMPER_PROFILE .. " profile")
    device:try_update_metadata({ profile = TAMPER_PROFILE })
  end
  device.thread:call_with_delay(SETTINGS_READ_DELAY_S, function() YaleConexis.read_settings(device) end, "yale_read_settings")
end

local function cancel_held_lock_event(device)
  local timer = device:get_field(HELD_LOCK_EVENT_TIMER)
  if timer ~= nil then
    device.thread:cancel_timer(timer)
    device:set_field(HELD_LOCK_EVENT_TIMER, nil)
  end
end

--- History wording, e.g. "Unlocked by Alex", "Locked by SmartThings", "Unlocked Manually".
--- @return string|nil nil for states that aren't a lock or unlock
function YaleConexis.activity_text(event)
  local state = event.value.value
  local verb
  if state == "locked" then
    verb = "Locked"
  elseif state == "unlocked" or state == "unlocked with timeout" then
    verb = "Unlocked"
  else
    return nil
  end
  local data = event.data or {}
  if data.method == "command" then
    return verb .. " by SmartThings"
  elseif data.method == "rfid" or data.method == "keypad" then
    local who = data.userName or data.codeName or (data.codeId and ("Tag " .. data.codeId))
    return who and (verb .. " by " .. who) or verb
  elseif data.method == "manual" then
    return verb .. " Manually"
  elseif data.method == "auto" then
    return verb .. " Automatically"
  end
  return verb
end

--- Emit a lock event on the Conexis: it replaces any held plain event, is hidden from History,
--- and is paired with a Lock activity event whose History text reads "Unlocked by Alex" etc.
function YaleConexis.emit_lock_event(device, event)
  if not YaleConexis.is_conexis(device) or event.capability.ID ~= capabilities.lock.ID then
    return device:emit_event(event)
  end
  cancel_held_lock_event(device)
  local previous_state = device:get_latest_state("main", capabilities.lock.ID, capabilities.lock.lock.NAME)
  local text = YaleConexis.activity_text(event)
  if device:supports_capability_by_id(LOCK_ACTIVITY_ID) then
    event.visibility = { displayed = false }
  end
  device:emit_event(event)
  -- a repeat of the current state with nothing new to say (e.g. a follow-up status poll) isn't activity
  local is_repeat = previous_state == event.value.value and (event.data == nil or event.data.method == nil)
  if text ~= nil and not is_repeat and device:supports_capability_by_id(LOCK_ACTIVITY_ID) then
    device:emit_event(capabilities[LOCK_ACTIVITY_ID].activity(text))
  end
end

function YaleConexis.door_lock_operation_report(driver, device, cmd)
  if not YaleConexis.is_conexis(device) then
    return LockDefaults.zwave_handlers[cc.DOOR_LOCK][DoorLock.OPERATION_REPORT](driver, device, cmd)
  end
  local event
  if cmd.args.door_lock_mode == DoorLock.door_lock_mode.DOOR_SECURED then
    event = capabilities.lock.lock.locked()
  elseif cmd.args.door_lock_mode == DoorLock.door_lock_mode.DOOR_UNSECURED_WITH_TIMEOUT then
    event = capabilities.lock.lock.unlocked_with_timeout()
  elseif cmd.args.door_lock_mode == DoorLock.door_lock_mode.DOOR_LOCK_STATE_UNKNOWN then
    event = capabilities.lock.lock.unknown()
  else
    event = capabilities.lock.lock.unlocked()
  end
  cancel_held_lock_event(device)
  local timer = device.thread:call_with_delay(LOCK_EVENT_HOLD_S, function()
    device:set_field(HELD_LOCK_EVENT_TIMER, nil)
    local last_command = device:get_field(LAST_LOCK_COMMAND)
    if last_command ~= nil and last_command.value == event.value.value and
       os.time() - last_command.time <= COMMAND_WINDOW_S then
      event.data = { method = "command" }
    end
    YaleConexis.emit_lock_event(device, event)
  end, "yale_held_lock_event")
  device:set_field(HELD_LOCK_EVENT_TIMER, timer)
end

local function note_lock_command(device, value)
  if YaleConexis.is_conexis(device) then
    device:set_field(LAST_LOCK_COMMAND, { value = value, time = os.time() })
  end
end

function YaleConexis.lock_command(driver, device, cmd)
  note_lock_command(device, "locked")
  LockDefaults.capability_handlers[capabilities.lock.commands.lock](driver, device, cmd)
end

function YaleConexis.unlock_command(driver, device, cmd)
  note_lock_command(device, "unlocked")
  LockDefaults.capability_handlers[capabilities.lock.commands.unlock](driver, device, cmd)
end

function YaleConexis.info_changed(driver, device, event, args)
  if not YaleConexis.is_conexis(device) then return end
  if device:supports_capability(capabilities.tamperAlert) and
     device:get_latest_state("main", capabilities.tamperAlert.ID, capabilities.tamperAlert.tamper.NAME) == nil then
    device:emit_event(capabilities.tamperAlert.tamper.clear())
  end
  local old_preferences = args and args.old_st_store and args.old_st_store.preferences or {}
  for _, param in ipairs(YaleConexis.PARAMETERS) do
    local old_value = tonumber(old_preferences[param.preference])
    local new_value = tonumber(device.preferences[param.preference])
    -- old_value is nil when the preference has only just appeared (profile change), and the
    -- app's default may not match the lock, so only write values the user has actually changed
    if old_value ~= nil and new_value ~= nil and old_value ~= new_value then
      device.log.info(string.format("Setting %s (parameter %d) to %d", param.label, param.number, new_value))
      device:send(Configuration:Set({
        parameter_number = param.number,
        size = 1,
        configuration_value = to_signed_byte(new_value)
      }))
      device:send(Configuration:Get({ parameter_number = param.number }))
    end
  end
end

function YaleConexis.configuration_report(driver, device, cmd)
  local param = find_parameter(cmd.args.parameter_number)
  local value = to_unsigned_byte(cmd.args.configuration_value)
  local label = param and param.label or "unknown setting"
  device.log.info(string.format("Lock reports %s (parameter %d) = %d", label, cmd.args.parameter_number, value))
end

return YaleConexis
