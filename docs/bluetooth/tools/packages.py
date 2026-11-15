"""Work-package data for the Angstrom Bluetooth implementation plan (single source of truth)."""

# ---------------------------------------------------------------- upstream paths
UP = "$UPSTREAM/"
BT = UP + "src/pylamarzocco/clients/_bluetooth.py"
MBT = UP + "src/pylamarzocco/models/_bluetooth.py"
MACH = UP + "src/pylamarzocco/devices/_machine.py"
THING = UP + "src/pylamarzocco/devices/_thing.py"
CONST = UP + "src/pylamarzocco/const.py"
EXC = UP + "src/pylamarzocco/exceptions.py"
GEN = UP + "src/pylamarzocco/models/_general.py"
CLOUD = UP + "src/pylamarzocco/clients/_cloud.py"
README = UP + "README.md"
LEG = UP + "docs/legacy/bluetooth_characteristics.md"
TBC = UP + "tests/test_bluetooth_client.py"
TBD = UP + "tests/test_bluetooth_dashboard.py"
TM = UP + "tests/test_machine.py"
TT = UP + "tests/test_thing.py"
TMO = UP + "tests/test_models.py"
TCC = UP + "tests/test_cloud_client.py"
CONF = UP + "tests/conftest.py"
SNAP = UP + "tests/__snapshots__/test_bluetooth_dashboard.ambr"
REC = UP + "tests/fixtures/machine/shot_counter_2026-10-05.txt"

# ---------------------------------------------------------------- repo paths
B = "Sources/Angstrom/Bluetooth/"
P_CONST, P_TRANSPORT, P_TOKEN = B + "BluetoothConstants.swift", B + "BluetoothTransport.swift", B + "BluetoothAuthToken.swift"
P_ENUMS, P_MODELS, P_COERCE = B + "BluetoothEnums.swift", B + "BluetoothModels.swift", B + "BluetoothWireCoercion.swift"
P_SCMODELS, P_DIAG = B + "BluetoothShotCounterModels.swift", B + "BluetoothDiagnostics.swift"
P_CODEC, P_DECODER, P_BSM = B + "BluetoothCodec.swift", B + "BluetoothResponseDecoder.swift", B + "BrewingStateMachine.swift"
P_DASH, P_OPTABLE = B + "Dashboard+Bluetooth.swift", B + "BluetoothOpTable.swift"
P_CLIENT = B + "LaMarzoccoBluetoothClient.swift"
P_CLIENT_REQ = B + "LaMarzoccoBluetoothClient+Requests.swift"
P_CLIENT_SC = B + "LaMarzoccoBluetoothClient+ShotCounter.swift"
P_CLIENT_DISC = B + "LaMarzoccoBluetoothClient+Discovery.swift"
P_CLOUDTOKEN = "Sources/Angstrom/LaMarzoccoCloudClient+BluetoothToken.swift"
P_MODELS_SWIFT, P_COMMANDS, P_PKG = "Sources/Angstrom/Models.swift", "Sources/Angstrom/Commands.swift", "Package.swift"
P_CB_TRANSPORT = "Sources/AngstromBluetooth/BluetoothTransport+CoreBluetooth.swift"
P_CB_CENTRAL = "Sources/AngstromBluetooth/CoreBluetoothCentral.swift"
P_CB_LINK = "Sources/AngstromBluetooth/CoreBluetoothLink.swift"
P_CB_DOCC = "Sources/AngstromBluetooth/Documentation.docc/AngstromBluetooth.md"
UI = "Sources/AngstromUI/"
P_UI_MAIN, P_UI_EVENT = UI + "LaMarzoccoMachine.swift", UI + "MachineBluetoothEvent.swift"
P_UI_CMD = UI + "LaMarzoccoMachine+BluetoothCommands.swift"
P_UI_DASH = UI + "LaMarzoccoMachine+BluetoothDashboard.swift"
P_UI_CONN = UI + "LaMarzoccoMachine+BluetoothConnection.swift"
P_UI_SC = UI + "LaMarzoccoMachine+ShotCounter.swift"
TS = "Tests/AngstromTestSupport/"
TS_MODULE, TS_FIXTURE = TS + "AngstromTestSupport.swift", TS + "Fixtures/shot_counter_2026-10-05.txt"
TS_CENTRAL, TS_LINK, TS_SLEEPER = TS + "FakeBluetoothCentral.swift", TS + "FakeBluetoothLink.swift", TS + "ManualBluetoothSleeper.swift"
TS_CLOCK, TS_VECTORS, TS_REC = TS + "BluetoothTestClock.swift", TS + "BluetoothTestVectors.swift", TS + "ShotCounterRecording.swift"
T = "Tests/AngstromTests/Bluetooth/"
T_FAKE = T + "FakeBluetoothTests.swift"
T_ENUMS, T_COERCE, T_MODELS = T + "BluetoothEnumsTests.swift", T + "BluetoothWireCoercionTests.swift", T + "BluetoothModelsTests.swift"
T_CODEC, T_DECODER = T + "BluetoothCodecTests.swift", T + "BluetoothResponseDecoderTests.swift"
T_BSM, T_NTFDEC = T + "BrewingStateMachineTests.swift", T + "ShotCounterNotificationDecoderTests.swift"
T_DASH, T_TOKEN, T_OPTABLE = T + "DashboardBluetoothTests.swift", T + "BluetoothTokenTests.swift", T + "BluetoothOpTableTests.swift"
T_CORE, T_DISC = T + "BluetoothClientCoreTests.swift", T + "BluetoothDiscoveryTests.swift"
T_REQSMOKE, T_SCSMOKE = T + "BluetoothClientRequestsSmokeTests.swift", T + "BluetoothClientShotCounterSmokeTests.swift"
T_CONN, T_AUTH = T + "BluetoothConnectionTests.swift", T + "BluetoothAuthTests.swift"
T_REQ, T_DIAGT = T + "BluetoothRequestTests.swift", T + "BluetoothDiagnosticsTests.swift"
T_SCLIFE, T_SCNTF = T + "ShotCounterLifecycleTests.swift", T + "ShotCounterNotificationTests.swift"
T_SCREC, T_SCRC = T + "ShotCounterRecordedSessionTests.swift", T + "ShotCounterReconnectTests.swift"
U = "Tests/AngstromUITests/Bluetooth/"
U_HARNESS, U_HARNESS_T = U + "BluetoothMachineHarness.swift", U + "BluetoothMachineHarnessTests.swift"
U_ROUTING, U_DEVSTATE = U + "MachineTransportRoutingTests.swift", U + "BluetoothDeviceStateTests.swift"
U_FALLBACK, U_SIDE = U + "BluetoothFallbackTests.swift", U + "BluetoothCommandSideEffectTests.swift"
U_DASHREF, U_OVERLAY = U + "BluetoothDashboardRefreshTests.swift", U + "ShotCounterOverlayTests.swift"
C = "cli/Sources/angcli/"
C_PKG, C_PLIST, C_ANGCLI, C_OUTPUT = "cli/Package.swift", "cli/Support/Info.plist", C + "AngCLI.swift", C + "Output.swift"
C_BLE, C_SESSION, C_BLEOUT = C + "Ble/Ble.swift", C + "Ble/BleSession.swift", C + "Ble/BleOutput.swift"
C_SCAN, C_GATT, C_TOKEN = C + "Ble/BleScan.swift", C + "Ble/BleGatt.swift", C + "Ble/BleToken.swift"
C_READ, C_CMD, C_LISTEN = C + "Ble/BleRead.swift", C + "Ble/BleCmd.swift", C + "Ble/BleListen.swift"
CT = "cli/Tests/angcliTests/"
CT_SESSION, CT_OUTPUT, CT_DISC = CT + "BleSessionTests.swift", CT + "BleOutputTests.swift", CT + "BleDiscoveryCommandTests.swift"
CT_REQ, CT_LISTEN = CT + "BleRequestCommandTests.swift", CT + "BleListenTests.swift"
D_CLAUDE, D_UPSTREAM, D_README = "CLAUDE.md", "UPSTREAM.md", "README.md"
D_DRIFT, D_DOCSYML = ".github/workflows/upstream-drift.yml", ".github/workflows/docs.yml"
DOCC = "Sources/Angstrom/Documentation.docc/"
D_ANG, D_BTART, D_GS = DOCC + "Angstrom.md", DOCC + "Bluetooth.md", DOCC + "GettingStarted.md"
D_UIDOCC = "Sources/AngstromUI/Documentation.docc/AngstromUI.md"
D_CLISPEC, D_CLIREADME = "cli/SPEC.md", "cli/README.md"

PLACEHOLDERS_CORE = [T_ENUMS, T_COERCE, T_MODELS, T_CODEC, T_DECODER, T_BSM, T_NTFDEC, T_DASH, T_TOKEN,
                     T_OPTABLE, T_CORE, T_DISC, T_REQSMOKE, T_SCSMOKE, T_CONN, T_AUTH, T_REQ, T_DIAGT,
                     T_SCLIFE, T_SCNTF, T_SCREC, T_SCRC]
PLACEHOLDERS_UI = [U_ROUTING, U_DEVSTATE, U_FALLBACK, U_SIDE, U_DASHREF, U_OVERLAY]
PLACEHOLDERS_CLI = [CT_SESSION, CT_OUTPUT, CT_DISC, CT_REQ, CT_LISTEN]

# ---------------------------------------------------------------- acceptance helpers
BUILD = "swift build --build-tests"
TEST = "swift test"
CLI_BUILD = "swift build --package-path cli"
CLI_TEST = "swift test --package-path cli"
# G5 builds from scratch in its own scratch path: an incremental (null) build prints no diagnostics.
# NO_COLOR=1: swiftc colours diagnostics even through a pipe, and the escape code before `warning:` defeats the regex.
WARN = ("bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; "
        "NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && "
        "! grep -E \"/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\\+BluetoothToken\\.swift|Sources/AngstromBluetooth/|"
        "Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:\" "
        ".build/bt-warnings.log'")
# G5' (CLI): the same rule for the angcli package's Bluetooth files.
CLI_WARN = ("bash -c 'set -o pipefail; mkdir -p cli/.build; rm -rf cli/.build/g5; "
            "NO_COLOR=1 swift build --package-path cli --build-tests --scratch-path cli/.build/g5 2>&1 | tee cli/.build/bt-warnings.log && "
            "! grep -E \"/cli/(Sources/angcli/Ble/|Sources/angcli/Output\\.swift|Sources/angcli/AngCLI\\.swift|Tests/angcliTests/Ble)[^:]*:[0-9]+:[0-9]+: warning:\" "
            "cli/.build/bt-warnings.log'")
BLOCKED = "bash -c '! grep -rn \"BLOCKED-BY\" Tests cli/Tests'"


def filt(*classes):
    return "swift test --filter '" + "|".join(classes) + "'"


def cfilt(*classes):
    return "swift test --package-path cli --filter '" + "|".join(classes) + "'"


def nostub(pid):
    return f"bash -c '! grep -rn \"unimplemented: {pid}\" Sources Tests cli/Sources'"


def exists(*paths):
    return "bash -c 'for f in " + " ".join(paths) + "; do test -f \"$f\" || { echo \"missing $f\"; exit 1; }; done'"


def stub_owners(where, allowed_regex):
    return ("bash -c '! grep -rhoE \"unimplemented: BT-W[0-9]-[0-9]+\" " + where +
            " | sed \"s/unimplemented: //\" | sort -u | grep -vxE \"" + allowed_regex + "\"'")


def std_impl(pid, *classes, cli=False):
    acc = [BUILD]
    if classes:
        acc.append(filt(*classes))
    acc += [TEST, WARN, nostub(pid)]
    if cli:
        acc += [CLI_BUILD, CLI_TEST]
    return acc


def std_cli(pid, *classes):
    return [CLI_BUILD, cfilt(*classes), CLI_TEST, CLI_WARN, nostub(pid)]


PACKAGES = []


def pkg(**kw):
    kw.setdefault("create", [])
    kw.setdefault("modify", [])
    kw.setdefault("extraTests", [])
    kw.setdefault("risks", [])
    PACKAGES.append(kw)


# ================================================================= WAVE 0 (serial)
pkg(id="BT-W0-01", title="Core contracts: Package.swift, errors, seam, leaf types, every core stub",
    wave=0, kind="implement", size="L", dependsOn=[],
    create=[P_CONST, P_TRANSPORT, P_TOKEN, P_ENUMS, P_MODELS, P_COERCE, P_SCMODELS, P_DIAG, P_CODEC,
            P_DECODER, P_BSM, P_DASH, P_OPTABLE, P_CLIENT, P_CLIENT_REQ, P_CLIENT_SC, P_CLIENT_DISC,
            P_CLOUDTOKEN, P_CB_TRANSPORT, TS_MODULE, TS_FIXTURE],
    modify=[P_PKG, P_MODELS_SWIFT, P_COMMANDS],
    specRefs=["§3.10", "§4.11 (merge rule)", "§5.1", "§5.3", "§6.1–§6.15", "§7.1", "§12 D8", "PLAN §3.0", "PLAN §3.1"],
    upstreamRefs=[BT + ":40-54", BT + ":57-64", CONST + ":11-31", CONST + ":141-146", CONST + ":182",
                  CONST + ":198-218", CONST + ":260-275", CONST + ":307-339", MBT + ":22-213",
                  MACH + ":58-84", EXC + ":20-47", GEN + ":128-136", REC],
    deliverables=[
        "Package.swift: AngstromBluetooth product + target; AngstromTestSupport target (path Tests/AngstromTestSupport, resources [.copy(\"Fixtures\")]); both test targets depend on it.",
        "LaMarzoccoError: five new cases, verbatim errorDescription texts, isBluetoothConnectionFailure; Machine doc-comment rewording.",
        "CommandResponse package init.",
        "Fully implemented leaf types: constants, timing, seam types/protocols, RealSleeper, token, enums + mappings, models, wire coercion, shot-counter models (isEmpty/merging), RawBluetoothFrame, BluetoothDashboardState, BluetoothCodec.readRequestFrame/authFrame.",
        "Stub files with frozen signatures for codec, decoder, state machine, dashboard transforms, cloud token, op table, CoreBluetooth transport, and the four client files (stored state + init real).",
        "AngstromTestSupport skeleton + verbatim REC fixture.",
    ],
    task=(
        "Land the compile-time skeleton of the whole core Bluetooth surface so every later package compiles and can be tested in isolation. "
        "(1) Package.swift exactly per the SPEC §7.1 row: add product `.library(name: \"AngstromBluetooth\", targets: [\"AngstromBluetooth\"])`, target `.target(name: \"AngstromBluetooth\", dependencies: [\"Angstrom\"])`, target `.target(name: \"AngstromTestSupport\", dependencies: [\"Angstrom\"], path: \"Tests/AngstromTestSupport\", resources: [.copy(\"Fixtures\")])`, and add \"AngstromTestSupport\" to the dependencies of BOTH test targets. No unsafeFlags, no new package dependency. "
        "(2) Sources/Angstrom/Models.swift: SPEC §6.4 verbatim. Append the five cases at the END of LaMarzoccoError, add their errorDescription texts character for character, add `isBluetoothConnectionFailure` (true for .bluetoothConnectionFailed, .bluetoothAuthenticationFailed, .bluetoothUnavailable), and reword the doc comments at Models.swift:25-26 and :29-31. Do not add a Machine field or change coding. Sources/Angstrom/Commands.swift: add §6.15 `package init(id: String, status: CommandStatus, errorCode: String?)` inside CommandResponse. "
        "(3) Fully implement the 'real in Wave 0' items of PLAN §3.0. "
        "BluetoothConstants.swift (§6.1): UUIDs and constants copied from $UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:40-54; BluetoothTiming defaults exactly as §6.1. "
        "BluetoothTransport.swift (§6.2): every public/package value type, the three protocols, RealSleeper via `Task.sleep(for:)`, and BluetoothTransportError.description. "
        "BluetoothAuthToken.swift (§6.3): description \"**REDACTED**\", debugDescription \"BluetoothAuthToken(**REDACTED**)\", empty Mirror, NOT Codable. "
        "BluetoothEnums.swift (§6.5): raw values from const.py:322-339 and :307-311. Model(bluetoothFamily:) uppercases, removes ALL whitespace, then applies the table in the §6.5 doc comment (const.py:198-218 including the e0f0249 aliases \"GS3\"→.gs3AV and \"LINEA\"→.lineaMini; Model.match stays unchanged, D8). Also Model.steamLevelModels/steamTemperatureModels, MachineState(bluetoothMode:) and BoilerStatus(bluetoothMode:) (_machine.py:65-75), and the SteamLevel mappings (_machine.py:58-62 and :78-84: 0 < t < 128 → .level1; 128 ≤ t ≤ 130 → .level2; else .level3). "
        "BluetoothModels.swift (§6.6): types and memberwise public inits; isSuccess = status.lowercased() == \"success\". "
        "BluetoothWireCoercion.swift (§6.7): implement the SPEC §3.10 table exactly, including the hazard rule (a JSON boolean only when CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(); integer vs float via CFNumberIsFloatType). Failure.detail texts are free-form. "
        "BluetoothShotCounterModels.swift (§6.9): every type; isEmpty; merging(_:) where other's non-nil fields overwrite and a merge never clears (§4.11); the BluetoothJSONValue subscript; BluetoothShotCounterUpdate.init that fills brewingStartTime = receivedAt − timerValue when it is nil, state == .brewing and timerValue != nil; DecodedShotCounterNotification. "
        "BluetoothDiagnostics.swift (§6.10): RawBluetoothFrame with the exact marker strings; mtuMarker(n) = \"[mtu \\(n)]\". "
        "In Dashboard+Bluetooth.swift, BluetoothDashboardState (§6.12) is real. In BluetoothCodec.swift, readRequestFrame (UTF8(rawValue)+[0x00]) and authFrame (UTF8(token.rawValue), no NUL) are real. "
        "(4) Stub everything else with the exact frozen signatures and owner markers (PLAN §3.0). Owners: the rest of BluetoothCodec.swift → BT-W1-02; BluetoothResponseDecoder.swift → BT-W1-03; BrewingStateMachine.swift (deriveState, BrewingTracker with a real init and private stored data, ShotCounterNotificationDecoder) → BT-W1-04; the Dashboard+Bluetooth.swift extension methods → BT-W1-05; LaMarzoccoCloudClient+BluetoothToken.swift → BT-W1-06; BluetoothOpTable.swift with the PLAN §3.1 signature (real init) → BT-W1-07; Sources/AngstromBluetooth/BluetoothTransport+CoreBluetooth.swift with the two §6.14 public declarations → BT-W1-08 (no CoreBluetooth import needed yet). "
        "LaMarzoccoBluetoothClient.swift: every §6.11 public member SPEC assigns to main, ALL frozen internal stored state, a real init (timing = BluetoothTiming(), empty listener and task tables, tracker = BrewingTracker(), every flag false, central/sleeper/now taken from the transport), the [main] helper and test-seam stubs → BT-W1-09, and the inert members of PLAN §3.0. "
        "LaMarzoccoBluetoothClient+Requests.swift: the [+Requests] members → BT-W2-01. +ShotCounter.swift: the [+ShotCounter] members, including the inert fast paths of PLAN §3.0 → BT-W2-02. +Discovery.swift → BT-W1-10. Put every declaration in the file SPEC §6.11 assigns it to. "
        "(5) Test-support skeleton: Tests/AngstromTestSupport/AngstromTestSupport.swift containing only `import Angstrom` and a module doc comment (it must NOT import XCTest), and a byte-identical copy of $UPSTREAM/tests/fixtures/machine/shot_counter_2026-10-05.txt at Tests/AngstromTestSupport/Fixtures/shot_counter_2026-10-05.txt (85 lines). "
        "Write no new tests (BT-W1-01 tests the leaf types). The existing 177 library and 15 CLI tests must stay green. In your report, list every existing `switch` over LaMarzoccoError that needed new arms."),
    tests=["No new tests. Leaf behaviour is tested by BT-W1-01, stubs by their owners. Existing suites must stay green."],
    acceptance=[BUILD, TEST, CLI_BUILD, CLI_TEST, WARN,
                "bash -c 'cmp Tests/AngstromTestSupport/Fixtures/shot_counter_2026-10-05.txt \"$UPSTREAM/tests/fixtures/machine/shot_counter_2026-10-05.txt\"'",
                "bash -c '! grep -rnE \"^(@preconcurrency )?import CoreBluetooth\" Sources/Angstrom Sources/AngstromUI'",
                "bash -c '! grep -rn \"import XCTest\" Tests/AngstromTestSupport'",
                "bash -c 'grep -q \"AngstromBluetooth\" Package.swift && grep -q \"AngstromTestSupport\" Package.swift && ! grep -q unsafeFlags Package.swift'",
                stub_owners("Sources Tests", "BT-W1-(0[2-9]|10)|BT-W2-0[12]")],
    risks=["A trapping stub reachable from a constructor breaks every later test. Follow the PLAN §3.0 inert list exactly.",
           "New LaMarzoccoError cases break exhaustive switches. The only in-repo switch is errorDescription; check cli/ too (`grep -rn \"case .operationNotAvailable\" Sources cli`).",
           "The CFBoolean hazard in coercion: `as? Bool` also matches the numbers 0 and 1."])

