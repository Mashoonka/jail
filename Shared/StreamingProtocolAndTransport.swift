//
//  StreamingProtocolAndTransport.swift
//  LowLatencyScreenMirror (Shared Module: iOS + BroadcastExtension + tvOS)
//
//  Назначение:
//  - Бинарный RTP-подобный протокол заголовков (24 байта, Big-Endian, Zero-Allocation).
//  - Фрагментация видеокадров (AVCC) и аудиопакетов под безопасный MTU (1200 байт).
//  - Обратный канал управления (PLI - мгновенный запрос IDR-кадра, Ping/Pong RTT и потери).
//  - Адаптивный контроллер битрейта, разрешения и FPS (AIMD + Thermal State).
//  - Обнаружение устройств через Bonjour/mDNS и высокоприоритетный UDP-транспорт (DSCP CS4/AF41).
//

import Foundation
import Network
import os.log

// MARK: - 1. Константы и общие настройки

public enum StreamConfig {
    /// Тип сервиса Bonjour для обнаружения Apple TV в локальной сети
    public static let bonjourServiceType = "_llmirror._udp"
    /// Идентификатор App Group для обмена настройками и телеметрией между приложением и Extension
    public static let appGroupIdentifier = "group.com.example.lowlatencymirror"
    /// Безопасный размер полезной нагрузки UDP-дейтаграммы (исключает IP-фрагментацию в Wi-Fi)
    public static let maxPayloadSize: Int = 1200
    /// Фиксированный размер бинарного заголовка пакета
    public static let headerSize: Int = 24
    /// Максимальный размер UDP-пакета на проводе
    public static let maxDatagramSize: Int = headerSize + maxPayloadSize
    /// UDP-порт по умолчанию для прямого подключения или QR-кода
    public static let defaultUDPPort: UInt16 = 5004

    // Ключи для UserDefaults (App Group)
    public static let keyTargetHost = "target_host"
    public static let keyTargetPort = "target_port"
    public static let keyTargetServiceName = "target_service_name"
    public static let keySelectedCodec = "selected_codec"
    public static let keyStreamActive = "stream_active"
    public static let keyTelemetryFPS = "telemetry_fps"
    public static let keyTelemetryBitrateMbps = "telemetry_bitrate_mbps"
    public static let keyTelemetryRTTMs = "telemetry_rtt_ms"
    public static let keyTelemetryLossPercent = "telemetry_loss_percent"
}

/// Тип пакета в нашем низкозадержечном протоколе
public enum PacketType: UInt8, Sendable {
    case videoConfig = 0x01  // Параметры кодека: SPS + PPS (или VPS+SPS+PPS для HEVC)
    case videoIDR    = 0x02  // Ключевой видеокадр (I-frame / IDR)
    case videoSlice  = 0x03  // Дельта-кадр (P-frame, без B-кадров)
    case audioPCM    = 0x04  // Аудиофрейм (LPCM 16-bit 48kHz Stereo или сжатый AAC)
    case feedbackPLI = 0x10  // Picture Loss Indication (запрос мгновенного IDR от ТВ к iPhone)
    case ping        = 0x11  // Запрос измерения RTT (отправитель -> получатель)
    case pong        = 0x12  // Ответ измерения RTT + статистика потерь (получатель -> отправитель)
    case streamStop  = 0xFF  // Штатная остановка трансляции
}

/// Тип аппаратного видеокодека
public enum VideoCodecType: UInt8, Sendable, CaseIterable {
    case h264 = 0x01
    case hevc = 0x02

    public var title: String {
        switch self {
        case .h264: return "H.264 (AVC) — мин. задержка"
        case .hevc: return "HEVC (H.265) — мин. битрейт"
        }
    }
}

// MARK: - 2. Бинарный заголовок пакета (24 байта, без аллокаций в куче)

