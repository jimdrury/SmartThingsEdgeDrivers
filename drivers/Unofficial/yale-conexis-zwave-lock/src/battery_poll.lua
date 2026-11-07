-- Copyright 2026 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

-- Periodic Battery Get for locks that never send unsolicited Battery Reports.

--- @type st.zwave.CommandClass.Battery
local Battery = (require "st.zwave.CommandClass.Battery")({ version = 1 })

local BatteryPoll = {}

local TIMER_FIELD = "batteryPollTimer"
local DEFAULT_HOURS = 6
-- delay the first poll so it doesn't compete with start-up traffic (and the refresh sent on add)
local FIRST_POLL_DELAY_S = 30

local function interval_hours(device)
  local hours = tonumber(device.preferences and device.preferences.batteryPollHours) or DEFAULT_HOURS
  if hours < 1 then hours = DEFAULT_HOURS end
  return hours
end

function BatteryPoll.poll(device)
  device.log.info("Requesting battery level")
  device:send(Battery:Get({}))
end

--- Send a Battery Get shortly and (re)start the repeating timer.
function BatteryPoll.start(device)
  BatteryPoll.stop(device)
  device.thread:call_with_delay(FIRST_POLL_DELAY_S, function() BatteryPoll.poll(device) end, "battery_poll_first")
  local hours = interval_hours(device)
  local timer = device.thread:call_on_schedule(hours * 60 * 60, function() BatteryPoll.poll(device) end, "battery_poll")
  device:set_field(TIMER_FIELD, timer)
  device.log.info(string.format("Battery poll scheduled every %d hour(s)", hours))
end

function BatteryPoll.stop(device)
  local timer = device:get_field(TIMER_FIELD)
  if timer ~= nil then
    device.thread:cancel_timer(timer)
    device:set_field(TIMER_FIELD, nil)
  end
end

function BatteryPoll.info_changed(driver, device, event, args)
  local old_hours = args and args.old_st_store and args.old_st_store.preferences
    and args.old_st_store.preferences.batteryPollHours
  if old_hours ~= device.preferences.batteryPollHours then
    BatteryPoll.start(device)
  end
end

return BatteryPoll