pkg(id="BT-W0-02", title="AngstromUI contracts: optional cloud client, BLE state, extension-file stubs",
    wave=0, kind="implement", size="M", dependsOn=["BT-W0-01"],
    create=[P_UI_EVENT, P_UI_CMD, P_UI_DASH, P_UI_CONN, P_UI_SC],
    modify=[P_UI_MAIN],
    specRefs=["§4.15", "§5.8", "§6.16", "§13", "PLAN §3.0"],
    upstreamRefs=[THING + ":27-38", THING + ":73-126", MACH + ":88", MACH + ":132-156"],
    deliverables=["LaMarzoccoMachine compiles against SPEC §6.16: cloudClient/bluetooth/client accessor, designated + convenience init, widened setters, base/overlay storage and funnel functions, BLE observable state and plumbing.",
                  "MachineBluetoothEvent.swift complete.",
                  "Four extension files with frozen signatures (stubs; bluetoothFirst's no-Bluetooth path real)."],
    task=(
        "Make AngstromUI compile against SPEC §6.16 without changing any cloud behaviour. "
        "In Sources/AngstromUI/LaMarzoccoMachine.swift: replace `private let client: LaMarzoccoCloudClient` with `let cloudClient: LaMarzoccoCloudClient?`, `public let bluetooth: LaMarzoccoBluetoothClient?` and `var client: LaMarzoccoCloudClient { get throws }`, which throws LaMarzoccoError.cloudOnlyFunctionality when cloudClient is nil. Widen dashboard, settings, schedule, statistics, isLive, isConnected, lastUpdateAt and lastError from `public private(set)` to `public internal(set)`. "
        "Add `var baseDashboard: Dashboard?`, the five new observable properties and the six @ObservationIgnored plumbing properties with exactly the §6.16 types and defaults. Add the designated `public init(serialNumber:client:bluetooth:snapshot:)` and turn the existing initialiser into a `public convenience init(serialNumber:client:snapshot:)` that delegates to it. Snapshot seeding is unchanged, but it must also set baseDashboard. If `bluetooth != nil`, the designated init calls startObservingBluetoothConnection(). "
        "Implement for real: hasCloudClient, hasBluetoothClient, setBaseDashboard(_:) (sets baseDashboard, then renderDashboard()), updateBaseDashboard(_:) (applies the transform to baseDashboard if non-nil, then renders), and renderDashboard() (`dashboard = bluetoothBrewingUpdate == nil ? baseDashboard : baseDashboard?.overlayingBluetoothBrewing(bluetoothBrewingUpdate)`). Make requireModel and capturing `internal`. clientForTesting returns `cloudClient!`. "
        "Make only the minimal call-site edits needed to compile (`try client` in throwing paths; stop() uses `cloudClient?`). Do NOT convert the existing `dashboard = …` assignment sites and do NOT route the six BLE-first commands: that is BT-W1-11. "
        "Create MachineBluetoothEvent.swift, complete per §6.16. Create the four extension files with the exact frozen signatures. In +BluetoothCommands.swift, bluetoothFirst implements the no-Bluetooth path for real (PLAN §3.0) and traps with owner BT-W3-07 otherwise. +BluetoothDashboard.swift → BT-W3-08. +BluetoothConnection.swift: startObservingBluetoothConnection is a no-op and bluetoothConnectionEvents is a stub, owner BT-W3-06. +ShotCounter.swift: setBluetoothBrewingExpiryForTesting is real (assigns the two properties), everything else is a stub, owner BT-W3-09. "
        "Record in your report every compiler warning in LaMarzoccoMachine.swift that existed before your change: run `swift build` on the base commit first. The unmodified Tests/AngstromUITests/LaMarzoccoMachineTests.swift must pass."),
    tests=["No new tests. The existing AngstromUITests must pass unmodified."],
    acceptance=[BUILD, TEST, WARN,
                "bash -c '! grep -n \"private let client\" Sources/AngstromUI/LaMarzoccoMachine.swift'",
                "bash -c '! grep -rnE \"^(@preconcurrency )?import CoreBluetooth\" Sources/AngstromUI'",
                stub_owners("Sources/AngstromUI", "BT-W3-0[6-9]")],
    risks=["Changing `client` to a throwing accessor can silently change control flow in non-throwing contexts (stop(), Task closures). Keep behaviour identical when a cloud client is present.",
           "Pre-existing warnings in LaMarzoccoMachine.swift would trip gate G5. Report them (PLAN §9.2)."])

pkg(id="BT-W0-03", title="Test support: fakes, sleeper, clock, vectors, recording, library test placeholders",
    wave=0, kind="implement", size="L", dependsOn=["BT-W0-01"],
    create=[TS_CENTRAL, TS_LINK, TS_SLEEPER, TS_CLOCK, TS_VECTORS, TS_REC, T_FAKE] + PLACEHOLDERS_CORE,
    specRefs=["§4.2 step 3", "§5.3", "§6.17", "§9.1", "§9.2", "§9.3.4 (harness)", "PLAN §3.4", "PLAN §3.5"],
    upstreamRefs=[TBC + ":40-59", TBC + ":86-154", TBC + ":157-292", TBC + ":886-909", REC],
    deliverables=["Working AngstromTestSupport per SPEC §6.17 (package access, no XCTest import).",
                  "Self-tests for the fakes.",
                  "Every library placeholder test file of PLAN §3.4."],
    task=(
        "Implement the frozen test-support API of SPEC §6.17 fully, because every later client test runs on it, and create the library placeholder test files of PLAN §3.4. The UI harness is BT-W0-04's (it needs BT-W0-02, which runs concurrently with you). "
        "Files under Tests/AngstromTestSupport/: FakeBluetoothCentral.swift; FakeBluetoothLink.swift (with FakeOp and `laMarzocco(token:confirmOnRead:commandResponse:settingResponses:)`); ManualBluetoothSleeper.swift; BluetoothTestClock.swift (also `BluetoothTransport.fake(_:sleeper:clock:)` and `BluetoothPeripheralID.fake` = \"00000000-0000-0000-0000-000000000001\"); BluetoothTestVectors.swift; ShotCounterRecording.swift. Every §6.17 member is `package` exactly as declared (including `package static` on BluetoothTestVectors), and nothing imports XCTest. "
        "Semantics come from the SPEC §6.17 doc comments and the §9.2 mapping (upstream FakeBleakClient $UPSTREAM/tests/test_bluetooth_client.py:157-292, IdleTimer :108-154, FakeClock :86-105). "
        "Clock plumbing (§6.17): `BluetoothTransport.fake(_:sleeper:clock:)` sets `central.now = clock.now` and builds the transport with the same sleeper and `now: clock.now`; FakeBluetoothCentral.connect sets `link.now = self.now` on every link it returns (queued or made) before returning it. "
        "FakeBluetoothLink: awaits beforeOp, then appends every op to recordedOps in order. disconnect() records .disconnect, then yields `.disconnected(nil)` once and finishes `events`, as bleak reports user disconnects through the callback. drop(_:) yields `.disconnected(error)` once and finishes. Any op after a drop or disconnect throws `.notConnected`. subscribe(_) delivers every replayOnSubscribe value as `.notification` stamped with `now()` BEFORE it returns. replayOnSubscribe defaults to `[BluetoothTestVectors.tick(\"3.34\")]`, exactly upstream's `self.replay = _tick(3.34)` ($UPSTREAM/tests/test_bluetooth_client.py:176, delivered inside start_notify at :272-273); `[]` means no replay. discover(wanted, refresh:) returns `wanted ∩ (refresh ? (presentAfterRefresh ?? present) : present)`. notify(_:_:at:) yields one `.notification`. invalidateServices() yields `.servicesInvalidated`. "
        "The scripted machine `laMarzocco(token:)` follows the §6.17 comment: an auth read returns [0x01] from the confirmOnRead-th read after a write to 0d0b… whose bytes equal UTF8(token), and [0x00] otherwise; reads of 0b0b… return commandResponse; reads of 0a0b… return settingResponses[the setting named by the last write to 0a0b…, NUL removed] ?? Data(\"[]\".utf8). "
        "FakeBluetoothCentral: availability defaults to .poweredOn. setAvailability sets the state and yields it on every availabilityUpdates() stream. connect pops enqueueConnect outcomes, else calls makeLink(), records connectCount and connectTimeouts, and appends successful links to `links`. The default makeLink is `.laMarzocco(token: \"token\")`. "
        "ManualBluetoothSleeper: purposes in `manual` suspend until fire(_:) (oldest first) or task cancellation; cancellation throws CancellationError and removes the sleep from pending. Other purposes return immediately (so with the default `manual`, a `.poweredOnWait` sleep ends at once, SPEC §6.17). Every requested duration is recorded per purpose. waitForPending(_:count:) suspends without polling until that many are pending. "
        "BluetoothTestVectors: commandSuccess and started verbatim from tests/test_bluetooth_client.py:47-48. tick(_:backflush:) renders Python json.dumps default separators exactly, e.g. tick(\"3.34\") = `{\"BrewingUpdateGroup1Time\": 3.34, \"BrewingUpdateGroup1Ev\": true, \"BrewingUpdateGroup1Backflush\": false}` (_tick, :51-59). "
        "ShotCounterRecording.sessions() ports _load_sessions (tests/test_bluetooth_client.py:894-909). Skip lines starting with '#'. Split each other line at the first space into time and payload. A payload ending in `# replay` starts a new session whose replay is that payload with the suffix removed and stripped (isReplay = true). Times are UTC on 2026-10-05, format HH:MM:SS.fff. Load the file through Bundle.module. "
        "Write Tests/AngstromTests/Bluetooth/FakeBluetoothTests.swift, which drives the fakes by hand (the client is still a stub). "
        "Create every library placeholder test file of PLAN §3.4 (not the UI or CLI ones). Each contains the imports and one empty `final class <FileName>: XCTestCase {}` whose doc comment names the owner package."),
    extraTests=[
        "FakeBluetoothTests.testCentralPopsQueuedOutcomesThenMakeLink",
        "FakeBluetoothTests.testConnectCountAndTimeoutsRecorded",
        "FakeBluetoothTests.testAvailabilityUpdatesYieldOnSet",
        "FakeBluetoothTests.testLinkRecordsOpsInOrder",
        "FakeBluetoothTests.testDiscoverHonoursPresentAndPresentAfterRefresh",
        "FakeBluetoothTests.testScriptedAuthConfirmsOnNthRead",
        "FakeBluetoothTests.testScriptedSettingAndCommandResponses",
        "FakeBluetoothTests.testReplayDeliveredBeforeSubscribeReturns",
        "FakeBluetoothTests.testDefaultReplayIsTick334 (TBC:176; `[]` delivers nothing)",
        "FakeBluetoothTests.testReplayStampedWithTransportClock",
        "FakeBluetoothTests.testDropYieldsDisconnectedOnceAndFinishes",
        "FakeBluetoothTests.testOpsAfterDropThrowNotConnected",
        "FakeBluetoothTests.testUserDisconnectYieldsDisconnected",
        "FakeBluetoothTests.testBeforeOpHoldsOperation",
        "FakeBluetoothTests.testManualSleeperFireAndCancel",
        "FakeBluetoothTests.testNonManualSleepRecordsDuration",
        "FakeBluetoothTests.testClockSetAndAdvance",
        "FakeBluetoothTests.testTickRendersPythonSeparators",
        "FakeBluetoothTests.testRecordingHasTwoSessionsAndEightyNotifications",
    ],
    tests=[],
    acceptance=[BUILD, filt("FakeBluetoothTests"), TEST, WARN,
                "bash -c '! grep -rn \"import XCTest\" Tests/AngstromTestSupport'",
                exists(*PLACEHOLDERS_CORE)],
    risks=["Every client test depends on these fakes. A subtle fake bug shows up as false failures in Waves 1–3. Self-test every behaviour listed.",
           "AngstromTestSupport is a regular (non-test) target: importing XCTest there breaks linking.",
           "The default replay (tick 3.34) is load-bearing: upstream tests C22, C24, C25, C28, C30–C32 and C36 rely on it consuming the replay flag."])

pkg(id="BT-W0-04", title="UI test harness and UI test placeholders",
    wave=0, kind="implement", size="M", dependsOn=["BT-W0-02", "BT-W0-03"],
    create=[U_HARNESS, U_HARNESS_T] + PLACEHOLDERS_UI,
    specRefs=["§6.16", "§6.17", "§9.2", "§9.3.6 (seed)", "PLAN §3.3", "PLAN §3.4", "PLAN §3.5"],
    upstreamRefs=[TBD + ":68-105", TM + ":99-131"],
    deliverables=["BluetoothMachineHarness per PLAN §3.3.",
                  "Self-tests for the harness.",
                  "Every UI placeholder test file of PLAN §3.4."],
    task=(
        "Create Tests/AngstromUITests/Bluetooth/BluetoothMachineHarness.swift exactly per PLAN §3.3, on the AngstromTestSupport fakes (BT-W0-03) and the BT-W0-02 LaMarzoccoMachine declarations. It reuses MockBackend/MockURLProtocol and the UI Fixtures, which you must not modify. BT-DASH-SEED-001 is $UPSTREAM/tests/test_bluetooth_dashboard.py:68-105. "
        "Write BluetoothMachineHarnessTests.swift: construction with and without each client, and the standard seed. "
        "Create every UI placeholder test file of PLAN §3.4. Each contains the imports and one empty `@MainActor final class <FileName>: XCTestCase {}` whose doc comment names the owner package."),
    extraTests=[
        "BluetoothMachineHarnessTests.testStandardSeedMatchesSeed001",
        "BluetoothMachineHarnessTests.testHarnessWithoutCloudOrBluetooth",
    ],
    tests=[],
    acceptance=[BUILD, filt("BluetoothMachineHarnessTests"), TEST, WARN, exists(*PLACEHOLDERS_UI)],
    risks=["Every UI Bluetooth test depends on the harness. Keep its seeds and failure modes exactly as PLAN §3.3."])

# ================================================================= WAVE 1 (parallel)
pkg(id="BT-W1-01", title="Leaf types: parity tests and fixes (enums, coercion, models, errors)",
    wave=1, kind="implement", size="M", dependsOn=["BT-W0-01", "BT-W0-03"],
    modify=[P_CONST, P_TRANSPORT, P_TOKEN, P_ENUMS, P_MODELS, P_COERCE, P_SCMODELS, P_DIAG, P_MODELS_SWIFT,
            T_ENUMS, T_COERCE, T_MODELS],
    specRefs=["§2.2", "§2.3", "§3.10", "§4.11", "§6.1–§6.7", "§6.9", "§6.10", "§12 D5 D8"],
    upstreamRefs=[BT + ":40-54", BT + ":62-64", CONST + ":198-218", CONST + ":307-339", MACH + ":58-84",
                  MBT + ":73-87", TMO + ":391-418", TBD + ":636-670"],
    deliverables=["Tests that pin every Wave 0 leaf implementation to SPEC/upstream; fixes to those leaf files if they deviate."],
    task=(
        "Write the parity and unit tests for the leaf types that BT-W0-01 implemented, and fix those files wherever they deviate from the SPEC. You own the leaf source files only for fixes; do not change any frozen signature. "
        "SPEC §3.10 was amended after BT-W0-01 merged, so BluetoothWireCoercion.swift implements the OLD rules in three places; bring it into line and pin each with the test named below: (1) int: try the exact `Int(n.stringValue)` path first for a non-float number, so 9223372036854775807 and -9223372036854775808 decode exactly instead of throwing; (2) double: a string containing x or X (a hex float such as \"0x1p3\") is an error; (3) string: an integer literal too large for UInt64 (a non-fractional NSDecimalNumber) renders as its decimal digits, not float text. "
        "BluetoothEnumsTests: the five characteristic UUIDs and every §2.2 constant, verbatim against $UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:40-54; BluetoothReadSetting and BluetoothBrewingState raw values (const.py:322-339); BluetoothBoilerType raw round-trip including .other; Model(bluetoothFamily:) for every row of the §6.5 table plus whitespace and case normalisation; Model(code: \"GS3\") is still .gs3 (Model.match is private, so test it through the public initialiser; D8); MachineState/BoilerStatus(bluetoothMode:) for all four MachineMode cases; SteamLevel ↔ temperature both ways; a null shotCounterSupported in a Machine payload decodes as false. "
        "BluetoothWireCoercionTests: every row of the SPEC §3.10 table. Include JSON true/false versus the numbers 1/0 (the CFBoolean hazard), \"false\" → false for wire and notification bools (D5a), array/object truthiness for both bool rules ([] → false, {\"a\":1} → true), int truncation 93.5 → 93, int(\"93.5\") fails, int from 1e300 and from 12345678901234567890 throws without trapping (D5d), float(\"abc\") fails, \"nan\"/\"inf\" strings fail (D5e), \"1_0\" fails (D5f), numeric strings for doubles, str() of bool → \"True\"/\"False\", a required string that is null → \"None\" and absent → throws, an optional string that is null → nil, and an array/object string → its compact sorted-keys JSON text (D5c). "
        "BluetoothModelsTests: merging never clears and false/0/\"\" count as set; isEmpty; telemetry merge; the BluetoothShotCounterUpdate default start time; isSuccess is case-insensitive; the BluetoothJSONValue subscript; RawBluetoothFrame marker texts and mtuMarker; every §6.4 errorDescription verbatim; isBluetoothConnectionFailure for every case; BluetoothTransportError.description is non-empty for every case."),
    extraTests=[
        "BluetoothEnumsTests.testConstantsVerbatim", "BluetoothEnumsTests.testReadSettingRawValues",
        "BluetoothEnumsTests.testBrewingStateRawValues", "BluetoothEnumsTests.testBoilerTypeRoundTrip",
        "BluetoothEnumsTests.testCloudModelMatchUnchanged (Angstrom-only: D8)",
        "BluetoothEnumsTests.testMachineStateFromBluetoothMode", "BluetoothEnumsTests.testBoilerStatusFromBluetoothMode",
        "BluetoothEnumsTests.testSteamLevelToTarget", "BluetoothEnumsTests.testSteamLevelEdges (Angstrom-only: G-DEV-4)",
        "BluetoothWireCoercionTests.testParseBool", "BluetoothWireCoercionTests.testRequiredBoolStringFalseIsFalse (Angstrom-only: D5, G-CODEC-3)",
        "BluetoothWireCoercionTests.testCFBooleanHazard", "BluetoothWireCoercionTests.testDoubleRule",
        "BluetoothWireCoercionTests.testIntRuleTruncates", "BluetoothWireCoercionTests.testStringRule",
        "BluetoothWireCoercionTests.testBoolContainerTruthiness",
        "BluetoothWireCoercionTests.testRequiredStringNullIsNone",
        "BluetoothWireCoercionTests.testStringFromContainerIsCompactJSON (Angstrom-only: D5c)",
        "BluetoothWireCoercionTests.testIntRejectsOutOfRangeAndNonFinite (Angstrom-only: D5d)",
        "BluetoothWireCoercionTests.testDoubleRejectsNonFiniteAndUnderscoreStrings (Angstrom-only: D5e, D5f)",
        "BluetoothWireCoercionTests.testIntExactAtIntBounds (Angstrom-only: §3.10 amendment)",
        "BluetoothWireCoercionTests.testDoubleRejectsHexFloatString (Angstrom-only: §3.10 amendment)",
        "BluetoothWireCoercionTests.testStringFromHugeIntegerIsDigits (Angstrom-only: §3.10 amendment)",
        "BluetoothModelsTests.testBrewingMergeNeverClears", "BluetoothModelsTests.testIsEmpty",
        "BluetoothModelsTests.testTelemetryMerge", "BluetoothModelsTests.testUpdateDefaultStartTime",
        "BluetoothModelsTests.testCommandStatusIsSuccessCaseInsensitive", "BluetoothModelsTests.testJSONValueSubscript",
        "BluetoothModelsTests.testRawFrameMarkers", "BluetoothModelsTests.testErrorDescriptionsVerbatim",
        "BluetoothModelsTests.testIsBluetoothConnectionFailure", "BluetoothModelsTests.testTransportErrorDescriptions",
    ],
    tests=[],
    acceptance=std_impl("BT-W1-01", "BluetoothEnumsTests", "BluetoothWireCoercionTests", "BluetoothModelsTests"),
    risks=["Python bool(\"false\") is True upstream. Angstrom deliberately diverges (D5a). Assert the Angstrom behaviour and cite D5.",
           "`Int(_:)` on a Double outside Int range traps. Range-check before converting (SPEC §3.10 int rule)."])

