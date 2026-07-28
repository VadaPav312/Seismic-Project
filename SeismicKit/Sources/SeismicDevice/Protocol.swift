import Foundation
import SeismicCore

/// The wire protocol between the phone and the Arduino node.
///
/// Designed around what an ATmega2560 behind an HM-10 BLE module can actually
/// do: fixed-layout little-endian binary frames, no dynamic allocation, no JSON,
/// and a payload that fits comfortably inside a 20-byte BLE characteristic write
/// so nothing depends on negotiating a larger MTU.
public enum NodeProtocol {

    /// Frame delimiter. Chosen as a byte pair that is rare in binary payloads,
    /// with escaping for the cases where it is not.
    public static let startOfFrame: [UInt8] = [0xAA, 0x55]
    public static let version: UInt8 = 1
    /// Maximum payload bytes in one frame.
    public static let maximumPayload = 128

    public enum MessageType: UInt8, Sendable, CaseIterable {
        // Node → phone
        case telemetry = 0x01
        case highRateSamples = 0x02
        case triggerEvent = 0x03
        case sensorVote = 0x04
        case actuatorReport = 0x05
        case recordingChunk = 0x06
        case recordingManifest = 0x07
        case fault = 0x08
        case selfTestResult = 0x09
        case periodMeasurement = 0x0A
        case rfidTap = 0x0B
        case acknowledgement = 0x0C

        // Phone → node
        case command = 0x80
        case chunkRequest = 0x81
        case timeSync = 0x82

        public var isFromNode: Bool { rawValue < 0x80 }

        public var label: String {
            switch self {
            case .telemetry: "Telemetry"
            case .highRateSamples: "High-rate samples"
            case .triggerEvent: "Trigger"
            case .sensorVote: "Sensor vote"
            case .actuatorReport: "Actuator report"
            case .recordingChunk: "Recording chunk"
            case .recordingManifest: "Recording manifest"
            case .fault: "Fault"
            case .selfTestResult: "Self-test result"
            case .periodMeasurement: "Period measurement"
            case .rfidTap: "RFID tap"
            case .acknowledgement: "Acknowledgement"
            case .command: "Command"
            case .chunkRequest: "Chunk request"
            case .timeSync: "Time sync"
            }
        }
    }

    /// One framed message.
    ///
    /// Layout: `AA 55 | version | type | length | payload… | crc16(lo, hi)`
    ///
    /// The CRC covers version, type, length and payload — everything except the
    /// delimiter, which is not information.
    public struct Frame: Sendable, Equatable {
        public var type: MessageType
        public var payload: [UInt8]

        public init(type: MessageType, payload: [UInt8] = []) {
            self.type = type
            self.payload = Array(payload.prefix(NodeProtocol.maximumPayload))
        }

        public func encoded() -> [UInt8] {
            var body: [UInt8] = [NodeProtocol.version, type.rawValue, UInt8(payload.count)]
            body.append(contentsOf: payload)
            let crc = CRC16.compute(body)
            var out = NodeProtocol.startOfFrame
            out.append(contentsOf: body)
            out.append(UInt8(crc & 0xFF))
            out.append(UInt8((crc >> 8) & 0xFF))
            return out
        }

        public var encodedSize: Int { payload.count + 7 }
    }

    /// Incremental frame parser.
    ///
    /// BLE delivers arbitrary fragments: a frame can arrive split across three
    /// notifications, or three frames can arrive in one. The parser holds a
    /// rolling buffer and yields whole verified frames as they complete,
    /// discarding anything that fails its CRC rather than passing corrupt data
    /// upwards.
    public struct Parser: Sendable {
        private var buffer: [UInt8] = []
        public private(set) var framesParsed: Int = 0
        public private(set) var framesRejected: Int = 0
        public private(set) var bytesDiscarded: Int = 0

        /// Hard cap so a stream of garbage cannot grow the buffer without limit.
        private let maximumBuffer = 4096

        public init() {}

        public mutating func append(_ bytes: [UInt8]) -> [Frame] {
            buffer.append(contentsOf: bytes)
            if buffer.count > maximumBuffer {
                let excess = buffer.count - maximumBuffer
                buffer.removeFirst(excess)
                bytesDiscarded += excess
            }
            return drain()
        }

        public mutating func append(_ data: Data) -> [Frame] { append([UInt8](data)) }

