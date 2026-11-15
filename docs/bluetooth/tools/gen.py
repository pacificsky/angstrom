"""Generate docs/bluetooth/PLAN.md and docs/bluetooth/work-packages.json from packages.py + fragments."""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import packages as P  # noqa: E402

OUT_DIR = os.environ.get("OUT_DIR", os.path.dirname(HERE))  # docs/bluetooth


def frag(name):
    with open(os.path.join(HERE, name)) as f:
        return f.read()


# ------------------------------------------------------------------ upstream test coverage (§7.2)
# (function, file abbrev, def line, case ids, [swift tests], owner)
UT = []


def ut(fn, f, line, cases, swift, owner):
    UT.append(dict(fn=fn, file=f, line=line, cases=cases, swift=swift, owner=owner))


FILES = {"TBC": "tests/test_bluetooth_client.py", "TBD": "tests/test_bluetooth_dashboard.py",
         "TM": "tests/test_machine.py", "TT": "tests/test_thing.py", "TMO": "tests/test_models.py",
         "TCC": "tests/test_cloud_client.py"}

R, Cn, A = "BluetoothRequestTests.", "BluetoothConnectionTests.", "BluetoothAuthTests."
L, N, RC = "ShotCounterLifecycleTests.", "ShotCounterNotificationTests.", "ShotCounterReconnectTests."
ut("test_ble_set_power", "TBC", 295, "C01", [R + "testSetPowerOnWritesMachineChangeMode"], "BT-W3-02")
ut("test_ble_set_temperature", "TBC", 310, "C02", [R + "testSetTemperatureSteamWritesSettingBoilerTarget"], "BT-W3-02")
ut("test_ble_set_smart_standby", "TBC", 324, "C03", [R + "testSetSmartStandbyWritesMinutesModeEnabled"], "BT-W3-02")
ut("test_ble_get_machine_capability", "TBC", 338, "C04", [R + "testGetMachineCapabilitiesDecodesFirstElement"], "BT-W3-02")
ut("test_ble_get_boiler_details", "TBC", 361, "C05", [R + "testGetBoilersDecodesList"], "BT-W3-02")
ut("test_ble_get_smart_standby_details", "TBC", 388, "C06", [R + "testGetSmartStandbyAcceptsStringBool"], "BT-W3-02")
ut("test_ble_get_tank_status", "TBC", 406, "C07", [R + "testGetTankStatusStringTrue"], "BT-W3-02")
ut("test_get_machine_mode", "TBC", 420, "C08", [R + "testGetMachineModeBrewing"], "BT-W3-02")
ut("test_persistent_connection_auto_connect", "TBC", 434, "C09", [Cn + "testFirstCommandConnectsAndAuthenticates"], "BT-W3-01")
ut("test_persistent_connection_reuse", "TBC", 454, "C10", [Cn + "testSequentialCommandsReuseConnection"], "BT-W3-01")
ut("test_auto_disconnect_after_idle", "TBC", 475, "C11", [Cn + "testIdleTimeoutDisconnects"], "BT-W3-01")
ut("test_timer_reset_on_new_command", "TBC", 493, "C12 (restated)", [Cn + "testCommandRestartsIdleTimer"], "BT-W3-01")
ut("test_concurrent_commands_thread_safe", "TBC", 516, "C13", [Cn + "testConcurrentCommandsConnectOnce"], "BT-W3-01")
ut("test_exception_triggers_disconnect", "TBC", 544, "C14", [Cn + "testCommandErrorDropsIdleConnection"], "BT-W3-01")
ut("test_characteristic_resolution_failure_clears_cache", "TBC", 565, "C15", [Cn + "testMissingCharacteristicRediscoversThenDrops"], "BT-W3-01")
ut("test_is_connected_property", "TBC", 584, "C16", [Cn + "testIsConnectedLifecycle"], "BT-W3-01")
ut("test_reconnect_after_disconnect", "TBC", 600, "C17", [Cn + "testCommandAfterManualDisconnectReconnects"], "BT-W3-01")
ut("test_auth_read_back_failure", "TBC", 617, "C18", [A + "testWrongTokenReadsTenTimesThenFails"], "BT-W3-01")
ut("test_auth_read_back_retries_until_confirmed", "TBC", 636, "C19", [A + "testAuthRetriesUntilConfirmed"], "BT-W3-01")
ut("test_start_shot_counter_characteristic_missing", "TBC", 652, "C20", [L + "testMissingCharacteristicReturnsFalseAfterOneRediscovery"], "BT-W3-03")
ut("test_start_shot_counter_rediscovers_services", "TBC", 677, "C21", [L + "testStaleServiceCacheRediscoversCharacteristic"], "BT-W3-03")
ut("test_start_shot_counter", "TBC", 699, "C22", [L + "testStartSubscribesAndDisconnectUnsubscribes"], "BT-W3-03")
ut("test_shot_counter_suppresses_auto_disconnect", "TBC", 719, "C23", [L + "testShotCounterSuppressesIdleDisconnect"], "BT-W3-03")
ut("test_shot_counter_state_machine", "TBC", 784, "C24 [sequence], C25 [malformed]", [N + "testSequence", N + "testMalformedPayloadsAreDropped"], "BT-W3-04")
ut("test_shot_counter_discards_replay", "TBC", 822, "C26 [during_subscribe], C27 [after_subscribe]", [N + "testReplayDuringSubscribeIsDropped", N + "testReplayAfterSubscribeIsDropped"], "BT-W3-04")
ut("test_shot_counter_telemetry", "TBC", 848, "C28", [N + "testTelemetryRoutingAndParsing"], "BT-W3-04")
ut("test_shot_counter_recorded_sessions", "TBC", 912, "C29", ["ShotCounterRecordedSessionTests.testRecordedMorning20261005"], "BT-W3-04")
ut("test_shot_counter_brewing_start_time", "TBC", 980, "C30", [N + "testBrewingStartTimeIsEarliestEstimate"], "BT-W3-04")
ut("test_shot_counter_callback_exception_is_caught", "TBC", 1009, "C31 (restated, D4)", [N + "testCancelledConsumerDoesNotAffectClient"], "BT-W3-04")
ut("test_shot_counter_reconnects_after_disconnect", "TBC", 1022, "C32", [RC + "testReconnectsAndResetsTrackerAfterLinkLoss"], "BT-W3-05")
ut("test_shot_counter_reconnect_retries_failed_connections", "TBC", 1053, "C33 (restated counts)", [RC + "testReconnectRetriesThroughConnectErrors"], "BT-W3-05")
ut("test_shot_counter_gives_up_after_auth_failures", "TBC", 1072, "C34", [RC + "testGivesUpAfterThreeAuthFailures"], "BT-W3-05")
ut("test_shot_counter_no_reconnect_after_disconnect", "TBC", 1094, "C35", [RC + "testUserDisconnectDoesNotReconnect"], "BT-W3-05")
ut("test_start_shot_counter_twice", "TBC", 1108, "C36 (restated, D4)", [L + "testStartTwiceSubscribesOnce"], "BT-W3-03")
ut("test_stop_shot_counter_reentrant", "TBC", 1126, "C37 [stop_shot_counter], C38 [disconnect] (restated, D4)", [L + "testStopFromEventConsumerIsNoOp"], "BT-W3-03")
ut("test_machine_stop_from_update_callback", "TBC", 1156, "C39 (restated, D4)", ["ShotCounterOverlayTests.testStopFromEventConsumerDoesNotRecurse"], "BT-W3-09")
ut("test_stop_shot_counter_notifies_connection_callback", "TBC", 1183, "C40", [L + "testDisconnectReportsUnsubscribed"], "BT-W3-03")
ut("test_cancelled_connect_does_not_keep_unauthenticated_link", "TBC", 1197, "C41", [A + "testCancellationDuringAuthDropsLink"], "BT-W3-01")
ut("test_read_response_is_nul_terminated", "TBC", 1223, "C42", [R + "testReadResponseCutAtFirstNul"], "BT-W3-02")
ut("test_get_plumbed_in", "TBC", 1238, "C43–C46 (4 cases)", [R + "testGetPlumbedIn"], "BT-W3-02")
ut("test_requests_are_atomic", "TBC", 1253, "C47", [Cn + "testRequestWriteReadPairsAreAtomic"], "BT-W3-01")
ut("test_command_error_keeps_shot_counter_connection", "TBC", 1287, "C48", [L + "testCommandErrorKeepsShotCounterLink"], "BT-W3-03")
ut("test_authentication_failed_flag", "TBC", 1305, "C49", [A + "testAuthenticationFailedFlagSetAndCleared"], "BT-W3-01")
ut("test_discover_devices_prefixes", "TBC", 1326, "C50", ["BluetoothDiscoveryTests.testNamePrefixFilter"], "BT-W1-10")
ut("test_ble_device_callback", "TBC", 1345, "C51 (restated, D3)", [Cn + "testConnectUsesStoredPeripheralID"], "BT-W3-01")
ut("test_connection_callback_connect_and_idle_disconnect", "TBC", 1361, "C52", [Cn + "testConnectionEventsConnectAndIdle"], "BT-W3-01")
ut("test_connection_callback_connection_lost", "TBC", 1382, "C53", [Cn + "testConnectionEventsDeduplicate"], "BT-W3-01")
ut("test_connection_callback_not_called_on_failed_authentication", "TBC", 1405, "C54", [A + "testUnauthenticatedLinkNeverReportedConnected"], "BT-W3-01")
ut("test_connection_callback_unregister", "TBC", 1424, "C55 (restated, D4)", [Cn + "testCancelledEventStreamStopsDelivery"], "BT-W3-01")