pkg(id="BT-W1-02", title="BluetoothCodec: ordered command writer, frames, NUL handling, ensure_ascii",
    wave=1, kind="implement", size="M", dependsOn=["BT-W0-01", "BT-W0-03"],
    modify=[P_CODEC, T_CODEC],
    specRefs=["§3.5", "§3.6", "§3.7", "§3.9", "§6.8", "§9.3.1", "§12 D6"],
    upstreamRefs=[BT + ":596-626", BT + ":655-710", CONST + ":322-330", TBC + ":295-336", TBC + ":1223-1231"],
    deliverables=["BluetoothCodec complete: commandFrame, the four command builders, responseText, jsonString (Python ensure_ascii), integral-double rule."],
    task=(
        "Implement the rest of Sources/Angstrom/Bluetooth/BluetoothCodec.swift (SPEC §6.8). It is the ONLY producer of BLE command bytes and must never use JSONEncoder. "
        "commandFrame(name:parameter:) writes `{\"name\":<name>,\"parameter\":{…}}` with no whitespace, keys in the given order, then exactly one 0x00 (_bluetooth.py:702-710, `separators=(\",\", \":\")`). "
        "jsonString follows Python json.dumps(ensure_ascii=True) as in SPEC §3.9: escape \" and \\ ; use \\b \\f \\n \\r \\t; other code points < U+0020 become \\u00xx; every code point ≥ U+007F (U+007F included: json.dumps(\"\\x7f\") is \"\\u007f\") becomes \\uxxxx in lowercase hex, with a surrogate pair above U+FFFF; do not escape /. "
        "Doubles: a finite integral value with abs < 1e15 is written as an integer (`90`); otherwise as String(describing:) (`96.5`). Callers guarantee finiteness (D6). "
        "The four builders produce exactly BT-REQ-001…006 (SPEC §3.7), with key orders mode / identifier,state / minutes,mode,enabled / identifier,value. "
        "responseText(_:context:) keeps the bytes before the first 0x00 and decodes them strictly as UTF-8; failure throws LaMarzoccoError.decoding(\"bluetooth \\(context): invalid UTF-8\"). Keep the Wave 0 readRequestFrame/authFrame, and fix them if wrong."),
    extraTests=[
        "BluetoothCodecTests.testCommandFramesMatchPinnedVectors (BT-REQ-001…006; supplementary to C01–C03)",
        "BluetoothCodecTests.testSetSteamAndPowerOffBytes (Angstrom-only: G-CODEC-2)",
        "BluetoothCodecTests.testReadRequestFrames (BT-READ-REQ-001…006)",
        "BluetoothCodecTests.testAuthFrameHasNoTerminator (BT-AUTH-001)",
        "BluetoothCodecTests.testResponseTextCutsAtFirstNul (BT-RSP-MODE-002; Angstrom-only: G-CODEC-4 reads)",
        "BluetoothCodecTests.testResponseTextInvalidUTF8",
        "BluetoothCodecTests.testJSONStringEnsureASCII (incl. U+007F → \\u007f, / unescaped, a surrogate pair)",
        "BluetoothCodecTests.testIntegralDoubleRule (Angstrom-only: D6)",
        "BluetoothCodecTests.testKeyOrderIsNotSorted",
    ],
    tests=[],
    acceptance=std_impl("BT-W1-02", "BluetoothCodecTests") + ["bash -c '! grep -n \"JSONEncoder\" Sources/Angstrom/Bluetooth/BluetoothCodec.swift'"],
    risks=["Swift's String(describing: Double) and Python repr agree on shortest round-trip output for normal values. Keep the 1e15 boundary exactly as SPEC §3.9."])

pkg(id="BT-W1-03", title="BluetoothResponseDecoder: read-setting and command-status decoding",
    wave=1, kind="implement", size="M", dependsOn=["BT-W0-01", "BT-W0-03"],
    modify=[P_DECODER, T_DECODER],
    specRefs=["§3.6", "§3.7 (status)", "§3.10", "§6.6", "§9.3.2", "§12 D5 D9"],
    upstreamRefs=[BT + ":555-594", BT + ":702-710", MBT + ":22-65", CONST + ":198-218", TBC + ":338-430", TBC + ":1234-1250", CONF + ":183-195", TBD + ":517-519"],
    deliverables=["BluetoothResponseDecoder: machineMode, capabilities, bool, boilers, smartStandby, commandStatus with SPEC §3.10 rules and `.decoding(\"bluetooth <rawValue|command>: …\")` errors."],
    task=(
        "Implement Sources/Angstrom/Bluetooth/BluetoothResponseDecoder.swift (SPEC §6.6). The input is NUL-truncated UTF-8 text. Parse it with JSONSerialization(.fragmentsAllowed) and coerce with BluetoothWireCoercion (§3.10). "
        "machineMode: a JSON string \"BrewingMode\"/\"EcoMode\"/\"StandBy\" → MachineMode; anything else → .decoding (ValueError parity, _bluetooth.py:558). "
        "capabilities: an array; element [0]; an empty array → .decoding (IndexError parity). family goes through Model(bluetoothFamily:), and an unknown family throws exactly `.decoding(\"bluetooth machineCapabilities: Invalid model name: <raw>\")`. Required ints and wire bool per §3.10. machineModes entries keep .other (D5). "
        "bool(_:setting:): parseBool. "
        "boilers: an array in wire order; id → BluetoothBoilerType (unknown → .other, D5); target/current as Double (D9). "
        "smartStandby: an object; mode → SmartStandbyAfter (unknown → .decoding); minutes int; enabled wire bool (\"true\" → true; \"false\" → false, D5). "
        "commandStatus: an object with required id/message/status coerced with the required-string rule (null → \"None\", so {\"id\":\"a\",\"message\":null,\"status\":\"success\"} is a success); a missing key or a non-object → `.decoding(\"bluetooth command: …\")`. "
        "Pin every BT-COERCE-001…011 row of SPEC §9.3.2 (the Angstrom column). "
        "Every error is LaMarzoccoError.decoding(\"bluetooth <setting rawValue | command>: <detail>\")."),
    extraTests=[
        "BluetoothResponseDecoderTests.testCapabilitiesMicra (BT-RSP-CAP-001)",
        "BluetoothResponseDecoderTests.testCapabilitiesFamilies (BT-RSP-CAP-002)",
        "BluetoothResponseDecoderTests.testBoilers (BT-RSP-BOIL-001)",
        "BluetoothResponseDecoderTests.testSmartStandbyStringTrue (BT-RSP-SSB-001)",
        "BluetoothResponseDecoderTests.testSmartStandbyStringFalseIsFalse (Angstrom-only: D5, BT-RSP-SSB-002)",
        "BluetoothResponseDecoderTests.testTankAndPlumbBools (BT-RSP-TANK-001, BT-RSP-PLUMB-001…004)",
        "BluetoothResponseDecoderTests.testMachineMode (BT-RSP-MODE-001)",
        "BluetoothResponseDecoderTests.testEmptyBoilers (BT-RSP-EMPTY-001)",
        "BluetoothResponseDecoderTests.testCommandStatus (BT-RSP-CMD-001, BT-CMDSTATUS-CONF)",
        "BluetoothResponseDecoderTests.testCommandStatusMissingKey (Angstrom-only: G-CODEC-6)",
        "BluetoothResponseDecoderTests.testMalformedResponsesThrowDecoding (empty capabilities, unknown mode, non-JSON)",
        "BluetoothResponseDecoderTests.testUnknownBoilerIdTolerated (Angstrom-only: D5)",
        "BluetoothResponseDecoderTests.testFractionalBoilerTarget (Angstrom-only: D9)",
        "BluetoothResponseDecoderTests.testResponseCoercionVectors (BT-COERCE-001…011; D5, D9 rows marked)",
    ],
    tests=[],
    acceptance=std_impl("BT-W1-03", "BluetoothResponseDecoderTests"),
    risks=["Do not reuse CommandStatus(rawValue:) for BLE statuses (SPEC §3.7)."])

pkg(id="BT-W1-04", title="Brewing state machine, tracker and shot-counter notification decoder",
    wave=1, kind="implement", size="L", dependsOn=["BT-W0-01", "BT-W0-03"],
    modify=[P_BSM, T_BSM, T_NTFDEC],
    specRefs=["§3.8", "§3.10", "§4.11", "§4.12", "§6.9", "§9.3.3", "§9.3.4", "§12 D5"],
    upstreamRefs=[MBT + ":68-213", BT + ":77-111", BT + ":441-465", TBC + ":745-781", TBC + ":848-884", TBC + ":894-976", TBC + ":980-1006", REC],
    deliverables=["deriveState(receivedAt:), BrewingTracker.process(_:receivedAt:), ShotCounterNotificationDecoder.decode(_:) per SPEC §3.8/§4.11."],
    task=(
        "Implement Sources/Angstrom/Bluetooth/BrewingStateMachine.swift (SPEC §6.9). "
        "deriveState(receivedAt:) applies the §4.11 rule table in order and fills the update fields exactly as §4.11 (timerValue only for .brewing, defaulting to 0.0; finalShotTime = brewingStoppedTime in any state; brewingStartTime = receivedAt − timerValue for .brewing). "
        "BrewingTracker.process ports _BrewingTracker ($UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:77-111) line for line: reset on startedDoseIndex; merge; derive; keep fragments when there is no state; reset after .flushed or .brewingStopped; keep the earliest start estimate S and write it into the update. "
        "ShotCounterNotificationDecoder.decode (§3.8): strip 0x00 from both ends only, then parse a JSON object. Decode the brewing keys and telemetry keys of the §3.8 tables with the §3.10 rules (notification bool, double, string; MachineMode unknown or non-string → nil; MachineStatistics: absent or JSON null → unset with the rest of the notification processed, a JSON string → its parsed content with a parsed `null` → unset, any other value or an unparseable string → drop). If either part fails, return nil. Unknown keys are ignored. "
        "Unit-test every row of the §4.11 transition table. Also add the pure recorded-session golden: run every notification of the REC fixture (ShotCounterRecording, replays skipped) through decoder + tracker, and assert SPEC §9.3.4 assertions 1–4 and the finer golden (≤ 1 ms). This test is supplementary to C29, which BT-W3-04 owns through the client. If the golden table disagrees while assertions 1–4 hold, report it and do NOT edit the expected values (SPEC U22)."),
    extraTests=[
        "BrewingStateMachineTests.testTransitionTable (every row of SPEC §4.11)",
        "BrewingStateMachineTests.testSequenceAtTrackerLevel (BT-NTF-SEQ-001; supplementary to C24)",
        "BrewingStateMachineTests.testEarliestStartTime (BT-NTF-START-001 at tracker level)",
        "BrewingStateMachineTests.testLateTickAfterStopReentersBrewing (BT-NTF-LATE-001)",
        "BrewingStateMachineTests.testFragmentAccumulates (BT-NTF-FRAG-001)",
        "BrewingStateMachineTests.testEvFalseStringIsStop (Angstrom-only: D5, BT-NTF-COERCE-001)",
        "BrewingStateMachineTests.testRecordedMorningPureGolden (supplementary to C29)",
        "ShotCounterNotificationDecoderTests.testMalformedDropped (BT-NTF-SEQ-002 at decoder level)",
        "ShotCounterNotificationDecoderTests.testNulStrippedBothEndsOnly (Angstrom-only: G-CODEC-4 notifications)",
        "ShotCounterNotificationDecoderTests.testTelemetryKeys (BT-NTF-TEL-001…005 at decoder level)",
        "ShotCounterNotificationDecoderTests.testMachineStatisticsRule (Angstrom-only: G-CODEC-7, BT-NTF-COERCE-002…005)",
        "ShotCounterNotificationDecoderTests.testNotificationCoercionVectors (BT-NTF-COERCE-006…010; D5 rows marked)",
        "ShotCounterNotificationDecoderTests.testUnknownMachineModeIsNil",
        "ShotCounterNotificationDecoderTests.testHeatingCoefficientIgnored",
        "ShotCounterNotificationDecoderTests.testNumericStringTime",
    ],
    tests=[],
    acceptance=std_impl("BT-W1-04", "BrewingStateMachineTests", "ShotCounterNotificationDecoderTests"),
    risks=["The hand-traced golden (SPEC U22) may be wrong. Assertions 1–6 are authoritative; escalate rather than adjust the golden."])

pkg(id="BT-W1-05", title="Dashboard transforms: BLE widget synthesis and the shot-counter overlay",
    wave=1, kind="implement", size="M", dependsOn=["BT-W0-01", "BT-W0-03"],
    modify=[P_DASH, T_DASH],
    specRefs=["§4.17 (pure part)", "§4.19 (overlay)", "§6.12", "§9.3.6", "§12 D12"],
    upstreamRefs=[MACH + ":58-84", MACH + ":287-323", MACH + ":350-492", SNAP + ":2-145", TBD + ":560-689"],
    deliverables=["Dashboard.upserting, removingWidgets, settingMachineState, applyingBluetoothState(_:model:), overlayingBluetoothBrewing(_:)."],
    task=(
        "Implement the Dashboard extension in Sources/Angstrom/Bluetooth/Dashboard+Bluetooth.swift (SPEC §6.12) using the internal widget memberwise initialisers. "
        "upserting replaces the first widget with the same code, keeping its index, else appends. removingWidgets(code:) removes all of them. settingMachineState sets only CMMachineStatus.status. "
        "applyingBluetoothState follows the §4.17 table exactly: waterOK = isPlumbedIn || tankStatus; boilerStatus(enabled); an 'existing W' must have the matching typed kind; an .unknown widget carrying code W is replaced in place by the default-built typed widget, keeping its index, so a code never appears twice; when no widget has the code, append index 1 in the order CMMachineStatus, CMCoffeeBoiler, steam widget, CMNoWater; upstream defaults kept (coffee 80/110/0.1; Mini steam 95/140 supported=false; other steam 20/134 supported=true; enabledSupported per table); the coffee boiler never shows .off; duplicate boiler ids: last wins; .other ids ignored; the level path removes every CMSteamBoilerTemperature and the temperature path removes every CMSteamBoilerLevel; CMMachineGroupStatus is untouched. "
        "overlayingBluetoothBrewing follows the §4.19 table: nil → self; no CMMachineStatus → self; .brewing → status .brewing and brewingStartTime = update.brewingStartTime; any other state (including .backflushing) → status = (base.status == .brewing ? .poweredOn : base.status) and the base brewingStartTime. "
        "Test the pure snapshots BT-DASH-SNAP-001/002, GS3-001, MINI-001, PLUMB-001 and STATUS-001…005 (supplementary to the UI-level D01–D06/D15–D19 owned by BT-W3-08) and every overlay row."),
    extraTests=[
        "DashboardBluetoothTests.testUpsertingKeepsIndex", "DashboardBluetoothTests.testRemovingWidgets",
        "DashboardBluetoothTests.testSettingMachineStateOnlyMachineStatus",
        "DashboardBluetoothTests.testApplyMicraSnapshot (BT-DASH-SNAP-001)",
        "DashboardBluetoothTests.testApplyEmptyMiniR (BT-DASH-SNAP-002)",
        "DashboardBluetoothTests.testApplyGS3UsesTemperature (BT-DASH-GS3-001)",
        "DashboardBluetoothTests.testApplyOriginalMiniDefaults (BT-DASH-MINI-001)",
        "DashboardBluetoothTests.testStatusTable (BT-DASH-STATUS-001…005)",
        "DashboardBluetoothTests.testPlumbInFalseTankFalseRaisesAlarm (BT-DASH-PLUMB-001)",
        "DashboardBluetoothTests.testWidgetDefaultsAndEdgeCases (Angstrom-only: G-DEV-3)",
        "DashboardBluetoothTests.testAvailableModesKept (Angstrom-only: G-DEV-10)",
        "DashboardBluetoothTests.testUnknownWidgetReplacedInPlace",
        "DashboardBluetoothTests.testOverlayTable (Angstrom-only: D12)",
    ],
    tests=[],
    acceptance=std_impl("BT-W1-05", "DashboardBluetoothTests"),
    risks=["Keep upstream's BLE widget defaults even where they differ from cloud fixtures (Q12)."])

pkg(id="BT-W1-06", title="Cloud: bluetoothAuthToken(serial:) from GET /things",
    wave=1, kind="implement", size="S", dependsOn=["BT-W0-01", "BT-W0-03"],
    modify=[P_CLOUDTOKEN, T_TOKEN],
    specRefs=["§2.6", "§3.3", "§4.21", "§6.3", "§6.13", "§12 D2"],
    upstreamRefs=[GEN + ":128-136", CLOUD + ":84-92", TCC + ":322", README + ":78-98"],
    deliverables=["LaMarzoccoCloudClient.bluetoothAuthToken(serial:) per SPEC §4.21."],
    task=(
        "Implement Sources/Angstrom/LaMarzoccoCloudClient+BluetoothToken.swift (SPEC §6.13, §4.21). Make an authenticated GET /things through the existing internal `authed(path:method:)`. Parse with JSONSerialization: the body must be an array of objects, else `.decoding(\"things shape\")`. Find the first object whose serialNumber == serial, else `.decoding(\"things: no thing with serial <serial>\")`. Its top-level `bleAuthToken`: a non-empty JSON string → BluetoothAuthToken; null, absent or \"\" → nil. Never log or print the value. "
        "Tests use the existing Tests/AngstromTests/Support/MockTransport.swift (read-only; do not modify) with a small inline /things body. Include the 64 × \"0\" placeholder token present in Tests/AngstromTests/Fixtures/dashboard_strada_profile.json. Port the intent of upstream's masking test: the token's description, debugDescription and Mirror never reveal the value, and it is not Encodable."),
    extraTests=[
        "BluetoothTokenTests.testMissingSerialThrows", "BluetoothTokenTests.testWrongShapeThrows",
        "BluetoothTokenTests.testTokenIsNotEncodableAndMirrorIsEmpty (Angstrom-only: D2)",
    ],
    tests=[],
    acceptance=std_impl("BT-W1-06", "BluetoothTokenTests"),
    risks=["Do not add a field to Machine (D2)."])

