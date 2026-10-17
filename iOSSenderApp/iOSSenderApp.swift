//
//  iOSSenderApp.swift
//  LowLatencyScreenMirror — Таргет: iOSSenderApp (iOS 16+)
//
//  Назначение:
//  - Главное приложение-отправитель на iPhone.
//  - Автоматическое обнаружение Apple TV в локальной сети через Bonjour (`_llmirror._udp`).
//  - Подключение в 1 тап или по IP / QR-коду.
//  - Интеграция системной кнопки запуска трансляции `RPSystemBroadcastPickerView`.
//  - Живой дашборд телеметрии (FPS, битрейт, RTT, потери пакетов, тепловой статус).
//

import SwiftUI
import ReplayKit
import AVFoundation

// MARK: - 1. Обёртка над системным RPSystemBroadcastPickerView

/// На iOS системную трансляцию всего экрана (`Broadcast Upload Extension`) можно запустить
/// ТОЛЬКО через системный пикер `RPSystemBroadcastPickerView`.
/// Эта обёртка встраивает системный триггер в кастомную кнопку SwiftUI.
public struct SystemBroadcastPickerButton: UIViewRepresentable {
    /// Bundle Identifier таргета Broadcast Upload Extension
    public let extensionBundleIdentifier: String

    public init(extensionBundleIdentifier: String = "com.example.lowlatencymirror.BroadcastExtension") {
        self.extensionBundleIdentifier = extensionBundleIdentifier
    }

    public func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        picker.preferredExtension = extensionBundleIdentifier
        picker.showsMicrophoneButton = false
        return picker
    }

    public func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = extensionBundleIdentifier
    }
}

// MARK: - 2. ViewModel отправителя (связь с App Group и мониторинг телеметрии)

@MainActor
public final class SenderDashboardViewModel: ObservableObject {
    @Published public var selectedReceiverName: String = "Не выбран"
    @Published public var manualIPAddress: String = ""
    @Published public var manualPort: String = "5004"
    @Published public var selectedCodec: VideoCodecType = .h264 {
        didSet {
            sharedDefaults?.set(Int(selectedCodec.rawValue), forKey: StreamConfig.keySelectedCodec)
        }
    }

    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var currentFPS: Int = 0
    @Published public private(set) var currentBitrateMbps: Double = 0.0
    @Published public private(set) var currentRTTMs: Double = 0.0
    @Published public private(set) var currentLossPercent: Double = 0.0
    @Published public private(set) var thermalStateText: String = "Норма (Nominal)"

    private let sharedDefaults = UserDefaults(suiteName: StreamConfig.appGroupIdentifier)
    private var telemetryTimer: Timer?

    public init() {
        loadSavedSettings()
        startTelemetryPolling()
    }

    public func selectBonjourReceiver(_ receiver: DiscoveredTVReceiver) {
        selectedReceiverName = receiver.name
        sharedDefaults?.set(receiver.name, forKey: StreamConfig.keyTargetServiceName)
        sharedDefaults?.set("", forKey: StreamConfig.keyTargetHost)
    }

    public func applyManualEndpoint() {
        let trimmed = manualIPAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let port = Int(manualPort) ?? Int(StreamConfig.defaultUDPPort)
        selectedReceiverName = "\(trimmed):\(port)"
        sharedDefaults?.set("", forKey: StreamConfig.keyTargetServiceName)
        sharedDefaults?.set(trimmed, forKey: StreamConfig.keyTargetHost)
        sharedDefaults?.set(port, forKey: StreamConfig.keyTargetPort)
    }

    /// Обработка строки из QR-кода вида `llmirror://192.168.1.50:5004`
    public func handleScannedQRCode(_ code: String) {
        guard let url = URL(string: code),
              url.scheme == "llmirror",
              let host = url.host else { return }
        let port = url.port ?? Int(StreamConfig.defaultUDPPort)
        manualIPAddress = host
        manualPort = String(port)
        applyManualEndpoint()
    }

    private func loadSavedSettings() {
        if let service = sharedDefaults?.string(forKey: StreamConfig.keyTargetServiceName), !service.isEmpty {
            selectedReceiverName = service
        } else if let host = sharedDefaults?.string(forKey: StreamConfig.keyTargetHost), !host.isEmpty {
            let port = sharedDefaults?.integer(forKey: StreamConfig.keyTargetPort) ?? Int(StreamConfig.defaultUDPPort)
            selectedReceiverName = "\(host):\(port)"
            manualIPAddress = host
            manualPort = String(port)
        }
    }