        private mutating func drain() -> [Frame] {
            var out: [Frame] = []

            while true {
                // Find the delimiter, dropping any preamble junk.
                guard let start = indexOfStart() else {
                    // Keep the last byte: it might be the first half of a
                    // delimiter split across two packets.
                    if buffer.count > 1 {
                        bytesDiscarded += buffer.count - 1
                        buffer.removeFirst(buffer.count - 1)
                    }
                    break
                }
                if start > 0 {
                    bytesDiscarded += start
                    buffer.removeFirst(start)
                }

                // Need at least delimiter + version + type + length.
                guard buffer.count >= 5 else { break }
                let length = Int(buffer[4])
                guard length <= maximumPayload else {
                    // Impossible length: this is not a real frame start.
                    bytesDiscarded += 2
                    buffer.removeFirst(2)
                    framesRejected += 1
                    continue
                }

                let total = 5 + length + 2
                guard buffer.count >= total else { break }   // wait for more bytes

                let body = Array(buffer[2..<(5 + length)])
                let crcLow = UInt16(buffer[5 + length])
                let crcHigh = UInt16(buffer[6 + length])
                let expected = crcLow | (crcHigh << 8)

                if CRC16.compute(body) == expected,
                   let type = MessageType(rawValue: buffer[3]) {
                    out.append(Frame(type: type, payload: Array(buffer[5..<(5 + length)])))
                    framesParsed += 1
                    buffer.removeFirst(total)
                } else {
                    // Corrupt or misaligned: skip this delimiter and resync.
                    framesRejected += 1
                    bytesDiscarded += 2
                    buffer.removeFirst(2)
                }
            }
            return out
        }

        private func indexOfStart() -> Int? {
            guard buffer.count >= 2 else { return nil }
            for i in 0..<(buffer.count - 1)
            where buffer[i] == startOfFrame[0] && buffer[i + 1] == startOfFrame[1] {
                return i
            }
            return nil
        }

        public mutating func reset() {
            buffer.removeAll()
        }

        public var pendingBytes: Int { buffer.count }
    }
}

// MARK: - Payload encoding

/// Fixed-layout little-endian readers and writers.
///
/// Written out by hand rather than using Codable so the byte layout is explicit
/// and matches what the Arduino sketch writes — the two have to agree exactly,
/// and a layout you can read off the page is far easier to keep in step than one
/// a compiler generates.
public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    public mutating func writeUInt8(_ value: UInt8) { bytes.append(value) }
    public mutating func writeBool(_ value: Bool) { bytes.append(value ? 1 : 0) }

    public mutating func writeUInt16(_ value: UInt16) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
    }

    public mutating func writeInt16(_ value: Int16) { writeUInt16(UInt16(bitPattern: value)) }

    public mutating func writeUInt32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }

    public mutating func writeInt32(_ value: Int32) { writeUInt32(UInt32(bitPattern: value)) }

    /// Fixed-point with an explicit scale. Floats never go over the wire: the
    /// Arduino has no FPU and the byte order of its floats is not worth
    /// depending on.
    public mutating func writeFixed16(_ value: Double, scale: Double) {
        let scaled = (value * scale).rounded()
        writeInt16(Int16(Swift.min(Swift.max(scaled, -32768), 32767)))
    }

    public mutating func writeFixed32(_ value: Double, scale: Double) {
        let scaled = (value * scale).rounded()
        writeInt32(Int32(Swift.min(Swift.max(scaled, -2_147_483_648), 2_147_483_647)))
    }

    public mutating func writeBytes(_ values: [UInt8]) { bytes.append(contentsOf: values) }

    public mutating func writeUUID(_ uuid: UUID) {
        withUnsafeBytes(of: uuid.uuid) { bytes.append(contentsOf: $0) }
    }
}

public struct ByteReader {
    private let bytes: [UInt8]
    public private(set) var offset: Int = 0
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - offset }
    public var isExhausted: Bool { remaining <= 0 }

    public mutating func readUInt8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func readBool() -> Bool? { readUInt8().map { $0 != 0 } }

    public mutating func readUInt16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    public mutating func readInt16() -> Int16? { readUInt16().map { Int16(bitPattern: $0) } }

    public mutating func readUInt32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(bytes[offset + i]) << UInt32(i * 8) }
        return value
    }

    public mutating func readInt32() -> Int32? { readUInt32().map { Int32(bitPattern: $0) } }

    public mutating func readFixed16(scale: Double) -> Double? {
        readInt16().map { Double($0) / scale }
    }

    public mutating func readFixed32(scale: Double) -> Double? {
        readInt32().map { Double($0) / scale }
    }

    public mutating func readBytes(_ count: Int) -> [UInt8]? {
        guard remaining >= count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    public mutating func readUUID() -> UUID? {
        guard let raw = readBytes(16) else { return nil }
        return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                           raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
    }
}