pkg(id="BT-W1-07", title="BluetoothOpTable: exactly-once in-flight operation table",
    wave=1, kind="implement", size="M", dependsOn=["BT-W0-01", "BT-W0-03"],
    modify=[P_OPTABLE, T_OPTABLE],
    specRefs=["§5.4", "§6.10 (op table)", "PLAN §3.1"],
    upstreamRefs=["(no upstream counterpart: Apple-specific; reference = $RESEARCH/06-corebluetooth.md Appendix B `OpTable`, if provided)"],
    deliverables=["BluetoothOpTable per PLAN §3.1 with unit tests."],
    task=(
        "Implement Sources/Angstrom/Bluetooth/BluetoothOpTable.swift with exactly the PLAN §3.1 signature (generic over Key). It is a queue-confined, non-thread-safe table. "
        "register stores (key, isGATTRequest, completion) and appends the token to a FIFO order. finish removes the entry BEFORE calling completion, returns false if the token is unknown, and when abandoning a GATT request records one owed reply for its key. finishOldest first swallows one owed reply for the key if any (returning true); otherwise it finishes the oldest registered op with that key. owe adds an owed reply. isAwaiting is true if an owed reply or a registered op exists for the key. failAll drops owed replies for matching keys and finishes every matching op with .failure(error). "
        "No CoreBluetooth import. Reference: $RESEARCH/06-corebluetooth.md Appendix B, if provided. Unit-test exactly-once completion across reply/timeout/cancel/fan-out orderings."),
    extraTests=[
        "BluetoothOpTableTests.testFinishRemovesBeforeComplete", "BluetoothOpTableTests.testFinishUnknownTokenReturnsFalse",
        "BluetoothOpTableTests.testAbandonedGATTRequestOwesOneReply", "BluetoothOpTableTests.testAbandonedNonGATTOwesNothing",
        "BluetoothOpTableTests.testOweSwallowsNextReply", "BluetoothOpTableTests.testFinishOldestIsFIFO",
        "BluetoothOpTableTests.testFailAllMatchingClearsOrphans", "BluetoothOpTableTests.testIsAwaiting",
        "BluetoothOpTableTests.testCompletionMayReenterTable",
    ],
    tests=[],
    acceptance=std_impl("BT-W1-07", "BluetoothOpTableTests") + ["bash -c '! grep -nE \"^(@preconcurrency )?import CoreBluetooth\" Sources/Angstrom/Bluetooth/BluetoothOpTable.swift'"])

pkg(id="BT-W1-08", title="AngstromBluetooth: CoreBluetooth adapter (central, link, transport factory)",
    wave=1, kind="implement", size="L", dependsOn=["BT-W0-01"],
    create=[P_CB_CENTRAL, P_CB_LINK, P_CB_DOCC],
    modify=[P_CB_TRANSPORT],
    specRefs=["§3.1", "§3.2", "§5.1", "§5.3", "§5.4", "§5.5", "§6.2", "§6.14", "§8.1", "§8.2", "§8.6", "§11 (AngstromBluetooth.md)", "PLAN §3.1"],
    upstreamRefs=[BT + ":233-269", BT + ":396-439", BT + ":522-547", LEG + ":10",
                  "BLEAK 1.1.1 backends/corebluetooth (not in $UPSTREAM; SPEC §5.4 is authoritative)"],
    deliverables=["CoreBluetoothCentral + CoreBluetoothLink implementing the §6.2 seam on one private serial queue; BluetoothTransport.coreBluetooth(showPowerAlert:) and BluetoothAuthorization.current; DocC landing page."],
    task=(
        "Implement the CoreBluetooth adapter in the new AngstromBluetooth target. This is the ONLY place that may `import CoreBluetooth`. Wrap every file in `#if canImport(CoreBluetooth)`. Follow SPEC §5.4 bullet by bullet. "
        "One private serial DispatchQueue(label: \"angstrom.bluetooth\") is both the CBCentralManager delegate queue and the confinement domain. CoreBluetoothCentral and CoreBluetoothLink are `final class …: NSObject, …Delegate, @unchecked Sendable`; justify the @unchecked conformance in a comment and assert `dispatchPrecondition(condition: .onQueue(queue))`. "
        "Bridge async calls with withTaskCancellationHandler + withCheckedThrowingContinuation, and register every in-flight op in a queue-confined BluetoothOpTable (PLAN §3.1 signature; it is implemented in parallel by BT-W1-07, so rely only on its documented semantics). "
        "Required behaviours: owed replies swallowed; a read resolves before a notification; notifications are routed BEFORE setNotifyValue(true) is acknowledged; the manager is created lazily with CBCentralManagerOptionShowPowerAlertKey; a [UUID: CBPeripheral] retention table, emptied on .unknown/.resetting/.unsupported/.unauthorized; resolve on connect via known ?? retrievePeripherals, else a ≤ 10 s scan for that identifier, else .unknownPeripheral; connect timeout via cancelPeripheralConnection, and a late didConnect is cancelled; a non-poweredOn state synthesises .disconnected once per live link, fails pending connects with .unavailable and multicasts availabilityUpdates(); didModifyServices → drop the characteristic table and yield .servicesInvalidated; .withResponse writes longer than maximumWriteValueLength(for: .withResponse) throw .valueTooLong; disconnect waits ≤ 5 s; scan has no service filter, de-duplicates and keeps first-seen order, names come from CBPeripheral.name else CBAdvertisementDataLocalNameKey; discover(_:refresh:timeout:) runs discoverServices(nil) and then discoverCharacteristics on every service and matches by characteristic UUID (never assume the legacy service d30a…, SPEC §3.1); attMTU() = maximumWriteValueLength(.withoutResponse) + 3; gattTable lists every service/characteristic with the §6.2 property names; stamp GATTNotification.receivedAt with the transport's now() inside the delegate callback. "
        "Never use CBConnectPeripheralOptionEnableAutoReconnect, `@preconcurrency import CoreBluetooth`, Mutex, an actor with a custom executor, or a Task hop inside a delegate callback. Use no macOS-unavailable connection-event APIs. "
        "Public surface: only BluetoothTransport.coreBluetooth(showPowerAlert:) and BluetoothAuthorization.current (from CBManager.authorization, which allocates no manager). Everything else is internal. "
        "Write Documentation.docc/AngstromBluetooth.md: the factory, BluetoothAuthorization.current, and the Info.plist/entitlement table of SPEC §8.2. "
        "If $RESEARCH is provided, start from $RESEARCH/06-corebluetooth.md Appendix B and $RESEARCH/06-sketch/btsketch/Sources/BTCoreBluetooth/CoreBluetoothAdapter.swift, and adapt them to the frozen seam (add availabilityUpdates, attMTU, gattTable, the scan-by-identifier fallback and first-seen order; use BluetoothOpTable). "
        "No unit tests are possible (no test may construct CBCentralManager). Acceptance is a warning-free build for macOS and iOS."),
    extraTests=["(compile-only: no test may construct CBCentralManager/CBPeripheral; behaviour is verified by BT-W2-11 review and hardware items H1–H28)"],
    tests=[],
    acceptance=[BUILD, WARN, nostub("BT-W1-08"),
                "bash -c '! grep -rnE \"^@preconcurrency import CoreBluetooth\" Sources'",
                "bash -c '! grep -rlE \"^(@preconcurrency )?import CoreBluetooth\" Sources | grep -v \"^Sources/AngstromBluetooth/\"'",
                "bash -c 'for f in Sources/AngstromBluetooth/*.swift; do grep -q \"canImport(CoreBluetooth)\" \"$f\" || { echo \"no canImport guard: $f\"; exit 1; }; done'",
                "bash -c '! grep -rnE \"EnableAutoReconnect|Mutex<\" Sources/AngstromBluetooth | grep -vE \"^[^:]+:[0-9]+:[[:space:]]*(//|///|\\*)\"'",
                "xcodebuild -scheme Angstrom-Package -destination 'generic/platform=iOS Simulator' -quiet build"],
    risks=["Swift 6 region-isolation errors for CB objects appear only on a full `swift build` (not -typecheck).",
           "The xcodebuild scheme name may differ. Run `xcodebuild -list` and use the package scheme (report the name).",
           "No runtime test exists. Hardware items H1–H4, H8–H10, H13–H20 exercise this code before release."])

pkg(id="BT-W1-09", title="LaMarzoccoBluetoothClient core: gates, connect, auth, idle, teardown, events, raw tap",
    wave=1, kind="implement", size="L", dependsOn=["BT-W0-01", "BT-W0-03"],
    modify=[P_CLIENT, T_CORE],
    specRefs=["§3.4", "§4.1–§4.8", "§4.4.1", "§4.13 (handleConnectionLost)", "§5.5", "§5.6", "§5.7", "§6.11 [main]", "§8.1", "§12 D1 D7 D10 D11 D16 D19"],
    upstreamRefs=[BT + ":114-136", BT + ":142-325", BT + ":467-486", BT + ":549-553", BT + ":628-653",
                  "BRC 4.4.4 (not in $UPSTREAM; SPEC §2.2/§4.2 values are authoritative)"],
    deliverables=["Every [main] member of SPEC §6.11 implemented: FIFO gates, ensureConnected, authenticate, idle timer, teardown, link-event watcher, connection events, raw tap, error mapping, test seams."],
    task=(
        "Implement every [main] member of Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient.swift (SPEC §6.11) exactly per §4.1–§4.8. "
        "acquire/release are two FIFO continuation gates (.connection, .request); the lock order is always request → connection. "
        "ensureConnected(refresh:) follows §4.2 steps 1–8: availability per §8.1 — create the availabilityUpdates() stream BEFORE reading availability(), and for unknown/resetting/notDetermined race that stream against `sleeper.sleep(for: timing.poweredOnWait, purpose: .poweredOnWait)` in a task group (first finisher decides, the other is cancelled), failing fast on every other state; ≤ timing.connectAttempts single attempts with timing.connectTimeout, sleeping (.connectBackoff) 0.25 s after .timedOut else 0.1 s; .unknownPeripheral is terminal; the final message is `Failed to connect to <peripheral> after <n> attempts: <last error>`; discover the four session characteristics; a missing auth characteristic → `Could not find characteristic 0d0b7847-e12b-09a8-b04b-8e0922a9abab on machine.`; raw markers [connecting]/[connected]/[mtu n]/[authenticated]; on ANY error from step 4 on, including CancellationError, disconnect the new link and emit no event; on success set link, start the watcher, clear needsRediscovery, resetIdleTimer(), setConnected(true). "
        "authenticate follows §3.4 exactly: write UTF8(token) with response to 0d0b…; ≤ 10 reads with an .authPoll sleep of 50 ms before every read except the first; authenticationFailed = (bytes != [0x01]) after EVERY read; 10 misses → .bluetoothAuthenticationFailed; transport errors → `.bluetoothConnectionFailed(\"Failed to connect to machine with Bluetooth: <e>\")`, unavailable → .bluetoothUnavailable; the auth write is tapped with isSecret: true. "
        "Idle timer per §4.6 (it never cancels itself; suppressed while shotCounterEnabled). Teardown paths and link events per the §4.7 table, including the stale-link identity guard, D16 (a loss cancels the idle task) and servicesInvalidated → needsRediscovery. The link watcher is exactly the SPEC §5.5 form `Task { [weak self] in for await e in link.events { await self?.handleLinkEvent(e, from: link) } }` (a strong self makes the await a G5 warning). Step 1 trusts the stored link (I1, D7e). "
        "setConnected is edge-triggered. connectionEvents()/rawFrames() are multiplexed AsyncStreams (the house pattern of LaMarzoccoCloudClient.swift:488-498), and emitRaw costs nothing without listeners. handleConnectionLost per §4.13 (it starts `reconnectTask = Task { await reconnectLoop() }`; reconnectLoop is BT-W2-02's). mapTransportError implements every cell of the §4.4.1 table. "
        "Test seams: drainBackgroundWorkForTesting awaits every tracked task (drops, reconnect) except the idle task; hasBackgroundWorkForTesting includes idle and reconnect; logHandler output never contains the token. "
        "Do not implement +Requests/+ShotCounter/+Discovery members. Your tests drive the client through the internal ensureConnected()/disconnect()/link events, using the AngstromTestSupport fakes."),
    extraTests=[
        "BluetoothClientCoreTests.testEnsureConnectedDiscoversAndAuthenticates",
        "BluetoothClientCoreTests.testGatesAreFIFOAndOrdered",
        "BluetoothClientCoreTests.testAvailabilityFailFast (Angstrom-only: D10)",
        "BluetoothClientCoreTests.testAvailabilityWaitsForPoweredOn (manual: [.idleDisconnect, .poweredOnWait])",
        "BluetoothClientCoreTests.testAvailabilityWaitTimesOut (fires .poweredOnWait by hand; asserts requested(.poweredOnWait) == [10 s])",
        "BluetoothClientCoreTests.testConnectRetriesThreeTimesWithBackoff (Angstrom-only: G-CONN-1, D1)",
        "BluetoothClientCoreTests.testUnknownPeripheralIsTerminal",
        "BluetoothClientCoreTests.testMissingAuthCharacteristic",
        "BluetoothClientCoreTests.testFailedConnectDisconnectsLinkWithoutEvent",
        "BluetoothClientCoreTests.testCancellationDuringConnectDisconnects",
        "BluetoothClientCoreTests.testSetConnectedIsEdgeTriggered",
        "BluetoothClientCoreTests.testIdleTimerFiresDisconnect",
        "BluetoothClientCoreTests.testIdleTaskDoesNotCancelItself",
        "BluetoothClientCoreTests.testLinkLossFromCurrentLink",
        "BluetoothClientCoreTests.testStaleLinkEventsIgnored",
        "BluetoothClientCoreTests.testServicesInvalidatedSetsRediscovery",
        "BluetoothClientCoreTests.testMapTransportErrorTable",
        "BluetoothClientCoreTests.testDisconnectIsIdempotent",
        "BluetoothClientCoreTests.testTeardownCompletesOnDeadLink (Angstrom-only: G-CONN-3)",
        "BluetoothClientCoreTests.testRawFrameLifecycleMarkers",
        "BluetoothClientCoreTests.testAuthWriteIsSecretOnRawTap",
        "BluetoothClientCoreTests.testLogNeverContainsToken",
    ],
    tests=[],
    acceptance=std_impl("BT-W1-09", "BluetoothClientCoreTests") + ["swift test --sanitize=thread --filter 'BluetoothClientCoreTests'"],
    risks=["Actor re-entrancy at every await. Request atomicity depends on the gates, not on the actor.",
           "A cleanup path missing on cancellation leaves an unauthenticated link up (C41)."])

pkg(id="BT-W1-10", title="Discovery, pairing-mode token read and GATT table (static)",
    wave=1, kind="implement", size="M", dependsOn=["BT-W0-01", "BT-W0-03"],
    modify=[P_CLIENT_DISC, T_DISC],
    specRefs=["§3.2", "§3.3", "§4.14", "§6.11 (+Discovery)", "§12 D3 D20"],
    upstreamRefs=[BT + ":46", BT + ":522-547", TBC + ":1326-1342"],
    deliverables=["static scanAll(transport:duration:), discoverMachines(transport:duration:), readToken(transport:peripheral:), gattTable(transport:peripheral:)."],
    task=(
        "Implement Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Discovery.swift (SPEC §4.14). The members are static and touch no instance state or raw tap; they use default BluetoothTiming() and the transport's sleeper. Write your own fileprivate availability wait, the same rule as §4.2 step 3 including the `.poweredOnWait` sleep on the transport's sleeper (do not depend on the [main] helpers, which are implemented in parallel). "
        "scanAll: availability, then central.scan(for:duration) returned unchanged (no name filter). discoverMachines: scanAll, then keep a peripheral iff its name is non-nil, non-empty and case-sensitively starts with one of BluetoothConstants.machineNamePrefixes (\"LINEAR_4\" matches). Keep first-seen order, de-duplicated. "
        "readToken: availability; ONE connect with timing.tokenReadConnectTimeout (10 s); no auth; discover({token}, refresh: false), and a missing characteristic → `Could not find characteristic 0c0b7847-e12b-09a8-b04b-8e0922a9abab on machine.`; read; strict UTF-8 with NO NUL stripping, invalid → `.decoding(\"bluetooth token: invalid UTF-8\")`; a .gatt error with ATT code 2/5/8/15 → `.bluetoothConnectionFailed(\"Could not read the Bluetooth token (ATT error <code>). Is the machine in pairing mode?\")`; always disconnect. The token read is never printed. "
        "gattTable: one connect with timing.connectTimeout, link.gattTable(timeout:), disconnect; no auth."),
    extraTests=[
        "BluetoothDiscoveryTests.testNilOrEmptyNameSkipped (Angstrom-only: G-CODEC-8)",
        "BluetoothDiscoveryTests.testFirstSeenOrderDeduplicated (Angstrom-only: D3)",
        "BluetoothDiscoveryTests.testDiscoveryUnavailableThrows",
        "BluetoothDiscoveryTests.testScanAllIsUnfiltered (Angstrom-only: U3/H10; nil, empty and OTHER names kept in first-seen order)",
        "BluetoothDiscoveryTests.testDiscoveryAvailabilityWaitTimesOut (fires .poweredOnWait by hand)",
        "BluetoothDiscoveryTests.testReadTokenOneAttemptNoAuth (Angstrom-only: G-CODEC-1)",
        "BluetoothDiscoveryTests.testReadTokenKeepsNul",
        "BluetoothDiscoveryTests.testReadTokenInvalidUTF8",
        "BluetoothDiscoveryTests.testReadTokenATTErrorMessage (Angstrom-only: D20)",
        "BluetoothDiscoveryTests.testReadTokenAlwaysDisconnects",
        "BluetoothDiscoveryTests.testReadTokenMissingCharacteristic",
        "BluetoothDiscoveryTests.testGattTableOneConnectNoAuth",
    ],
    tests=[],
    acceptance=std_impl("BT-W1-10", "BluetoothDiscoveryTests"))