DR, SE, FB, OV = "BluetoothDashboardRefreshTests.", "BluetoothCommandSideEffectTests.", "BluetoothFallbackTests.", "ShotCounterOverlayTests."
ut("test_get_dashboard_from_bluetooth", "TBD", 110, "D01", [DR + "testRefreshMicraFromBluetooth"], "BT-W3-08")
ut("test_get_dashboard_no_bluetooth", "TBD", 183, "D02", [DR + "testRefreshWithoutClientThrows"], "BT-W3-08")
ut("test_get_model_info_from_bluetooth", "TBD", 189, "D03", [DR + "testModelInfoFromCapabilities"], "BT-W3-08")
ut("test_get_dashboard_initializes_missing_widgets", "TBD", 213, "D04", [DR + "testRefreshCreatesMissingWidgetsMiniR"], "BT-W3-08")
ut("test_get_dashboard_without_steam_level_support", "TBD", 269, "D05", [DR + "testRefreshGS3UsesSteamTemperature"], "BT-W3-08")
ut("test_get_dashboard_mini_original_temperature_only", "TBD", 334, "D06", [DR + "testRefreshOriginalMiniUsesSteamTemperature"], "BT-W3-08")
ut("test_set_power_updates_dashboard", "TBD", 396, "D07", [SE + "testSetPowerUpdatesModeOnly"], "BT-W3-07")
ut("test_set_power_off_updates_dashboard", "TBD", 414, "D08", [SE + "testSetPowerOffUpdatesMode"], "BT-W3-07")
ut("test_set_steam_updates_dashboard", "TBD", 436, "D09", [SE + "testSetSteamUpdatesEnabled"], "BT-W3-07")
ut("test_set_coffee_temp_updates_dashboard", "TBD", 452, "D10", [SE + "testSetCoffeeTempUpdatesWidget"], "BT-W3-07")
ut("test_set_steam_level_updates_dashboard", "TBD", 470, "D11", [SE + "testSetSteamLevelUpdatesWidget"], "BT-W3-07")
ut("test_set_steam_temp_updates_dashboard", "TBD", 488, "D12", [SE + "testSetSteamTempUpdatesWidget"], "BT-W3-07")
ut("test_failed_command_does_not_update_dashboard", "TBD", 506, "D13 (restated, D18)", [SE + "testNonSuccessStatusWithoutCloudThrowsCommandFailed"], "BT-W3-07")
ut("test_bluetooth_exception_does_not_update_dashboard", "TBD", 533, "D14 (restated, D18)", [SE + "testBluetoothErrorWithoutCloudRethrows"], "BT-W3-07")
ut("test_get_dashboard_from_bluetooth_statuses", "TBD", 606, "D15–D19 (5 cases)", [DR + "testStatusDerivation"], "BT-W3-08")
ut("test_get_dashboard_from_bluetooth_steam_level", "TBD", 650, "D20–D25 (6 cases)", ["BluetoothEnumsTests.testSteamLevelFromTarget"], "BT-W1-01")
ut("test_get_dashboard_from_bluetooth_plumb_in_unsupported", "TBD", 674, "D26", [DR + "testPlumbInUnsupportedFallsBackToTank"], "BT-W3-08")

ut("test_bluetooth_command_with_cloud_fallback", "TM", 206, "M01–M12 (6 commands × {bluetooth, cloud})", [FB + "testCommandUsesBluetoothThenCloud"], "BT-W3-07")
ut("test_failing_command", "TM", 486, "M13 (restated, D18)", [FB + "testBothTransportsFailThrowsCloudError"], "BT-W3-07")
ut("test_connect_bluetooth_shot_counter", "TM", 745, "M14", [OV + "testStartIgnoresCloudSupportFlag"], "BT-W3-09")
ut("test_register_bluetooth_connection_callback", "TM", 765, "M15 (restated, D4; moved R6)", ["BluetoothDeviceStateTests.testBluetoothConnectionEventsForwardOrFinish"], "BT-W3-06")
ut("test_shot_counter_overrides_machine_status", "TM", 784, "M16", [OV + "testOverrideLifecycle"], "BT-W3-09")
ut("test_shot_counter_falls_back_to_websocket_callback", "TM", 835, "M17 (restated, D13)", [OV + "testBrewingUpdateRendersObservableDashboard"], "BT-W3-09")
ut("test_disconnect_bluetooth_shot_counter", "TM", 853, "M18", [OV + "testStopRestoresSilently"], "BT-W3-09")
ut("test_shot_counter_state_expires", "TM", 882, "M19", [OV + "testStaleStateExpiresAfter60s"], "BT-W3-09")
ut("test_bluetooth_refresh_after_shot_replaces_cloud_status", "TM", 917, "M20", [OV + "testBluetoothRefreshBecomesBaseline"], "BT-W3-09")
ut("test_bluetooth_refresh_while_brewing_keeps_cloud_start_time", "TM", 940, "M21", [OV + "testBluetoothRefreshKeepsCloudStartTime"], "BT-W3-09")
ut("test_bluetooth_telemetry", "TM", 961, "M22", [OV + "testTelemetryMergeAndModeApply"], "BT-W3-09")
ut("test_bluetooth_machine_mode_during_shot", "TM", 995, "M23", [OV + "testModeDuringShotAppliedAfterShot"], "BT-W3-09")
ut("test_bluetooth_machine_mode_falls_back_to_websocket_callback", "TM", 1014, "M24 (restated, D13)", [OV + "testTemperatureTelemetryDoesNotChangeDashboard"], "BT-W3-09")
ut("test_bluetooth_shot_counter_active", "TM", 1036, "M25", [OV + "testShotCounterActiveMirrorsClient"], "BT-W3-09")
ut("test_get_model_info_from_bluetooth_errors", "TM", 1049, "M26", [DR + "testModelInfoErrors"], "BT-W3-08")
ut("test_get_model_info_from_bluetooth_unknown_model", "TM", 1063, "M27 (restated)", [DR + "testUnknownFamilyThrowsAndKeepsModel"], "BT-W3-08")
ut("test_get_dashboard_from_bluetooth_error", "TM", 1079, "M28", [DR + "testRefreshErrorPropagatesWithoutMutation"], "BT-W3-08")
ut("test_set_power_updates_group_status", "TM", 1089, "M29", [SE + "testSetPowerUpdatesGroupStatus"], "BT-W3-07")
ut("test_set_smart_standby_auto_standby", "TM", 1137, "M30–M31 (2 cases)", [FB + "testSmartStandbyUsesCloudAutoStandbyWhenSupported"], "BT-W3-07")
ut("test_bluetooth_failure_without_cloud", "TM", 1155, "M32 (restated, D18)", [FB + "testBluetoothFailureWithoutCloudRethrows"], "BT-W3-07")

ut("test_cloud_only_without_cloud_client", "TT", 29, "T00 (added by plan, R7)", ["MachineTransportRoutingTests.testCloudOnlyWithoutCloudClientThrows"], "BT-W1-11")
ut("test_connection_properties_without_clients", "TT", 36, "T01", ["BluetoothDeviceStateTests.testPropertiesWithoutClients"], "BT-W3-06")
ut("test_connection_properties_with_clients", "TT", 48, "T02", ["BluetoothDeviceStateTests.testPropertiesWithClients"], "BT-W3-06")
ut("test_shot_counter_supported", "TMO", 395, "O01–O03 (true/false already covered by ModelsTests)", ["BluetoothEnumsTests.testShotCounterSupportedNull"], "BT-W1-01")
ut("test_model_name_from_bluetooth_family", "TMO", 416, "O04–O07", ["BluetoothEnumsTests.testFamilyMapping"], "BT-W1-01")
ut("test_debug_log_masks_bluetooth_token", "TCC", 322, "X01", ["BluetoothTokenTests.testTokenDescriptionIsRedacted", "BluetoothTokenTests.testBluetoothAuthTokenFromThings"], "BT-W1-06")