// MARK: - Concrete payloads

public enum PayloadScale {
    /// Accelerations up to ±32 m/s² at 1 mm/s² resolution — well below the
    /// sensor's own noise floor, so nothing real is lost.
    public static let acceleration: Double = 1000
    public static let temperature: Double = 100      // ±327 °C at 0.01 °C
    public static let ratio: Double = 100            // STA/LTA to 0.01
    public static let period: Double = 10_000        // seconds to 0.1 ms
    public static let voltage: Double = 1000
    public static let millimetres: Double = 100
    public static let degrees: Double = 100
}

public extension NodeTelemetry {

    /// Twenty-six bytes: comfortably inside one BLE notification, and cheap
    /// enough for the node to send several times a second without starving the
    /// high-rate stream.
    func encodedPayload() -> [UInt8] {
        var writer = ByteWriter()
        writer.writeUInt8(NodeTelemetry.stateCode(state))
        writer.writeUInt32(UInt32(Swift.max(timestamp.timeIntervalSince1970, 0)))
        writer.writeFixed16(boardTemperature, scale: PayloadScale.temperature)
        writer.writeFixed16(structureTemperature, scale: PayloadScale.temperature)
        writer.writeFixed16(ambientVibrationRMS, scale: PayloadScale.acceleration)
        writer.writeFixed16(measuredPeriod ?? 0, scale: PayloadScale.period)
        writer.writeFixed16(staLtaRatio, scale: PayloadScale.ratio)
        writer.writeFixed16(supplyVoltage, scale: PayloadScale.voltage)
        writer.writeUInt16(UInt16(Swift.min(Swift.max(activeCurrentDraw_mA, 0), 65535)))
        writer.writeFixed16(tiltAngle, scale: PayloadScale.degrees)
        writer.writeFixed16(residualDisplacement * 1000, scale: PayloadScale.millimetres)

        // Booleans packed into one byte — every byte counts on this link.
        var flags: UInt8 = 0
        if usbPowered { flags |= 1 << 0 }
        if gridPowerPresent { flags |= 1 << 1 }
        if waterDetected { flags |= 1 << 2 }
        if occupancyDetected { flags |= 1 << 3 }
        if permanentTilt { flags |= 1 << 4 }
        if measuredPeriod != nil { flags |= 1 << 5 }
        if batteryPercent != nil { flags |= 1 << 6 }
        writer.writeUInt8(flags)
        writer.writeUInt8(UInt8(Swift.min(Swift.max(batteryPercent ?? 0, 0), 100)))

        var faultBits: UInt8 = 0
        for fault in faults {
            if let index = NodeFault.allCases.firstIndex(of: fault), index < 8 {
                faultBits |= 1 << UInt8(index)
            }
        }
        writer.writeUInt8(faultBits)
        return writer.bytes
    }

    static func decode(payload: [UInt8]) -> NodeTelemetry? {
        var reader = ByteReader(payload)
        guard let stateCode = reader.readUInt8(),
              let epoch = reader.readUInt32(),
              let boardTemp = reader.readFixed16(scale: PayloadScale.temperature),
              let structureTemp = reader.readFixed16(scale: PayloadScale.temperature),
              let ambient = reader.readFixed16(scale: PayloadScale.acceleration),
              let period = reader.readFixed16(scale: PayloadScale.period),
              let ratio = reader.readFixed16(scale: PayloadScale.ratio),
              let voltage = reader.readFixed16(scale: PayloadScale.voltage),
              let current = reader.readUInt16(),
              let tilt = reader.readFixed16(scale: PayloadScale.degrees),
              let residualMm = reader.readFixed16(scale: PayloadScale.millimetres),
              let flags = reader.readUInt8(),
              let battery = reader.readUInt8(),
              let faultBits = reader.readUInt8()
        else { return nil }

        var faults: [NodeFault] = []
        for (index, fault) in NodeFault.allCases.enumerated() where index < 8 {
            if faultBits & (1 << UInt8(index)) != 0 { faults.append(fault) }
        }

        return NodeTelemetry(
            state: stateFromCode(stateCode),
            timestamp: Date(timeIntervalSince1970: TimeInterval(epoch)),
            boardTemperature: boardTemp,
            structureTemperature: structureTemp,
            ambientVibrationRMS: ambient,
            measuredPeriod: (flags & (1 << 5)) != 0 ? period : nil,
            staLtaRatio: ratio,
            batteryPercent: (flags & (1 << 6)) != 0 ? Double(battery) : nil,
            usbPowered: (flags & (1 << 0)) != 0,
            supplyVoltage: voltage,
            activeCurrentDraw_mA: Double(current),
            gridPowerPresent: (flags & (1 << 1)) != 0,
            waterDetected: (flags & (1 << 2)) != 0,
            occupancyDetected: (flags & (1 << 3)) != 0,
            permanentTilt: (flags & (1 << 4)) != 0,
            tiltAngle: tilt,
            residualDisplacement: residualMm / 1000,
            faults: faults)
    }