pkg(id="BT-W1-11", title="AngstromUI: base-dashboard funnel, cloud-only accessor use, BLE-first routing",
    wave=1, kind="implement", size="M", dependsOn=["BT-W0-02", "BT-W0-04"],
    modify=[P_UI_MAIN, U_ROUTING],
    specRefs=["§1.4", "§4.15", "§4.16 (routing table)", "§4.19 (base model)", "§4.20", "§6.16 (main-file changes)", "§13"],
    upstreamRefs=[THING + ":27-38", MACH + ":494-509", MACH + ":764-841", MACH + ":870-892", MACH + ":983-1049", TT + ":29-34"],
    deliverables=["All ~33 dashboard writes through setBaseDashboard/updateBaseDashboard, reading only baseDashboard (SPEC §4.19 read rule); snapshot from baseDashboard; gating sets from core; the six methods call bluetoothFirst with the §4.16 mapping; cloud-only operations throw .cloudOnlyFunctionality without a cloud client."],
    task=(
        "You are the only owner of Sources/AngstromUI/LaMarzoccoMachine.swift after Wave 0. Apply the SPEC §6.16 'main-file behaviour changes'. "
        "(1) Every `dashboard = …` write becomes setBaseDashboard(…) (the three wholesale sites: snapshot seed, refreshDashboard, refreshAll) or updateBaseDashboard { … } (the push merge in start() and every optimistic site). The push merge is NOT wholesale: `if let current = self.dashboard { self.dashboard = current.applying(update); self.lastUpdateAt = Date() }` becomes `if self.baseDashboard != nil { self.updateBaseDashboard { $0.applying(update) }; self.lastUpdateAt = Date() }`, so a widget-less push keeps the base widgets. SPEC §4.19 read rule: every value that feeds a base write is read from baseDashboard, never from the rendered dashboard (that includes guard reads such as `dashboard?.groupDoses` and `dashboard?.grinderDoses?.mode` in the optimistic paths); otherwise the overlay's .brewing status leaks into the base and the snapshot. Afterwards the only assignment to `dashboard` in the file is inside renderDashboard(). "
        "(2) `snapshot` persists baseDashboard. "
        "(3) Self.steamLevelModels/steamTemperatureModels become Model.steamLevelModels/Model.steamTemperatureModels; the other gating sets stay. "
        "(4) setPower, setSteam, setSteamTargetLevel, setCoffeeTargetTemperature, setSteamTargetTemperature and setSmartStandby call bluetoothFirst(bluetooth:cloud:) inside their existing capturing{}, after gating, with exactly the BLE and cloud calls of the §4.16 table (the BLE argument order is (enabled, mode: after, minutes); setSteamTargetLevel sends Double(level.bluetoothTargetTemperature); no rounding on the BLE leg). setSmartStandby with schedule?.autoStandBySupported == true stays cloud-only via `try client` (\"HH:MM\" = String(format: \"%02d:%02d\", minutes / 60, minutes % 60), or \"Off\"). Optimistic updates stay after the call. "
        "(5) Every other cloud method resolves `try client`, so a machine without a cloud client throws .cloudOnlyFunctionality and records lastError through capturing. start() resolves the client first; stop() is a no-op without one. "
        "bluetoothFirst's BLE branch is BT-W3-07's; your tests use machines without a Bluetooth client, through BluetoothMachineHarness(bluetooth: false) or the existing MockBackend. "
        "Existing tests (LaMarzoccoMachineTests.swift, unmodified) must stay green."),
    extraTests=[
        "MachineTransportRoutingTests.testStartWithoutCloudThrowsAndStopIsNoOp",
        "MachineTransportRoutingTests.testDashboardEqualsBaseWithoutOverlay",
        "MachineTransportRoutingTests.testWidgetlessPushKeepsBaseWidgets",
        "MachineTransportRoutingTests.testSnapshotPersistsBaseDashboard",
        "MachineTransportRoutingTests.testSixCommandsWithoutBluetoothUseCloud",
        "MachineTransportRoutingTests.testSmartStandbyAutoStandbyStaysCloudOnly",
        "MachineTransportRoutingTests.testGatingUsesCoreModelSets",
    ],
    tests=[],
    acceptance=std_impl("BT-W1-11", "MachineTransportRoutingTests", "LaMarzoccoMachineTests") + [
        "bash -c 'n=$(grep -cE \"(^|[^A-Za-z_])(self\\.)?dashboard = \" Sources/AngstromUI/LaMarzoccoMachine.swift); test \"$n\" -eq 1 || { echo \"dashboard assignments: $n\"; exit 1; }'"],
    risks=["About 33 sites in a 774-line file. A missed site makes the overlay and snapshot wrong only in BLE scenarios, which existing tests never see. Use the mechanical count."])

pkg(id="BT-W1-12", title="angcli scaffolding: package, Info.plist, Ble command tree, redaction, internal API stubs",
    wave=1, kind="implement", size="M", dependsOn=["BT-W0-01"],
    create=[C_PLIST, C_BLE, C_SESSION, C_BLEOUT, C_SCAN, C_GATT, C_TOKEN, C_READ, C_CMD, C_LISTEN] + PLACEHOLDERS_CLI,
    modify=[C_PKG, C_ANGCLI, C_OUTPUT],
    specRefs=["§8.4", "§10.1", "§10.4", "§10.5", "§10.6", "PLAN §3.2", "PLAN §3.4"],
    upstreamRefs=[CLOUD + ":84-92"],
    deliverables=["cli/Package.swift (AngstromBluetooth dep + -sectcreate), cli/Support/Info.plist, Ble parent + six subcommand stubs, BleSession/BleOutput stubs, Redact.bluetoothFrame (complete), CLI test placeholders."],
    task=(
        "Prepare the angcli package for the `ble` command tree (SPEC §10) so BT-W2-03…06 can work in parallel. "
        "cli/Package.swift: add `.product(name: \"AngstromBluetooth\", package: \"Angstrom\")` to the angcli target, and `linkerSettings: [.unsafeFlags([\"-Xlinker\", \"-sectcreate\", \"-Xlinker\", \"__TEXT\", \"-Xlinker\", \"__info_plist\", \"-Xlinker\", \"Support/Info.plist\"])]` (SPEC §8.4). If the relative path does not resolve, the allowed fallback is `\"\\(Context.packageDirectory)/Support/Info.plist\"`; report which one you used. "
        "cli/Support/Info.plist: CFBundleIdentifier `angstrom.angcli`, CFBundleName `angcli`, NSBluetoothAlwaysUsageDescription `angcli talks to your La Marzocco machine over Bluetooth for debugging.` "
        "AngCLI.swift: subcommands [Listen.self, Dump.self, Machines.self, Ble.self]; mention Bluetooth in abstract/discussion; version \"2.0.0\". "
        "Output.swift: add Redact.bluetoothFrame(_:) per SPEC §10.4. If frame.isSecret, OR the frame is a write to 0d0b7847-e12b-09a8-b04b-8e0922a9abab, OR a read of 0c0b7847-e12b-09a8-b04b-8e0922a9abab, both hex and text are Redact.placeholder. Otherwise hex is lowercase hex and text is the UTF-8 string or nil. Redact.secrets(in:) is unchanged. "
        "Create Ble/Ble.swift complete per PLAN §3.2. Create Ble/BleSession.swift and Ble/BleOutput.swift with exactly the PLAN §3.2 declarations as stubs (owner BT-W2-03); BleTargetOptions is complete. Create BleScan/BleGatt/BleToken (owner BT-W2-04), BleRead/BleCmd (BT-W2-05) and BleListen (BT-W2-06) as AsyncParsableCommand structs whose configuration has an abstract and whose run() throws CLIError(\"unimplemented: <owner>\"). "
        "Create the CLI test placeholders of PLAN §3.4. Existing CLI tests must pass."),
    extraTests=["(scaffolding: behaviour tests belong to BT-W2-03…06; Redact.bluetoothFrame is tested by BT-W2-03)"],
    tests=[],
    acceptance=[CLI_BUILD, CLI_TEST, CLI_WARN, BUILD, nostub("BT-W1-12"),
                "plutil -lint cli/Support/Info.plist",
                "bash -c 'grep -q NSBluetoothAlwaysUsageDescription cli/Support/Info.plist'",
                "bash -c '! grep -q unsafeFlags Package.swift'",
                stub_owners("cli/Sources", "BT-W2-0[3-6]"),
                exists(*PLACEHOLDERS_CLI)],
    risks=["unsafeFlags is allowed only because cli/ is always a root package (SPEC §8.4). Never add it to the root Package.swift."])

# ================================================================= WAVE 2 (parallel)
pkg(id="BT-W2-01", title="Client requests: request wrapper, resolution, reads, commands, rawRead",
    wave=2, kind="implement", size="M", dependsOn=["BT-W1-02", "BT-W1-03", "BT-W1-09", "BT-W0-03"],
    modify=[P_CLIENT_REQ, T_REQSMOKE],
    specRefs=["§3.5–§3.7", "§4.4", "§4.4.1", "§4.5", "§6.11 (+Requests)", "§12 D7 D19"],
    upstreamRefs=[BT + ":114-136", BT + ":555-626", BT + ":655-747", TBC + ":295-430", TBC + ":1223-1302"],
    deliverables=["request(_:frame:), resolve(_:on:), readSetting, sendCommand, the six reads, the four commands, rawRead(_:)."],
    task=(
        "Implement Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Requests.swift (SPEC §6.11 [+Requests]). "
        "request(_:frame:) is exactly §4.4 steps 1–7: the request gate held end to end; ensureConnected; resolve; a write with response (operationTimeout) tapped as .write; the same-link check `self.link !== link` → `.bluetoothConnectionFailed(\"Client is not connected\")` (D7a), else resetIdleTimer(); a read of the same characteristic tapped as .read; on error mapTransportError(phase: .request), then dropConnectionInBackground() for drop-class errors unless `shotCounterEnabled && link != nil`; rethrow. "
        "resolve(_:on:) is exactly §4.5, including one in-place rediscovery and an unconditional drop when the characteristic is still missing. "
        "readSetting writes BluetoothCodec.readRequestFrame to 0a0b… and returns BluetoothCodec.responseText (context = setting rawValue). Decoding happens AFTER the gate is released, so a decode error never drops the link. "
        "sendCommand writes the frame to 0b0b…, reads 0b0b…, and decodes with BluetoothResponseDecoder.commandStatus. A non-success status is RETURNED, not thrown. "
        "setTemperature rejects a non-finite value with `.operationNotAvailable(\"temperature must be finite\")` before any I/O (D21), and does not round. rawRead returns the verbatim bytes before NUL truncation. "
        "Write narrow smoke tests only; the parity suites are BT-W3-01/02/03."),
    extraTests=[
        "BluetoothClientRequestsSmokeTests.testEachReadDecodes",
        "BluetoothClientRequestsSmokeTests.testEachCommandWritesFrameAndReturnsStatus",
        "BluetoothClientRequestsSmokeTests.testNonSuccessStatusIsReturned",
        "BluetoothClientRequestsSmokeTests.testDecodeErrorKeepsLink",
        "BluetoothClientRequestsSmokeTests.testDropClassErrorDropsIdleLink",
        "BluetoothClientRequestsSmokeTests.testSmokeMissingCharacteristicDrops",
        "BluetoothClientRequestsSmokeTests.testLinkDropBetweenWriteAndReadFails",
        "BluetoothClientRequestsSmokeTests.testNonFiniteTemperatureRejected",
        "BluetoothClientRequestsSmokeTests.testRawReadIsVerbatim",
        "BluetoothClientRequestsSmokeTests.testRequestTimeoutIsBluetoothTimedOut",
    ],
    tests=[],
    acceptance=std_impl("BT-W2-01", "BluetoothClientRequestsSmokeTests"))

pkg(id="BT-W2-02", title="Client shot counter: subscribe, notifications, stop, reconnect loop",
    wave=2, kind="implement", size="L", dependsOn=["BT-W1-04", "BT-W1-09", "BT-W0-03"],
    modify=[P_CLIENT_SC, T_SCSMOKE],
    specRefs=["§3.8", "§4.9", "§4.10", "§4.12", "§4.13", "§6.11 (+ShotCounter)", "§12 D4 D14 D15"],
    upstreamRefs=[BT + ":327-465", BT + ":475-520", TBC + ":652-1191"],
    deliverables=["startShotCounter, stopShotCounter, shotCounterEvents, subscribeShotCounter, disableShotCounter, stopNotifyInternal, handleShotCounterNotification, reconnectLoop."],
    task=(
        "Implement Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+ShotCounter.swift (SPEC §6.11 [+ShotCounter]) exactly per §4.9, §4.10 and §4.13. Replace the Wave 0 inert fast paths with the full behaviour. "
        "startShotCounter: enabled = true; subscribe; on a throw or false, disable (and resetIdleTimer if linked), then rethrow or return false; a second call while subscribed returns true with no new .subscribed. "
        "subscribeShotCounter: the [false, true] refresh loop of §4.9, under the connection gate; tracker reset and replayPending = true BEFORE link.subscribe; .subscribed is emitted after releasing the gate. "
        "stopShotCounter and disableShotCounter per §4.9: state is mutated before any event. stopNotifyInternal is best effort. "
        "handleShotCounterNotification per §4.10: raw tap first, then the replay drop, then decode, then brewing before telemetry; emit only while enabled. "
        "reconnectLoop: the §4.13 pseudocode verbatim. Sleep (.reconnectBackoff) BEFORE every attempt. D14: the sleep ends early, resetting the delay to reconnectInitialDelay, when central.availabilityUpdates() yields .poweredOn after a non-poweredOn value seen during this loop. Auth failures are counted cumulatively and do not double the delay. Other errors disconnect under the gate and double the delay up to 60 s. An unsupported result gives up. Giving up clears reconnectTask, disables the counter, re-arms the idle timer if linked, and emits .gaveUp(lastError) when the counter was still enabled (D15). CancellationError returns silently. "
        "shotCounterEvents() is multiplexed like connectionEvents(). Write narrow smoke tests only; the parity suites are BT-W3-03/04/05."),
    extraTests=[
        "BluetoothClientShotCounterSmokeTests.testStartAuthenticatesThenSubscribes",
        "BluetoothClientShotCounterSmokeTests.testReplayIsDropped",
        "BluetoothClientShotCounterSmokeTests.testBrewingEmittedBeforeTelemetry",
        "BluetoothClientShotCounterSmokeTests.testStopUnsubscribesAndRearmsIdle",
        "BluetoothClientShotCounterSmokeTests.testLossReconnectsAndResubscribes",
        "BluetoothClientShotCounterSmokeTests.testGiveUpEmitsGaveUp",
        "BluetoothClientShotCounterSmokeTests.testUnsupportedReturnsFalse",
        "BluetoothClientShotCounterSmokeTests.testSmokePoweredOnCutsBackoff (no polling: make .reconnectBackoff manual and `await sleeper.waitForPending(.reconnectBackoff, count: 1)`; SPEC §4.13 creates the availability stream before the first sleep, so it exists by then — assert central.availabilitySubscriberCount >= 1, then setAvailability)",
    ],
    tests=[],
    acceptance=std_impl("BT-W2-02", "BluetoothClientShotCounterSmokeTests") + ["swift test --sanitize=thread --filter 'BluetoothClientShotCounterSmokeTests'"],
    risks=["The D14 availability race with the backoff sleep. Implement it as a task group or a cancellation of the sleep, never by polling.",
           "Emitting .unsubscribed at give-up would duplicate the event already sent at loss time (§4.13)."])

pkg(id="BT-W2-03", title="angcli: BleSession (selection, token precedence) and BleOutput (lines, redaction)",
    wave=2, kind="implement", size="M", dependsOn=["BT-W1-12"],
    modify=[C_SESSION, C_BLEOUT, CT_SESSION, CT_OUTPUT],
    specRefs=["§8.7", "§10.2", "§10.3", "§10.4", "PLAN §3.2"],
    upstreamRefs=[CLOUD + ":84-92", README + ":78-125"],
    deliverables=["BleSession and BleOutput implemented per PLAN §3.2 and SPEC §10.2–§10.4, with tests."],
    task=(
        "Implement cli/Sources/angcli/Ble/BleSession.swift and BleOutput.swift with exactly the PLAN §3.2 declarations. "
        "BleSession: token precedence --ble-token → LAMARZOCCO_BLE_TOKEN → cloud (Bootstrap.connect() + MachineSelector.choose(serial:) + bluetoothAuthToken(serial:)). A nil cloud token → CLIError(\"The cloud has no Bluetooth token for <serial>. Use 'angcli ble token' in pairing mode or the QR label.\"). Peripheral selection per §10.2 with an interactive pick on stderr. Never persist the token or the peripheral id. cliError maps .bluetoothUnavailable(.unauthorized(_)) and .poweredOff to the exact §10.3 texts. "
        "BleOutput: one JSON object per line. A raw line is {\"ts\",\"dir\":\">>\"|\"<<\",\"kind\":\"write|read|notification|event\",\"char\",\"hex\",\"text\"} built through Redact.bluetoothFrame (never bypass it). Decoded lines are {\"ts\",\"event\",\"value\"} with CLI-local Encodable mirrors of BluetoothShotCounterUpdate/BluetoothMachineTelemetry. tokenLine is masked unless showSecret. Reuse Stdout/Stderr/Timestamp from Output.swift (read-only for you). "
        "Tests cover only pure functions: no CoreBluetooth and no network. Build DiscoveredPeripheral, BluetoothGATTService and BluetoothGATTCharacteristic values with their public inits (SPEC §6.2); angcli is a separate package and cannot see `package` declarations."),
    extraTests=[
        "BleSessionTests.testTokenPrecedenceFlagThenEnvironment", "BleSessionTests.testEmptyLocalTokensFallThroughToCloud",
        "BleSessionTests.testSelectPeripheralNoneOneMany", "BleSessionTests.testUnavailableErrorTexts",
        "BleSessionTests.testTargetOptionsParse",
        "BleOutputTests.testRawLineShape", "BleOutputTests.testSecretFrameRedacted",
        "BleOutputTests.testAuthWriteRedactedByUUID", "BleOutputTests.testTokenReadRedactedByUUID",
        "BleOutputTests.testNonUTF8RawHasNoText", "BleOutputTests.testDecodedLineShapes",
        "BleOutputTests.testTokenLineMaskedByDefault", "BleOutputTests.testExistingRedactSecretsUnchanged",
    ],
    tests=[],
    acceptance=std_cli("BT-W2-03", "BleSessionTests", "BleOutputTests"))

pkg(id="BT-W2-04", title="angcli: ble scan, ble gatt, ble token",
    wave=2, kind="implement", size="S", dependsOn=["BT-W1-12"],
    modify=[C_SCAN, C_GATT, C_TOKEN, CT_DISC],
    specRefs=["§10.1", "§10.3", "§10.4", "§9.6 (H1, H10, H17)", "PLAN §3.2"],
    upstreamRefs=[BT + ":522-547"],
    deliverables=["BleScan (--duration, --all via scanAll), BleGatt (--peripheral), BleToken (--peripheral, --show-secret)."],
    task=(
        "Implement cli/Sources/angcli/Ble/BleScan.swift, BleGatt.swift and BleToken.swift (SPEC §10.1) on top of the PLAN §3.2 API (BleSession/BleOutput are implemented in parallel by BT-W2-03: only call their declared signatures). "
        "scan: `--duration <s>` (default 5). Without `--all` it calls LaMarzoccoBluetoothClient.discoverMachines; with `--all` it calls the public LaMarzoccoBluetoothClient.scanAll (unfiltered, SPEC §4.14) and prints the count to stderr. It prints one peripheralLine per peripheral (name may be null with --all). Only public Angstrom API is visible from cli/ (no `package` access). "
        "gatt: requires --peripheral and prints gattLines. "
        "token: requires --peripheral, calls LaMarzoccoBluetoothClient.readToken, prints tokenLine masked unless `--show-secret`, which prints to stdout only. "
        "Map errors through BleSession.cliError. Tests are argument-parsing only (`Ble*.parse([...])`); no hardware."),
    extraTests=["BleDiscoveryCommandTests.testScanParsesDurationAndAll", "BleDiscoveryCommandTests.testGattRequiresPeripheral",
                "BleDiscoveryCommandTests.testTokenShowSecretDefaultsOff"],
    tests=[],
    acceptance=std_cli("BT-W2-04", "BleDiscoveryCommandTests"))