    private func startTelemetryPolling() {
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isStreaming = self.sharedDefaults?.bool(forKey: StreamConfig.keyStreamActive) ?? false
                self.currentFPS = self.sharedDefaults?.integer(forKey: StreamConfig.keyTelemetryFPS) ?? 0
                self.currentBitrateMbps = self.sharedDefaults?.double(forKey: StreamConfig.keyTelemetryBitrateMbps) ?? 0.0
                self.currentRTTMs = self.sharedDefaults?.double(forKey: StreamConfig.keyTelemetryRTTMs) ?? 0.0
                self.currentLossPercent = self.sharedDefaults?.double(forKey: StreamConfig.keyTelemetryLossPercent) ?? 0.0
                self.thermalStateText = Self.describeThermalState(ProcessInfo.processInfo.thermalState)
            }
        }
    }

    private static func describeThermalState(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "Норма (Nominal)"
        case .fair:     return "Тёплый (Fair)"
        case .serious:  return "Горячий — снижение до 720p (Serious)"
        case .critical: return "Перегрев — троттлинг (Critical)"
        @unknown default: return "Неизвестно"
        }
    }
}

// MARK: - 3. Главный экран iOS-приложения

public struct SenderMainView: View {
    @StateObject private var browser = BonjourReceiverBrowser()
    @StateObject private var viewModel = SenderDashboardViewModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                // Секция 1: Статус и кнопка запуска системной трансляции
                Section {
                    HStack(spacing: 16) {
                        SystemBroadcastPickerButton()
                            .frame(width: 56, height: 56)
                            .background(viewModel.isStreaming ? Color.red.opacity(0.15) : Color.blue.opacity(0.15))
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 4) {
                            Text(viewModel.isStreaming ? "Трансляция активна" : "Нажмите значок слева для старта")
                                .font(.headline)
                            Text("Приёмник: \(viewModel.selectedReceiverName)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Управление эфиром")
                }

                // Секция 2: Автоматическое обнаружение Apple TV (Bonjour)
                Section {
                    if browser.receivers.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Поиск Apple TV в локальной сети Wi-Fi...")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(browser.receivers) { tv in
                            Button {
                                viewModel.selectBonjourReceiver(tv)
                            } label: {
                                HStack {
                                    Image(systemName: "appletv.fill")
                                        .foregroundStyle(.blue)
                                    Text(tv.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if viewModel.selectedReceiverName == tv.name {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Телевизоры в сети (1 тап)")
                }

                // Секция 3: Ручной ввод IP или подключение по коду с экрана ТВ
                Section {
                    HStack {
                        TextField("IP-адрес ТВ (напр. 192.168.1.50)", text: $viewModel.manualIPAddress)
                            .keyboardType(.numbersAndPunctuation)
                        TextField("Порт", text: $viewModel.manualPort)
                            .frame(width: 70)
                            .keyboardType(.numberPad)
                        Button("Выбрать") {
                            viewModel.applyManualEndpoint()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Picker("Аппаратный кодек", selection: $viewModel.selectedCodec) {
                        ForEach(VideoCodecType.allCases, id: \.self) { codec in
                            Text(codec.title).tag(codec)
                        }
                    }
                } header: {
                    Text("Прямое подключение по IP / Настройки кодека")
                }

                // Секция 4: Живая телеметрия потока
                Section {
                    LabeledContent("Частота кадров (FPS)", value: "\(viewModel.currentFPS) fps")
                    LabeledContent("Битрейт видео", value: String(format: "%.1f Мбит/с", viewModel.currentBitrateMbps))
                    LabeledContent("Сетевой RTT (Ping)", value: String(format: "%.1f мс", viewModel.currentRTTMs))
                    LabeledContent("Потери пакетов UDP", value: String(format: "%.2f %%", viewModel.currentLossPercent))
                    LabeledContent("Тепловой режим", value: viewModel.thermalStateText)
                } header: {
                    Text("Телеметрия в реальном времени")
                }
            }
            .navigationTitle("LowLatency Mirror")
            .onAppear {
                browser.start()
            }
            .onDisappear {
                browser.stop()
            }
        }
    }
}
