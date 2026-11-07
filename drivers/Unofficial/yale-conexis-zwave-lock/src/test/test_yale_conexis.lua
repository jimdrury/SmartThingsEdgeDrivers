-- Copyright 2026 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

local test = require "integration_test"
local t_utils = require "integration_test.utils"
local capabilities = require "st.capabilities"
local zw = require "st.zwave"
local Alarm = (require "st.zwave.CommandClass.Alarm")({ version = 1 })
local Battery = (require "st.zwave.CommandClass.Battery")({ version = 1 })
local Configuration = (require "st.zwave.CommandClass.Configuration")({ version = 1 })
local DoorLock = (require "st.zwave.CommandClass.DoorLock")({ version = 1 })
local constants = require "lock_utils.constants"

local YALE_MFR = 0x0129
local CONEXIS_PRODUCT_TYPE = 0x6600
local CONEXIS_PRODUCT_ID = 0x0002

test.add_package_capability("lockActivity.yaml")
local lock_activity = capabilities["aboutartist00260.lockActivity"]

test.disable_startup_messages()

local zwave_lock_endpoints = {
  {
    command_classes = {
      { value = zw.BATTERY },
      { value = zw.DOOR_LOCK },
      { value = zw.USER_CODE },
      { value = zw.ALARM },
      { value = zw.CONFIGURATION },
    }
  }
}

local function build_conexis(profile_file, preferences)
  return test.mock_device.build_test_zwave_device({
    profile = t_utils.get_profile_definition(profile_file),
    zwave_endpoints = zwave_lock_endpoints,
    zwave_manufacturer_id = YALE_MFR,
    zwave_product_type = CONEXIS_PRODUCT_TYPE,
    zwave_product_id = CONEXIS_PRODUCT_ID,
    preferences = preferences,
  })
end

local default_preferences = {
  batteryPollHours = 6,
  yaleVolume = "2",
  yaleAutoRelock = "255",
  yaleAutoRelockTime = 30,
  yaleWrongTagLimit = 5,
  yaleWrongTagLockout = 180,
}

local mock_device = build_conexis("base-lock-tamper.yml", default_preferences)
local mock_old_profile = build_conexis("base-lock.yml", { batteryPollHours = 6 })

local function test_init()
  test.mock_device.add_test_device(mock_device)
  test.mock_device.add_test_device(mock_old_profile)
end
test.set_test_init_function(test_init)

test.register_coroutine_test(
  "init reads lock settings after 15s, polls battery after 30s and then every 6 hours",
  function()
    test.timer.__create_and_queue_test_time_advance_timer(30, "oneshot")
    test.timer.__create_and_queue_test_time_advance_timer(6 * 60 * 60, "interval")
    test.timer.__create_and_queue_test_time_advance_timer(15, "oneshot")
    test.socket.device_lifecycle:__queue_receive({ mock_device.id, "init" })
    test.wait_for_events()

    test.mock_time.advance_time(15)
    for _, number in ipairs({ 1, 2, 3, 4, 7 }) do
      test.socket.zwave:__expect_send(Configuration:Get({ parameter_number = number }):build_test_tx(mock_device.id))
    end
    test.wait_for_events()

    test.mock_time.advance_time(15)
    test.socket.zwave:__expect_send(Battery:Get({}):build_test_tx(mock_device.id))
    test.wait_for_events()

    test.mock_time.advance_time(6 * 60 * 60 - 30)
    test.socket.zwave:__expect_send(Battery:Get({}):build_test_tx(mock_device.id))
  end,
  { min_api_version = 14 }
)

test.register_coroutine_test(
  "init moves a Conexis on the old base-lock profile to base-lock-tamper",
  function()
    test.socket.device_lifecycle:__queue_receive({ mock_old_profile.id, "init" })
    mock_old_profile:expect_metadata_update({ profile = "base-lock-tamper" })
  end,
  { min_api_version = 14 }
)

local function hidden(event)
  event.visibility = { displayed = false }
  return event
end

-- a Conexis lock event is hidden from History and paired with the Lock activity text
local function expect_lock_event(event, activity_text)
  test.socket.capability:__expect_send(mock_device:generate_test_message("main", hidden(event)))
  if activity_text ~= nil then
    test.socket.capability:__expect_send(mock_device:generate_test_message("main", lock_activity.activity(activity_text)))
  end
end

test.register_coroutine_test(
  "Yale tag unlock (alarm 144) is reported as an rfid unlock (legacy handlers)",
  function()
    test.socket.zwave:__queue_receive({ mock_device.id, Alarm:Report({ alarm_type = 144, alarm_level = 3 }) })
    expect_lock_event(capabilities.lock.lock.unlocked({ data = { codeId = "3", method = "rfid" } }), "Unlocked by Tag 3")
  end,
  { min_api_version = 14 }
)