/// Фиксированный 24-байтный заголовок пакета.
/// Сериализуется напрямую в `UnsafeMutableRawBufferPointer` без создания промежуточных объектов `Data`.
///
/// Раскладка байтов (Big-Endian):
/// [0]       : Magic Byte (0x4C = 'L')
/// [1]       : PacketType (UInt8)
/// [2]       : Flags: биты 0..3 = VideoCodecType, бит 7 (0x80) = isLastFragment
/// [3]       : ThermalLevel отправителя (0 = nominal .. 3 = critical)
/// [4..7]    : Sequence Number пакета (UInt32) — сквозной счётчик всех UDP-пакетов
/// [8..11]   : Frame Number (UInt32) — номер видеокадра или аудио-блока
/// [12..13]  : Fragment Index (UInt16) — индекс фрагмента внутри кадра (0 ..< fragmentCount)
/// [14..15]  : Fragment Count (UInt16) — общее количество фрагментов этого кадра
/// [16..23]  : Timestamp Us (UInt64) — монотонное время захвата в микросекундах
public struct StreamPacketHeader: Sendable {
    public static let magicByte: UInt8 = 0x4C

    public var packetType: PacketType
    public var codec: VideoCodecType
    public var isLastFragment: Bool
    public var thermalLevel: UInt8
    public var sequenceNumber: UInt32
    public var frameNumber: UInt32
    public var fragmentIndex: UInt16
    public var fragmentCount: UInt16
    public var timestampUs: UInt64

    public init(
        packetType: PacketType,
        codec: VideoCodecType = .h264,
        isLastFragment: Bool = true,
        thermalLevel: UInt8 = 0,
        sequenceNumber: UInt32,
        frameNumber: UInt32,
        fragmentIndex: UInt16 = 0,
        fragmentCount: UInt16 = 1,
        timestampUs: UInt64
    ) {
        self.packetType = packetType
        self.codec = codec
        self.isLastFragment = isLastFragment
        self.thermalLevel = thermalLevel
        self.sequenceNumber = sequenceNumber
        self.frameNumber = frameNumber
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.timestampUs = timestampUs
    }

    @inlinable
    public func write(to buffer: UnsafeMutableRawBufferPointer) {
        precondition(buffer.count >= StreamConfig.headerSize)
        buffer.storeBytes(of: Self.magicByte, toByteOffset: 0, as: UInt8.self)
        buffer.storeBytes(of: packetType.rawValue, toByteOffset: 1, as: UInt8.self)
        let flags: UInt8 = (codec.rawValue & 0x0F) | (isLastFragment ? 0x80 : 0x00)
        buffer.storeBytes(of: flags, toByteOffset: 2, as: UInt8.self)
        buffer.storeBytes(of: thermalLevel, toByteOffset: 3, as: UInt8.self)
        buffer.storeBytes(of: sequenceNumber.bigEndian, toByteOffset: 4, as: UInt32.self)
        buffer.storeBytes(of: frameNumber.bigEndian, toByteOffset: 8, as: UInt32.self)
        buffer.storeBytes(of: fragmentIndex.bigEndian, toByteOffset: 12, as: UInt16.self)
        buffer.storeBytes(of: fragmentCount.bigEndian, toByteOffset: 14, as: UInt16.self)
        buffer.storeBytes(of: timestampUs.bigEndian, toByteOffset: 16, as: UInt64.self)
    }

    @inlinable
    public static func read(from buffer: UnsafeRawBufferPointer) -> StreamPacketHeader? {
        guard buffer.count >= StreamConfig.headerSize else { return nil }
        guard buffer.load(fromByteOffset: 0, as: UInt8.self) == Self.magicByte else { return nil }
        guard let type = PacketType(rawValue: buffer.load(fromByteOffset: 1, as: UInt8.self)) else { return nil }

        let flags = buffer.load(fromByteOffset: 2, as: UInt8.self)
        let codec = VideoCodecType(rawValue: flags & 0x0F) ?? .h264
        let isLast = (flags & 0x80) != 0
        let thermal = buffer.load(fromByteOffset: 3, as: UInt8.self)

        let seq = UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        let frame = UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
        let fragIdx = UInt16(bigEndian: buffer.loadUnaligned(fromByteOffset: 12, as: UInt16.self))
        let fragCnt = UInt16(bigEndian: buffer.loadUnaligned(fromByteOffset: 14, as: UInt16.self))
        let ts = UInt64(bigEndian: buffer.loadUnaligned(fromByteOffset: 16, as: UInt64.self))

        return StreamPacketHeader(
            packetType: type,
            codec: codec,
            isLastFragment: isLast,
            thermalLevel: thermal,
            sequenceNumber: seq,
            frameNumber: frame,
            fragmentIndex: fragIdx,
            fragmentCount: fragCnt,
            timestampUs: ts
        )
    }
}

