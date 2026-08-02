import Foundation

/// Which characteristics on a connected peripheral carry the protocol.
///
/// The node's firmware speaks newline-delimited JSON over whatever serial
/// bridge happens to be soldered to the board, and there is no single answer to
/// where that is. A genuine HM-10 puts both directions on FFE1 inside FFE0. A
/// Nordic UART module splits them — 6E400003 notifies, 6E400002 accepts writes.
/// The clones (MLT-BT05, CC41, AT-09) do either, sometimes on a vendor service
/// of their own, and sometimes only expose FFE0 after you have connected rather
/// than in the advertisement.
///
/// So the choice is made on *properties*, ranked, with the known UUIDs
/// preferred: the UUID is a convention and the properties are the contract.
/// Kept here, free of CoreBluetooth, because this is the logic that decides
/// whether the hardware works at all and it should not only be testable by
/// holding a board.
public enum BluetoothSerial {

    /// One characteristic, described by what it can do.
    public struct Candidate: Sendable, Equatable, Hashable {
        public var service: String
        public var characteristic: String
        public var canNotify: Bool
        public var canWrite: Bool

        public init(service: String, characteristic: String,
                    canNotify: Bool, canWrite: Bool) {
            self.service = service
            self.characteristic = characteristic
            self.canNotify = canNotify
            self.canWrite = canWrite
        }
    }

    public struct Selection: Sendable, Equatable {
        /// Where the node's stream comes from. Without this there is no link.
        public var notify: Candidate?
        /// Where commands go. Without this the node can be watched and not
        /// commanded, which is a real state and worth distinguishing.
        public var write: Candidate?

        public var isUsable: Bool { notify != nil }
        public var isFullyUsable: Bool { notify != nil && write != nil }
    }

    // MARK: Known UUIDs

    public static let hm10Service = "FFE0"
    public static let hm10Characteristic = "FFE1"
    public static let nordicService = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    /// The module transmits on this, so it is the phone's *receive*.
    public static let nordicNotify = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    public static let nordicWrite = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"

    /// The serial services worth ranking above an unknown one.
    public static let knownServices = [hm10Service, nordicService,
                                       "49535343-FE7D-4AE5-8FA9-9FAFD205E455"]

    // MARK: Choosing

    /// Picks the best notify and the best write from everything discovered.
    ///
    /// Across *all* services, not the first one that has something workable.
    /// Characteristic discovery answers per service in whatever order the radio
    /// feels like, so "first workable wins" means a vendor service beating
    /// FFE0/FFE1 at random between one launch and the next.
    public static func choose(from candidates: [Candidate]) -> Selection {
        var selection = Selection()
        var bestNotify = Int.min
        var bestWrite = Int.min

        for candidate in candidates {
            if candidate.canNotify {
                let rank = rank(candidate, preferredCharacteristic: hm10Characteristic,
                                nordicCharacteristic: nordicNotify)
                if rank > bestNotify {
                    bestNotify = rank
                    selection.notify = candidate
                }
            }
            if candidate.canWrite {
                let rank = rank(candidate, preferredCharacteristic: hm10Characteristic,
                                nordicCharacteristic: nordicWrite)
                if rank > bestWrite {
                    bestWrite = rank
                    selection.write = candidate
                }
            }
        }

        // Having settled on where the stream comes from, prefer a write on the
        // same service. A module that exposes an unrelated writable
        // characteristic elsewhere — a configuration register, a DFU control
        // point — will accept the write and do something entirely unintended
        // with it, so a same-service candidate of equal rank wins.
        if let notify = selection.notify,
           let sameService = candidates.first(where: {
               $0.canWrite && same($0.service, notify.service)
           }),
           let current = selection.write, !same(current.service, notify.service) {
            selection.write = sameService
        }

        return selection
    }

    /// 3 for the HM-10 pair, 2 for the Nordic pair, 1 for a known service, 0
    /// for anything else with the right properties.
    private static func rank(_ candidate: Candidate,
                             preferredCharacteristic: String,
                             nordicCharacteristic: String) -> Int {
        if same(candidate.service, hm10Service),
           same(candidate.characteristic, preferredCharacteristic) { return 3 }
        if same(candidate.service, nordicService),
           same(candidate.characteristic, nordicCharacteristic) { return 2 }
        if knownServices.contains(where: { same($0, candidate.service) }) { return 1 }
        return 0
    }

    // MARK: UUID forms

    /// Compares two UUIDs across the short and long forms of the same thing.
    ///
    /// `FFE0` and `0000FFE0-0000-1000-8000-00805F9B34FB` are the same service.
    /// Which one arrives depends on the module and on the OS version, and
    /// CoreBluetooth's own `CBUUID` equality says they are different — it
    /// compares its bytes, and one is two bytes long and the other sixteen. A
    /// direct comparison is therefore a match that works on the bench and fails
    /// on somebody else's board.
    public static func same(_ a: String, _ b: String) -> Bool {
        shortName(a) == shortName(b)
    }

    /// The 16-bit form where the UUID is a Bluetooth SIG one, for comparison
    /// and for display — "FFE1" is readable and the 128-bit form is not.
    public static func shortName(_ uuid: String) -> String {
        let text = uuid.uppercased()
        let base = "-0000-1000-8000-00805F9B34FB"
        if text.count == 36, text.hasPrefix("0000"), text.hasSuffix(base) {
            return String(text.dropFirst(4).prefix(4))
        }
        return text
    }
}