test.register_coroutine_test(
  "Yale tag unlock (alarm 144) is reported as an rfid unlock (migrated device)",
  function()
    mock_device:set_field(constants.DRIVER_STATE.SLGA_MIGRATED, true, { persist = true })
    test.socket.zwave:__queue_receive({ mock_device.id, Alarm:Report({ alarm_type = 144, alarm_level = 3 }) })
    expect_lock_event(capabilities.lock.lock.unlocked({ data = { codeId = "3", method = "rfid" } }), "Unlocked by Tag 3")
  end,
  { min_api_version = 14 }
)

test.register_coroutine_test(
  "Tag unlock uses the name from the Tag names setting, and just the slot when unnamed",
  function()
    local prefs = {}
    for k, v in pairs(default_preferences) do prefs[k] = v end
    prefs.yaleTagNames = "1=Sam,  3 = Alex "
    test.socket.device_lifecycle:__queue_receive(mock_device:generate_info_changed({ preferences = prefs }))
    test.socket.capability:__expect_send(mock_device:generate_test_message("main", capabilities.tamperAlert.tamper.clear()))
    test.wait_for_events()

    test.socket.zwave:__queue_receive({ mock_device.id, Alarm:Report({ alarm_type = 144, alarm_level = 3 }) })
    expect_lock_event(capabilities.lock.lock.unlocked({ data = { codeId = "3", codeName = "Alex", userName = "Alex", method = "rfid" } }),
      "Unlocked by Alex")
    test.wait_for_events()

    test.socket.zwave:__queue_receive({ mock_device.id, Alarm:Report({ alarm_type = 144, alarm_level = 5 }) })
    expect_lock_event(capabilities.lock.lock.unlocked({ data = { codeId = "5", method = "rfid" } }), "Unlocked by Tag 5")
  end,
  { min_api_version = 14 }
)

test.register_coroutine_test(
  "Fob unlock as the lock sends it: held Operation Report is replaced by the detailed rfid event",
  function()
    test.timer.__create_and_queue_test_time_advance_timer(2, "oneshot")
    test.socket.zwave:__queue_receive({ mock_device.id,
      DoorLock:OperationReport({ door_lock_mode = DoorLock.door_lock_mode.DOOR_UNSECURED }) })
    test.wait_for_events()
    test.socket.zwave:__queue_receive({ mock_device.id, Alarm:Report({ alarm_type = 144, alarm_level = 3 }) })
    expect_lock_event(capabilities.lock.lock.unlocked({ data = { codeId = "3", method = "rfid" } }), "Unlocked by Tag 3")
    test.wait_for_events()
    -- the held plain event must not appear once its timer would have fired
    test.mock_time.advance_time(2)
  end,
  { min_api_version = 14 }
)

test.register_coroutine_test(
  "Operation Report with no following alarm (e.g. refresh) is still emitted after the hold",
  function()
    test.timer.__create_and_queue_test_time_advance_timer(2, "oneshot")
    test.socket.zwave:__queue_receive({ mock_device.id,
      DoorLock:OperationReport({ door_lock_mode = DoorLock.door_lock_mode.DOOR_SECURED }) })
    test.wait_for_events()
    test.mock_time.advance_time(2)
    expect_lock_event(capabilities.lock.lock.locked(), "Locked")
  end,
  { min_api_version = 14 }
)

test.register_coroutine_test(
  "The hold stays at 2s when reports keep arriving without an alarm (no creep)",
  function()
    for _, mode in ipairs({ DoorLock.door_lock_mode.DOOR_UNSECURED, DoorLock.door_lock_mode.DOOR_SECURED,
                            DoorLock.door_lock_mode.DOOR_UNSECURED }) do
      test.timer.__create_and_queue_test_time_advance_timer(2, "oneshot")
      test.socket.zwave:__queue_receive({ mock_device.id, DoorLock:OperationReport({ door_lock_mode = mode }) })
      test.wait_for_events()
      test.mock_time.advance_time(2)
      if mode == DoorLock.door_lock_mode.DOOR_SECURED then
        expect_lock_event(capabilities.lock.lock.locked(), "Locked")
      else
        expect_lock_event(capabilities.lock.lock.unlocked(), "Unlocked")
      end
      test.wait_for_events()
    end
  end,
  { min_api_version = 14 }
)

test.register_coroutine_test(
  "Remote lock: the lock sends no alarm, so the report after our lock command is attributed to it",
  function()
    test.timer.__create_and_queue_test_time_advance_timer(4.2, "oneshot")
    test.timer.__create_and_queue_test_time_advance_timer(2, "oneshot")
    test.socket.capability:__queue_receive({ mock_device.id, { capability = "lock", component = "main", command = "lock", args = {} } })
    test.socket.zwave:__expect_send(
      DoorLock:OperationSet({ door_lock_mode = DoorLock.door_lock_mode.DOOR_SECURED }):build_test_tx(mock_device.id))
    test.wait_for_events()
    test.socket.zwave:__queue_receive({ mock_device.id,
      DoorLock:OperationReport({ door_lock_mode = DoorLock.door_lock_mode.DOOR_SECURED }) })
    test.wait_for_events()
    test.mock_time.advance_time(2)
    expect_lock_event(capabilities.lock.lock.locked({ data = { method = "command" } }), "Locked by SmartThings")
    test.wait_for_events()
    -- stock follow-up status request 4.2s after the command
    test.mock_time.advance_time(2.2)
    test.socket.zwave:__expect_send(DoorLock:OperationGet({}):build_test_tx(mock_device.id))
  end,
  { min_api_version = 14 }
)

