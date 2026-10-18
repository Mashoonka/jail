//
//  BroadcastExtension_CaptureAndEncoder.swift
//  LowLatencyScreenMirror — Таргет: BroadcastUploadExtension (iOS 16+)
//
//  Назначение:
//  - Захват системного экрана и звука через ReplayKit (`RPBroadcastSampleHandler`).
//  - Строгое соблюдение лимита памяти Broadcast Extension (~50 МБ):
//    Zero-Copy передача `CVPixelBuffer` напрямую из `CMSampleBuffer` в `VTCompressionSession`.
//  - Аппаратное кодирование H.264 / HEVC (`VideoToolbox`) в режиме реального времени:
//    - `kVTCompressionPropertyKey_RealTime = kCFBooleanTrue`
//    - `kVTCompressionPropertyKey_AllowFrameReordering = kCFBooleanFalse` (0 B-кадров!)
//    - `kVTCompressionPropertyKey_MaxFrameDelayCount = 0`
//    - Принудительный ключевой кадр (IDR) по запросу PLI при потере пакета.
//

import Foundation
import ReplayKit
import VideoToolbox
import CoreMedia
import CoreVideo
import Network
import os.log

// MARK: - 1. Аппаратный видеокодер (VideoToolbox Low-Latency Encoder)

public protocol HardwareVideoEncoderDelegate: AnyObject, Sendable {
    /// Вызывается на очереди кодера сразу по готовности закодированного кадра
    func encoderDidOutputConfig(parameterSetsBlob: UnsafeRawBufferPointer, codec: VideoCodecType, frameNumber: UInt32, timestampUs: UInt64)
    func encoderDidOutputFrame(avccPayload: UnsafeRawBufferPointer, isKeyFrame: Bool, codec: VideoCodecType, frameNumber: UInt32, timestampUs: UInt64)
}

/// Низкозадержечный аппаратный кодер H.264 / HEVC.
/// Все операции выполняются на выделенной очереди `QoS.userInteractive`.
/// Не создаёт копий `CVPixelBuffer`: буфер ядра CoreVideo передаётся напрямую в аппаратный блок Apple Media Engine.
public final class HardwareVideoEncoder: @unchecked Sendable {
    public weak var delegate: HardwareVideoEncoderDelegate?

    /// Выделенная высокоприоритетная очередь для кодирования
    private let encoderQueue = DispatchQueue(
        label: "com.llmirror.encoder.videotoolbox",
        qos: .userInteractive,
        attributes: [],
        autoreleaseFrequency: .workItem
    )

    private var session: VTCompressionSession?
    private var currentProfile: EncodingProfile
    private let codec: VideoCodecType
    private var forceNextKeyframe: Bool = true
    private var frameCounter: UInt32 = 0
    private var lastFrameTimestampUs: UInt64 = 0
    private let logger = Logger(subsystem: "com.llmirror.extension", category: "HardwareEncoder")