/// Полезная нагрузка пакета обратной связи Pong (18 байт)
public struct FeedbackPongPayload: Sendable {
    public static let size = 18

    public var originalPingTimestampUs: UInt64
    public var receivedPacketsCount: UInt32
    public var lostPacketsCount: UInt32
    public var decodedFPS: UInt16

    public init(originalPingTimestampUs: UInt64, receivedPacketsCount: UInt32, lostPacketsCount: UInt32, decodedFPS: UInt16) {
        self.originalPingTimestampUs = originalPingTimestampUs
        self.receivedPacketsCount = receivedPacketsCount
        self.lostPacketsCount = lostPacketsCount
        self.decodedFPS = decodedFPS
    }

    public func write(to buffer: UnsafeMutableRawBufferPointer) {
        precondition(buffer.count >= Self.size)
        buffer.storeBytes(of: originalPingTimestampUs.bigEndian, toByteOffset: 0, as: UInt64.self)
        buffer.storeBytes(of: receivedPacketsCount.bigEndian, toByteOffset: 8, as: UInt32.self)
        buffer.storeBytes(of: lostPacketsCount.bigEndian, toByteOffset: 12, as: UInt32.self)
        buffer.storeBytes(of: decodedFPS.bigEndian, toByteOffset: 16, as: UInt16.self)
    }

    public static func read(from buffer: UnsafeRawBufferPointer) -> FeedbackPongPayload? {
        guard buffer.count >= Self.size else { return nil }
        return FeedbackPongPayload(
            originalPingTimestampUs: UInt64(bigEndian: buffer.loadUnaligned(fromByteOffset: 0, as: UInt64.self)),
            receivedPacketsCount: UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
            lostPacketsCount: UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: 12, as: UInt32.self)),
            decodedFPS: UInt16(bigEndian: buffer.loadUnaligned(fromByteOffset: 16, as: UInt16.self))
        )
    }
}

// MARK: - 3. Монотонные часы высокой точности (mach_absolute_time)

public enum MonotonicClock {
    private static let timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    @inlinable
    public static func nowMicroseconds() -> UInt64 {
        let ticks = mach_absolute_time()
        let nanos = (ticks &* UInt64(timebaseInfo.numer)) / UInt64(timebaseInfo.denom)
        return nanos / 1_000
    }
}

// MARK: - 4. Кольцевой пул буферов (Zero-Allocation в горячем пути отправки)

/// Кольцевой пул предварительно выделенных буферов для сборки UDP-дейтаграмм.
/// Исключает вызовы `malloc`/`free` при нарезке 60 кадров/с и удерживает память Extension < 20 МБ.
public final class DatagramBufferPool: @unchecked Sendable {
    private let capacity: Int
    private var buffers: [UnsafeMutableRawBufferPointer] = []
    private var index: Int = 0
    private var lock = os_unfair_lock_s()

    public init(poolSizePowerOfTwo: Int = 256, datagramSize: Int = StreamConfig.maxDatagramSize) {
        precondition(poolSizePowerOfTwo > 0 && (poolSizePowerOfTwo & (poolSizePowerOfTwo - 1)) == 0)
        self.capacity = poolSizePowerOfTwo
        self.buffers.reserveCapacity(poolSizePowerOfTwo)
        for _ in 0..<poolSizePowerOfTwo {
            let ptr = UnsafeMutableRawBufferPointer.allocate(
                byteCount: datagramSize,
                alignment: MemoryLayout<UInt64>.alignment
            )
            buffers.append(ptr)
        }
    }

    deinit {
        for ptr in buffers {
            ptr.deallocate()
        }
    }

    @inlinable
    public func withNextBuffer<R>(_ body: (UnsafeMutableRawBufferPointer) -> R) -> R {
        os_unfair_lock_lock(&lock)
        let buf = buffers[index]
        index = (index + 1) & (capacity - 1)
        os_unfair_lock_unlock(&lock)
        return body(buf)
    }
}

// MARK: - 5. Контроллер адаптивного битрейта, разрешения и FPS (ABR)

public struct EncodingProfile: Equatable, Sendable {
    public var width: Int32
    public var height: Int32
    public var targetFPS: Int32
    public var bitrateBps: Int32

