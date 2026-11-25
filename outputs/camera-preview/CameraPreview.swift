import AppKit
import AVFoundation
import Foundation
import SwiftUI

struct PreviewError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func previewLog(_ message: String) {
    FileHandle.standardOutput.write(Data("\(message)\n".utf8))
}

final class PreviewApp: NSObject, NSApplicationDelegate {
    private let sessionQueue = DispatchQueue(label: "local.dataset.dual-camera-preview.sessions")
    private let panes = [CameraPane(number: 1), CameraPane(number: 2)]
    private lazy var tuning = CameraTuningModel(queue: sessionQueue, panes: panes)
    private let model = CollectorModel()
    private let window: NSWindow
    private let tabs = NSTabView()
    private let modes = NSSegmentedControl(labels: ["相机调试", "定时采集", "数据浏览", "设备信息"], trackingMode: .selectOne, target: nil, action: nil)
    private let reconnectButton = NSButton(title: "重新连接", target: nil, action: nil)
    private var previewTimer: Timer?
    private var refreshTimer: Timer?
    private var quitTimer: Timer?
    private var verificationTimer: Timer?
    private var permissionTimer: Timer?
    private var deviceObservers: [NSObjectProtocol] = []
    private var selectedMode = 0
    private var previewGeneration = 0

    override init() {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let height = min(840, screen.height - 56)
        let width = min(screen.width - 72, (height - 124) * 8 / 9 + 372)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let runtime: [String: String] = ["appPath": Bundle.main.bundleURL.path, "runtime": "preview"]
            let data = try JSONEncoder().encode(runtime)
            try data.write(to: CaptureScheduler.defaultRoot.appendingPathComponent("capture-runtime.json"), options: .atomic)
        } catch { previewLog("登记采集程序失败：\(error.localizedDescription)") }
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "双摄像头预览")
        appMenu.addItem(withTitle: "退出双摄像头预览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu

        window.title = "双摄像头采集工作台"
        window.minSize = NSSize(width: 900, height: 560)
        window.collectionBehavior = .fullScreenPrimary
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)

        let shell = NSView()
        window.contentView = shell
        tabs.tabViewType = .noTabsNoBorder
        modes.selectedSegment = 0
        modes.segmentDistribution = .fillEqually
        modes.target = self
        modes.action = #selector(changeMode)
        for item in [modes, tabs] {
            item.translatesAutoresizingMaskIntoConstraints = false
            shell.addSubview(item)
        }
        NSLayoutConstraint.activate([
            modes.topAnchor.constraint(equalTo: shell.topAnchor, constant: 12),
            modes.centerXAnchor.constraint(equalTo: shell.centerXAnchor),
            modes.widthAnchor.constraint(equalToConstant: 480),
            tabs.topAnchor.constraint(equalTo: modes.bottomAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
            tabs.bottomAnchor.constraint(equalTo: shell.bottomAnchor)
        ])
        let views = [previewPane(), NSHostingView(rootView: ScheduleView(model: model)),
                     NSHostingView(rootView: HistoryView(model: model)),
                     NSHostingView(rootView: DeviceCapabilitiesView(model: tuning))]
        for (index, view) in views.enumerated() {
            let tab = NSTabViewItem(identifier: index)
            tab.view = view
            tabs.addTabViewItem(tab)
        }
        tabs.selectTabViewItem(at: 0)
        window.center()
        showWindow()

        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self, self.selectedMode == 0 else { return }
            self.panes.forEach { $0.update() }
            self.tuning.tick()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.refreshStatus()
            if self.selectedMode != 0 { self.model.refreshHistory() }
        }
        model.startMonitoring()
        for notification in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(NotificationCenter.default.addObserver(
                forName: notification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, self.selectedMode == 0 else { return }
                self.connect()
            })
        }
        if CommandLine.arguments.contains("--history") {
            modes.selectedSegment = 2
            changeMode()
        } else {
            connect()
        }
        if let option = CommandLine.arguments.firstIndex(of: "--verify-studio"),
           CommandLine.arguments.indices.contains(option + 1) {
            let folder = URL(fileURLWithPath: CommandLine.arguments[option + 1], isDirectory: true)
            verificationTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self, self.panes.allSatisfy({ Date().timeIntervalSince($0.feed.statistics.receivedAt) < 3 }) else { return }
                timer.invalidate()
                self.verificationTimer = nil
                self.verifyStudio(to: folder)
            }
        }
    }

    private func previewPane() -> NSView {
        let content = NSView()
        let controls = NSHostingView(rootView: CameraControlsView(model: tuning))

        let column = NSStackView(views: panes.map(\.view))
        column.orientation = .vertical
        column.alignment = .leading
        column.distribution = .fillEqually
        column.spacing = 14
        column.detachesHiddenViews = false
        reconnectButton.target = self
        reconnectButton.action = #selector(connect)

        for view in [column, reconnectButton, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -16),
            controls.widthAnchor.constraint(equalToConstant: 330),
            controls.topAnchor.constraint(equalTo: content.topAnchor),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            panes[0].view.widthAnchor.constraint(equalTo: column.widthAnchor),
            panes[1].view.widthAnchor.constraint(equalTo: column.widthAnchor),
            reconnectButton.topAnchor.constraint(equalTo: column.bottomAnchor, constant: 12),
            reconnectButton.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            reconnectButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        return content
    }

    private func showWindow() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func verifyStudio(to folder: URL) {
        let feeds = panes.map(\.feed)
        let saved = tuning.document
        sessionQueue.async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                guard feeds.allSatisfy({ Date().timeIntervalSince($0.statistics.receivedAt) < 3 }) else {
                    throw PreviewError(message: "硬件验证尚未收到两路新画面。请允许相机权限后重试。")
                }
                try self.tuning.exportSnapshots(to: folder.appendingPathComponent("初始画面"), document: saved)
                var report: [String] = []
                for (index, feed) in feeds.enumerated() {
                    guard let device = feed.device else { throw PreviewError(message: "设备未连接。") }
                    let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                    let oldFPS = 1 / device.activeVideoMinFrameDuration.seconds
                    defer {
                        do {
                            try feed.setFormat(width: Int(dimensions.width), height: Int(dimensions.height),
                                               fps: min(30, max(25, oldFPS.rounded())))
                        } catch { previewLog("恢复测试前的格式失败：\(error.localizedDescription)") }
                    }
                    let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("uvc-control")
                    let usb = UVCDevice(deviceID: device.uniqueID, helper: helper)
                    let controls = try usb.controls()
                    report.append("camera-\(index + 1) [\(device.uniqueID)] \(controls.count) 项 USB 控制")
                    for size in [(1280, 720), (3840, 2160), (Int(dimensions.width), Int(dimensions.height))] {
                        try feed.setFormat(width: size.0, height: size.1, fps: 25)
                        Thread.sleep(forTimeInterval: 1.5)
                        let measured = feed.statistics
                        guard measured.resolution == "\(size.0)×\(size.1)" else {
                            throw PreviewError(message: "实测格式不匹配：\(measured.resolution)")
                        }
                        report.append("  已验证 \(measured.resolution) · \(String(format: "%.1f", measured.fps)) fps")
                    }
                    try feed.setFormat(width: Int(dimensions.width), height: Int(dimensions.height),
                                       fps: min(30, max(25, oldFPS.rounded())))
                    if let focus = controls.first(where: { $0.key == "focus" }),
                       let autoFocus = controls.first(where: { $0.key == "focusAuto" }) {
                        try usb.set(key: "focusAuto", value: 0)
                        try usb.set(key: "focus", value: max(focus.min, focus.value - 10))
                        try usb.set(key: "focus", value: focus.value)
                        try usb.set(key: "focusAuto", value: autoFocus.value)
                        report.append("  手动对焦写入、读回及恢复通过")
                    }
                    if let zoom = controls.first(where: { $0.key == "zoom" }) {
                        try usb.set(key: "zoom", value: min(zoom.max, zoom.value + zoom.step))
                        try usb.set(key: "zoom", value: zoom.value)
                        report.append("  变焦写入、读回及恢复通过")
                    }
                }
                try "硬件测试通过\n\(report.joined(separator: "\n"))\n".write(
                    to: folder.appendingPathComponent("硬件测试.txt"), atomically: true, encoding: .utf8
                )
                DispatchQueue.main.async {
                    self.tuning.feedback = "硬件验证已完成，结果保存在 \(folder.path)"
                    self.tuning.error = false
                    if let content = self.window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("软件界面.png"))
                    }
                }
            } catch {
                previewLog("验证失败：\(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.tuning.feedback = "硬件验证失败：\(error.localizedDescription)"
                    self.tuning.error = true
                }
            }
        }
    }

    @objc private func changeMode() {
        let destination = modes.selectedSegment
        guard destination != selectedMode else { return }
        selectedMode = destination
        tabs.selectTabViewItem(at: destination)
        if destination == 0 {
            connect()
        } else {
            previewGeneration += 1
            let feeds = panes.map(\.feed)
            sessionQueue.async { feeds.forEach { $0.stop() } }
            model.refreshStatus()
            model.refreshHistory()
        }
    }

    @objc private func connect() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        previewGeneration += 1
        let generation = previewGeneration
        reconnectButton.isEnabled = false
        tuning.prepareToConnect()
        panes.forEach { $0.show("正在连接…") }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startFeeds(generation: generation)
        case .notDetermined:
            panes.forEach { $0.show("请在 macOS 提示中允许相机访问。") }
            previewLog("正在请求 macOS 相机权限")
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
                guard let self, self.previewGeneration == generation else { return }
                self.panes.forEach { $0.show("相机授权仍在等待。请确认系统提示后点「重新连接」。") }
                self.reconnectButton.isEnabled = true
            }
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.previewGeneration == generation else { return }
                    self.permissionTimer?.invalidate()
                    self.permissionTimer = nil
                    if granted { self.startFeeds(generation: generation) }
                    else { self.showPermissionError() }
                }
            }
        default:
            showPermissionError()
        }
    }

    private func showPermissionError() {
        panes.forEach { $0.show("请在「系统设置 → 隐私与安全性 → 相机」中允许双摄像头预览。") }
        reconnectButton.isEnabled = true
        previewLog("相机权限未授权")
    }

    private func startFeeds(generation: Int) {
        let feeds = panes.map(\.feed)
        let saved = tuning.savedSettings
        sessionQueue.async { [weak self] in
            feeds.forEach { $0.stop() }
            let config = CaptureScheduler.defaultRoot.appendingPathComponent("cameras.json")
            guard let data = try? Data(contentsOf: config),
                  let ids = try? JSONDecoder().decode([String].self, from: data),
                  ids.count == feeds.count, Set(ids).count == feeds.count else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.previewGeneration == generation else { return }
                    self.panes.forEach { $0.show("读取摄像头编号失败，请先完成采集脚本的 setup。") }
                    self.reconnectButton.isEnabled = true
                }
                previewLog("无法读取采集任务保存的摄像头编号")
                return
            }
            let devices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external], mediaType: .video, position: .unspecified
            ).devices

            for (index, id) in ids.enumerated() {
                do {
                    guard let device = devices.first(where: { $0.uniqueID == id }) else {
                        throw PreviewError(message: "找不到这台摄像头，请检查原来的 USB 端口。")
                    }
                    try feeds[index].start(device: device, saved: saved[id])
                    if var hardware = saved[id]?.hardware, !hardware.isEmpty,
                       let binary = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("uvc-control") {
                        let usb = UVCDevice(deviceID: id, helper: binary)
                        let lockedFocus = saved[id]?.focusLocked == true ? hardware["focus"] : nil
                        let approach = saved[id]?.focusApproach
                        if let lockedFocus, let approach, approach != lockedFocus {
                            hardware.removeValue(forKey: "focus")
                        }
                        try usb.apply(hardware)
                        if let focus = lockedFocus {
                            // Some USB lenses report the requested position before settling.
                            for attempt in 0..<3 {
                                if attempt > 0 { try usb.set(key: "focusAuto", value: 0) }
                                do {
                                    if let approach, approach != focus {
                                        try approachLockedFocus(device: device, from: approach, to: focus)
                                    } else if attempt > 0 {
                                        try usb.set(key: "focus", value: focus)
                                    }
                                } catch {
                                    guard attempt < 2 else { throw error }
                                    continue
                                }
                                Thread.sleep(forTimeInterval: 0.5)
                                let readback = Dictionary(uniqueKeysWithValues: try usb.controls().map { ($0.key, $0.value) })
                                if readback["focusAuto"] == 0, let actual = readback["focus"],
                                   abs(actual - focus) <= 4 {
                                    previewLog("camera-\(index + 1) 已核对恢复的焦点 \(actual)")
                                    break
                                }
                                guard attempt < 2 else {
                                    throw PreviewError(message: "镜头实际焦点与保存值不符，请重新连接或校准焦点。")
                                }
                            }
                            if let point = saved[id]?.subjectFocus, point.isValid {
                                do {
                                    try feeds[index].focusLiveSubject(point, target: focus, usb: usb)
                                } catch {
                                    if let approach, approach != focus {
                                        try approachLockedFocus(device: device, from: approach, to: focus)
                                    } else {
                                        try usb.set(key: "focus", value: focus)
                                    }
                                    previewLog(error.localizedDescription)
                                    let message = error.localizedDescription
                                    DispatchQueue.main.async { [weak self] in
                                        guard let self, self.previewGeneration == generation else { return }
                                        self.tuning.feedback = "camera-\(index + 1) \(message)"
                                        self.tuning.error = true
                                    }
                                }
                            }
                        }
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.previewGeneration == generation else { return }
                        self.panes[index].watch(id: id)
                        self.tuning.connected(index: index, device: device)
                    }
                } catch {
                    previewLog("camera-\(index + 1) [\(id)] \(error.localizedDescription)")
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.previewGeneration == generation else { return }
                        self.panes[index].show(error.localizedDescription)
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previewGeneration == generation else { return }
                self.reconnectButton.isEnabled = true
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        deviceObservers.forEach(NotificationCenter.default.removeObserver)
        model.endSleepAssertion()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.busy else { return .terminateNow }
        quitTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self, !self.model.busy else { return }
            timer.invalidate()
            self.quitTimer = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct CameraAppMain {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 5 && arguments[1] == "--camera-collector" {
            guard ["capture", "setup", "probe", "authorize"].contains(arguments[2]) else { exit(64) }
            startCollector(mode: arguments[2], root: arguments[3], receipt: arguments[4])
            return
        }
        let application = NSApplication.shared
        let delegate = PreviewApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