pkg(id="BT-W2-05", title="angcli: ble read, ble cmd (with --confirm)",
    wave=2, kind="implement", size="M", dependsOn=["BT-W1-12"],
    modify=[C_READ, C_CMD, CT_REQ],
    specRefs=["§10.1", "§10.3", "§9.6 (H22–H27)", "PLAN §3.2"],
    upstreamRefs=[BT + ":555-626", CONST + ":322-330"],
    deliverables=["BleRead (<setting|all>) and BleCmd (power/steam/temp/standby subcommands, refusing without --confirm)."],
    task=(
        "Implement cli/Sources/angcli/Ble/BleRead.swift and BleCmd.swift (SPEC §10.1). "
        "read <setting|all> takes @OptionGroup BleTargetOptions. For each setting it calls rawRead and then the typed read, and prints BleOutput.readLine with `raw` = the UTF-8 text of the verbatim bytes (hex if not UTF-8) and a CLI-local Encodable mirror as `decoded`. "
        "cmd has nested subcommands: `power <on|off>`, `steam <on|off>`, `temp <coffee|steam> <celsius>`, `standby --enabled <bool> --minutes <n> --mode <LastBrewing|PowerOn>`. Each requires `--confirm`, enforced in validate() with a ValidationError (it actuates hardware), and prints BleOutput.commandLine with success = status.isSuccess. "
        "Use only the PLAN §3.2 signatures of BleSession/BleOutput (implemented in parallel by BT-W2-03). Tests are parsing/validation only."),
    extraTests=["BleRequestCommandTests.testReadParsesSettingAndAll", "BleRequestCommandTests.testCmdRefusesWithoutConfirm",
                "BleRequestCommandTests.testCmdSubcommandsParse", "BleRequestCommandTests.testTempRejectsNonFinite"],
    tests=[],
    acceptance=std_cli("BT-W2-05", "BleRequestCommandTests"))

pkg(id="BT-W2-06", title="angcli: ble listen (raw + decoded, SIGINT teardown)",
    wave=2, kind="implement", size="M", dependsOn=["BT-W1-12"],
    modify=[C_LISTEN, CT_LISTEN],
    specRefs=["§10.1", "§10.3", "§9.6 (H2, H12–H14, H18, H20)", "PLAN §3.2"],
    upstreamRefs=[BT + ":327-465"],
    deliverables=["BleListen: registers rawFrames/connectionEvents/shotCounterEvents BEFORE startShotCounter, prints until SIGINT, then stopShotCounter + disconnect and exits 0."],
    task=(
        "Implement cli/Sources/angcli/Ble/BleListen.swift (SPEC §10.1, §10.3). It takes @OptionGroup BleTargetOptions and `--raw` / `--decoded` (reuse OutputMode from AngCLI.swift; both are shown by default). "
        "Register client.rawFrames(), connectionEvents() and shotCounterEvents() BEFORE startShotCounter(), so the auth and subscribe frames are captured. Print through BleOutput (rawLine / connectionLine / shotCounterLine). "
        "Install SignalHandler(SIGINT) → stopShotCounter() + disconnect(), mirroring Listen.swift:34-38, and exit 0. If startShotCounter returns false, print `Shot counter not supported by this machine` to stderr and exit non-zero. "
        "Use only the PLAN §3.2 signatures (BT-W2-03 implements them in parallel). Tests are parsing only."),
    extraTests=["BleListenTests.testListenDefaultsToBoth", "BleListenTests.testListenRawOnly", "BleListenTests.testListenAcceptsTargetOptions"],
    tests=[],
    acceptance=std_cli("BT-W2-06", "BleListenTests"))

pkg(id="BT-W2-07", title="Process docs: CLAUDE.md, UPSTREAM.md (divergence register), workflows",
    wave=2, kind="docs", size="M", dependsOn=["BT-W0-01"],
    modify=[D_CLAUDE, D_UPSTREAM, D_DRIFT, D_DOCSYML],
    specRefs=["§11", "§12", "§13", "§14"],
    upstreamRefs=[README + ":229-269"],
    deliverables=["CLAUDE.md Bluetooth architecture/conventions/status; UPSTREAM.md 'Bluetooth port (v2.0.0)' section with D1–D22 and the UNVERIFIED list; workflow edits."],
    task=(
        "Apply the SPEC §11 rows for CLAUDE.md, UPSTREAM.md, .github/workflows/upstream-drift.yml and .github/workflows/docs.yml, writing from the frozen SPEC (the code is being built in parallel). "
        "CLAUDE.md: replace the out-of-scope sentence at :12 with the §11 text; add Sources/Angstrom/Bluetooth/, Sources/AngstromBluetooth/, AngstromTestSupport, the new AngstromUI files and `angcli ble` to the Architecture section; add the three conventions; add a v2.0.0 Status paragraph; remove 'Bluetooth remains out of scope'. "
        "UPSTREAM.md: keep the markers `<!-- upstream-version: v2.5.6 -->` and `<!-- upstream-sha: 4c639ee -->` byte-identical; update the Scope row and :26-31 to 'cloud and Bluetooth parity'; add a 'Bluetooth port (v2.0.0)' section listing D1–D22 (with D5's six and D7's five sub-items) and their SPEC §12 rationale and the SPEC §14.2 UNVERIFIED items; append a pointer after the historical out-of-scope notes (:119-163) without rewriting them; extend the e0f0249 note to say the BLE aliases live in Model(bluetoothFamily:); change the runbook triage line (:253-255) and the review-surface diff to include clients/_bluetooth.py, models/_bluetooth.py and the BT paths in devices/. "
        "upstream-drift.yml: line 97 → 'port cloud and Bluetooth changes'; fix the :60 comment. "
        "docs.yml: add `--target AngstromBluetooth` next to the existing --target flags. "
        "Do not touch ci.yml."),
    extraTests=["(docs: verified by the acceptance greps and by BT-W4-06)"],
    tests=[],
    acceptance=["bash -c 'grep -q \"<!-- upstream-version: v2.5.6 -->\" UPSTREAM.md && grep -q \"<!-- upstream-sha: 4c639ee -->\" UPSTREAM.md'",
                "bash -c 'for i in $(seq 1 22); do grep -qE \"D$i([^0-9]|$)\" UPSTREAM.md || { echo \"missing D$i\"; exit 1; }; done'",
                "bash -c '! grep -n \"Bluetooth is explicitly out of scope\" CLAUDE.md && ! grep -n \"Bluetooth remains out of scope\" CLAUDE.md'",
                "bash -c 'grep -q -- \"--target AngstromBluetooth\" .github/workflows/docs.yml'",
                "bash -c '! grep -n \"skip Bluetooth-only\" .github/workflows/upstream-drift.yml'",
                "bash -c 'git diff --quiet e1bc403 -- .github/workflows/ci.yml'"])

pkg(id="BT-W2-08", title="User docs: README, DocC catalogs and Bluetooth article, angcli docs",
    wave=2, kind="docs", size="L", dependsOn=["BT-W0-02", "BT-W1-12"],
    create=[D_BTART],
    modify=[D_README, D_ANG, D_GS, D_UIDOCC, D_CLISPEC, D_CLIREADME],
    specRefs=["§5.8", "§8", "§10", "§11", "§13"],
    upstreamRefs=[README + ":78-125", README + ":225-269"],
    deliverables=["README Bluetooth section; DocC topic group + Bluetooth.md article + 2.0.0 getting-started; AngstromUI catalog additions; cli/SPEC.md + cli/README.md ble sections."],
    task=(
        "Write the user-facing docs from the frozen SPEC. The code is built in parallel; every public symbol already exists as a stub, so DocC links resolve. "
        "README.md (§11): cloud AND Bluetooth at :5 and :21-24; a Bluetooth section covering the products, token sources (cloud bleAuthToken via bluetoothAuthToken(serial:), pairing-mode readToken, the QR label), the shot counter, app requirements (§8.2), the single-central caveat (README:231 upstream) and identity persistence (§8.7); install snippet `from: \"2.0.0\"`. "
        "Sources/Angstrom/Documentation.docc/Angstrom.md: drop the out-of-scope sentence at :7-11; add a `### Bluetooth` topic group with the §11 symbols. New Bluetooth.md article: tokens, discovery and identity, lifecycle (lazy connect, 30 s idle, shot counter), errors and fallback, platform requirements, and the §5.8 recipe. GettingStarted.md: version 2.0.0 plus a link to the article. Sources/AngstromUI/Documentation.docc/AngstromUI.md: BLE-first commands, refreshDashboardFromBluetooth, the shot counter, bluetoothEvents(), isBluetoothConnected. "
        "cli/SPEC.md and cli/README.md: a `ble` section (the §10.1 tree, §10.2 selection, TCC notes from §8.4, the §10.4 redaction rules, and that `ble cmd` needs --confirm). "
        "Never show a real token in examples; use `**REDACTED**`."),
    extraTests=["(docs: verified by the docs build and by BT-W4-06)"],
    tests=[],
    acceptance=["swift package --allow-writing-to-directory .build/bt-docs generate-documentation --target Angstrom --target AngstromUI --target AngstromBluetooth --enable-experimental-combined-documentation --disable-indexing --output-path .build/bt-docs",
                "bash -c 'grep -q \"from: \\\"2.0.0\\\"\" README.md'",
                "bash -c '! grep -n \"Bluetooth is out of scope\" Sources/Angstrom/Documentation.docc/Angstrom.md'",
                "bash -c 'grep -q \"ble\" cli/README.md && grep -q \"ble\" cli/SPEC.md'"])

# ---- Wave 2 verify packages (review Wave 1)
pkg(id="BT-W2-09", title="Verify: wire-level parity of constants, codec, decoders, coercion, enums, token, discovery",
    wave=2, kind="verify", size="M", dependsOn=["BT-W1-01", "BT-W1-02", "BT-W1-03", "BT-W1-06", "BT-W1-10"],
    specRefs=["§2.2", "§2.3", "§3", "§4.14", "§4.21", "§6.1–§6.8", "§6.13", "§9.3.1", "§9.3.2", "§9.3.5"],
    upstreamRefs=[BT + ":40-64", BT + ":522-626", BT + ":655-710", MBT + ":22-87", CONST + ":11-31", CONST + ":141-339",
                  MACH + ":58-84", GEN + ":128-136", EXC + ":20-47", TBC + ":40-59", TBC + ":295-430", TBC + ":1223-1250", TBC + ":1326-1342", TMO + ":391-418"],
    deliverables=["§5.2 JSON report: per-constant and per-vector diff, coercion table walk-through, findings with fix owners."],
    task=(
        "Adversarially diff the Swift wire layer against upstream, line by line. Files: BluetoothConstants, BluetoothTransport (error descriptions), BluetoothAuthToken, BluetoothEnums, BluetoothModels, BluetoothWireCoercion, BluetoothShotCounterModels (merge), BluetoothDiagnostics markers, BluetoothCodec, BluetoothResponseDecoder, LaMarzoccoCloudClient+BluetoothToken, LaMarzoccoBluetoothClient+Discovery, and the §6.4 error texts in Models.swift. "
        "For EVERY UUID, JSON key, raw value, enum mapping, error message and timing constant, quote the $UPSTREAM line and the Swift line side by side. Re-derive every BT-REQ/BT-READ-REQ/BT-AUTH/BT-RSP vector by hand from upstream and compare it with the bytes the Swift tests assert. Walk every row of the SPEC §3.10 coercion table against the implementation, and confirm that D5 (a–f), D6, D8, D9 and D21 are the ONLY departures from Python semantics; spot-check BT-COERCE rows against upstream with the X3 command (PLAN §6.1) if `uv` is available. Check the ensure_ascii escaping (lowercase hex, U+007F escaped, surrogates), the integral-double rule, and that the int rule cannot trap. "
        "Write throwaway probes in your temp dir if useful (for example a tiny swift test via `swift test --filter`), but never commit."),
    extraTests=[], tests=[],
    acceptance=[BUILD, filt("BluetoothEnumsTests", "BluetoothWireCoercionTests", "BluetoothModelsTests", "BluetoothCodecTests",
                            "BluetoothResponseDecoderTests", "BluetoothTokenTests", "BluetoothDiscoveryTests"),
                "bash -c 'for u in 0a0b 0b0b 0c0b 0d0b 0e0b; do grep -q \"${u}7847-e12b-09a8-b04b-8e0922a9abab\" Sources/Angstrom/Bluetooth/BluetoothConstants.swift || { echo \"missing $u\"; exit 1; }; done'"])

pkg(id="BT-W2-10", title="Verify: state machine, dashboard transforms and the UI funnel against upstream",
    wave=2, kind="verify", size="M", dependsOn=["BT-W1-04", "BT-W1-05", "BT-W1-11"],
    specRefs=["§3.8", "§4.11", "§4.15–§4.20", "§6.9", "§6.12", "§6.16", "§9.3.3", "§9.3.6", "§9.3.8", "§12 D12 D17 D18"],
    upstreamRefs=[MBT + ":68-213", BT + ":77-111", BT + ":441-465", MACH + ":58-88", MACH + ":287-323", MACH + ":350-509",
                  MACH + ":764-892", MACH + ":983-1049", THING + ":27-38", THING + ":73-126", TBD + ":560-689"],
    deliverables=["§5.2 JSON report including a rule-by-rule equivalence table for derive_state/_BrewingTracker and the overlay-equivalence argument for D12."],
    task=(
        "Review BrewingStateMachine.swift, Dashboard+Bluetooth.swift and Sources/AngstromUI/LaMarzoccoMachine.swift (BT-W1-11's funnel and routing) against upstream. "
        "(1) Map every branch of MBT derive_state and _BrewingTracker.process to the Swift code, including the reset points and the earliest-start rule; produce the table. "
        "(2) Check every cell of the §4.17 widget-synthesis table and the §4.19 overlay table against _machine.py:287-323 and :350-492. Argue (or refute) that the base + overlay model reproduces upstream's object-identity bookkeeping for vectors D1–D14 of SPEC §9.3.8. "
        "(3) Confirm that every `dashboard` write in LaMarzoccoMachine.swift goes through the funnel (exactly one assignment, in renderDashboard), that snapshot persists baseDashboard, that the six methods use exactly the §4.16 BLE/cloud calls with gating BEFORE any transport, and that every other method throws .cloudOnlyFunctionality without a cloud client (THING:27-38)."),
    extraTests=[], tests=[],
    acceptance=[BUILD, filt("BrewingStateMachineTests", "ShotCounterNotificationDecoderTests", "DashboardBluetoothTests",
                            "MachineTransportRoutingTests", "LaMarzoccoMachineTests"),
                "bash -c 'n=$(grep -cE \"(^|[^A-Za-z_])(self\\.)?dashboard = \" Sources/AngstromUI/LaMarzoccoMachine.swift); test \"$n\" -eq 1'"])

pkg(id="BT-W2-11", title="Verify: CoreBluetooth adapter and op table — Swift 6 concurrency and SPEC §5.4 conformance",
    wave=2, kind="verify", size="M", dependsOn=["BT-W1-07", "BT-W1-08"],
    specRefs=["§5.1", "§5.3", "§5.4", "§5.5", "§6.2", "§6.14", "§8.1", "§8.6", "PLAN §3.1"],
    upstreamRefs=["(Apple-specific; reference = SPEC §5.4 and, if provided, $RESEARCH/06-corebluetooth.md §3 and Appendix B)"],
    deliverables=["§5.2 JSON report: a §5.4 bullet-by-bullet conformance table plus a data-race analysis of every mutable adapter field."],
    task=(
        "Review Sources/AngstromBluetooth/* and Sources/Angstrom/Bluetooth/BluetoothOpTable.swift as a Swift 6 concurrency expert. "
        "Check each SPEC §5.4 bullet and report pass/fail with the code line. "
        "For every mutable stored property in the adapter, show that it is touched only on the private queue (or is immutable/Sendable). Show that no CBPeripheral/CBCharacteristic/CBCentralManager value escapes to another isolation domain. Show that every continuation is resumed exactly once across the reply/timeout/cancellation/disconnect/state-drop paths (trace through BluetoothOpTable). Check that owed replies cannot resolve a newer op, that notifications are routed before the CCCD ack, and that a late didConnect after a timeout is cancelled. "
        "Check that there is no `@preconcurrency import CoreBluetooth`, no `Mutex`, no `Task.immediate`, no custom executor, no Task hop inside delegate callbacks, and no API newer than macOS 14/iOS 17. Build for macOS and iOS."),
    extraTests=[], tests=[],
    acceptance=[BUILD, filt("BluetoothOpTableTests"),
                "xcodebuild -scheme Angstrom-Package -destination 'generic/platform=iOS Simulator' -quiet build",
                "bash -c '! grep -rnE \"^@preconcurrency import|Mutex<|Task\\.immediate|EnableAutoReconnect\" Sources/AngstromBluetooth Sources/Angstrom/Bluetooth | grep -vE \"^[^:]+:[0-9]+:[[:space:]]*(//|///|\\*)\"'"])

pkg(id="BT-W2-12", title="Verify: client core lifecycle (gates, connect, auth, idle, teardown, events) against upstream",
    wave=2, kind="verify", size="M", dependsOn=["BT-W1-09"],
    specRefs=["§3.4", "§4.1–§4.8", "§4.4.1", "§5.5", "§5.7", "§6.11", "§8.1", "§12 D1 D7 D10 D11 D16 D19"],
    upstreamRefs=[BT + ":114-325", BT + ":467-486", BT + ":628-653"],
    deliverables=["§5.2 JSON report: an invariant check (I1–I6), an error-mapping cell-by-cell table, and a re-entrancy analysis of every await in the main file."],
    task=(
        "Review Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient.swift against _bluetooth.py:114-325, :467-486 and :628-653 and SPEC §4.1–§4.8. "
        "Verify invariants I1–I6, with evidence for each. For every `await` in the actor, state what other actor work can interleave and why the gates keep request atomicity (TBC:1253-1284) and the lock order request → connection. "
        "Check every cell of the §4.4.1 mapping table and every verbatim error text. Check the cleanup-on-error path including CancellationError (TBC:1197-1220), the edge-triggered events, that the idle timer never cancels itself (83289c6), that D16 cancels it on loss, and that the auth-poll timing and the authenticationFailed update rule match _bluetooth.py:636-653 exactly. Run the core tests under the Thread Sanitizer."),
    extraTests=[], tests=[],
    acceptance=[BUILD, filt("BluetoothClientCoreTests"), "swift test --sanitize=thread --filter 'BluetoothClientCoreTests'"])