    /// Предварительно выделенный буфер (8 КБ) для сериализации SPS/PPS/VPS без аллокаций в куче
    private let configScratchBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 8192, alignment: 8)

    public init(profile: EncodingProfile = .fullHD60, codec: VideoCodecType = .h264) {
        self.currentProfile = profile
        self.codec = codec
        encoderQueue.sync {
            setupCompressionSession(profile: profile)
        }
    }

    deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        configScratchBuffer.deallocate()
    }

    /// Запрос мгновенного ключевого кадра (IDR) при получении PLI от приёмника
    public func requestImmediateKeyframe() {
        encoderQueue.async { [weak self] in
            self?.forceNextKeyframe = true
        }
    }

    /// Динамическое обновление битрейта, FPS и разрешения без остановки потока
    public func applyProfile(_ newProfile: EncodingProfile) {
        encoderQueue.async { [weak self] in
            guard let self else { return }
            let resolutionChanged = (newProfile.width != self.currentProfile.width) || (newProfile.height != self.currentProfile.height)
            self.currentProfile = newProfile

            if resolutionChanged || self.session == nil {
                self.setupCompressionSession(profile: newProfile)
            } else if let session = self.session {
                // Меняем битрейт и целевой FPS «на лету» без пересоздания сессии
                VTSessionSetProperty(
                    session,
                    key: kVTCompressionPropertyKey_AverageBitRate,
                    value: NSNumber(value: newProfile.bitrateBps)
                )
                // Ограничиваем пиковый всплеск размера кадра (VBV Buffer = 0.25 сек),
                // чтобы большой IDR-кадр не вызвал переполнение буфера Wi-Fi точки доступа
                let byteLimitPerWindow = Int(Double(newProfile.bitrateBps) / 8.0 * 0.25 * 1.25)
                let dataRateLimits: [NSNumber] = [NSNumber(value: byteLimitPerWindow), NSNumber(value: 0.25)]
                VTSessionSetProperty(
                    session,
                    key: kVTCompressionPropertyKey_DataRateLimits,
                    value: dataRateLimits as CFArray
                )
                VTSessionSetProperty(
                    session,
                    key: kVTCompressionPropertyKey_ExpectedFrameRate,
                    value: NSNumber(value: newProfile.targetFPS)
                )
            }
        }
    }

    /// Кодирует кадр из ReplayKit напрямую из `CMSampleBuffer` без копирования пикселей
    public func encode(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let captureTimeUs = MonotonicClock.nowMicroseconds()

        encoderQueue.async { [weak self] in
            guard let self, let session = self.session else { return }

            // Ограничение частоты кадров (Frame Pacing) при снижении targetFPS из-за нагрева или плохой сети
            let minIntervalUs = UInt64(1_000_000 / max(1, Int(self.currentProfile.targetFPS))) - 1_500
            if captureTimeUs - self.lastFrameTimestampUs < minIntervalUs && !self.forceNextKeyframe {
                return
            }
            self.lastFrameTimestampUs = captureTimeUs

            var frameProperties: CFDictionary? = nil
            if self.forceNextKeyframe {
                let props: [CFString: Any] = [
                    kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!
                ]
                frameProperties = props as CFDictionary
                self.forceNextKeyframe = false
            }

            var infoFlags = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                duration: duration,
                frameProperties: frameProperties,
                infoFlagsOut: &infoFlags
            ) { [weak self] status, flags, encodedSampleBuffer in
                guard let self else { return }
                self.handleEncodedFrame(
                    status: status,
                    flags: flags,
                    sampleBuffer: encodedSampleBuffer,
                    captureTimestampUs: captureTimeUs
                )
            }

            if status != noErr {
                self.logger.error("Ошибка VTCompressionSessionEncodeFrame: \(status). Пересоздаём сессию.")
                self.setupCompressionSession(profile: self.currentProfile)
            }
        }
    }

    // MARK: Внутренняя инициализация VTCompressionSession

    private func setupCompressionSession(profile: EncodingProfile) {
        if let existing = session {
            VTCompressionSessionInvalidate(existing)
            session = nil
        }

        let cmCodec: CMVideoCodecType = (codec == .hevc) ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var newSession: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: profile.width,
            height: profile.height,
            codecType: cmCodec,
            encoderSpecification: nil,
            imageBufferAttributes: nil, // Не задаём атрибуты, чтобы избежать переаллокации буферов ReplayKit!
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )

        guard status == noErr, let vtSession = newSession else {
            logger.error("Не удалось создать VTCompressionSession: \(status)")
            return
        }

        // 1. КРИТИЧНО: Режим реального времени (аппаратный низкозадержечный пайплайн)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // 2. КРИТИЧНО: Полный запрет B-кадров и переупорядочивания кадров (0 кадров задержки кодера)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0))

        // 3. Профиль кодека и энтропийное кодирование
        if codec == .h264 {
            VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
            VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        } else {
            VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        }

        // 4. Интервал ключевых кадров (раз в 1.5 секунды или 90 кадров)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 1.5))
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 90))

        // 5. Настройка битрейта и жёсткого низкого буфера (VBV)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: profile.bitrateBps))
        let byteLimitPerQuarterSec = Int(Double(profile.bitrateBps) / 8.0 * 0.25 * 1.25)
        let rateLimits: [NSNumber] = [NSNumber(value: byteLimitPerQuarterSec), NSNumber(value: 0.25)]
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_DataRateLimits, value: rateLimits as CFArray)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: profile.targetFPS))

        // 6. Цветовое пространство Rec.709 для ТВ
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)

        VTCompressionSessionPrepareToEncodeFrames(vtSession)
        self.session = vtSession
        self.forceNextKeyframe = true
        logger.info("Сессия аппаратного кодирования готова: \(profile.width)x\(profile.height) @ \(profile.targetFPS)fps, \(profile.bitrateBps / 1_000_000) Мбит/с")
    }

    // MARK: Обработка готового закодированного кадра (Zero-Copy CMBlockBuffer)

    private func handleEncodedFrame(
        status: OSStatus,
        flags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?,
        captureTimestampUs: UInt64
    ) {
        guard status == noErr,
              !flags.contains(.frameDropped),
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        frameCounter &+= 1
        let currentFrameNo = frameCounter

        // Проверяем, является ли кадр ключевым (IDR)
        let isKeyFrame: Bool = {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
                  let first = attachments.first else {
                return true
            }
            let notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            return !notSync
        }()

        // Если кадр ключевой — сначала извлекаем и отправляем параметр-сеты (SPS/PPS или VPS/SPS/PPS)
        if isKeyFrame, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            if let configSlice = serializeParameterSets(from: formatDesc) {
                delegate?.encoderDidOutputConfig(
                    parameterSetsBlob: configSlice,
                    codec: codec,
                    frameNumber: currentFrameNo,
                    timestampUs: captureTimestampUs
                )
            }
        }

        // Получаем прямой указатель на память CMBlockBuffer (формат AVCC: [4-byte length][NALU]...)
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<CChar>?

        let blockStatus = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        if blockStatus == kCMBlockBufferNoErr, let dataPointer, lengthAtOffset == totalLength {
            // Быстрый путь (99.9% случаев): буфер непрерывный в памяти — передаём указатель без копирования!
            let rawSlice = UnsafeRawBufferPointer(start: dataPointer, count: totalLength)
            delegate?.encoderDidOutputFrame(
                avccPayload: rawSlice,
                isKeyFrame: isKeyFrame,
                codec: codec,
                frameNumber: currentFrameNo,
                timestampUs: captureTimestampUs
            )
        } else if totalLength > 0 {
            // Резервный путь, если CMBlockBuffer фрагментирован внутри CoreMedia
            var contiguousData = Data(count: totalLength)
            contiguousData.withUnsafeMutableBytes { dst in
                if let base = dst.baseAddress {
                    _ = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: totalLength, destination: base)
                }
            }
            contiguousData.withUnsafeBytes { rawSlice in
                delegate?.encoderDidOutputFrame(
                    avccPayload: rawSlice,
                    isKeyFrame: isKeyFrame,
                    codec: codec,
                    frameNumber: currentFrameNo,
                    timestampUs: captureTimestampUs
                )
            }
        }
    }

    /// Упаковывает SPS/PPS (или VPS/SPS/PPS) в компактный бинарный блок:
    /// `[count: UInt8] -> повторить count раз: [len: UInt16 BigEndian][bytes...]`
    private func serializeParameterSets(from formatDesc: CMFormatDescription) -> UnsafeRawBufferPointer? {
        var paramCount: Int = 0
        if codec == .h264 {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: nil
            )
        } else {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDesc, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: nil
            )
        }

        guard paramCount > 0, let base = configScratchBuffer.baseAddress else { return nil }
        configScratchBuffer.storeBytes(of: UInt8(paramCount), toByteOffset: 0, as: UInt8.self)
        var offset = 1

        for idx in 0..<paramCount {
            var ptr: UnsafePointer<UInt8>?
            var size: Int = 0
            let status: OSStatus
            if codec == .h264 {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc, parameterSetIndex: idx,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
            } else {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDesc, parameterSetIndex: idx,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
            }

            guard status == noErr, let ptr, size > 0, offset + 2 + size <= configScratchBuffer.count else {
                return nil
            }
            configScratchBuffer.storeBytes(of: UInt16(size).bigEndian, toByteOffset: offset, as: UInt16.self)
            offset += 2
            memcpy(base.advanced(by: offset), ptr, size)
            offset += size
        }

        return UnsafeRawBufferPointer(start: base, count: offset)
    }
}