# ------------------------------------------------------------------ SPEC §2 parity inventory → owners (§7.1)
INV = [
    # (§, upstream, angstrom, implement owner(s), test owner(s))
    ("2.1", "`__init__(ble_device, ble_token, ble_device_callback)` (BT:142-181)", "`init(transport:peripheral:token:logHandler:)`; callback not ported (D3)", "BT-W0-01, BT-W1-09", "BT-W3-01 (C51)"),
    ("2.1", "`is_connected` (183-186)", "`isConnected` (authenticated, D11)", "BT-W0-01", "BT-W3-01 (C16)"),
    ("2.1", "`register_connection_callback` (188-206)", "`connectionEvents()`", "BT-W1-09", "BT-W3-01 (C52, C53, C55)"),
    ("2.1", "`_set_connected` (208-214)", "`setConnected(_:)`", "BT-W1-09", "BT-W1-09, BT-W3-01"),
    ("2.1", "`authentication_failed` (216-222)", "`authenticationFailed`", "BT-W0-01, BT-W1-09", "BT-W3-01 (C49)"),
    ("2.1", "`shot_counter_active` (224-231)", "`shotCounterActive`", "BT-W0-01", "BT-W3-03"),
    ("2.1", "`_ensure_connected` (233-269)", "`ensureConnected(refresh:)`", "BT-W1-09", "BT-W1-09, BT-W3-01 (C09, C10)"),
    ("2.1", "`_reset_disconnect_timer` / `_auto_disconnect` (271-291)", "`resetIdleTimer()` + idle task", "BT-W1-09", "BT-W3-01 (C11, C12)"),
    ("2.1", "`_disconnect_internal` (293-311)", "`disconnectInternal(fromIdleTimer:)`", "BT-W1-09", "BT-W1-09"),
    ("2.1", "`_drop_connection` (313-317)", "`dropConnection` / `dropConnectionInBackground`", "BT-W1-09", "BT-W3-01 (C14)"),
    ("2.1", "`disconnect()` (319-325)", "`disconnect() async`", "BT-W1-09", "BT-W3-01 (C17), BT-W3-03 (C40)"),
    ("2.1", "`start_shot_counter` (327-362)", "`startShotCounter()` + `shotCounterEvents()`", "BT-W2-02", "BT-W3-03 (C22, C36)"),
    ("2.1", "`stop_shot_counter` (364-371)", "`stopShotCounter()`", "BT-W2-02", "BT-W3-03 (C37, C38)"),
    ("2.1", "`_disable_shot_counter` (373-394)", "`disableShotCounter()`", "BT-W2-02", "BT-W3-03"),
    ("2.1", "`_stop_notify_internal` (396-401)", "`stopNotifyInternal()`", "BT-W2-02", "BT-W3-03"),
    ("2.1", "`_subscribe_shot_counter` (403-439)", "`subscribeShotCounter()`", "BT-W2-02", "BT-W3-03 (C20, C21)"),
    ("2.1", "`_handle_shot_counter_notification` (441-465)", "`handleShotCounterNotification(_:)`", "BT-W2-02", "BT-W3-04 (C24–C30)"),
    ("2.1", "`_on_bleak_disconnected` (467-473)", "`handleLinkEvent(.disconnected, from:)`", "BT-W1-09", "BT-W1-09, BT-W3-01"),
    ("2.1", "`_handle_connection_lost` (475-486)", "`handleConnectionLost()`", "BT-W1-09", "BT-W3-05 (C32)"),
    ("2.1", "`_reconnect_shot_counter` (488-520)", "`reconnectLoop()`", "BT-W2-02", "BT-W3-05 (C32–C35)"),
    ("2.1", "`discover_devices` (522-537)", "`static discoverMachines(transport:duration:)` (+ Angstrom-only unfiltered `scanAll`)", "BT-W1-10", "BT-W1-10 (C50, `testScanAllIsUnfiltered`)"),
    ("2.1", "`read_token` (539-547)", "`static readToken(transport:peripheral:)`", "BT-W1-10", "BT-W1-10 (G-CODEC-1)"),
    ("2.1", "`address` (549-553)", "`nonisolated let peripheral`", "BT-W0-01", "BT-W3-01 (C51)"),
    ("2.1", "`get_machine_mode` (555-560)", "`machineMode()`", "BT-W2-01", "BT-W3-02 (C08)"),
    ("2.1", "`get_machine_capabilities` (562-568)", "`machineCapabilities()`", "BT-W2-01", "BT-W3-02 (C04)"),
    ("2.1", "`get_tank_status` (570-575)", "`tankStatus()`", "BT-W2-01", "BT-W3-02 (C07)"),
    ("2.1", "`get_plumbed_in` (577-582)", "`isPlumbedIn()`", "BT-W2-01", "BT-W3-02 (C43–C46)"),
    ("2.1", "`get_boilers` (584-588)", "`boilers()`", "BT-W2-01", "BT-W3-02 (C05)"),
    ("2.1", "`get_smart_standby_settings` (590-594)", "`smartStandby()`", "BT-W2-01", "BT-W3-02 (C06)"),
    ("2.1", "`set_power` (596-600)", "`setPower(on:)`", "BT-W2-01", "BT-W3-02 (C01)"),
    ("2.1", "`set_steam` (602-608)", "`setSteam(on:)`", "BT-W2-01", "BT-W3-02"),
    ("2.1", "`set_smart_standby` (610-618)", "`setSmartStandby(enabled:mode:minutes:)`", "BT-W2-01", "BT-W3-02 (C03)"),
    ("2.1", "`set_temp` (620-626)", "`setTemperature(boiler:celsius:)`", "BT-W2-01", "BT-W3-02 (C02)"),
    ("2.1", "`_authenticate` (628-653)", "`authenticate(_:)`", "BT-W1-09", "BT-W3-01 (C18, C19, C49)"),
    ("2.1", "`__read_value_from_machine` (655-657)", "`readSetting(_:)`", "BT-W2-01", "BT-W3-02"),
    ("2.1", "`_read_bluetooth_message` / `__write_bluetooth_message` (659-700)", "`request(_:frame:)` + `BluetoothCodec`", "BT-W2-01, BT-W1-02", "BT-W3-02 (C42), BT-W1-02"),
    ("2.1", "`__send_command` (702-710)", "`sendCommand(_:)`", "BT-W2-01", "BT-W3-02"),
    ("2.1", "`_resolve_characteristic` (712-747)", "`resolve(_:on:)` (D7)", "BT-W2-01", "BT-W3-01 (C15), BT-W3-03 (G-CONN-6)"),
    ("2.1", "`disconnect_on_exception` (114-136)", "request wrapper `request(_:frame:)`", "BT-W2-01", "BT-W3-01 (C14), BT-W3-03 (C48)"),
    ("2.1", "`_BrewingTracker` (77-111)", "`BrewingTracker`", "BT-W1-04", "BT-W1-04, BT-W3-04"),
    ("2.1", "`_parse_bool` (62-64)", "`BluetoothWireCoercion.parseBool(_:)`", "BT-W0-01", "BT-W1-01"),
    ("2.1", "`_safe_call` (67-74)", "not ported (D4)", "—", "BT-W3-04 (C31 restated)"),
    ("2.1", "`_utcnow` (57-59)", "`BluetoothTransport.now`", "BT-W0-01, BT-W0-03 (test clock)", "BT-W3-04 (C30)"),
    ("2.1", "logging (`_logger.*`)", "optional `logHandler`, never the token", "BT-W1-09", "BT-W1-09, BT-W4-05"),
    ("2.2", "`READ_/WRITE_/GET_TOKEN_/AUTH_/SHOT_COUNTER_CHARACTERISTIC` (BT:40-44)", "`BluetoothConstants.*Characteristic`", "BT-W0-01", "BT-W1-01, BT-W2-09"),
    ("2.2", "`BT_MODEL_PREFIXES` (BT:46)", "`machineNamePrefixes`", "BT-W0-01", "BT-W1-01, BT-W1-10"),
    ("2.2", "`IDLE_TIMEOUT`, `AUTH_SUCCESS`, `AUTH_READ_ATTEMPTS`, `AUTH_READ_INTERVAL`, `MAX_AUTH_FAILURES`, `RECONNECT_INITIAL_DELAY`, `RECONNECT_MAX_DELAY` (BT:47-54)", "`BluetoothTiming` / `BluetoothConstants.authSuccess`", "BT-W0-01", "BT-W1-01, BT-W3-01, BT-W3-05"),
    ("2.2", "`establish_connection(max_attempts=3)` (BT:252), `BLEAK_TIMEOUT = 20.0` (BRC:102)", "`connectAttempts`, `connectTimeout`", "BT-W0-01, BT-W1-09", "BT-W1-09 (G-CONN-1)"),
    ("2.3", "`BluetoothMachineCapabilities` (MBT:22-39)", "struct + decoder", "BT-W0-01, BT-W1-03", "BT-W1-03, BT-W3-02"),
    ("2.3", "`BluetoothBoilerDetails` (MBT:42-49)", "struct (Double, D9) + decoder", "BT-W0-01, BT-W1-03", "BT-W1-03, BT-W3-02"),
    ("2.3", "`BluetoothSmartStandbyDetails` (MBT:51-57)", "struct + decoder", "BT-W0-01, BT-W1-03", "BT-W1-03, BT-W3-02"),
    ("2.3", "`BluetoothCommandStatus` (MBT:59-65)", "struct + `isSuccess` + decoder", "BT-W0-01, BT-W1-03", "BT-W1-01, BT-W1-03"),
    ("2.3", "`_known_machine_mode` (MBT:68-70)", "telemetry decoder drops `.other`", "BT-W1-04", "BT-W1-04"),
    ("2.3", "`_PartialNotification.is_empty/merge` (MBT:73-87)", "`isEmpty` / `merging(_:)`", "BT-W0-01", "BT-W1-01"),
    ("2.3", "`BluetoothBrewingData` + `derive_state` (MBT:90-163)", "struct + `deriveState(receivedAt:)`", "BT-W0-01, BT-W1-04", "BT-W1-04, BT-W3-04"),
    ("2.3", "`BluetoothShotCounterUpdate` (MBT:166-188)", "struct", "BT-W0-01", "BT-W1-01, BT-W3-04"),
    ("2.3", "`BluetoothMachineTelemetry` (MBT:191-213)", "struct (`BluetoothJSONValue` statistics)", "BT-W0-01, BT-W1-04", "BT-W1-04, BT-W3-04 (C28)"),
    ("2.3", "`BluetoothReadSetting` (CONST:322-330)", "enum", "BT-W0-01", "BT-W1-01"),
    ("2.3", "`BluetoothBrewingState` (CONST:333-339)", "enum", "BT-W0-01", "BT-W1-01"),
    ("2.3", "`BoilerType` (CONST:307-311)", "`BluetoothBoilerType`", "BT-W0-01", "BT-W1-01"),
    ("2.3", "`SmartStandByType` (CONST:260-264)", "reuse `SmartStandbyAfter`", "existing", "BT-W1-03, BT-W3-02"),
    ("2.3", "`MachineMode` / `MachineState` / `BoilerStatus` (CONST:11-31, 267-275)", "reuse existing enums", "existing", "BT-W1-01"),
    ("2.3", "`SteamTargetLevel` (CONST:141-146)", "reuse `SteamLevel`", "existing", "BT-W1-01"),
    ("2.3", "`STEAM_LEVEL_MAPPING` (MACH:58-62)", "`SteamLevel.bluetoothTargetTemperature`", "BT-W0-01", "BT-W1-01"),
    ("2.3", "`_steam_level_from_temperature` (MACH:78-84)", "`SteamLevel(bluetoothTargetTemperature:)`", "BT-W0-01", "BT-W1-01 (D20–D25)"),
    ("2.3", "`BLE_MACHINE_STATE` (MACH:65-69)", "`MachineState(bluetoothMode:)`", "BT-W0-01", "BT-W1-01"),
    ("2.3", "`BLE_BOILER_STATUS` (MACH:71-75)", "`BoilerStatus(bluetoothMode:)`", "BT-W0-01", "BT-W1-01"),
    ("2.3", "`ModelName.from_string` BLE aliases (CONST:198-218)", "`Model(bluetoothFamily:)` (D8)", "BT-W0-01", "BT-W1-01 (O04–O07)"),
    ("2.3", "`ModelCode[family.name]` (MACH:344)", "not needed (`Model` is name and code)", "—", "BT-W3-08 (D03)"),
    ("2.3", "`STEAM_LEVEL_MODELS` (CONST:182)", "`Model.steamLevelModels`", "BT-W0-01, BT-W1-11", "BT-W1-01, BT-W1-11"),
    ("2.3", "`models_supported((GS3, GS3_AV, GS3_MP, STRADA_X))` (MACH:823)", "`Model.steamTemperatureModels`", "BT-W0-01, BT-W1-11", "BT-W1-11, BT-W3-07"),
    ("2.4", "`BluetoothConnectionFailed` (EXC:20-21)", "`.bluetoothConnectionFailed` + `.bluetoothUnavailable` (D10)", "BT-W0-01, BT-W1-09", "BT-W1-01, BT-W1-09"),
    ("2.4", "`BluetoothAuthenticationFailed` (EXC:46-47)", "`.bluetoothAuthenticationFailed` + `isBluetoothConnectionFailure`", "BT-W0-01", "BT-W1-01, BT-W3-01"),
    ("2.4", "`BleakError`", "`.bluetoothConnectionFailed(String)`", "BT-W1-09", "BT-W1-09 (mapping table)"),
    ("2.4", "bare `TimeoutError` (request phase)", "`.bluetoothTimedOut(String)`", "BT-W1-09, BT-W2-01", "BT-W3-01 (D19)"),
    ("2.4", "`CloudOnlyFunctionality` (EXC:28-35)", "`.cloudOnlyFunctionality`", "BT-W0-01, BT-W1-11", "BT-W1-11 (T00)"),
    ("2.4", "`UnsupportedModel` (EXC:38-39)", "existing `.unsupportedModel`", "existing", "BT-W3-07"),
    ("2.4", "decode errors (`ValueError`, `JSONDecodeError`, …)", "existing `.decoding(String)`", "BT-W1-03, BT-W1-04", "BT-W1-03, BT-W3-02 (G-CODEC-5)"),
    ("2.5", "`LaMarzoccoThing.__init__(serial, cloud_client, bluetooth_client)` (THING:73-90)", "`init(serialNumber:client:bluetooth:snapshot:)`", "BT-W0-02", "BT-W3-06 (T01, T02)"),
    ("2.5", "`bluetooth_client_available` (THING:99-102)", "`hasBluetoothClient`", "BT-W0-02", "BT-W3-06"),
    ("2.5", "`cloud_client_available` (THING:104-107)", "`hasCloudClient`", "BT-W0-02", "BT-W3-06"),
    ("2.5", "`bluetooth_connected` (THING:109-114)", "`isBluetoothConnected`", "BT-W3-06", "BT-W3-06 (G-DEV-9)"),
    ("2.5", "`register_bluetooth_connection_callback` (THING:116-126)", "`bluetoothConnectionEvents()`", "BT-W3-06", "BT-W3-06 (M15)"),
    ("2.5", "`cloud_only` decorator (THING:27-38)", "throwing `client` accessor", "BT-W0-02, BT-W1-11", "BT-W1-11 (T00)"),
    ("2.5", "`models_supported` (THING:41-67)", "existing `requireModel`", "BT-W0-02 (access)", "BT-W3-07"),
    ("2.5", "`_dashboard_config_updated` hook (THING:181-182, MACH:316-323)", "`setBaseDashboard`/`updateBaseDashboard` + `renderDashboard()` (D12)", "BT-W0-02, BT-W1-11", "BT-W1-11, BT-W3-09"),
    ("2.5", "`_widget(cls)` (THING:184-186)", "existing `Dashboard` accessors", "existing", "—"),
    ("2.5", "`get_model_info_from_bluetooth` (MACH:325-348)", "`refreshModelFromBluetooth()`", "BT-W3-08", "BT-W3-08 (D03, M26, M27)"),
    ("2.5", "`get_dashboard_from_bluetooth` (MACH:350-485)", "`refreshDashboardFromBluetooth()` + `applyingBluetoothState`", "BT-W3-08, BT-W1-05", "BT-W3-08 (D01–D06, D15–D19, D26, M28), BT-W1-05"),
    ("2.5", "`_update_machine_mode_widgets` (MACH:487-492)", "existing `settingMachineMode(_:)`", "existing", "BT-W3-07 (M29)"),
    ("2.5", "`set_power` / `set_steam` / `set_steam_level` / `set_coffee_target_temperature` / `set_steam_target_temperature` / `set_smart_standby` (MACH:494-509, 764-841, 870-892)", "six methods routed through `bluetoothFirst`", "BT-W1-11, BT-W3-07", "BT-W3-07 (M01–M13, M29–M32, D07–D14)"),
    ("2.5", "`__bluetooth_command_with_cloud_fallback` (MACH:983-1049)", "`bluetoothFirst(bluetooth:cloud:)`", "BT-W3-07", "BT-W3-07"),
    ("2.5", "`BLE_BREWING_STATE_TIMEOUT = 60` (MACH:88)", "`bluetoothBrewingStateTimeout`", "BT-W0-02", "BT-W3-09 (M19)"),
    ("2.5", "`ble_brewing_update` (MACH:132-135)", "`bluetoothBrewingUpdate`", "BT-W0-02, BT-W3-09", "BT-W3-09"),
    ("2.5", "`bluetooth_telemetry` (MACH:137-143)", "`bluetoothTelemetry`", "BT-W0-02, BT-W3-09", "BT-W3-09 (M22)"),
    ("2.5", "`last_shot_time` (MACH:145-148)", "`lastShotTime`", "BT-W0-02, BT-W3-09", "BT-W3-09"),
    ("2.5", "`bluetooth_shot_counter_active` (MACH:150-156)", "`isShotCounterActive`", "BT-W0-02, BT-W3-09", "BT-W3-09 (M25)"),
    ("2.5", "`connect_bluetooth_shot_counter` (MACH:158-191)", "`startShotCounter()` + `bluetoothEvents()`", "BT-W3-09", "BT-W3-09 (M14)"),
    ("2.5", "`disconnect_bluetooth_shot_counter` (MACH:193-207)", "`stopShotCounter()`", "BT-W3-09", "BT-W3-09 (M18)"),
    ("2.5", "`_on_shot_counter_update` / `_connection` / `_telemetry` (MACH:209-241)", "`handleShotCounterEvent(_:)`", "BT-W3-09", "BT-W3-09 (M16, M22, M23)"),
    ("2.5", "`_drop_ble_brewing_state` / `_clear_…` / `_apply_…` (MACH:243-246, 273-314)", "`clearBluetoothBrewingState(notify:)` + `overlayingBluetoothBrewing(_:)`", "BT-W3-09, BT-W1-05", "BT-W3-09, BT-W1-05"),
    ("2.5", "`_notify_shot_counter_listeners` / `_notify_dashboard_listeners` (MACH:248-271)", "`bluetoothEvents()` + `@Observable`; websocket-config synthesis not ported (D13)", "BT-W3-09", "BT-W3-09 (M17, M24)"),
    ("2.5", "`LaMarzoccoGrinder` accepts `bluetooth_client`, never uses it", "no grinder routing (parity)", "BT-W1-11", "BT-W4-02"),
    ("2.6", "`Thing.ble_auth_token` (GEN:128-130)", "`bluetoothAuthToken(serial:)` (D2)", "BT-W1-06", "BT-W1-06 (X01)"),
    ("2.6", "`_mask_bluetooth_token` (CLOUD:84-92)", "library never logs bodies; `Redact.bluetoothFrame` + existing `Redact.bleAuthToken`", "BT-W1-12, BT-W2-03", "BT-W2-03, BT-W4-05"),
    ("2.6", "`Thing.shot_counter_supported` (GEN:131-136)", "existing `Machine.shotCounterSupported` (doc reworded)", "BT-W0-01", "BT-W1-01 (O01–O03), BT-W3-09 (M14)"),
    ("2.7", "`BleakClientWithServiceCache`, `use_services_cache`, `clear_cache()`", "not ported; intent = `discover(…, refresh: true)`", "BT-W2-01, BT-W2-02", "BT-W3-01 (C15), BT-W3-03 (C21)"),
    ("2.7", "`ble_device_callback`", "not ported (D3)", "—", "BT-W3-01 (C51 restated)"),
    ("2.7", "`_safe_call`", "not ported (D4)", "—", "BT-W3-04 (C31 restated)"),
    ("2.7", "`asyncio.Task(eager_start=True)` re-entrancy (TBC:1125-1180)", "not applicable (streams)", "—", "BT-W3-03 (C37/C38), BT-W3-09 (C39)"),
    ("2.7", "legacy GATT layout (LEG)", "not ported (§1.2)", "—", "BT-W2-11 (no d30a… assumption)"),
    ("2.7", "bleak `pair()`", "not ported (§1.2)", "—", "BT-W2-11"),
    ("2.7", "`ThingDashboardWebsocketConfig` synthesis for listeners", "not ported (D13)", "—", "BT-W3-09 (M17, M24 restated)"),
]