# ================================================================= WAVE 3 (parallel)
pkg(id="BT-W3-01", title="Parity suite: connection lifecycle and authentication",
    wave=3, kind="implement", size="L", dependsOn=["BT-W1-09", "BT-W2-01", "BT-W2-02", "BT-W0-03"],
    modify=[T_CONN, T_AUTH],
    specRefs=["§3.4", "§4.2–§4.8", "§4.4.1", "§9.2", "§9.4 (T1 rows)", "§12 D7 D11 D16 D19", "PLAN §3.5"],
    upstreamRefs=[TBC + ":157-292", TBC + ":434-649", TBC + ":1197-1220", TBC + ":1253-1284", TBC + ":1305-1323", TBC + ":1345-1435", BT + ":114-325", BT + ":628-653"],
    deliverables=["BluetoothConnectionTests and BluetoothAuthTests porting every assigned upstream test plus the assigned gap/divergence tests."],
    task=(
        "Port the upstream connection and auth tests assigned below into Tests/AngstromTests/Bluetooth/BluetoothConnectionTests.swift and BluetoothAuthTests.swift, against the real LaMarzoccoBluetoothClient over the AngstromTestSupport fakes. Read each upstream test in full first, and assert the same observable behaviour (op sequences via FakeBluetoothLink.recordedOps, connectCount, events, flags, sleeper durations). "
        "Restated tests follow the SPEC §9.4 wording: C12 = exactly one pending idle sleep after each command, and firing it disconnects; C51 = connect(to: peripheral) uses the stored id on every reconnect; C55 = a cancelled event-stream iteration stops delivery to that consumer only. "
        "Also write the Angstrom-only tests listed below. You own test files only. If behaviour deviates from SPEC, apply the BLOCKED-BY protocol (PLAN §1.6) against the fix owner (BT-W1-09 main, BT-W2-01 requests, BT-W2-02 shot counter, BT-W0-03 fakes)."),
    extraTests=[
        "BluetoothAuthTests.testTransportErrorDuringAuthIsConnectionFailed (Angstrom-only: G-AUTH-1)",
        "BluetoothAuthTests.testAuthPollIntervalIs50ms (Angstrom-only: G-AUTH-2)",
        "BluetoothAuthTests.testAuthenticationFailedUnchangedByPreAuthFailure (Angstrom-only: G-AUTH-3)",
        "BluetoothConnectionTests.testRediscoveredCharacteristicServesRequest (Angstrom-only: G-CONN-2, D7b)",
        "BluetoothConnectionTests.testIdleTimerArmedAfterAuthAndReusedLink (Angstrom-only: G-CONN-4)",
        "BluetoothConnectionTests.testFailedRequestDropsWhenShotCounterEnabledButUnlinked (Angstrom-only: G-CONN-5)",
        "BluetoothConnectionTests.testLinkLossCancelsIdleTask (Angstrom-only: G-CONN-7, D16)",
        "BluetoothConnectionTests.testLinkDropBetweenWriteAndReadFailsRequest (Angstrom-only: G-CONN-8, D7a)",
        "BluetoothConnectionTests.testServicesInvalidatedForcesRediscovery (Angstrom-only: D7c)",
        "BluetoothConnectionTests.testCancellationInsideRequestDrops (Angstrom-only: D7d)",
        "BluetoothConnectionTests.testRequestInDisconnectWindowFailsThenReconnects (Angstrom-only: D7e; the link's ops throw .disconnected(code: 7) before any event is yielded → .bluetoothConnectionFailed, one drop, the next request reconnects)",
        "BluetoothConnectionTests.testIsConnectedOnlyAfterAuth (Angstrom-only: D11)",
        "BluetoothConnectionTests.testOperationTimeoutsMapPerPhase (Angstrom-only: D19; also assert every FakeBluetoothLink.requestedTimeouts entry equals timing.operationTimeout)",
    ],
    tests=[],
    acceptance=[BUILD, filt("BluetoothConnectionTests", "BluetoothAuthTests"), TEST, WARN,
                "swift test --sanitize=thread --filter 'BluetoothConnectionTests|BluetoothAuthTests'"])

pkg(id="BT-W3-02", title="Parity suite: reads, commands, framing and the raw diagnostics tap",
    wave=3, kind="implement", size="M", dependsOn=["BT-W2-01", "BT-W2-02", "BT-W0-03"],
    modify=[T_REQ, T_DIAGT],
    specRefs=["§3.5–§3.7", "§3.10", "§4.4", "§5.7", "§6.10", "§9.3.1", "§9.3.2", "§9.4 (T2 rows)", "PLAN §3.5"],
    upstreamRefs=[TBC + ":40-59", TBC + ":295-430", TBC + ":1223-1250", BT + ":555-626", BT + ":655-710"],
    deliverables=["BluetoothRequestTests (C01–C08, C42–C46 + gap tests) and BluetoothDiagnosticsTests."],
    task=(
        "Port the upstream request tests assigned below into BluetoothRequestTests.swift. Assert the exact bytes written (FakeBluetoothLink.recordedOps), the characteristic used, and the decoded values (SPEC §9.3.1/§9.3.2 vectors). Also write the gap tests: G-CODEC-5 (malformed reads throw .decoding and do NOT drop the link); the derived frames BT-REQ-002/005/006 at client level; a non-finite temperature rejected with no write; a non-success status returned not thrown; the smartStandBy \"enabled\":\"false\" → false (D5). "
        "BluetoothDiagnosticsTests covers rawFrames(): the auth write has isSecret == true and every other frame false; write/read frames are verbatim and directional; a shot-counter notification is tapped BEFORE the replay drop ([replay dropped] marker follows); the lifecycle markers appear in order; no frames are buffered for a listener that subscribes later; two listeners both receive frames; rawRead returns bytes before NUL truncation. "
        "You own test files only; use BLOCKED-BY against BT-W2-01/BT-W1-09/BT-W1-02/BT-W1-03 for defects."),
    extraTests=[
        "BluetoothRequestTests.testMalformedReadsThrowDecodingAndKeepLink (Angstrom-only: G-CODEC-5)",
        "BluetoothRequestTests.testDerivedCommandFramesAtClientLevel (BT-REQ-002/005/006)",
        "BluetoothRequestTests.testNonFiniteTemperatureWritesNothing",
        "BluetoothRequestTests.testNonSuccessStatusReturned",
        "BluetoothRequestTests.testSmartStandbyStringFalse (Angstrom-only: D5)",
        "BluetoothDiagnosticsTests.testAuthWriteIsSecretOthersNot", "BluetoothDiagnosticsTests.testFramesVerbatimAndDirectional",
        "BluetoothDiagnosticsTests.testNotificationTappedBeforeReplayDrop", "BluetoothDiagnosticsTests.testLifecycleMarkerOrder",
        "BluetoothDiagnosticsTests.testNoBufferingWithoutListeners", "BluetoothDiagnosticsTests.testTwoListenersBothReceive",
        "BluetoothDiagnosticsTests.testRawReadBeforeNulTruncation",
    ],
    tests=[],
    acceptance=[BUILD, filt("BluetoothRequestTests", "BluetoothDiagnosticsTests"), TEST, WARN])

pkg(id="BT-W3-03", title="Parity suite: shot-counter lifecycle (start, stop, subscribe, rediscovery)",
    wave=3, kind="implement", size="M", dependsOn=["BT-W2-01", "BT-W2-02", "BT-W0-03"],
    modify=[T_SCLIFE],
    specRefs=["§4.4", "§4.5", "§4.9", "§9.4 (T3 lifecycle rows)", "§12 D4", "PLAN §3.5"],
    upstreamRefs=[TBC + ":652-742", TBC + ":1108-1195", TBC + ":1287-1302", BT + ":327-439", BT + ":712-747"],
    deliverables=["ShotCounterLifecycleTests porting the assigned upstream tests + gap tests."],
    task=(
        "Port the shot-counter lifecycle tests assigned below into ShotCounterLifecycleTests.swift. "
        "Restated tests follow SPEC §9.4: C36 = one subscribe, no second .subscribed, returns true; C37/C38 = a consumer of shotCounterEvents() that calls stopShotCounter() (case 1) or disconnect() (case 2) on .unsubscribed causes exactly one unsubscribe, and the events are [.subscribed, .unsubscribed]. C20 asserts connects with refresh [false, true], one extra disconnect, still connected, idle re-armed. "
        "Also write the gap tests below. You own the test file only; use BLOCKED-BY against BT-W2-02/BT-W2-01/BT-W1-09 for defects."),
    extraTests=[
        "ShotCounterLifecycleTests.testMissingCharacteristicDropsEvenWithShotCounter (Angstrom-only: G-CONN-6)",
        "ShotCounterLifecycleTests.testStopWithoutCounterOnlyRearmsIdle (Angstrom-only: G-SC-1)",
        "ShotCounterLifecycleTests.testNotificationAfterStopDropped (Angstrom-only: G-SC-4)",
        "ShotCounterLifecycleTests.testSecondStartKeepsTrackerAndReplayFlag (Angstrom-only: G-SC-5)",
        "ShotCounterLifecycleTests.testStartWhileReconnectPendingSubscribesOnce (Angstrom-only: G-SC-6)",
        "ShotCounterLifecycleTests.testStartFailureThrowsAndDisables (Angstrom-only: G-RC-4)",
    ],
    tests=[],
    acceptance=[BUILD, filt("ShotCounterLifecycleTests"), TEST, WARN])

pkg(id="BT-W3-04", title="Parity suite: shot-counter notifications and the recorded Linea Micra session",
    wave=3, kind="implement", size="L", dependsOn=["BT-W1-04", "BT-W2-02", "BT-W0-03"],
    modify=[T_SCNTF, T_SCREC],
    specRefs=["§3.8", "§4.10", "§4.11", "§4.12", "§9.3.3", "§9.3.4", "§9.4 (T3 notification rows)", "§14.2 U22", "PLAN §3.5"],
    upstreamRefs=[TBC + ":745-1020", REC, BT + ":441-465", MBT + ":90-213"],
    deliverables=["ShotCounterNotificationTests and ShotCounterRecordedSessionTests through the real client."],
    task=(
        "Port the notification tests assigned below into ShotCounterNotificationTests.swift, driving notifications through FakeBluetoothLink.notify(_:_:at:) on a started client and asserting shotCounterEvents(). Use the exact vectors of SPEC §9.3.3 (BluetoothTestVectors.started/tick). The fake link's default replayOnSubscribe is tick(\"3.34\") (upstream's fake, TBC:176), which consumes the client's replay flag, so the first notify(…) after start is processed exactly as upstream's tests expect; set `replayOnSubscribe = []` only where the upstream test sets `replay = None`. C31 is restated: a consumer that stops iterating does not affect other listeners or the client. Also add G-SC-3 and the client-level vectors BT-NTF-COERCE-001…004, LATE-001 and FRAG-001. "
        "ShotCounterRecordedSessionTests.testRecordedMorning20261005 replays REC per §9.3.4. For each session: startShotCounter() with the session's replay as replayOnSubscribe, each line delivered at its UTC timestamp, then stopShotCounter(). Assert upstream assertions 1–6 exactly, and the finer golden table with ≤ 1 ms tolerance. "
        "If the golden disagrees while assertions 1–6 hold, do NOT change expected values. Mark only the golden sub-assertion with BLOCKED-BY \"SPEC U22\" and report it for a human decision. "
        "You own test files only; use BLOCKED-BY against BT-W2-02/BT-W1-04 for defects."),
    extraTests=[
        "ShotCounterNotificationTests.testTrackerResetOnResubscribe (Angstrom-only: G-SC-3)",
        "ShotCounterNotificationTests.testEvFalseStringStopsAtClientLevel (Angstrom-only: D5, BT-NTF-COERCE-001)",
        "ShotCounterNotificationTests.testStatisticsObjectDropped (BT-NTF-COERCE-002)",
        "ShotCounterNotificationTests.testStatisticsNullIsUnset (BT-NTF-COERCE-003, BT-NTF-COERCE-004)",
        "ShotCounterNotificationTests.testLateTickReentersBrewing (Angstrom-only: BT-NTF-LATE-001, Q9)",
        "ShotCounterNotificationTests.testFragmentsAccumulate (Angstrom-only: BT-NTF-FRAG-001)",
    ],
    tests=[],
    acceptance=[BUILD, filt("ShotCounterNotificationTests", "ShotCounterRecordedSessionTests"), TEST, WARN],
    risks=["SPEC U22: the per-line golden was hand-traced. Escalate rather than edit."])

pkg(id="BT-W3-05", title="Parity suite: shot-counter reconnect loop",
    wave=3, kind="implement", size="M", dependsOn=["BT-W2-02", "BT-W0-03"],
    modify=[T_SCRC],
    specRefs=["§4.13", "§9.2", "§9.3.3 (RESET-001)", "§9.4 (T4 rows)", "§12 D14 D15", "PLAN §3.5"],
    upstreamRefs=[TBC + ":1022-1105", BT + ":475-520", README + ":269"],
    deliverables=["ShotCounterReconnectTests porting C32–C35 + reconnect gap/divergence tests with asserted backoff values."],
    task=(
        "Port the reconnect tests assigned below into ShotCounterReconnectTests.swift. Use ManualBluetoothSleeper.requested(.reconnectBackoff) to assert backoff values (closing G-RC-1). "
        "C33 is restated per SPEC §9.4: enqueue 3 × .disconnected(code: 7), then 3 × .timedOut, then success; expect connectCount == 8, events [.subscribed, .unsubscribed, .subscribed], and requested(.reconnectBackoff) == [1 s, 2 s, 4 s]. Derive the expected count yourself from SPEC §4.2 (3 attempts per ensureConnected) and §4.13. If your derivation disagrees with 8, report SPEC-DEFECT (PLAN §1.7) instead of changing the number. "
        "C34: connectCount == 4, requested(.reconnectBackoff) == [1 s, 1 s, 1 s], authenticationFailed, not active, not connected, hasBackgroundWorkForTesting == false, plus .gaveUp(.bluetoothAuthenticationFailed). C32 includes BT-NTF-RESET-001. "
        "Also write G-RC-1/2/3/5, G-SC-7, D14 and D15. You own the test file only; use BLOCKED-BY against BT-W2-02/BT-W1-09."),
    extraTests=[
        "ShotCounterReconnectTests.testBackoffSequence (Angstrom-only: G-RC-1)",
        "ShotCounterReconnectTests.testAuthFailuresAreCumulative (Angstrom-only: G-RC-2, D15)",
        "ShotCounterReconnectTests.testCharacteristicGoneGivesUp (Angstrom-only: G-RC-3)",
        "ShotCounterReconnectTests.testIdleOrErrorDropWhileEnabledReconnects (Angstrom-only: G-RC-5)",
        "ShotCounterReconnectTests.testFirstAttemptWaitsInitialDelay (Angstrom-only: G-SC-7)",
        "ShotCounterReconnectTests.testPoweredOnCutsBackoffShort (Angstrom-only: D14; no polling: after `await sleeper.waitForPending(.reconnectBackoff, count: 1)` the §4.13 availability stream exists — assert central.availabilitySubscriberCount >= 1, then setAvailability)",
        "ShotCounterReconnectTests.testGaveUpCarriesLastError (Angstrom-only: D15)",
    ],
    tests=[],
    acceptance=[BUILD, filt("ShotCounterReconnectTests"), TEST, WARN,
                "swift test --sanitize=thread --filter 'ShotCounterReconnectTests'"],
    risks=["The C33 connect count was flagged for a second look in the SPEC author's report."])

pkg(id="BT-W3-06", title="AngstromUI: Bluetooth connection observation and device-state properties",
    wave=3, kind="implement", size="S", dependsOn=["BT-W1-11", "BT-W2-01", "BT-W0-04"],
    modify=[P_UI_CONN, U_DEVSTATE],
    specRefs=["§2.5", "§4.15", "§6.16 (+BluetoothConnection)", "§12 D11", "PLAN §3.3"],
    upstreamRefs=[THING + ":99-126", TT + ":36-64", TM + ":765-781"],
    deliverables=["startObservingBluetoothConnection(), bluetoothConnectionEvents(), isBluetoothConnected behaviour."],
    task=(
        "Implement Sources/AngstromUI/LaMarzoccoMachine+BluetoothConnection.swift. startObservingBluetoothConnection() (called from init when bluetooth != nil) starts bluetoothConnectionTask: a MainActor Task with [weak self] that iterates `await bluetooth.connectionEvents()` and sets isBluetoothConnected (true on .connected, false on .disconnected). bluetoothConnectionEvents() returns the client's stream, or an already-finished stream without a client (upstream returns a no-op unregister, _thing.py:116-126). "
        "Tests use BluetoothMachineHarness. Trigger a connection with a client read (e.g. `try await harness.bluetooth!.machineMode()`), never through UI commands (BT-W3-07 builds those in parallel). Port T01/T02/M15 and add G-DEV-9."),
    extraTests=["BluetoothDeviceStateTests.testIsBluetoothConnectedFollowsRealClient (Angstrom-only: G-DEV-9, D11)",
                "BluetoothDeviceStateTests.testObservationStopsWhenMachineDeallocates"],
    tests=[],
    acceptance=[BUILD, filt("BluetoothDeviceStateTests"), TEST, WARN])

pkg(id="BT-W3-07", title="AngstromUI: BLE-first commands with cloud fallback and their side effects",
    wave=3, kind="implement", size="L", dependsOn=["BT-W1-11", "BT-W2-01", "BT-W0-04"],
    modify=[P_UI_CMD, U_FALLBACK, U_SIDE],
    specRefs=["§1.4", "§4.16", "§4.20", "§6.16 (+BluetoothCommands)", "§9.3.6 (SNAP-003…005)", "§9.3.7", "§12 D10 D18", "PLAN §3.3"],
    upstreamRefs=[MACH + ":494-509", MACH + ":764-892", MACH + ":983-1049", TM + ":134-237", TM + ":486-497", TM + ":1089-1160", TBD + ":396-560", SNAP + ":110-145", CONF + ":183-195"],
    deliverables=["bluetoothFirst(bluetooth:cloud:) per §4.16, BluetoothFallbackTests, BluetoothCommandSideEffectTests."],
    task=(
        "Implement the Bluetooth branch of bluetoothFirst(bluetooth:cloud:) in Sources/AngstromUI/LaMarzoccoMachine+BluetoothCommands.swift, exactly per the SPEC §4.16 pseudocode. "
        "When a BLE client exists, ALWAYS try it first (no isBluetoothConnected check). On isSuccess, return CommandResponse(id: status.id, status: .success, errorCode: nil). On a non-success status, fall through to the cloud, or without a cloud client throw .commandFailed(status: status.status, errorCode: status.message) (D18). Catch only errors whose isBluetoothConnectionFailure is true: rethrow when there is no cloud client, else log the upstream message and fall back. Every other error (.bluetoothTimedOut, .decoding, CancellationError) propagates with NO cloud call. With neither client, throw .cloudOnlyFunctionality. "
        "The six call sites and their gating/optimistic updates already exist (BT-W1-11). Do not edit LaMarzoccoMachine.swift; if a call site is wrong, BLOCKED-BY BT-W1-11. "
        "Tests use BluetoothMachineHarness with its failure modes: assert the BLE frames (BT-FALLBACK-001…006 bytes via bluetoothWrites(to:)), the cloud command names/bodies (cloudCommandCount/cloudCommandBody), and the optimistic widget values (SNAP-003…005). M01–M12 is one parametrised test over six commands × {BLE ok → no cloud call; BLE .bluetoothConnectionFailed → exactly one cloud call}."),
    extraTests=[
        "BluetoothFallbackTests.testNonSuccessStatusFallsBackToCloud (Angstrom-only: G-DEV-1)",
        "BluetoothFallbackTests.testTimeoutAndDecodeErrorsDoNotFallBack (Angstrom-only: G-DEV-2, D19)",
        "BluetoothFallbackTests.testAutoStandbyMinuteFormatting (Angstrom-only: G-DEV-8)",
        "BluetoothFallbackTests.testUnavailableBluetoothFallsBack (Angstrom-only: D10)",
        "BluetoothFallbackTests.testNeitherClientThrowsCloudOnly (Angstrom-only: D18)",
        "BluetoothFallbackTests.testGatingRunsBeforeAnyTransport",
        "BluetoothCommandSideEffectTests.testSetSteamUpdatesBothSteamWidgets (Angstrom-only: G-DEV-11)",
    ],
    tests=[],
    acceptance=[BUILD, filt("BluetoothFallbackTests", "BluetoothCommandSideEffectTests"), TEST, WARN])