    public static let fullHD60 = EncodingProfile(width: 1920, height: 1080, targetFPS: 60, bitrateBps: 16_000_000)
    public static let hd900p50 = EncodingProfile(width: 1600, height: 900,  targetFPS: 50, bitrateBps: 9_000_000)
    public static let hd720p45 = EncodingProfile(width: 1280, height: 720,  targetFPS: 45, bitrateBps: 5_500_000)
}

/// Управляет параметрами VideoToolbox в реальном времени на основе:
/// 1) Сглаженного RTT (круговой задержки в локальной сети)
/// 2) Процента потерянных пакетов
/// 3) Теплового состояния iPhone (`ProcessInfo.ThermalState`)
public final class AdaptiveBitrateController: @unchecked Sendable {
    public private(set) var currentProfile: EncodingProfile = .fullHD60
    public private(set) var smoothedRTTMs: Double = 6.0
    public private(set) var packetLossRatio: Double = 0.0

    private let minBitrateBps: Int32 = 3_500_000   // 3.5 Мбит/с
    private let maxBitrateBps: Int32 = 22_000_000  // 22 Мбит/с
    private var lastAdjustmentUs: UInt64 = 0

    public init() {}

    public func evaluate(
        rttMs: Double,
        lossRatio: Double,
        thermalState: ProcessInfo.ThermalState
    ) -> EncodingProfile? {
        smoothedRTTMs = smoothedRTTMs * 0.75 + rttMs * 0.25
        packetLossRatio = lossRatio

        let now = MonotonicClock.nowMicroseconds()
        // Не меняем профиль чаще раза в 800 мс, чтобы избежать дребезга кодера
        guard now - lastAdjustmentUs >= 800_000 else { return nil }
        lastAdjustmentUs = now

        var next = currentProfile

        // 1. Учёт нагрева устройства (Thermal Throttling)
        switch thermalState {
        case .critical, .serious:
            next.width = 1280
            next.height = 720
            next.targetFPS = 40
            next.bitrateBps = min(next.bitrateBps, 6_000_000)
        case .fair:
            next.targetFPS = min(next.targetFPS, 48)
            next.bitrateBps = min(next.bitrateBps, 12_000_000)
        case .nominal:
            next.targetFPS = 60
        @unknown default:
            break
        }

        // 2. Алгоритм AIMD по потерям и RTT
        if lossRatio > 0.025 || smoothedRTTMs > 40.0 {
            // Мультипликативное снижение битрейта на 25% при перегрузке Wi-Fi эфира
            next.bitrateBps = max(minBitrateBps, Int32(Double(next.bitrateBps) * 0.75))
            if next.bitrateBps < 7_000_000 {
                next.width = 1280
                next.height = 720
                next.targetFPS = max(40, min(next.targetFPS, 45))
            } else if next.bitrateBps < 11_000_000 {
                next.width = 1600
                next.height = 900
                next.targetFPS = max(45, min(next.targetFPS, 50))
            }
        } else if lossRatio < 0.004 && smoothedRTTMs < 16.0 && thermalState == .nominal {
            // Аддитивное повышение битрейта на +1.2 Мбит/с при чистом радиоканале
            next.bitrateBps = min(maxBitrateBps, next.bitrateBps + 1_200_000)
            if next.bitrateBps >= 11_500_000 {
                next.width = 1920
                next.height = 1080
                next.targetFPS = 60
            }
        }

        if next != currentProfile {
            currentProfile = next
            return next
        }
        return nil
    }
}

// MARK: - 6. Обнаружение телевизоров через Bonjour/mDNS

public struct DiscoveredTVReceiver: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint

    public init(name: String, endpoint: NWEndpoint) {
        self.id = "\(name)|\(endpoint)"
        self.name = name
        self.endpoint = endpoint
    }
}

@MainActor
public final class BonjourReceiverBrowser: ObservableObject {
    @Published public private(set) var receivers: [DiscoveredTVReceiver] = []
    @Published public private(set) var isSearching: Bool = false

    private var browser: NWBrowser?
    private let browserQueue = DispatchQueue(label: "com.llmirror.bonjour.browser", qos: .userInitiated)

    public init() {}

    public func start() {
        stop()
        let params = NWParameters()
        params.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: StreamConfig.bonjourServiceType, domain: "local.")
        let nwBrowser = NWBrowser(for: descriptor, using: params)

        nwBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.isSearching = (state == .ready)
            }
        }

        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            let list: [DiscoveredTVReceiver] = results.compactMap { res in
                if case let .service(name, _, _, _) = res.endpoint {
                    return DiscoveredTVReceiver(name: name, endpoint: res.endpoint)
                }
                return nil
            }
            Task { @MainActor in
                self?.receivers = list
            }
        }

        self.browser = nwBrowser
        nwBrowser.start(queue: browserQueue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }
}

// MARK: - 7. Высокоприоритетный UDP-транспорт отправителя (SenderUDPTransport)

public protocol SenderTransportDelegate: AnyObject, Sendable {
    /// Приёмник сообщил о потере фрагмента (PLI) — кодер должен немедленно выдать IDR-кадр
    func transportDidRequestKeyframe()
    /// Обновлены сетевые метрики по результатам Ping/Pong
    func transportDidUpdateMetrics(rttMs: Double, lossRatio: Double, receiverFPS: UInt16)
    /// Изменился статус UDP-канала
    func transportDidChangeState(isReady: Bool, errorDescription: String?)
}

/// Отвечает за отправку фрагментированных видео/аудио пакетов по UDP с минимальной задержкой.
/// Использует выделенную очередь `QoS.userInteractive` и маркировку трафика `NWParameters.ServiceClass.interactiveVideo` (DSCP CS4/AF41).
public final class SenderUDPTransport: @unchecked Sendable {
    public weak var delegate: SenderTransportDelegate?

    private let transportQueue = DispatchQueue(
        label: "com.llmirror.sender.udp",
        qos: .userInteractive,
        attributes: [],
        autoreleaseFrequency: .workItem
    )

    private var connection: NWConnection?
    private let bufferPool = DatagramBufferPool(poolSizePowerOfTwo: 256)
    private var sequenceNumber: UInt32 = 0
    private var pingTimer: DispatchSourceTimer?
    private var prevReceivedPackets: UInt32 = 0
    private var prevLostPackets: UInt32 = 0
    private let logger = Logger(subsystem: "com.llmirror.sender", category: "UDPTransport")

    public init() {}

    /// Конфигурация UDP без буферизации с приоритетом WMM Video Queue (DSCP CS4)
    public static func makeLowLatencyUDPParameters() -> NWParameters {
        let udpOptions = NWProtocolUDP.Options()
        let params = NWParameters(dtls: nil, udp: udpOptions)
        // КРИТИЧНО: переводит пакеты в аппаратную очередь WMM Video (VI) на Wi-Fi роутере
        params.serviceClass = .interactiveVideo
        // Запрещаем выход в сотовую сеть, работаем строго в локальной сети
        params.prohibitedInterfaceTypes = [.cellular]
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        return params
    }