# ------------------------------------------------------------------ hardware checklist (§6)
HW = [
    ("H1", "`angcli ble scan`, then `angcli ble gatt --peripheral <id>` on every available model", "service UUID hosting 0a0b…–0e0b…, characteristic property flags, notify vs indicate on 0e0b…", "U1, U2"),
    ("H2", "`angcli ble listen --peripheral <id> --raw`: read the `[mtu n]` marker on a Mac; repeat on an iPhone in an app that links AngstromBluetooth (maintainer-supplied, SPEC §9.6; no package builds one)", "negotiated ATT MTU; whether long writes are needed", "U14"),
    ("H3", "On a fresh macOS user, or after `tccutil reset Bluetooth`, run `angcli ble scan` and watch the state while the TCC prompt is on screen", "whether state reads .unknown or .unauthorized during the prompt; whether `poweredOnWait` (10 s) suffices", "U17, §8.1"),
    ("H4", "Deny Bluetooth in System Settings, then turn Bluetooth off, running `angcli ble read machineMode` each time; turn the radio off during `ble listen`", "the §8.1 error mapping; whether `[disconnected]` arrives on power-off", "§8.1"),
    ("H5", "Build angcli without the embedded Info.plist (local, uncommitted change) and a Pronto build without the usage string; run a scan", "crash vs silent deny when the usage string is missing", "U16"),
    ("H6", "Rebuild angcli/Pronto ad-hoc, self-signed and Developer ID; check whether the Bluetooth grant persists", "TCC grant persistence across signatures", "U16"),
    ("H7", "Run `angcli ble scan` from Terminal, iTerm2, the VS Code terminal and over ssh", "TCC attribution for a CLI", "U16"),
    ("H8", "Connect with angcli while the official app or phone is connected to the machine, and the reverse", "single-central behaviour and its error signature", "U12"),
    ("H9", "Compare `ble scan` ids from angcli vs Pronto; repeat after reboot, Bluetooth reset and 'Forget device'", "CBPeer.identifier scope", "U18"),
    ("H10", "`angcli ble scan --all` (public `scanAll`, unfiltered) per model; note names vs cloud serials", "advertised name format; MINI vs LINEA prefix per model", "U3"),
    ("H11", "Only if the custom-executor adapter design is ever tried: run the assumeIsolated probe on macOS 14", "R-4 trap risk (not applicable to the shipped design)", "—"),
    ("H12", "`angcli ble listen --raw`: count the auth reads before 0x01", "whether 10 × 50 ms is enough", "auth timing"),
    ("H13", "`angcli ble listen --raw` right after subscribe: is the first notification a replay, and does it precede `[subscribed]`?", "replay always sent; notify-before-ack routing", "U15"),
    ("H14", "`angcli ble listen --raw` during a shot and at idle; compare notification lengths with REC line 23 (418 B)", "whole notifications at Apple's MTU", "U14"),
    ("H15", "If MTU < 93: `angcli ble cmd standby --enabled true --minutes 30 --mode PowerOn --confirm`", "long-write support", "U14"),
    ("H16", "After first use: any OS pairing alert, or a bonded entry in System Settings?", "encryption/bonding requirements", "U2"),
    ("H17", "`angcli ble token --peripheral <id>` in and out of pairing mode", "token read behaviour and the ATT error code", "U5, U4 (length only)"),
    ("H18", "Sleep/wake the Mac for 5 min and toggle Bluetooth while `ble listen` runs", "D14 recovery; reconnect behaviour", "D14"),
    ("H19", "Pronto hidden for 30 min with BLE idle: is the idle disconnect late in the raw tap?", "App Nap / timer coalescing", "§8.3"),
    ("H20", "Reboot or update the machine while `ble listen` is connected", "`[services invalidated]` path (D7c)", "D7"),
    ("H21", "The maintainer-supplied iOS app (as H2) in background, with and without `UIBackgroundModes` → `bluetooth-central`. If no such app exists at A5, record H2-iOS and H21 as not run and list U14-on-iOS and §8.6 as unverified in the release notes", "foreground-only v1 assumptions", "§8.6"),
    ("H22", "`angcli ble read machineCapabilities` on **each** model", "family strings (GS3 MP `GS3` vs `GS3MP`; Mini R `LINEAMINI2023`)", "U13"),
    ("H23", "`angcli ble cmd temp coffee 93 --confirm`, then `93.5`", "firmware accepts integral `93` (D6) and fractional values", "U7"),
    ("H24", "`angcli ble cmd temp coffee 200 --confirm` (expected rejection)", "failure status strings and casing", "U8"),
    ("H25", "`angcli ble read isPlumbedIn` on the oldest available firmware", "reply to an unknown read setting", "U9"),
    ("H26", "`angcli ble read smartStandBy` with smart standby disabled", "`\"enabled\":\"false\"` vs `false` (D5 relevance)", "D5"),
    ("H27", "`angcli ble read all` repeatedly, watching latency", "is the response ready right after the write ack; max response size", "U6"),
    ("H28", "Notarise a Pronto (or angcli) build that links AngstromBluetooth and scans (hardened runtime, no entitlement); run it on a Mac with Bluetooth on (no espresso machine needed)", "Gatekeeper accepts it and the TCC prompt appears", "SPEC §8.3"),
]
RELEASE_CHECKS = [
    ("X1", "Run upstream's Bluetooth suites at 4c639ee: `uv run --frozen --extra dev pytest tests/test_bluetooth_client.py tests/test_bluetooth_dashboard.py tests/test_machine.py`", "the 123 upstream cases pass (SPEC U21)"),
    ("X2", "Run upstream's recorded-session test with prints of every update's brewing_start_time", "the per-line golden of SPEC §9.3.4 (U22)"),
    ("X3", "In `$UPSTREAM`, decode each BT-COERCE / BT-NTF-COERCE input (SPEC §9.3.2–§9.3.3) with the 4c639ee models, e.g. `uv run --frozen python -c \"from pylamarzocco.models import BluetoothCommandStatus as S; print(S.from_dict({'id': 'a', 'message': None, 'status': 'success'}))\"` (expect `message='None'`); notifications go through `BluetoothBrewingData.from_dict` and `BluetoothMachineTelemetry.from_dict` of `json.loads(payload)`", "the Upstream column of the coercion vectors (SPEC U10, settled with mashumaro 3.17; re-run if `uv.lock` moves)"),
    ("X4", "Build with the oldest Xcode whose Swift is 6.0 (the tools floor)", "SPEC U20"),
    ("X5", "TestFlight/App Store upload of a build that links AngstromBluetooth", "SPEC U19 (justifies the leaf product)"),
    ("X6", "Ask the upstream author whether the payloads in tests/test_bluetooth_client.py and tests/conftest.py are real captures", "SPEC U11"),
]