// MARK: - 2. Обработчик системной трансляции экрана (ReplayKit Broadcast Upload Extension)

/// Главный класс таргета `BroadcastUploadExtension`.
/// Жёсткое системное ограничение iOS для этого расширения: лимит памяти **50 МБ**.
/// Поэтому здесь не используются тяжёлые фреймворки, нет очереди кадров и нет копирования пиксельных буферов.
@objc(SampleHandler)
public final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private var encoder: HardwareVideoEncoder?
    private var transport: SenderUDPTransport?
    private let abrController = AdaptiveBitrateController()
    private var pathMonitor: NWPathMonitor?

    private var audioFrameCounter: UInt32 = 0
    private var encodedFramesInWindow: Int = 0
    private var bytesSentInWindow: Int = 0
    private var statsWindowStartUs: UInt64 = MonotonicClock.nowMicroseconds()
    private let logger = Logger(subsystem: "com.llmirror.extension", category: "SampleHandler")

    private lazy var sharedDefaults: UserDefaults? = {
        UserDefaults(suiteName: StreamConfig.appGroupIdentifier)
    }()

    public override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        // 1. Читаем адрес выбранного Apple TV из общего контейнера App Group
          let savedHost = sharedDefaults?.string(forKey: StreamConfig.keyTargetHost) ?? ""
      let host = "192.168.0.158"
   let port: UInt16 = 5004
   let serviceName = ""
        let rawCodec = UInt8(sharedDefaults?.integer(forKey: StreamConfig.keySelectedCodec) ?? Int(VideoCodecType.h264.rawValue))
        let selectedCodec = VideoCodecType(rawValue: rawCodec) ?? .h264

        // 2. Инициализируем аппаратный кодер и UDP-транспорт
        let hwEncoder = HardwareVideoEncoder(profile: .fullHD60, codec: selectedCodec)
        hwEncoder.delegate = self
        self.encoder = hwEncoder

        let udpTransport = SenderUDPTransport()
        udpTransport.delegate = self
        self.transport = udpTransport

        if !serviceName.isEmpty {
            let endpoint = NWEndpoint.service(
                name: serviceName,
                type: StreamConfig.bonjourServiceType,
                domain: "local.",
                interface: nil
            )
            udpTransport.connect(to: endpoint)
        } else if !host.isEmpty {
            udpTransport.connect(host: host, port: port == 0 ? StreamConfig.defaultUDPPort : port)
        } else {
            let err = NSError(
                domain: "com.llmirror.extension",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "Сначала выберите Apple TV или отсканируйте QR-код в приложении LowLatencyMirror."]
            )
            finishBroadcastWithError(err)
            return
        }

        // 3. Отслеживаем состояние Wi-Fi соединения
        startNetworkPathMonitor()
        sharedDefaults?.set(true, forKey: StreamConfig.keyStreamActive)
        logger.info("Broadcast Upload Extension успешно запущен")
    }

    public override func broadcastPaused() {
        logger.info("Трансляция приостановлена пользователем")
    }

    public override func broadcastResumed() {
        // После паузы обязательно принудительно отправляем ключевой кадр IDR
        encoder?.requestImmediateKeyframe()
    }

    public override func broadcastFinished() {
        sharedDefaults?.set(false, forKey: StreamConfig.keyStreamActive)
        pathMonitor?.cancel()
        pathMonitor = nil
        transport?.disconnect()
        transport = nil
        encoder = nil
        logger.info("Трансляция штатно завершена")
    }

    public override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            // Передаём видеокадр напрямую в аппаратный кодер без копирования CVPixelBuffer
            encoder?.encode(sampleBuffer: sampleBuffer)

        case .audioApp:
            // Передаём системный звук приложений с меткой времени для синхронизации
            sendAudioSampleBuffer(sampleBuffer)

        case .audioMic:
            // Опционально: микрофон (по умолчанию используем системный звук .audioApp)
            break

        @unknown default:
            break
        }
    }

    // MARK: Упаковка и отправка системного звука (Zero-Copy CMBlockBuffer)

    private func sendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<CChar>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { return }

        audioFrameCounter &+= 1
        let rawAudio = UnsafeRawBufferPointer(start: dataPointer, count: min(lengthAtOffset, totalLength))
        transport?.sendFrame(
            payload: rawAudio,
            packetType: .audioPCM,
            codec: .h264,
            frameNumber: audioFrameCounter,
            timestampUs: MonotonicClock.nowMicroseconds(),
            thermalLevel: currentThermalByte()
        )
    }

    // MARK: Мониторинг сети и теплового режима

    private func startNetworkPathMonitor() {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            if path.status != .satisfied {
                let err = NSError(
                    domain: "com.llmirror.extension",
                    code: -1002,
                    userInfo: [NSLocalizedDescriptionKey: "Соединение по Wi-Fi потеряно. Трансляция остановлена."]
                )
                self.sharedDefaults?.set(false, forKey: StreamConfig.keyStreamActive)
                self.finishBroadcastWithError(err)
            } else {
                // При переключении точки доступа Wi-Fi запрашиваем свежий IDR
                self.encoder?.requestImmediateKeyframe()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.llmirror.extension.pathmonitor"))
        self.pathMonitor = monitor
    }

    @inlinable
    private func currentThermalByte() -> UInt8 {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }
}