pkg(id="BT-W3-08", title="AngstromUI: dashboard and model from Bluetooth",
    wave=3, kind="implement", size="M", dependsOn=["BT-W1-05", "BT-W1-11", "BT-W2-01", "BT-W0-04"],
    modify=[P_UI_DASH, U_DASHREF],
    specRefs=["§4.17", "§4.18", "§6.16 (+BluetoothDashboard)", "§9.3.6", "§12 D17", "§14.1 Q11", "PLAN §3.3"],
    upstreamRefs=[MACH + ":325-492", TBD + ":110-390", TBD + ":560-689", TM + ":1049-1088", SNAP + ":2-108"],
    deliverables=["refreshDashboardFromBluetooth() and refreshModelFromBluetooth() + BluetoothDashboardRefreshTests."],
    task=(
        "Implement Sources/AngstromUI/LaMarzoccoMachine+BluetoothDashboard.swift per SPEC §4.17 and §4.18. "
        "refreshDashboardFromBluetooth: without a BLE client throw `.bluetoothConnectionFailed(\"Bluetooth client not initialized\")`; if model is nil or .unknown, run refreshModelFromBluetooth() first (D17), otherwise read no capabilities; read machineMode, isPlumbedIn (.decoding → false; other errors propagate), tankStatus, boilers, in that order; any error propagates with NO mutation; then setBaseDashboard((baseDashboard ?? Dashboard(machine: Machine(serialNumber:model:), widgets: [])).applyingBluetoothState(state, model:)). Do not stamp lastUpdateAt (Q11); do not touch settings/schedule/connected. Return the rendered dashboard. "
        "refreshModelFromBluetooth: read machineCapabilities and set only machine.model on the base (rebuild Dashboard(machine:widgets:)); errors propagate; return the capabilities. "
        "Tests use BluetoothMachineHarness with settingResponses scripted with the exact upstream payloads. To cover the interaction with an active shot-counter overlay without depending on BT-W3-09 (built in parallel), set `machine.bluetoothBrewingUpdate` directly and call `machine.renderDashboard()`, then refresh and assert the overlay is re-applied over the new base."),
    extraTests=[
        "BluetoothDashboardRefreshTests.testUnknownModelReadsCapabilitiesFirst (Angstrom-only: D17)",
        "BluetoothDashboardRefreshTests.testKnownModelSkipsCapabilities",
        "BluetoothDashboardRefreshTests.testReadOrder",
        "BluetoothDashboardRefreshTests.testDoesNotStampLastUpdateAt (Angstrom-only: Q11)",
        "BluetoothDashboardRefreshTests.testRefreshReappliesActiveOverlay",
    ],
    tests=[],
    acceptance=[BUILD, filt("BluetoothDashboardRefreshTests"), TEST, WARN])

pkg(id="BT-W3-09", title="AngstromUI: shot counter, overlay, telemetry merge and 60 s expiry",
    wave=3, kind="implement", size="L", dependsOn=["BT-W1-05", "BT-W1-11", "BT-W2-02", "BT-W0-04"],
    modify=[P_UI_SC, U_OVERLAY],
    specRefs=["§4.19", "§5.6", "§6.16 (+ShotCounter)", "§9.3.8", "§12 D4 D12 D13 D15", "PLAN §3.3"],
    upstreamRefs=[MACH + ":88", MACH + ":128-323", TM + ":99-131", TM + ":745-1047", TBC + ":1156-1180"],
    deliverables=["startShotCounter/stopShotCounter/bluetoothEvents/handleShotCounterEvent/clearBluetoothBrewingState/armBluetoothBrewingExpiry + ShotCounterOverlayTests."],
    task=(
        "Implement Sources/AngstromUI/LaMarzoccoMachine+ShotCounter.swift per SPEC §4.19. "
        "startShotCounter: false without a BLE client; subscribe to bluetooth.shotCounterEvents() BEFORE starting; consume it in a MainActor Task ([weak self]) calling handleShotCounterEvent; on a throw or false, cancel the listener and rethrow or return false; on true set isShotCounterActive. Do not gate on shotCounterSupported or the model. "
        "stopShotCounter: cancel the listener FIRST, await bluetooth?.stopShotCounter(), reset telemetry, clearBluetoothBrewingState(notify: false), isShotCounterActive = false; keep lastShotTime. "
        "handleShotCounterEvent follows the §4.19 event table exactly. Mutate state BEFORE emitting on bluetoothEvents() (G-DEV-12). Re-arm the expiry on EVERY brewing update and never on telemetry. Telemetry mode → updateBaseDashboard { $0.settingMachineMode(m).settingMachineState(MachineState(bluetoothMode: m)) }. .gaveUp → isShotCounterActive = false, lastError, .shotCounterStopped. "
        "Expiry: a MainActor task sleeping bluetoothBrewingStateTimeout through brewingExpirySleep, then clearBluetoothBrewingState(notify: true). bluetoothEvents() is a multiplexed stream. "
        "Tests drive the expiry with setBluetoothBrewingExpiryForTesting and a gate-controlled sleep, and drive cloud pushes through the existing MockWebSocket. Use the BT-OVL-001 and D7–D13 vectors of §9.3.8 verbatim. Simulate the BLE refresh in M20/M21 with `machine.updateBaseDashboard { $0.applyingBluetoothState(state, model: …) }` (exactly §4.17 step 6), because refreshDashboardFromBluetooth is built in parallel by BT-W3-08. C39 is restated: a bluetoothEvents() consumer calling stopShotCounter() does not recurse or deadlock."),
    extraTests=[
        "ShotCounterOverlayTests.testRestRefreshReappliesOverlay (Angstrom-only: G-DEV-5)",
        "ShotCounterOverlayTests.testResubscribeKeepsOverlayUntilExpiry (Angstrom-only: G-DEV-6)",
        "ShotCounterOverlayTests.testTelemetryModeUpdatesGroupWidget (Angstrom-only: G-DEV-7)",
        "ShotCounterOverlayTests.testStateMutatedBeforeEventEmitted (Angstrom-only: G-DEV-12)",
        "ShotCounterOverlayTests.testGaveUpSurfacesShotCounterStopped (Angstrom-only: D15)",
        "ShotCounterOverlayTests.testSnapshotNeverPersistsOverlay (Angstrom-only: D12)",
        "ShotCounterOverlayTests.testWidgetlessPushDuringOverlayDoesNotLeakIntoBase (Angstrom-only: SPEC §4.19 read rule; active .brewing overlay, a widget-less push, then expiry → rendered and snapshot status equal the pre-shot base status)",
        "ShotCounterOverlayTests.testLastShotTimeNeverReset",
    ],
    tests=[],
    acceptance=[BUILD, filt("ShotCounterOverlayTests"), TEST, WARN,
                "swift test --sanitize=thread --filter 'ShotCounterOverlayTests'"])

pkg(id="BT-W3-10", title="Verify: angcli ble commands, redaction and TCC packaging",
    wave=3, kind="verify", size="S", dependsOn=["BT-W1-12", "BT-W2-03", "BT-W2-04", "BT-W2-05", "BT-W2-06"],
    specRefs=["§8.4", "§10", "PLAN §3.2"],
    upstreamRefs=[CLOUD + ":84-92"],
    deliverables=["§5.2 JSON report: §10 conformance table (every subcommand, option, output field, error text) and a redaction audit."],
    task=(
        "Review every file under cli/ changed by BT-W1-12 and BT-W2-03…06 against SPEC §8.4 and §10 and PLAN §3.2. "
        "Check: the command tree and options; peripheral and token selection precedence; that `ble cmd` refuses without --confirm in validate(); the exact error texts; the JSON line shapes; that EVERY raw frame passes through Redact.bluetoothFrame, which redacts isSecret frames AND writes to 0d0b… AND reads of 0c0b… regardless of isSecret; that `ble token` masks unless --show-secret and prints secrets only to stdout; that nothing persists the token or the peripheral id; that unsafeFlags appears only in cli/Package.swift; that the Info.plist keys match §8.4; and that SIGINT teardown mirrors Listen.swift."),
    extraTests=[], tests=[],
    acceptance=[CLI_BUILD, CLI_TEST, CLI_WARN, "plutil -lint cli/Support/Info.plist", "bash -c '! grep -q unsafeFlags Package.swift'"])

# ================================================================= WAVE 4 (verify)
pkg(id="BT-W4-01", title="Verify: full LaMarzoccoBluetoothClient parity with _bluetooth.py (line by line)",
    wave=4, kind="verify", size="L", dependsOn=["BT-W1-10", "BT-W3-01", "BT-W3-02", "BT-W3-03", "BT-W3-04", "BT-W3-05"],
    specRefs=["§2.1", "§2.2", "§3", "§4.1–§4.14", "§6.11", "§12"],
    upstreamRefs=[BT + ":1-747", MBT + ":1-213", TBC + ":1-1435"],
    deliverables=["§5.2 JSON report with a function-by-function map of _bluetooth.py (every def and branch) → Swift (file:line) → test name."],
    task=(
        "Produce a complete map of $UPSTREAM/src/pylamarzocco/clients/_bluetooth.py: every function, every branch, every log-relevant decision, mapped to the Swift implementation (all four LaMarzoccoBluetoothClient*.swift files) and to the test that pins it. "
        "Every branch must be either matched, or a listed SPEC divergence (D1–D22), or a finding. Pay special attention to: the disconnect_on_exception drop rule including the shot-counter exemption; the characteristic resolution drop that ignores that exemption; the replay flag armed before subscribe; tracker reset points; the reconnect loop's sleep-first, cumulative auth counting, delay doubling only for connection errors, and give-up bookkeeping; the edge-triggered connection events; and stop/disconnect emitting .unsubscribed only when subscribed. "
        "Also confirm that every upstream test in tests/test_bluetooth_client.py has its Swift counterpart named in PLAN §7.2, asserting the same thing."),
    extraTests=[], tests=[],
    acceptance=[BUILD, filt("Bluetooth", "ShotCounter")])

pkg(id="BT-W4-02", title="Verify: device-layer parity with _machine.py/_thing.py (fallback, BLE dashboard, overlay, expiry)",
    wave=4, kind="verify", size="L", dependsOn=["BT-W3-06", "BT-W3-07", "BT-W3-08", "BT-W3-09"],
    specRefs=["§1.4", "§2.5", "§4.15–§4.20", "§6.12", "§6.16", "§9.3.6–§9.3.8", "§12 D12 D13 D15 D17 D18"],
    upstreamRefs=[MACH + ":1-1092", THING + ":1-226", TM + ":1-1195", TBD + ":1-689", TT + ":29-64"],
    deliverables=["§5.2 JSON report with a method-by-method map of the BT paths of _machine.py/_thing.py → Swift → test."],
    task=(
        "Map every Bluetooth path of $UPSTREAM/src/pylamarzocco/devices/_machine.py and _thing.py to Sources/AngstromUI (main file + the four extension files) and Dashboard+Bluetooth.swift, and to the pinning test. "
        "Verify the fallback matrix exactly (which errors fall back, which propagate, non-success status behaviour, no-cloud and no-BLE cases with D18), the gating-before-transport order, the read order and the no-mutation-on-error of refreshDashboardFromBluetooth, the model refresh writing only the model, the overlay/expiry/telemetry event table (state before events, expiry re-armed only by brewing updates), stopShotCounter's silent clear, and the base/overlay equivalence (D12) under websocket pushes (including widget-less pushes during an overlay), REST refreshes and BLE refreshes, with every base write reading baseDashboard (SPEC §4.19 read rule). "
        "Confirm that cloud-only behaviour is unchanged (§13): the existing LaMarzoccoMachineTests pass unmodified, and dashboard == baseDashboard whenever no overlay is held."),
    extraTests=[], tests=[],
    acceptance=[BUILD, filt("AngstromUITests"), "bash -c 'git diff --quiet e1bc403 -- Tests/AngstromUITests/LaMarzoccoMachineTests.swift Tests/AngstromUITests/MockTransport.swift Tests/AngstromUITests/MockWebSocket.swift'"])

pkg(id="BT-W4-03", title="Verify: Swift 6 concurrency and data races across client, UI and adapter (TSan + repeat runs)",
    wave=4, kind="verify", size="M", dependsOn=["BT-W1-08", "BT-W3-01", "BT-W3-02", "BT-W3-03", "BT-W3-04", "BT-W3-05", "BT-W3-06", "BT-W3-07", "BT-W3-08", "BT-W3-09"],
    specRefs=["§4.1 (I1–I6)", "§5.4", "§5.5", "§6.11", "§6.16", "§6.17"],
    upstreamRefs=["(Swift-specific; upstream ordering reference: " + BT + ":114-136, :233-325)"],
    deliverables=["§5.2 JSON report: isolation table per type, Task-lifetime audit, TSan output, repeat-run flakiness report; G-DEV-13 design check."],
    task=(
        "Audit concurrency across LaMarzoccoBluetoothClient (actor, two FIFO gates, unstructured background Tasks, stream continuations), LaMarzoccoMachine's Bluetooth extensions (MainActor Tasks, [weak self], cancellation on stop), the CoreBluetooth adapter (queue confinement) and the AngstromTestSupport fakes (@unchecked Sendable soundness). "
        "For each type, state its isolation and why every mutable field is safe. Find leaked Tasks, continuations that may never resume, and streams that never finish. Confirm G-DEV-13 (every client event is handled on the MainActor before widgets or the expiry are touched). "
        "Run the Bluetooth suites under the Thread Sanitizer, and run them five times to detect flakiness. Any nondeterministic failure is a major finding, with the fix owner being the test file's owner or the code's owner."),
    extraTests=[], tests=[],
    acceptance=[BUILD,
                "swift test --sanitize=thread --filter 'Bluetooth|ShotCounter|MachineTransportRouting|DashboardBluetooth'",
                "bash -c 'for i in 1 2 3 4 5; do swift test --filter \"Bluetooth|ShotCounter|MachineTransportRouting\" || exit 1; done'",
                "bash -c '! grep -rnE \"Task\\.immediate|Mutex<|^@preconcurrency import CoreBluetooth\" Sources Tests | grep -vE \"^[^:]+:[0-9]+:[[:space:]]*(//|///|\\*)\"'"])

pkg(id="BT-W4-04", title="Verify: public/package API conformance with SPEC §6 and PLAN §3; source compatibility (§13)",
    wave=4, kind="verify", size="M", dependsOn=["BT-W1-08", "BT-W2-03", "BT-W3-06", "BT-W3-07", "BT-W3-08", "BT-W3-09"],
    specRefs=["§6 (all)", "§13", "PLAN §3"],
    upstreamRefs=["(API shape only; no upstream counterpart)"],
    deliverables=["§5.2 JSON report: a table of every SPEC §6 / PLAN §3 declaration → present/mismatch (with the symbol-graph or source line), extra non-private declarations, and a §13 compatibility diff against e1bc403."],
    task=(
        "Mechanically compare the code with every declaration in SPEC §6 and PLAN §3.1–§3.3: name, argument labels, types, access level, async/throws, protocol conformances (Sendable, Hashable, Codable or deliberately NOT Codable for BluetoothAuthToken), and the default argument values. "
        "Use `swift package dump-symbol-graph --minimum-access-level internal` and/or direct source reading. Flag any added declaration that is not private/fileprivate and not in the SPEC. "
        "Compare the public API of Angstrom and AngstromUI with main @ e1bc403 (check out e1bc403 into a temporary worktree outside the repo). The ONLY breaking change allowed is the five new LaMarzoccoError cases (§13); every existing public signature must be unchanged."),
    extraTests=[], tests=[],
    acceptance=[BUILD, "swift package dump-symbol-graph --minimum-access-level internal"])

pkg(id="BT-W4-05", title="Verify: secrecy of the BLE token (library, logs, errors, snapshots, CLI)",
    wave=4, kind="verify", size="S", dependsOn=["BT-W1-06", "BT-W3-02", "BT-W3-10"],
    specRefs=["§2.6", "§3.3", "§5.7", "§6.3", "§8.7", "§10.4", "§12 D2"],
    upstreamRefs=[CLOUD + ":84-92", TCC + ":322"],
    deliverables=["§5.2 JSON report: every place token bytes flow (sources → sinks) with a verdict."],
    task=(
        "Trace every flow of BluetoothAuthToken.rawValue and token bytes in Sources/ and cli/Sources/: authFrame, the auth write, readToken, logHandler messages, error messages, description/debugDescription/Mirror, Codable conformances (MachineSnapshot must never contain it), the raw tap (isSecret on the auth write and the token read), and CLI output (Redact.bluetoothFrame, `ble token --show-secret`). "
        "Any interpolation of the raw value into a string that is not the auth frame or the explicit --show-secret output is a blocker. Run the token, diagnostics and CLI redaction tests."),
    extraTests=[], tests=[],
    acceptance=[BUILD, filt("BluetoothTokenTests", "BluetoothDiagnosticsTests", "BluetoothClientCoreTests"),
                cfilt("BleOutputTests"),
                "bash -c '! grep -rn \"Codable\" Sources/Angstrom/Bluetooth/BluetoothAuthToken.swift'"])

pkg(id="BT-W4-06", title="Verify: docs accuracy, divergence register and DocC build",
    wave=4, kind="verify", size="S", dependsOn=["BT-W2-07", "BT-W2-08", "BT-W1-08", "BT-W3-06", "BT-W3-07", "BT-W3-08", "BT-W3-09"],
    specRefs=["§11", "§12", "§13", "§14"],
    upstreamRefs=[README + ":78-125", README + ":225-269"],
    deliverables=["§5.2 JSON report: every doc claim checked against the code; D1–D22 present in UPSTREAM.md; DocC build log with no unresolved Bluetooth symbol links."],
    task=(
        "Check every Bluetooth statement in CLAUDE.md, README.md, UPSTREAM.md, the three DocC catalogs (including the AngstromBluetooth landing page), cli/SPEC.md and cli/README.md against the merged code and SPEC. "
        "Check that the watermark markers are unchanged, that all of D1–D22 and the UNVERIFIED list are recorded, that the version strings say 2.0.0 (library) and 2.0.0 (angcli), that code samples compile in principle against the real signatures, and that no example shows a real-looking token. Build the combined DocC archive and report any warning that mentions a Bluetooth symbol."),
    extraTests=[], tests=[],
    acceptance=["swift package --allow-writing-to-directory .build/bt-docs generate-documentation --target Angstrom --target AngstromUI --target AngstromBluetooth --enable-experimental-combined-documentation --disable-indexing --output-path .build/bt-docs",
                "bash -c 'grep -q \"<!-- upstream-version: v2.5.6 -->\" UPSTREAM.md && grep -q \"<!-- upstream-sha: 4c639ee -->\" UPSTREAM.md'"])

# ================================================================= WAVE 5 (serial)
pkg(id="BT-W5-01", title="Final integration: all gates, docs, iOS, release build, coverage and ownership audits",
    wave=5, kind="integrate", size="M", dependsOn=["BT-W4-01", "BT-W4-02", "BT-W4-03", "BT-W4-04", "BT-W4-05", "BT-W4-06"],
    specRefs=["§7", "§9.4", "§9.5", "§13", "PLAN §1.5", "PLAN §7"],
    upstreamRefs=[TBC, TBD, TM, TT, TMO, TCC],
    deliverables=["Release-candidate report (§5.2 schema, plus `gates`, `coverage` and `hardwareHandoff` arrays); no repository change."],
    task=(
        "On a fresh worktree of bluetooth/integration, run every acceptance command below and report each command with its exit status and a log excerpt. "
        "Coverage audit: every upstream test function in PLAN §7.2 has a Swift test whose doc comment starts `/// Upstream: <function> (`, and every Swift test of PLAN §7.2 exists as `func <method>(` in a file that declares `class <Class>`. Ownership audit: every path changed since e1bc403 is owned by some package in work-packages.json (or is one of the three docs/bluetooth files). Confirm that ci.yml is unchanged and that none of the SPEC §7.1 'MUST NOT change' files changed. "
        "Then prepare the hardware handoff: list H1–H28 and X1–X6 (PLAN §6) with the exact command lines for the human, and say whether an iOS app for H2/H21 exists. "
        "You change nothing; failures become findings with fix owners (Appendix A)."),
    extraTests=[], tests=[],
    acceptance=[]  # filled in by gen.py (needs coverage data)
    )