# ------------------------------------------------------------------ SPEC file-map rows that must be accounted for (§7.3)
SPEC_FILEMAP = [
    "Package.swift", "Sources/Angstrom/Models.swift", "Sources/Angstrom/Commands.swift",
    P.P_CONST, P.P_TRANSPORT, P.P_TOKEN, P.P_ENUMS, P.P_COERCE, P.P_MODELS, P.P_SCMODELS, P.P_DIAG,
    "Sources/AngstromBluetooth/Placeholder.swift", P.TS_FIXTURE, "Tests/AngstromTestSupport/*.swift",
    P.P_CODEC, P.P_DECODER, P.P_BSM, P.P_CLIENT, P.P_CLIENT_REQ, P.P_CLIENT_SC, P.P_CLIENT_DISC, P.P_OPTABLE,
    P.P_CB_CENTRAL, P.P_CB_LINK, P.P_CB_TRANSPORT, P.P_CB_DOCC, P.P_DASH, P.P_CLOUDTOKEN,
    P.P_UI_MAIN, P.P_UI_EVENT, P.P_UI_CMD, P.P_UI_DASH, P.P_UI_CONN, P.P_UI_SC,
    "Tests/AngstromTests/Bluetooth/*.swift", "Tests/AngstromUITests/Bluetooth/*.swift",
    P.C_PKG, P.C_PLIST, P.C_ANGCLI, P.C_OUTPUT, P.C_BLE, P.C_SESSION, P.C_SCAN, P.C_GATT, P.C_TOKEN, P.C_READ, P.C_CMD,
    P.C_LISTEN, P.C_BLEOUT, "cli/Tests/angcliTests/BleTests.swift", P.D_CLISPEC, P.D_CLIREADME,
    P.D_ANG, P.D_BTART, P.D_GS, P.D_UIDOCC, P.D_CLAUDE, P.D_README, P.D_UPSTREAM, P.D_DOCSYML, P.D_DRIFT,
    ".github/workflows/ci.yml",
]
SPECIAL = {
    "Sources/AngstromBluetooth/Placeholder.swift": "not created (R1): BT-W0-01 creates `BluetoothTransport+CoreBluetooth.swift` instead",
    "cli/Tests/angcliTests/BleTests.swift": "split into five files (R8): BT-W2-03 (2), BT-W2-04, BT-W2-05, BT-W2-06; placeholders by BT-W1-12",
    ".github/workflows/ci.yml": "no change (SPEC §11); BT-W2-07 acceptance and BT-W5-01 verify it is unchanged",
}

