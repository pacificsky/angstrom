// AngstromTestSupport — shared test doubles for the Bluetooth port (SPEC §6.17): fake transport
// (central, link), manual sleeper, test clock, wire vectors and the recorded shot-counter session
// (`Fixtures/shot_counter_2026-10-05.txt`, verbatim from pylamarzocco). Used by AngstromTests and
// AngstromUITests. It never imports XCTest and never touches CoreBluetooth.
import Angstrom
