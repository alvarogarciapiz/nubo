import Foundation
import NuboCore

public enum WireCodecError: Error, Equatable {
    case invalidMagic
    case unsupportedVersion(UInt16)
    case invalidChannel(UInt8)
    case payloadTooLarge(UInt32)
    case channelMismatch
    case malformedPayload
}

public struct WireEnvelope: Equatable, Sendable {
    public static let magic: UInt32 = 0x4E_55_42_4F // NUBO
    public static let headerLength = 12
    public static let maximumPayloadLength: UInt32 = 32 * 1_024 * 1_024

    public let version: UInt16
    public let channel: NuboChannel
    public let flags: UInt8
    public let payload: Data

    public init(version: UInt16 = NuboConstants.protocolVersion, channel: NuboChannel, flags: UInt8 = 0, payload: Data) {
        self.version = version
        self.channel = channel
        self.flags = flags
        self.payload = payload
    }

    public func encoded() throws -> Data {
        guard payload.count <= Self.maximumPayloadLength else {
            throw WireCodecError.payloadTooLarge(UInt32(clamping: payload.count))
        }
        var data = Data()
        data.appendBigEndian(Self.magic)
        data.appendBigEndian(version)
        data.append(channel.rawValue)
        data.append(flags)
        data.appendBigEndian(UInt32(payload.count))
        data.append(payload)
        return data
    }
}

public struct WireDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [WireEnvelope] {
        buffer.append(data)
        var envelopes: [WireEnvelope] = []
        while buffer.count >= WireEnvelope.headerLength {
            let magic = buffer.readBigEndian(UInt32.self, at: 0)
            guard magic == WireEnvelope.magic else { throw WireCodecError.invalidMagic }
            let version = buffer.readBigEndian(UInt16.self, at: 4)
            guard version == NuboConstants.protocolVersion else { throw WireCodecError.unsupportedVersion(version) }
            let rawChannel = buffer[6]
            guard let channel = NuboChannel(rawValue: rawChannel) else {
                throw WireCodecError.invalidChannel(rawChannel)
            }
            let flags = buffer[7]
            let length = buffer.readBigEndian(UInt32.self, at: 8)
            guard length <= WireEnvelope.maximumPayloadLength else {
                throw WireCodecError.payloadTooLarge(length)
            }
            let totalLength = WireEnvelope.headerLength + Int(length)
            guard buffer.count >= totalLength else { break }
            let payload = buffer.subdata(in: WireEnvelope.headerLength..<totalLength)
            envelopes.append(WireEnvelope(version: version, channel: channel, flags: flags, payload: payload))
            buffer.removeSubrange(0..<totalLength)
        }
        return envelopes
    }
}