# ------------------------------------------------------------------ waves
WAVES = [
    dict(id=0, name="Contracts", mode="dag"),
    dict(id=1, name="Core protocol pieces, client core, adapter, UI funnel, CLI scaffolding", mode="parallel"),
    dict(id=2, name="Client behaviours, CLI commands, docs; review of Wave 1", mode="parallel"),
    dict(id=3, name="Client parity suites and the AngstromUI Bluetooth layer; review of the CLI", mode="parallel"),
    dict(id=4, name="Independent area verification", mode="parallel"),
    dict(id=5, name="Final integration", mode="serial"),
]
GATE_BASE = [P.BUILD, P.TEST, P.CLI_BUILD, P.CLI_TEST, P.WARN, P.CLI_WARN, P.BLOCKED]
DOCS_BUILD = ("swift package --allow-writing-to-directory .build/bt-docs generate-documentation --target Angstrom --target AngstromUI "
              "--target AngstromBluetooth --enable-experimental-combined-documentation --disable-indexing --output-path .build/bt-docs")
IOS_BUILD = "xcodebuild -scheme Angstrom-Package -destination 'generic/platform=iOS Simulator' -quiet build"
FINAL_STUBS = "bash -c '! grep -rn \"unimplemented: BT-\" Sources Tests cli/Sources'"


def wave_stub_check(k):
    return f"bash -c '! grep -rnE \"unimplemented: BT-W[0-{k}]-\" Sources Tests cli/Sources'"


WAVES[0]["gate"] = GATE_BASE + [
                    P.stub_owners("Sources Tests cli/Sources", "BT-W1-(0[2-9]|10)|BT-W2-0[12]|BT-W3-0[6-9]"),
                    "bash -c 'cmp Tests/AngstromTestSupport/Fixtures/shot_counter_2026-10-05.txt \"$UPSTREAM/tests/fixtures/machine/shot_counter_2026-10-05.txt\"'"]
WAVES[1]["gate"] = GATE_BASE + [wave_stub_check(1)]
WAVES[2]["gate"] = GATE_BASE + [wave_stub_check(2)]
WAVES[3]["gate"] = GATE_BASE + [FINAL_STUBS]
WAVES[4]["gate"] = GATE_BASE + [FINAL_STUBS]

# coverage commands for BT-W5-01
fn_list = " ".join(sorted({u["fn"] for u in UT}))
swift_names = sorted({s for u in UT for s in u["swift"]})
COVER_UPSTREAM = ("bash -c 'm=0; for t in " + fn_list +
                  "; do grep -rqF \"Upstream: $t (\" Tests || { echo \"MISSING $t\"; m=1; }; done; exit $m'")
# Class.method: the method must be declared in a file that declares the class (names alone are not unique).
COVER_SWIFT = ("bash -c 'm=0; for t in " + " ".join(swift_names) +
               "; do c=${t%%.*}; f=${t#*.}; files=$(grep -rlE \"class $c[^A-Za-z0-9_]\" Tests); "
               "{ [ -n \"$files\" ] && grep -qE \"func $f\\(\" $files; } || { echo \"MISSING $t\"; m=1; }; done; exit $m'")
OWNERSHIP_AUDIT = ("python3 -c 'import json,subprocess,sys; d=json.load(open(\"docs/bluetooth/work-packages.json\")); "
                   "own={p for k in d[\"packages\"] for p in k[\"owns\"][\"create\"]+k[\"owns\"][\"modify\"]}|"
                   "{\"docs/bluetooth/SPEC.md\",\"docs/bluetooth/PLAN.md\",\"docs/bluetooth/work-packages.json\"}; "
                   "ch=subprocess.run([\"git\",\"diff\",\"--name-only\",\"e1bc403...HEAD\"],capture_output=True,text=True,check=True).stdout.split(); "
                   "bad=[p for p in ch if p not in own and not p.startswith(\"docs/bluetooth/\") and p != \".gitignore\"]; "
                   "print(\"\\n\".join(bad)); sys.exit(1 if bad else 0)'")
MUST_NOT_CHANGE = ("bash -c 'git diff --quiet e1bc403 -- Sources/Angstrom/Widgets.swift Sources/Angstrom/Enums.swift "
                   "Sources/Angstrom/Optimistic.swift Sources/Angstrom/WebSocket.swift Sources/Angstrom/LaMarzoccoCloudClient.swift "
                   "Sources/Angstrom/Diagnostics.swift Sources/AngstromUI/MachineSnapshot.swift Sources/Angstrom/Stomp.swift "
                   "Sources/Angstrom/Proof.swift Sources/Angstrom/InstallationKey.swift Sources/Angstrom/Statistics.swift "
                   "Sources/Angstrom/Settings.swift .github/workflows/ci.yml && "
                   "test -z \"$(git diff --name-only --diff-filter=MD e1bc403 -- Tests/AngstromTests Tests/AngstromUITests cli/Tests | grep -v /Bluetooth/)\"'")
FINAL = WAVES[5]
FINAL["gate"] = GATE_BASE + [FINAL_STUBS, DOCS_BUILD, IOS_BUILD, "swift build -c release",
                             COVER_UPSTREAM, COVER_SWIFT, OWNERSHIP_AUDIT, MUST_NOT_CHANGE]
for p in P.PACKAGES:
    if p["id"] == "BT-W5-01":
        p["acceptance"] = list(FINAL["gate"])

# ------------------------------------------------------------------ tests per package (parity from UT + extras)
for p in P.PACKAGES:
    parity = []
    for u in UT:
        if u["owner"] == p["id"]:
            parity.append(f"{u['cases']} `{u['fn']}` ({FILES[u['file']]}:{u['line']}) → " + ", ".join(u["swift"]))
    p["tests"] = parity + p["extraTests"]

