import Foundation

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

    public init(version: UInt16 = 1, channel: NuboChannel, flags: UInt8 = 0, payload: Data) {
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
            guard version == 1 else { throw WireCodecError.unsupportedVersion(version) }
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
        let message = try decoder.decode(NuboMessage.self, from: envelope.payload)
        guard message.channel == envelope.channel else { throw WireCodecError.channelMismatch }
        return message
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