public struct MessageCodec: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    public func encode(_ message: NuboMessage) throws -> Data {
        if case let .videoFrame(frame) = message {
            var payload = Data()
            payload.appendBigEndian(frame.sequence)
            payload.appendBigEndian(frame.presentationTimeNanoseconds)
            payload.appendBigEndian(frame.displayID.rawValue)
            payload.append(frame.isKeyFrame ? 1 : 0)
            payload.append(frame.bytes)
            return try WireEnvelope(channel: .video, flags: 1, payload: payload).encoded()
        }
        if case let .audioPacket(packet) = message {
            var payload = Data()
            payload.appendBigEndian(packet.sequence)
            payload.appendBigEndian(packet.presentationTimeNanoseconds)
            payload.append(packet.bytes)
            return try WireEnvelope(channel: .audio, flags: 1, payload: payload).encoded()
        }
        if case let .pointer(event) = message {
            return try WireEnvelope(channel: .input, flags: 2, payload: encodePointer(event)).encoded()
        }
        if case let .key(event) = message {
            return try WireEnvelope(channel: .input, flags: 2, payload: encodeKey(event)).encoded()
        }
        return try WireEnvelope(channel: message.channel, payload: encoder.encode(message)).encoded()
    }

    public func decode(_ envelope: WireEnvelope) throws -> NuboMessage {
        if envelope.channel == .video, envelope.flags == 1 {
            guard envelope.payload.count >= 21 else { throw WireCodecError.malformedPayload }
            return .videoFrame(EncodedVideoFrame(
                sequence: envelope.payload.readBigEndian(UInt64.self, at: 0),
                presentationTimeNanoseconds: envelope.payload.readBigEndian(UInt64.self, at: 8),
                displayID: .init(rawValue: envelope.payload.readBigEndian(UInt32.self, at: 16)),
                isKeyFrame: envelope.payload[20] != 0,
                bytes: Data(envelope.payload.dropFirst(21))
            ))
        }
        if envelope.channel == .audio, envelope.flags == 1 {
            guard envelope.payload.count >= 16 else { throw WireCodecError.malformedPayload }
            return .audioPacket(EncodedAudioPacket(
                sequence: envelope.payload.readBigEndian(UInt64.self, at: 0),
                presentationTimeNanoseconds: envelope.payload.readBigEndian(UInt64.self, at: 8),
                bytes: Data(envelope.payload.dropFirst(16))
            ))
        }
        if envelope.channel == .input, envelope.flags == 2 {
            return try decodeInput(envelope.payload)
        }
        let message = try decoder.decode(NuboMessage.self, from: envelope.payload)
        guard message.channel == envelope.channel else { throw WireCodecError.channelMismatch }
        return message
    }

    private func encodePointer(_ event: PointerEvent) -> Data {
        var payload = Data()
        switch event {
        case let .relativeMotion(vector):
            payload.append(1)
            payload.appendBigEndian(vector.dx.bitPattern)
            payload.appendBigEndian(vector.dy.bitPattern)
        case let .absoluteMotion(point):
            payload.append(2)
            payload.appendBigEndian(point.x.bitPattern)
            payload.appendBigEndian(point.y.bitPattern)
        case let .button(button, phase, clickCount):
            payload.append(3)
            payload.append(button.rawValue)
            payload.append(phase.rawValue)
            payload.appendBigEndian(UInt16(clamping: clickCount))
        case let .scroll(vector, isPrecise):
            payload.append(4)
            payload.appendBigEndian(vector.dx.bitPattern)
            payload.appendBigEndian(vector.dy.bitPattern)
            payload.append(isPrecise ? 1 : 0)
        }
        return payload
    }

    private func encodeKey(_ event: KeyInputEvent) throws -> Data {
        let characters = Data((event.characters ?? "").utf8)
        guard characters.count <= UInt16.max else { throw WireCodecError.malformedPayload }
        var payload = Data()
        payload.append(5)
        payload.appendBigEndian(event.hidUsage)
        payload.append((event.isDown ? 1 : 0) | (event.isRepeat ? 2 : 0))
        payload.appendBigEndian(event.modifiers.rawValue)
        payload.appendBigEndian(UInt16(characters.count))
        payload.append(characters)
        return payload
    }

    private func decodeInput(_ payload: Data) throws -> NuboMessage {
        guard let kind = payload.first else { throw WireCodecError.malformedPayload }
        switch kind {
        case 1:
            guard payload.count == 17 else { throw WireCodecError.malformedPayload }
            return .pointer(.relativeMotion(.init(
                dx: Double(bitPattern: payload.readBigEndian(UInt64.self, at: 1)),
                dy: Double(bitPattern: payload.readBigEndian(UInt64.self, at: 9))
            )))
        case 2:
            guard payload.count == 17 else { throw WireCodecError.malformedPayload }
            return .pointer(.absoluteMotion(.init(
                x: Double(bitPattern: payload.readBigEndian(UInt64.self, at: 1)),
                y: Double(bitPattern: payload.readBigEndian(UInt64.self, at: 9))
            )))
        case 3:
            guard payload.count == 5,
                  let button = MouseButton(rawValue: payload[1]),
                  let phase = ButtonPhase(rawValue: payload[2]) else {
                throw WireCodecError.malformedPayload
            }
            return .pointer(.button(
                button,
                phase,
                clickCount: Int(payload.readBigEndian(UInt16.self, at: 3))
            ))
        case 4:
            guard payload.count == 18 else { throw WireCodecError.malformedPayload }
            return .pointer(.scroll(.init(
                dx: Double(bitPattern: payload.readBigEndian(UInt64.self, at: 1)),
                dy: Double(bitPattern: payload.readBigEndian(UInt64.self, at: 9))
            ), isPrecise: payload[17] != 0))
        case 5:
            guard payload.count >= 8 else { throw WireCodecError.malformedPayload }
            let characterLength = Int(payload.readBigEndian(UInt16.self, at: 6))
            guard payload.count == 8 + characterLength,
                  let characters = String(data: payload.subdata(in: 8..<payload.count), encoding: .utf8) else {
                throw WireCodecError.malformedPayload
            }
            let state = payload[3]
            return .key(.init(
                hidUsage: payload.readBigEndian(UInt16.self, at: 1),
                characters: characters.isEmpty ? nil : characters,
                isDown: state & 1 != 0,
                isRepeat: state & 2 != 0,
                modifiers: .init(rawValue: payload.readBigEndian(UInt16.self, at: 4))
            ))
        default:
            throw WireCodecError.malformedPayload
        }
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    func readBigEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        self[offset..<(offset + MemoryLayout<T>.size)].reduce(T.zero) { ($0 << 8) | T($1) }
    }
}