# ------------------------------------------------------------------ briefs
IMPL_PRE = (
    "You are an implementation agent for work package {id}, \"{title}\" (Wave {wave}, size {size}), of the Angstrom Bluetooth port "
    "(a Swift 6 SwiftPM library porting pylamarzocco). You work alone in your own git worktree of the Angstrom repo, on branch bt/{lid}, "
    "branched from bluetooth/integration; you cannot talk to other agents. Read first: CLAUDE.md; docs/bluetooth/SPEC.md sections {specRefs}; "
    "docs/bluetooth/PLAN.md §1 (execution rules), §3 (plan-level contracts) and §3.5 (test conventions). The reference of record is "
    "pylamarzocco v2.5.6 (commit 4c639ee), read-only at $UPSTREAM; relevant upstream lines: {upstreamRefs}. Copy every wire value (UUIDs, JSON keys, "
    "raw values, error texts, timings, counts, orders) from $UPSTREAM or the SPEC verbatim, never from memory. SPEC §6 and PLAN §3 declarations "
    "are frozen: never rename, retype, reorder parameters of, or change the access level of one. Anything you add follows the SPEC §6 access rule: private/fileprivate in Sources/ and Tests/AngstromTestSupport; internal XCTestCase classes and test methods with private helpers in test files; internal command types and option properties in cli/. "
    "You may create ONLY: {create}; and modify ONLY: {modify}. Touch no other file, never commit Package.resolved or .build, never construct "
    "CBCentralManager/CBPeripheral in a test (no Bluetooth hardware exists), use only macOS 14/iOS 17 APIs (no Mutex, no Task.immediate), XCTest only, "
    "no wall-clock sleeps or sleep-polling in tests. Parity tests start with the doc comment `/// Upstream: <test function> (<path>:<line>) [<case ids>]`; "
    "Angstrom-only tests start with `/// Angstrom-only: <id> — <one line>`. If the SPEC is wrong or unimplementable as written, STOP and report "
    "`SPEC-DEFECT: <section>: <problem>: <proposed amendment>`; do not improvise. If code from an earlier package is defective, keep a test that proves it, "
    "start it with `try XCTSkipIf(true, \"BLOCKED-BY <owner-id>: <reason>\")` and report it. Remove every `unimplemented: {id}` stub marker. "
    "When every acceptance command exits 0, commit with message `{id}: <summary>` and reply with: changed files, exact test names added, deviations, "
    "BLOCKED-BY items, open questions.\n\nTASK: ")
DOCS_PRE = IMPL_PRE.replace("an implementation agent", "a documentation agent")
VERIFY_PRE = (
    "You are an independent verification agent for {id}, \"{title}\" (Wave {wave}), of the Angstrom Bluetooth port (a Swift 6 SwiftPM library porting "
    "pylamarzocco). You did not write the code under review; do not trust its comments, tests or commit messages. Work in a disposable worktree of "
    "bluetooth/integration at the current wave's base commit. You may build and test there (.build/ is git-ignored), but do NOT commit, and do NOT "
    "modify, create or delete any tracked or untracked repository file (scratch files go in your temp directory). Read CLAUDE.md, docs/bluetooth/SPEC.md sections {specRefs}, and docs/bluetooth/PLAN.md §3, §5 and Appendix A (fix owners). "
    "The reference of record is pylamarzocco v2.5.6 (4c639ee), read-only at $UPSTREAM; relevant upstream lines: {upstreamRefs}. Quote upstream as "
    "$UPSTREAM/<path>:<line> with the verbatim text. Intentional divergences D1–D22 (SPEC §12) are not findings unless implemented differently from the SPEC. "
    "Run every acceptance command listed below and include its result under `checks`. Your final output is ONLY a JSON object following PLAN §5.2: "
    "{{\"package\":\"{id}\",\"verdict\":\"PASS\"|\"FAIL\",\"reviewed\":[...],\"checks\":[...],\"findings\":[{{\"severity\",\"file\",\"line\",\"specRef\","
    "\"upstreamRef\",\"summary\",\"failureScenario\",\"suggestedFix\",\"fixOwner\",\"evidence\"}}]}}; verdict FAIL iff any blocker or major finding.\n\nSCOPE: ")
INTEG_PRE = VERIFY_PRE.replace("an independent verification agent", "the final integration agent")


def fmt_list(xs):
    return ", ".join(xs) if xs else "(nothing)"


for p in P.PACKAGES:
    pre = {"implement": IMPL_PRE, "docs": DOCS_PRE, "verify": VERIFY_PRE, "integrate": INTEG_PRE}[p["kind"]]
    head = pre.format(id=p["id"], lid=p["id"].lower(), title=p["title"], wave=p["wave"], size=p["size"],
                      specRefs="; ".join(p["specRefs"]), upstreamRefs="; ".join(p["upstreamRefs"]),
                      create=fmt_list(p["create"]), modify=fmt_list(p["modify"]))
    body = p["task"]
    tests = ""
    if p["tests"]:
        tests = "\n\nTESTS TO WRITE (exact names; parity rows cite upstream):\n- " + "\n- ".join(p["tests"])
    acc = "\n\nACCEPTANCE (run from the repo root; all must exit 0):\n- " + "\n- ".join(p["acceptance"])
    p["brief"] = head + body + tests + acc

# ------------------------------------------------------------------ manifest
manifest = {
    "meta": {
        "upstreamVersion": "v2.5.6",
        "upstreamSha": "4c639ee",
        "baseline": "main@e1bc403 (Angstrom v1.7.0)",
        "targetVersion": "2.0.0",
        "spec": "docs/bluetooth/SPEC.md",
        "plan": "docs/bluetooth/PLAN.md",
        "integrationBranch": "bluetooth/integration",
        "packageBranchPattern": "bt/<id-lowercased>",
        "environment": {"UPSTREAM": "read-only pylamarzocco clone at 4c639ee (required)",
                        "RESEARCH": "planning research notes directory (optional)"},
        "gates": GATE_BASE + [FINAL_STUBS],
        "humanApprovals": ["A0 before wave 0", "A1 after wave 0 gate", "A2 on SPEC-DEFECT", "A3 on escalation",
                           "A4 merge to main after BT-W5-01", "A5 release after hardware checklist"],
    },
    "waves": WAVES,
    "packages": [],
    "hardwareChecklist": [dict(id=h[0], step=h[1], verifies=f"{h[2]} (settles: {h[3]})") for h in HW],
    "releaseChecks": [dict(id=x[0], step=x[1], verifies=x[2]) for x in RELEASE_CHECKS],
}
KEYS = ["id", "title", "wave", "kind", "size", "dependsOn", "owns", "specRefs", "upstreamRefs", "deliverables", "tests",
        "acceptance", "risks", "brief"]
for p in P.PACKAGES:
    q = dict(p)
    q["owns"] = {"create": p["create"], "modify": p["modify"]}
    manifest["packages"].append({k: q.get(k, []) for k in KEYS})

# ------------------------------------------------------------------ fix owners (Appendix A)
order = {p["id"]: (p["wave"], p["id"]) for p in P.PACKAGES}
fix_owner = {}
for p in P.PACKAGES:
    if p["kind"] not in ("implement", "docs"):
        continue
    for path in p["create"] + p["modify"]:
        if path not in fix_owner or order[p["id"]] > order[fix_owner[path]]:
            fix_owner[path] = p["id"]

# ------------------------------------------------------------------ render PLAN.md
pk = {p["id"]: p for p in P.PACKAGES}


def md_paths(xs):
    return ", ".join(f"`{x}`" for x in xs) if xs else "—"


out = [frag("frag_head.md").replace("@@G5@@", P.WARN).replace("@@G5CLI@@", P.CLI_WARN)]

# §2 waves
out.append("## 2. Waves\n")
out.append("Dependency-ordered. Every package depends only on packages in the same or an earlier wave. In the parallel\n"
           "waves every dependency points to an earlier wave, so the packages of a wave are independent. In the **dag** wave\n"
           "(Wave 0) a package starts as soon as every dependency has merged, so packages with no path between them run\n"
           "concurrently and own disjoint files. The serial wave runs one package at a time. A wave starts only after the\n"
           "previous wave's gate is green.\n")
out.append("| Wave | Name | Mode | Packages | Width |\n|---|---|---|---|---|")
for w in WAVES:
    ids = [p["id"] for p in P.PACKAGES if p["wave"] == w["id"]]
    out.append(f"| {w['id']} | {w['name']} | {w['mode']} | {', '.join(ids)} | {len(ids)} |")
counts = {w["id"]: sum(1 for p in P.PACKAGES if p["wave"] == w["id"]) for w in WAVES}
widest = max(counts.values())
out.append(f"\nTotal: **{len(P.PACKAGES)} packages in {len(WAVES)} waves**. The widest waves are "
           + ", ".join(f"Wave {k}" for k, v in counts.items() if v == widest) + f" ({widest} packages each).\n")
out.append("""**Why this shape.**

- **Wave 0** (dag) lands every SPEC §6 declaration and every PLAN §3 contract, as real code or as
  an owner-tagged stub, plus working fakes, the UI harness and placeholder test files. After it,
  every later package compiles, and the tests it writes can run in isolation. BT-W0-02 (UI
  declarations) and BT-W0-03 (test support) need only BT-W0-01 and run side by side; BT-W0-04 (UI
  harness) needs both.
- **Wave 1** builds everything that depends only on Wave 0: the pure protocol pieces, the client
  core, the adapter, the AngstromUI funnel and the CLI scaffolding.
- **Wave 2** adds the two client files that need the Wave 1 core (requests, shot counter), the CLI
  commands and the docs. Four reviewers check Wave 1 at the same time.
- **Wave 3** holds the independently written client parity suites, and the AngstromUI behaviours
  that need a working client.
- **Wave 4** is reviewers only. **Wave 5** is the final integration.

```
W0  BT-W0-01 ─▶ { BT-W0-02 ∥ BT-W0-03 } ─▶ BT-W0-04                          (dag)
W1  W1-01 W1-02 W1-03 W1-04 W1-05 W1-06 W1-07 W1-08 W1-09 W1-10 W1-11 W1-12
W2  W2-01(←W1-02,03,09) W2-02(←W1-04,09) W2-03..06(←W1-12) W2-07 W2-08 | verify W2-09..12(←W1)
W3  W3-01..05(←W2-01/02) W3-06..09(←W1-11 + W2-01/02 + W0-04) | verify W3-10(←CLI)
W4  verify W4-01..06
W5  BT-W5-01
```

### 2.1 Dependency list

| Package | Depends on |
|---|---|""")
for p in P.PACKAGES:
    out.append(f"| {p['id']} | {', '.join(p['dependsOn']) or '—'} |")