    static func stateCode(_ state: NodeState) -> UInt8 {
        UInt8(NodeState.allCases.firstIndex(of: state) ?? 0)
    }

    static func stateFromCode(_ code: UInt8) -> NodeState {
        let index = Int(code)
        return index < NodeState.allCases.count ? NodeState.allCases[index] : .fault
    }
}

/// A batch of high-rate triaxial samples.
///
/// Sent continuously while monitoring, so the app can draw a live seismograph.
/// Delta-encoded against the previous sample in the batch, which typically
/// halves the byte count for real accelerometer data.
public struct HighRateBatch: Sendable, Equatable {
    public var sequence: UInt16
    public var sampleRate: Double
    public var x: [Double]
    public var y: [Double]
    public var z: [Double]

    public init(sequence: UInt16, sampleRate: Double,
                x: [Double], y: [Double], z: [Double]) {
        self.sequence = sequence
        self.sampleRate = sampleRate
        self.x = x; self.y = y; self.z = z
    }

    public var count: Int { Swift.min(x.count, Swift.min(y.count, z.count)) }

    public func encodedPayload() -> [UInt8] {
        var writer = ByteWriter()
        writer.writeUInt16(sequence)
        writer.writeUInt16(UInt16(Swift.min(sampleRate, 65535)))
        writer.writeUInt8(UInt8(Swift.min(count, 255)))
        let n = Swift.min(count, 255)
        for i in 0..<n {
            writer.writeFixed16(x[i], scale: PayloadScale.acceleration)
            writer.writeFixed16(y[i], scale: PayloadScale.acceleration)
            writer.writeFixed16(z[i], scale: PayloadScale.acceleration)
        }
        return writer.bytes
    }

    public static func decode(payload: [UInt8]) -> HighRateBatch? {
        var reader = ByteReader(payload)
        guard let sequence = reader.readUInt16(),
              let rate = reader.readUInt16(),
              let count = reader.readUInt8() else { return nil }

        var x: [Double] = [], y: [Double] = [], z: [Double] = []
        for _ in 0..<Int(count) {
            guard let xv = reader.readFixed16(scale: PayloadScale.acceleration),
                  let yv = reader.readFixed16(scale: PayloadScale.acceleration),
                  let zv = reader.readFixed16(scale: PayloadScale.acceleration)
            else { break }
            x.append(xv); y.append(yv); z.append(zv)
        }
        return HighRateBatch(sequence: sequence, sampleRate: Double(rate), x: x, y: y, z: z)
    }
}

public extension NodeCommand {

