import XCTest
@testable import SeismicDevice

/// The choice that decides whether the hardware works at all, tested against
/// the GATT layouts the modules people actually solder to these boards have.
final class BluetoothSerialTests: XCTestCase {

    private typealias Candidate = BluetoothSerial.Candidate

    /// A genuine HM-10: one characteristic that both notifies and accepts
    /// writes, on FFE0.
    private let hm10 = [
        Candidate(service: "1800", characteristic: "2A00", canNotify: false, canWrite: false),
        Candidate(service: "FFE0", characteristic: "FFE1", canNotify: true, canWrite: true),
    ]

    /// Nordic UART: two characteristics, and the reason the old code found
    /// nothing on these boards. It required one characteristic that could do
    /// both, and no NUS module has one.
    private let nordic = [
        Candidate(service: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E",
                  characteristic: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E",
                  canNotify: true, canWrite: false),
        Candidate(service: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E",
                  characteristic: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E",
                  canNotify: false, canWrite: true),
    ]

    func testHM10UsesFFE1ForBothDirections() {
        let selection = BluetoothSerial.choose(from: hm10)
        XCTAssertEqual(selection.notify?.characteristic, "FFE1")
        XCTAssertEqual(selection.write?.characteristic, "FFE1")
        XCTAssertTrue(selection.isFullyUsable)
    }

    /// The case the previous implementation could not handle at all.
    func testNordicUARTSplitsNotifyAndWriteAcrossTwoCharacteristics() {
        let selection = BluetoothSerial.choose(from: nordic)
        XCTAssertEqual(selection.notify?.characteristic,
                       "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        XCTAssertEqual(selection.write?.characteristic,
                       "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
        XCTAssertTrue(selection.isFullyUsable)
    }

    /// A clone that exposes FFE0 alongside a vendor service of its own. FFE1
    /// has to win, and it has to win *regardless of the order* the radio
    /// happened to report the services in — which is the whole reason the
    /// choice is made once at the end rather than on the first callback.
    func testTheKnownSerialPairWinsWhateverOrderDiscoveryArrivesIn() {
        let vendor = Candidate(service: "0000AB00-1212-EFDE-1523-785FEABCD123",
                               characteristic: "0000AB01-1212-EFDE-1523-785FEABCD123",
                               canNotify: true, canWrite: true)
        let real = Candidate(service: "FFE0", characteristic: "FFE1",
                             canNotify: true, canWrite: true)

        XCTAssertEqual(BluetoothSerial.choose(from: [vendor, real]).notify, real)
        XCTAssertEqual(BluetoothSerial.choose(from: [real, vendor]).notify, real)
    }

    /// A module nobody has heard of still works, so long as something on it can
    /// stream and something can be written. The UUID is a convention; the
    /// properties are the contract.
    func testAnUnknownModuleIsStillUsableOnItsProperties() {
        let unknown = [
            Candidate(service: "0000AB00-1212-EFDE-1523-785FEABCD123",
                      characteristic: "0000AB01-1212-EFDE-1523-785FEABCD123",
                      canNotify: true, canWrite: false),
            Candidate(service: "0000AB00-1212-EFDE-1523-785FEABCD123",
                      characteristic: "0000AB02-1212-EFDE-1523-785FEABCD123",
                      canNotify: false, canWrite: true),
        ]
        XCTAssertTrue(BluetoothSerial.choose(from: unknown).isFullyUsable)
    }

    /// Writing to a characteristic on some unrelated service is worse than not
    /// writing at all: a DFU control point or a configuration register will
    /// accept the bytes and do something entirely unintended with them.
    func testAWriteOnTheSameServiceAsTheStreamIsPreferred() {
        let elsewhere = Candidate(service: "FE59", characteristic: "8EC90003-F315-4F60-9FB8-838830DAEA50",
                                  canNotify: false, canWrite: true)
        let stream = Candidate(service: "0000AB00-1212-EFDE-1523-785FEABCD123",
                               characteristic: "0000AB01-1212-EFDE-1523-785FEABCD123",
                               canNotify: true, canWrite: false)
        let proper = Candidate(service: "0000AB00-1212-EFDE-1523-785FEABCD123",
                               characteristic: "0000AB02-1212-EFDE-1523-785FEABCD123",
                               canNotify: false, canWrite: true)

        let selection = BluetoothSerial.choose(from: [elsewhere, stream, proper])
        XCTAssertEqual(selection.write, proper)
    }

    /// A device with a stream and nowhere to write is a real state — the node
    /// can be watched and not commanded — and has to be distinguishable from
    /// a device that is unusable, because the app says different things about
    /// them.
    func testAStreamWithNoWriteIsUsableButNotFully() {
        let listenOnly = [Candidate(service: "FFE0", characteristic: "FFE1",
                                    canNotify: true, canWrite: false)]
        let selection = BluetoothSerial.choose(from: listenOnly)
        XCTAssertTrue(selection.isUsable)
        XCTAssertFalse(selection.isFullyUsable)
    }

    func testADeviceWithNothingThatStreamsIsNotUsable() {
        let batteryOnly = [Candidate(service: "180F", characteristic: "2A19",
                                     canNotify: false, canWrite: false)]
        XCTAssertFalse(BluetoothSerial.choose(from: batteryOnly).isUsable)
    }

    // MARK: UUID forms

    /// The trap that makes a match work on one phone and fail on another.
    ///
    /// Which form the OS reports for a Bluetooth SIG UUID is not something the
    /// app controls, and comparing the two directly says they are different
    /// services.
    func testShortAndLongFormsOfTheSameUUIDMatch() {
        XCTAssertTrue(BluetoothSerial.same("FFE0", "0000FFE0-0000-1000-8000-00805F9B34FB"))
        XCTAssertTrue(BluetoothSerial.same("ffe1", "0000FFE1-0000-1000-8000-00805f9b34fb"))
        XCTAssertEqual(BluetoothSerial.shortName("0000FFE1-0000-1000-8000-00805F9B34FB"), "FFE1")
    }

    /// And a UUID that merely looks similar must not match. The SIG base is a
    /// specific 96-bit suffix, not a pattern.
    func testANonSIGUUIDIsNotShortened() {
        let vendor = "0000AB01-1212-EFDE-1523-785FEABCD123"
        XCTAssertEqual(BluetoothSerial.shortName(vendor), vendor.uppercased())
        XCTAssertFalse(BluetoothSerial.same(vendor, "AB01"))
    }

    /// The whole selection has to survive the long form, because that is what
    /// some stacks report and the ranking is built on UUID comparison.
    func testAnHM10ReportedInLongFormIsStillRankedAsAnHM10() {
        let long = [
            Candidate(service: "0000AB00-1212-EFDE-1523-785FEABCD123",
                      characteristic: "0000AB01-1212-EFDE-1523-785FEABCD123",
                      canNotify: true, canWrite: true),
            Candidate(service: "0000FFE0-0000-1000-8000-00805F9B34FB",
                      characteristic: "0000FFE1-0000-1000-8000-00805F9B34FB",
                      canNotify: true, canWrite: true),
        ]
        XCTAssertEqual(BluetoothSerial.shortName(
            BluetoothSerial.choose(from: long).notify?.characteristic ?? ""), "FFE1")
    }
}