    public func connect(to endpoint: NWEndpoint) {
        disconnect()
        let conn = NWConnection(to: endpoint, using: Self.makeLowLatencyUDPParameters())
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.logger.info("UDP-канал установлен")
                self.receiveFeedbackLoop()
                self.startPingTimer()
                self.delegate?.transportDidChangeState(isReady: true, errorDescription: nil)
            case .failed(let err):
                self.logger.error("Обрыв UDP-канала: \(err.localizedDescription)")
                self.delegate?.transportDidChangeState(isReady: false, errorDescription: err.localizedDescription)
            case .cancelled:
                self.delegate?.transportDidChangeState(isReady: false, errorDescription: nil)
            default:
                break
            }
        }

        conn.start(queue: transportQueue)
    }

    public func connect(host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: nwPort))
    }

    public func disconnect() {
        pingTimer?.cancel()
        pingTimer = nil
        if let conn = connection {
            // Отправляем пакет уведомления об остановке потока
            var stopBuf = [UInt8](repeating: 0, count: StreamConfig.headerSize)
            stopBuf.withUnsafeMutableBytes { raw in
                let hdr = StreamPacketHeader(
                    packetType: .streamStop,
                    sequenceNumber: sequenceNumber &+ 1,
                    frameNumber: 0,
                    timestampUs: MonotonicClock.nowMicroseconds()
                )
                hdr.write(to: raw)
            }
            conn.send(content: Data(stopBuf), completion: .idempotent)
            conn.cancel()
        }
        connection = nil
    }

    /// Фрагментация и пакетная (`NWConnection.batch`) отправка кадра без лишних копий
    public func sendFrame(
        payload: UnsafeRawBufferPointer,
        packetType: PacketType,
        codec: VideoCodecType,
        frameNumber: UInt32,
        timestampUs: UInt64,
        thermalLevel: UInt8
    ) {
        guard let conn = connection, payload.count > 0 else { return }

        let totalBytes = payload.count
        let maxChunk = StreamConfig.maxPayloadSize
        let fragmentCount = UInt16((totalBytes + maxChunk - 1) / maxChunk)

        // NWConnection.batch объединяет отправку всех UDP-дейтаграмм одного кадра в один системный цикл ядра
        conn.batch {
            var offset = 0
            var fragIdx: UInt16 = 0

            while offset < totalBytes {
                let chunkLen = min(maxChunk, totalBytes - offset)
                let isLast = (offset + chunkLen) >= totalBytes
                sequenceNumber &+= 1
                let seq = sequenceNumber

                let packetData: Data = bufferPool.withNextBuffer { rawBuf in
                    let header = StreamPacketHeader(
                        packetType: packetType,
                        codec: codec,
                        isLastFragment: isLast,
                        thermalLevel: thermalLevel,
                        sequenceNumber: seq,
                        frameNumber: frameNumber,
                        fragmentIndex: fragIdx,
                        fragmentCount: fragmentCount,
                        timestampUs: timestampUs
                    )
                    header.write(to: rawBuf)

                    if let dstBase = rawBuf.baseAddress, let srcBase = payload.baseAddress {
                        memcpy(
                            dstBase.advanced(by: StreamConfig.headerSize),
                            srcBase.advanced(by: offset),
                            chunkLen
                        )
                    }
                    return Data(bytes: rawBuf.baseAddress!, count: StreamConfig.headerSize + chunkLen)
                }

                conn.send(content: packetData, completion: .idempotent)
                offset += chunkLen
                fragIdx &+= 1
            }
        }
    }

    private func receiveFeedbackLoop() {
        guard let conn = connection else { return }
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, data.count >= StreamConfig.headerSize {
                data.withUnsafeBytes { raw in
                    guard let header = StreamPacketHeader.read(from: raw) else { return }
                    switch header.packetType {
                    case .feedbackPLI:
                        self.delegate?.transportDidRequestKeyframe()
                    case .pong:
                        let body = UnsafeRawBufferPointer(rebasing: raw.dropFirst(StreamConfig.headerSize))
                        if let pong = FeedbackPongPayload.read(from: body) {
                            let nowUs = MonotonicClock.nowMicroseconds()
                            let rttUs = nowUs > pong.originalPingTimestampUs ? (nowUs - pong.originalPingTimestampUs) : 0
                            let rttMs = Double(rttUs) / 1000.0

                            let dRecv = pong.receivedPacketsCount &- self.prevReceivedPackets
                            let dLost = pong.lostPacketsCount &- self.prevLostPackets
                            self.prevReceivedPackets = pong.receivedPacketsCount
                            self.prevLostPackets = pong.lostPacketsCount

                            let total = dRecv &+ dLost
                            let loss = total > 0 ? (Double(dLost) / Double(total)) : 0.0
                            self.delegate?.transportDidUpdateMetrics(
                                rttMs: rttMs,
                                lossRatio: loss,
                                receiverFPS: pong.decodedFPS
                            )
                        }
                    default:
                        break
                    }
                }
            }
            if error == nil {
                self.receiveFeedbackLoop()
            }
        }
    }

    private func startPingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: transportQueue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, let conn = self.connection else { return }
            self.sequenceNumber &+= 1
            var buf = [UInt8](repeating: 0, count: StreamConfig.headerSize)
            buf.withUnsafeMutableBytes { raw in
                let hdr = StreamPacketHeader(
                    packetType: .ping,
                    sequenceNumber: self.sequenceNumber,
                    frameNumber: 0,
                    timestampUs: MonotonicClock.nowMicroseconds()
                )
                hdr.write(to: raw)
            }
            conn.send(content: Data(buf), completion: .idempotent)
        }
        self.pingTimer = timer
        timer.resume()
    }
}