out.append("\n---\n")

out.append(frag("frag_contracts.md"))

# §4 packages
out.append("## 4. Work packages\n")
out.append("Each manifest `brief` is one prompt that can be handed to an agent verbatim. It is built from a common preamble,\n"
           "the package's **Task** text (shown below), its **Tests** and its **Acceptance** commands. The preamble covers the\n"
           "role, worktree, files to read, `$UPSTREAM`, the frozen-contract rule, the exact owned paths, the platform rules,\n"
           "the test doc-comment headers, and the STOP and BLOCKED-BY protocols. There are three preambles, for implement/docs,\n"
           "verify and integrate packages. They are spelled out in full in every manifest brief.\n")
for w in WAVES:
    out.append(f"### Wave {w['id']} — {w['name']} ({w['mode']})\n")
    for p in [q for q in P.PACKAGES if q["wave"] == w["id"]]:
        out.append(f"#### {p['id']} — {p['title']}\n")
        out.append(f"| Wave | Kind | Size | Depends on |\n|---|---|---|---|\n| {p['wave']} | {p['kind']} | {p['size']} | {', '.join(p['dependsOn']) or '—'} |\n")
        out.append(f"- **Owns, create:** {md_paths(p['create'])}")
        out.append(f"- **Owns, modify:** {md_paths(p['modify'])}")
        out.append(f"- **SPEC:** {'; '.join(p['specRefs'])}")
        out.append(f"- **Upstream:** {'; '.join('`' + r + '`' for r in p['upstreamRefs'])}")
        out.append("- **Deliverables:**")
        for d in p["deliverables"]:
            out.append(f"  - {d}")
        if p["tests"]:
            out.append("- **Tests:**")
            for t in p["tests"]:
                out.append(f"  - {t}")
        out.append("- **Acceptance:**\n\n  ```sh")
        for a in p["acceptance"]:
            out.append("  " + a)
        out.append("  ```")
        if p["risks"]:
            out.append("- **Risks:**")
            for r in p["risks"]:
                out.append(f"  - {r}")
        out.append(f"- **Task (brief body):** {p['task']}\n")
out.append("---\n")

# §5 verification
out.append(frag("frag_verify.md"))
out.append("### 5.4 Named verify packages\n")
out.append("| Package | Wave | Reviews (dependsOn) | Focus | Output |\n|---|---|---|---|---|")
for p in P.PACKAGES:
    if p["kind"] in ("verify", "integrate"):
        out.append(f"| {p['id']} | {p['wave']} | {', '.join(p['dependsOn'])} | {p['title']} | {p['deliverables'][0]} |")
out.append("\nOn FAIL, the fix loop of §5.3 runs, using the fix owners in Appendix A. A verify package that is PASS\n"
           "with only `minor` findings files them as follow-ups. They do not block the wave.\n\n---\n")

# §6 hardware
out.append("## 6. Hardware-in-the-loop checklist (gates the release, not the merge)\n")
out.append("CI has no Bluetooth hardware, so these steps can only be run by a human, mostly with a machine and `angcli ble …`.\n"
           "They **gate the v2.0.0 release (approval A5)**, not any merge, including the merge to `main` (A4). Run them on\n"
           "macOS 14 (the floor), macOS 15 and current macOS, plus iOS 17+ where marked, on every available model (Linea Micra,\n"
           "Linea Mini, Linea Mini R, GS3 AV, GS3 MP). Record raw values (redacted) in a findings note. When a result\n"
           "contradicts a SPEC default (§14.2), file a SPEC amendment (A2) and a follow-up package. Do not edit code ad hoc.\n")
out.append("| Id | Step | Verifies | Settles |\n|---|---|---|---|")
for h in HW:
    out.append(f"| {h[0]} | {h[1]} | {h[2]} | {h[3]} |")
out.append("\n### 6.1 Other release checks (maintainer, no hardware)\n")
out.append("| Id | Step | Verifies |\n|---|---|---|")
for x in RELEASE_CHECKS:
    out.append(f"| {x[0]} | {x[1]} | {x[2]} |")
out.append("\n---\n")

# §7 coverage
out.append("## 7. Coverage tables\n")
out.append("### 7.1 SPEC §2 parity inventory → owning packages\n")
out.append("Every row of SPEC §2.1–§2.7. \"Implement\" owns the behaviour. \"Tests\" owns the pinning test.\n")
out.append("| § | Upstream | Angstrom | Implement | Tests |\n|---|---|---|---|---|")
for r in INV:
    out.append(f"| {r[0]} | {r[1]} | {r[2]} | {r[3]} | {r[4]} |")
out.append("\n### 7.2 Upstream Bluetooth tests → owning package (each owned exactly once)\n")
out.append(f"{len(UT)} upstream test functions: {sum(1 for u in UT if u['file']=='TBC')} in `test_bluetooth_client.py`, "
           f"{sum(1 for u in UT if u['file']=='TBD')} in `test_bluetooth_dashboard.py`, {sum(1 for u in UT if u['file']=='TM')} in "
           f"`test_machine.py`, {sum(1 for u in UT if u['file']=='TT')} in `test_thing.py` (T00 added by R7), "
           f"{sum(1 for u in UT if u['file']=='TMO')} in `test_models.py`, {sum(1 for u in UT if u['file']=='TCC')} in "
           "`test_cloud_client.py`. `test_grinder.py` has none. Line numbers are the `def` lines at `4c639ee`.\n")
out.append("| Upstream test (`$UPSTREAM/…:line`) | Cases | Swift test(s) | Owner |\n|---|---|---|---|")
for u in UT:
    out.append(f"| `{u['fn']}` ({FILES[u['file']]}:{u['line']}) | {u['cases']} | {', '.join('`' + s + '`' for s in u['swift'])} | {u['owner']} |")
out.append("\nAngstrom-only tests (the G-* gaps of §3.5 and the divergences D1–D22) are listed under each package's **Tests** in §4.\n")

out.append("### 7.3 SPEC file map → owning packages by wave\n")
out.append("Every path that any package creates or modifies, in first-touch order. W*n*:c = creates, W*n*:m = modifies.\n")
touch = {}
for p in P.PACKAGES:
    for path in p["create"]:
        touch.setdefault(path, []).append(f"{p['id']}:c")
    for path in p["modify"]:
        touch.setdefault(path, []).append(f"{p['id']}:m")
out.append("| Path | Packages (wave order) | Fix owner |\n|---|---|---|")
for path, ts in touch.items():
    out.append(f"| `{path}` | {', '.join(ts)} | {fix_owner.get(path, '—')} |")
out.append("\n**SPEC §7.1/§10.6/§11 rows → plan:**\n")
out.append("| SPEC file-map row | Plan |\n|---|---|")
for row in SPEC_FILEMAP:
    if row in SPECIAL:
        out.append(f"| `{row}` | {SPECIAL[row]} |")
    elif row.endswith("*.swift"):
        prefix = row[:-len("*.swift")]
        hits = sorted({t.split(':')[0] for path, ts in touch.items() if path.startswith(prefix) and path.endswith('.swift') for t in ts})
        out.append(f"| `{row}` | {', '.join(hits)} (see §3.4) |")
    else:
        out.append(f"| `{row}` | {', '.join(touch[row])} |")
out.append("\n---\n")

out.append(frag("frag_tail.md"))

out.append("## Appendix A. Fix-owner table\n")
out.append("A finding against a path goes to the **last** implement/docs package (by wave) that owns it. Verify and\n"
           "integrate packages own nothing. Paths outside this table (existing files that must not change) have no owner.\n"
           "A finding there is a blocker, and a human (A3) decides. The planning files under `docs/bluetooth/` (spec,\n"
           "plan, manifest, generator, research notes) and the `.gitignore` lines for the local worktree tooling are\n"
           "the orchestrator's: they are outside this rule and exempt from the ownership audit.\n")
out.append("| Path | Fix owner |\n|---|---|")
for path in sorted(fix_owner):
    out.append(f"| `{path}` | {fix_owner[path]} |")
out.append("")

plan_md = "\n".join(out)
os.makedirs(OUT_DIR, exist_ok=True)
with open(os.path.join(OUT_DIR, "PLAN.md"), "w") as f:
    f.write(plan_md)
with open(os.path.join(OUT_DIR, "work-packages.json"), "w") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")

# sanity checks of the coverage data itself
assert len(UT) == 92, len(UT)
owners = {u["owner"] for u in UT}
assert owners <= set(pk), owners - set(pk)
for r in INV:
    for o in (r[3] + ", " + r[4]).replace("(", ",").split(","):
        o = o.strip().split(" ")[0]
        if o.startswith("BT-"):
            assert o in pk, (o, r)
print("packages", len(P.PACKAGES), "waves", len(WAVES), "widest", widest, counts)
print("plan bytes", len(plan_md), "manifest bytes", len(json.dumps(manifest)))