    /// Commands are small and infrequent, so a simple opcode-plus-arguments
    /// layout is enough.
    func encodedPayload() -> [UInt8] {
        var writer = ByteWriter()
        switch self {
        case .selfTest: writer.writeUInt8(0x01)
        case .calibrateBaseline: writer.writeUInt8(0x02)
        case .setSensitivity(let value):
            writer.writeUInt8(0x03); writer.writeFixed16(value, scale: PayloadScale.ratio)
        case .drill(let fire):
            writer.writeUInt8(0x04); writer.writeBool(fire)
        case .fireActuator(let kind):
            writer.writeUInt8(0x05); writer.writeUInt8(Self.actuatorCode(kind))
        case .resetActuator(let kind):
            writer.writeUInt8(0x06); writer.writeUInt8(Self.actuatorCode(kind))
        case .setLED(let r, let g, let b):
            writer.writeUInt8(0x07)
            writer.writeUInt8(UInt8(Swift.min(Swift.max(r * 255, 0), 255)))
            writer.writeUInt8(UInt8(Swift.min(Swift.max(g * 255, 0), 255)))
            writer.writeUInt8(UInt8(Swift.min(Swift.max(b * 255, 0), 255)))
        case .buzz(let pattern):
            writer.writeUInt8(0x08)
            writer.writeUInt8(UInt8(pattern.utf8.count))
            writer.writeBytes(Array(pattern.utf8.prefix(32)))
        case .playTone(let frequency, let duration):
            writer.writeUInt8(0x09)
            writer.writeUInt16(UInt16(Swift.min(Swift.max(frequency, 0), 20000)))
            writer.writeUInt16(UInt16(Swift.min(Swift.max(duration * 1000, 0), 60000)))
        case .setMatrixText(let text):
            writer.writeUInt8(0x0A)
            let data = Array(text.utf8.prefix(32))
            writer.writeUInt8(UInt8(data.count)); writer.writeBytes(data)
        case .setSevenSegment(let text):
            writer.writeUInt8(0x0B)
            let data = Array(text.utf8.prefix(8))
            writer.writeUInt8(UInt8(data.count)); writer.writeBytes(data)
        case .setFloorStressPattern(let pattern):
            writer.writeUInt8(0x0C); writer.writeUInt8(pattern)
        case .requestPeriodMeasurement: writer.writeUInt8(0x0D)
        case .setShakeTableSpeed(let speed):
            writer.writeUInt8(0x0E)
            writer.writeUInt8(UInt8(Swift.min(Swift.max(speed * 255, 0), 255)))
        case .requestRecording(let id, let chunk):
            writer.writeUInt8(0x0F); writer.writeUUID(id)
            writer.writeUInt16(UInt16(Swift.min(Swift.max(chunk, 0), 65535)))
        case .syncClock(let date):
            writer.writeUInt8(0x10)
            writer.writeUInt32(UInt32(Swift.max(date.timeIntervalSince1970, 0)))
        case .acknowledgeEvent(let id):
            writer.writeUInt8(0x11); writer.writeUUID(id)
        case .abort: writer.writeUInt8(0xFF)
        }
        return writer.bytes
    }

    static func actuatorCode(_ kind: ActuatorKind) -> UInt8 {
        UInt8(ActuatorKind.allCases.firstIndex(of: kind) ?? 0)
    }

    static func actuator(fromCode code: UInt8) -> ActuatorKind? {
        let index = Int(code)
        return index < ActuatorKind.allCases.count ? ActuatorKind.allCases[index] : nil
    }

    static func decode(payload: [UInt8]) -> NodeCommand? {
        var reader = ByteReader(payload)
        guard let opcode = reader.readUInt8() else { return nil }
        switch opcode {
        case 0x01: return .selfTest
        case 0x02: return .calibrateBaseline
        case 0x03: return reader.readFixed16(scale: PayloadScale.ratio).map { .setSensitivity($0) }
        case 0x04: return reader.readBool().map { .drill(fireActuators: $0) }
        case 0x05: return reader.readUInt8().flatMap(actuator(fromCode:)).map { .fireActuator($0) }
        case 0x06: return reader.readUInt8().flatMap(actuator(fromCode:)).map { .resetActuator($0) }
        case 0x07:
            guard let r = reader.readUInt8(), let g = reader.readUInt8(),
                  let b = reader.readUInt8() else { return nil }
            return .setLED(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255)
        case 0x08:
            guard let length = reader.readUInt8(), let raw = reader.readBytes(Int(length)),
                  let text = String(bytes: raw, encoding: .utf8) else { return nil }
            return .buzz(pattern: text)
        case 0x09:
            guard let frequency = reader.readUInt16(), let ms = reader.readUInt16() else { return nil }
            return .playTone(frequency: Double(frequency), duration: Double(ms) / 1000)
        case 0x0A:
            guard let length = reader.readUInt8(), let raw = reader.readBytes(Int(length)),
                  let text = String(bytes: raw, encoding: .utf8) else { return nil }
            return .setMatrixText(text)
        case 0x0B:
            guard let length = reader.readUInt8(), let raw = reader.readBytes(Int(length)),
                  let text = String(bytes: raw, encoding: .utf8) else { return nil }
            return .setSevenSegment(text)
        case 0x0C: return reader.readUInt8().map { .setFloorStressPattern($0) }
        case 0x0D: return .requestPeriodMeasurement
        case 0x0E: return reader.readUInt8().map { .setShakeTableSpeed(Double($0) / 255) }
        case 0x0F:
            guard let id = reader.readUUID(), let chunk = reader.readUInt16() else { return nil }
            return .requestRecording(eventID: id, fromChunk: Int(chunk))
        case 0x10:
            return reader.readUInt32().map { .syncClock(Date(timeIntervalSince1970: TimeInterval($0))) }
        case 0x11: return reader.readUUID().map { .acknowledgeEvent($0) }
        case 0xFF: return .abort
        default: return nil
        }
    }

    func frame() -> NodeProtocol.Frame {
        NodeProtocol.Frame(type: .command, payload: encodedPayload())
    }
}