test.register_coroutine_test(
  "Lifting the handle (alarm 21 level 1) is a manual lock on the Conexis, not keypad",
  function()
    test.socket.zwave:__queue_receive({ mock_device.id, Alarm:Report({ alarm_type = 21, alarm_level = 1 }) })
    expect_lock_event(capabilities.lock.lock.locked({ data = { method = "manual" } }), "Locked Manually")
  end,
  { min_api_version = 14 }
)

test.register_coroutine_test(
  "A plain status repeating the current state (follow-up poll) adds no History line",
  function()
    test.socket.zwave:__queue_receive({ mock_device.id, Alarm:Report({ alarm_type = 25, alarm_level = 1 }) })
    expect_lock_event(capabilities.lock.lock.unlocked({ data = { method = "command" } }), "Unlocked by SmartThings")
    test.wait_for_events()
    test.timer.__create_and_queue_test_time_advance_timer(2, "oneshot")
    test.socket.zwave:__queue_receive({ mock_device.id,
      DoorLock:OperationReport({ door_lock_mode = DoorLock.door_lock_mode.DOOR_UNSECURED }) })
    test.wait_for_events()
    test.mock_time.advance_time(2)
    expect_lock_event(capabilities.lock.lock.unlocked(), nil)
  end,
  { min_api_version = 14 }
)

test.register_coroutine_test(
  "Remote unlock (alarm 25) and auto-relock (alarm 27) read as prose",
  function()
    test.socket.zwave:__queue_receive({ mock_device.id, Alarm:Report({ alarm_type = 25, alarm_level = 1 }) })
    expect_lock_event(capabilities.lock.lock.unlocked({ data = { method = "command" } }), "Unlocked by SmartThings")
    test.wait_for_events()
    test.socket.zwave:__queue_receive({ mock_device.id, Alarm:Report({ alarm_type = 27, alarm_level = 1 }) })
    expect_lock_event(capabilities.lock.lock.locked({ data = { method = "auto" } }), "Locked Automatically")
  end,
  { min_api_version = 14 }
)

test.register_coroutine_test(
  "Changing auto relock writes the setting (255 sent as signed -1) and reads it back",
  function()
    local prefs = {}
    for k, v in pairs(default_preferences) do prefs[k] = v end
    prefs.yaleAutoRelock = "0"
    -- the mock starts without preferences, so let them appear first (nothing is written)
    test.socket.device_lifecycle:__queue_receive(mock_device:generate_info_changed({ preferences = default_preferences }))
    -- first infoChanged with the tamper capability and no tamper state yet
    test.socket.capability:__expect_send(mock_device:generate_test_message("main", capabilities.tamperAlert.tamper.clear()))
    test.wait_for_events()

    test.socket.device_lifecycle:__queue_receive(mock_device:generate_info_changed({ preferences = prefs }))
    test.socket.zwave:__expect_send(
      Configuration:Set({ parameter_number = 2, size = 1, configuration_value = 0 }):build_test_tx(mock_device.id))
    test.socket.zwave:__expect_send(Configuration:Get({ parameter_number = 2 }):build_test_tx(mock_device.id))
    test.wait_for_events()

    test.socket.device_lifecycle:__queue_receive(mock_device:generate_info_changed({ preferences = default_preferences }))
    test.socket.zwave:__expect_send(
      Configuration:Set({ parameter_number = 2, size = 1, configuration_value = -1 }):build_test_tx(mock_device.id))
    test.socket.zwave:__expect_send(Configuration:Get({ parameter_number = 2 }):build_test_tx(mock_device.id))
  end,
  { min_api_version = 14 }
)

test.register_coroutine_test(
  "Settings appearing for the first time (profile change) are not written to the lock",
  function()
    test.socket.device_lifecycle:__queue_receive(mock_old_profile:generate_info_changed({ preferences = default_preferences }))
    -- no Configuration:Set expected; any send would fail the test
    test.wait_for_events()
  end,
  { min_api_version = 14 }
)

test.register_message_test(
  "Configuration reports are accepted",
  {
    {
      channel = "zwave",
      direction = "receive",
      message = { mock_device.id, Configuration:Report({ parameter_number = 2, size = 1, configuration_value = -1 }) }
    }
  },
  { min_api_version = 14 }
)

test.run_registered_tests()