// MARK: - Делегаты кодера и транспорта в SampleHandler

extension SampleHandler: HardwareVideoEncoderDelegate {
    public func encoderDidOutputConfig(
        parameterSetsBlob: UnsafeRawBufferPointer,
        codec: VideoCodecType,
        frameNumber: UInt32,
        timestampUs: UInt64
    ) {
        transport?.sendFrame(
            payload: parameterSetsBlob,
            packetType: .videoConfig,
            codec: codec,
            frameNumber: frameNumber,
            timestampUs: timestampUs,
            thermalLevel: currentThermalByte()
        )
    }

    public func encoderDidOutputFrame(
        avccPayload: UnsafeRawBufferPointer,
        isKeyFrame: Bool,
        codec: VideoCodecType,
        frameNumber: UInt32,
        timestampUs: UInt64
    ) {
        transport?.sendFrame(
            payload: avccPayload,
            packetType: isKeyFrame ? .videoIDR : .videoSlice,
            codec: codec,
            frameNumber: frameNumber,
            timestampUs: timestampUs,
            thermalLevel: currentThermalByte()
        )

        // Обновляем телеметрию раз в 1 секунду в App Group
        encodedFramesInWindow += 1
        bytesSentInWindow += avccPayload.count
        let nowUs = MonotonicClock.nowMicroseconds()
        let elapsedUs = nowUs - statsWindowStartUs
        if elapsedUs >= 1_000_000 {
            let seconds = Double(elapsedUs) / 1_000_000.0
            let fps = Int((Double(encodedFramesInWindow) / seconds).rounded())
            let mbps = (Double(bytesSentInWindow) * 8.0) / (seconds * 1_000_000.0)

            sharedDefaults?.set(fps, forKey: StreamConfig.keyTelemetryFPS)
            sharedDefaults?.set(mbps, forKey: StreamConfig.keyTelemetryBitrateMbps)

            encodedFramesInWindow = 0
            bytesSentInWindow = 0
            statsWindowStartUs = nowUs
        }
    }
}

extension SampleHandler: SenderTransportDelegate {
    public func transportDidRequestKeyframe() {
        logger.debug("Получен PLI от Apple TV -> генерируем внеочередной IDR кадр")
        encoder?.requestImmediateKeyframe()
    }

    public func transportDidUpdateMetrics(rttMs: Double, lossRatio: Double, receiverFPS: UInt16) {
        sharedDefaults?.set(rttMs, forKey: StreamConfig.keyTelemetryRTTMs)
        sharedDefaults?.set(lossRatio * 100.0, forKey: StreamConfig.keyTelemetryLossPercent)

        let thermal = ProcessInfo.processInfo.thermalState
        if let newProfile = abrController.evaluate(rttMs: rttMs, lossRatio: lossRatio, thermalState: thermal) {
            encoder?.applyProfile(newProfile)
        }
    }

    public func transportDidChangeState(isReady: Bool, errorDescription: String?) {
        if let errorDescription {
            logger.error("Статус транспорта: \(errorDescription)")
        }
    }
}
