import AppKit
import AVFoundation
import SwiftUI

final class CameraControlState: ObservableObject {
    let number: Int
    @Published var deviceID = ""
    @Published var isConnected = false
    @Published var formats: [CameraFormat] = []
    @Published var formatID = ""
    @Published var fps = 25.0
    var appliedFormatID = ""
    var appliedFPS = 25.0
    @Published var controls: [UVCControl] = []
    @Published var desired: [String: Int] = [:]
    @Published var adjustments = CameraAdjustments()
    @Published var grid = false
    @Published var picking = ""
    @Published var pickedPoints: [NormalizedPoint] = []
    @Published var sample: [Double]?
    @Published var statistics = FrameStatistics()
    @Published var hardwareError = ""
    @Published var usbDescription: USBDeviceDescription?
    @Published var nativeFormats: [NativeCameraFormat] = []
    @Published var focusModes = ""
    @Published var focusLocked = false
    @Published var previewMagnification = 1.0
    @Published var seedDetailCenter: NormalizedPoint?
    @Published var exposureModes = ""
    @Published var whiteBalanceModes = ""
    var pendingHardware = Set<String>()

    init(number: Int) { self.number = number }

    func controlBinding(_ key: String) -> Binding<Double> {
        Binding(get: { Double(self.desired[key] ?? 0) }, set: {
            self.desired[key] = Int($0.rounded())
            self.pendingHardware.insert(key)
        })
    }
}

final class CameraTuningModel: ObservableObject {
    let cameras = [CameraControlState(number: 1), CameraControlState(number: 2)]
    @Published var selected = 0
    @Published var busy = false
    @Published var feedback = ""
    @Published var error = false
    @Published private(set) var allCamerasConnected = false
    @Published var linkedFocus = 0.5
    @Published var linkedAutoFocus = true
    @Published var linkedFocusLocked = false
    @Published var focusStatus = "读取两路对焦状态…"
    private(set) var document = CameraSettingsDocument()
    private let queue: DispatchQueue
    private let panes: [CameraPane]
    private let file = CaptureScheduler.defaultRoot.appendingPathComponent("camera-settings.json")
    private var formatWork: [Int: DispatchWorkItem] = [:]
    private var focusWork: DispatchWorkItem?
    private var manualFocusWork: [Int: DispatchWorkItem] = [:]
    private var zoomWork: [Int: DispatchWorkItem] = [:]

    init(queue: DispatchQueue, panes: [CameraPane]) {
        self.queue = queue
        self.panes = panes
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                document = try JSONDecoder().decode(CameraSettingsDocument.self, from: Data(contentsOf: file))
                try document.validate()
            }
        } catch {
            document = CameraSettingsDocument()
            feedback = "参数文件读取失败。\(error.localizedDescription)"
            self.error = true
        }
        for index in cameras.indices {
            panes[index].surface.onPick = { [weak self] point in self?.pick(point, camera: index) }
        }
    }

    var savedSettings: [String: SavedCameraSettings] { document.cameras }

    private func uvc(_ id: String) throws -> UVCDevice {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("uvc-control"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PreviewError(message: "应用内缺少 USB 控制程序。请使用完整的应用包。")
        }
        return UVCDevice(deviceID: id, helper: executable)
    }

    func connected(index: Int, device: AVCaptureDevice) {
        let camera = cameras[index]
        camera.isConnected = true
        allCamerasConnected = cameras.allSatisfy { $0.isConnected }
        camera.deviceID = device.uniqueID
        camera.formats = CameraFeed.formats(for: device)
        camera.nativeFormats = NativeCameraFormat.read(device)
        camera.focusModes = (0...2).compactMap { raw in
            let mode = AVCaptureDevice.FocusMode(rawValue: raw)!
            return device.isFocusModeSupported(mode) ? ["锁定", "单次自动", "连续自动"][raw] : nil
        }.joined(separator: "、")
        camera.exposureModes = (0...2).compactMap { raw in
            let mode = AVCaptureDevice.ExposureMode(rawValue: raw)!
            return device.isExposureModeSupported(mode) ? ["锁定", "单次自动", "连续自动"][raw] : nil
        }.joined(separator: "、")
        camera.whiteBalanceModes = (0...2).compactMap { raw in
            let mode = AVCaptureDevice.WhiteBalanceMode(rawValue: raw)!
            return device.isWhiteBalanceModeSupported(mode) ? ["锁定", "单次自动", "连续自动"][raw] : nil
        }.joined(separator: "、")
        if camera.exposureModes.isEmpty { camera.exposureModes = "AVFoundation 未开放，可查看 USB 读回项目" }
        if camera.whiteBalanceModes.isEmpty { camera.whiteBalanceModes = "AVFoundation 未开放，可查看 USB 白平衡控制" }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        camera.appliedFormatID = "\(dimensions.width)×\(dimensions.height)"
        camera.appliedFPS = document.cameras[device.uniqueID]?.fps ?? 25
        camera.formatID = camera.appliedFormatID
        camera.fps = document.cameras[device.uniqueID]?.fps ?? 25
        camera.adjustments = panes[index].feed.adjustments
        refreshHardware(index: index)
    }

    func prepareToConnect() {
        allCamerasConnected = false
        cameras.forEach { $0.isConnected = false }
    }

    func tick() {
        for index in cameras.indices {
            cameras[index].statistics = panes[index].feed.statistics
        }
    }

    func softwareChanged(index: Int) {
        let camera = cameras[index]
        do {
            try camera.adjustments.validate()
            let previous = panes[index].feed.adjustments
            if previous.rotation != camera.adjustments.rotation ||
                previous.mirror != camera.adjustments.mirror ||
                previous.enabled != camera.adjustments.enabled ||
                previous.perspective != camera.adjustments.perspective ||
                previous.radialK1 != camera.adjustments.radialK1 ||
                previous.radialK2 != camera.adjustments.radialK2 ||
                previous.centerX != camera.adjustments.centerX ||
                previous.centerY != camera.adjustments.centerY ||
                previous.lensCalibration != camera.adjustments.lensCalibration {
                clearSeedDetail(index: index)
            }
            panes[index].feed.adjustments = camera.adjustments
            panes[index].surface.grid = camera.grid
            guard !camera.deviceID.isEmpty else { return }
            var saved = document.cameras[camera.deviceID] ?? SavedCameraSettings(deviceID: camera.deviceID)
            saved.adjustments = camera.adjustments
            document.cameras[camera.deviceID] = saved
            try persist()
        } catch { report(error) }
    }

    private func persist() throws {
        try document.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: file, options: .atomic)
    }

    private func report(_ failure: Error) {
        feedback = failure.localizedDescription
        error = true
        previewLog("相机控制：\(feedback)")
    }

    func refreshHardware(index: Int) {
        let camera = cameras[index]
        guard !camera.deviceID.isEmpty else { return }
        let id = camera.deviceID
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.uvc(id).controls() }
            let description = try? self.uvc(id).description()
            DispatchQueue.main.async {
                camera.usbDescription = description
                switch result {
                case .success(let controls):
                    camera.controls = controls
                    for control in controls where !camera.pendingHardware.contains(control.key) {
                        camera.desired[control.key] = control.value
                    }
                    camera.hardwareError = ""
                    camera.focusLocked = self.document.cameras[id]?.focusLocked == true &&
                        controls.first(where: { $0.key == "focusAuto" })?.value == 0
                    let automatic = self.cameras.map { camera in camera.controls.first(where: { $0.key == "focusAuto" })?.value }
                    if automatic.allSatisfy({ $0 != nil }) {
                        self.linkedAutoFocus = automatic.allSatisfy({ $0 == 1 })
                        self.linkedFocusLocked = automatic.allSatisfy({ $0 == 0 }) &&
                            self.cameras.allSatisfy { self.document.cameras[$0.deviceID]?.focusLocked == true }
                        self.focusStatus = self.linkedFocusLocked ? "当前焦点已锁定，采集时恢复各自位置" :
                            (self.linkedAutoFocus ? "两路自动对焦" : "两路当前包含手动对焦")
                    }
                case .failure(let error): camera.hardwareError = error.localizedDescription
                }
            }
        }
    }

    func exportCapabilities(index: Int) {
        let camera = cameras[index]
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "camera-\(index + 1)-设备能力.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let report = CameraCapabilityReport(
                generatedAt: Date(), deviceID: camera.deviceID, usb: camera.usbDescription,
                nativeFormats: camera.nativeFormats,
                controls: camera.controls.map {
                    CameraCapabilityReport.CapabilityControl(key: $0.key, current: $0.value, minimum: $0.min,
                        maximum: $0.max, step: $0.step, defaultValue: $0.defaultValue, writable: $0.writable)
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: url, options: .atomic)
            feedback = "设备能力报告已导出。"; error = false
        } catch { report(error) }
    }

    func restoreLinkedFocus() {
        focusWork?.cancel()
        changeLinkedFocus(automatic: true, reset: true)
    }

    func setPreviewMagnification(index: Int, value: Double) {
        guard cameras[index].picking.isEmpty else { return }
        cameras[index].previewMagnification = min(4, max(1, value))
        panes[index].feed.previewMagnification = cameras[index].previewMagnification
    }

    func beginSeedDetail() {
        for index in cameras.indices {
            if !cameras[index].picking.isEmpty { cancelPick(index: index) }
            clearSeedDetail(index: index)
            setPreviewMagnification(index: index, value: 1)
        }
        beginPick("seedDetail", index: 0)
    }

    func cancelSeedDetail() {
        if let index = cameras.firstIndex(where: { $0.picking == "seedDetail" }) {
            cancelPick(index: index)
        }
    }

    private func clearSeedDetail(index: Int) {
        cameras[index].seedDetailCenter = nil
        panes[index].feed.seedDetailCenter = nil
    }

    func scheduleDeviceZoom(index: Int, value: Double) {
        let camera = cameras[index]
        guard let control = camera.controls.first(where: { $0.key == "zoom" && $0.writable }) else { return }
        let step = max(1, control.step)
        let position = min(control.max, max(control.min, control.min +
            Int(((value - Double(control.min)) / Double(step)).rounded()) * step))
        camera.desired["zoom"] = position
        zoomWork[index]?.cancel()
        let pending = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.busy { self.scheduleDeviceZoom(index: index, value: Double(position)); return }
            let id = camera.deviceID
            var actual = position
            var changed = false
            var focusState: [String: Int] = [:]
            self.operate("设备变焦已应用；变焦后请检查清晰度并重新锁定焦点。") {
                let usb = try self.uvc(id)
                let before = try usb.controls()
                let original = Dictionary(uniqueKeysWithValues: before.filter {
                    ["zoom", "focus", "focusAuto"].contains($0.key) && $0.writable
                }.map { ($0.key, $0.value) })
                do {
                    try usb.apply(["zoom": position])
                    Thread.sleep(forTimeInterval: 0.3)
                    let controls = try usb.controls()
                    guard let readBack = controls.first(where: { $0.key == "zoom" }) else {
                        throw PreviewError(message: "未能读回设备变焦。")
                    }
                    actual = readBack.value
                    changed = actual != original["zoom"]
                    focusState = Dictionary(uniqueKeysWithValues: controls.filter {
                        ["focus", "focusAuto"].contains($0.key)
                    }.map { ($0.key, $0.value) })
                } catch {
                    let failure = error
                    do { try usb.apply(original) }
                    catch { previewLog("设备变焦恢复异常：\(error.localizedDescription)") }
                    throw failure
                }
            } completion: {
                var saved = self.document.cameras[id] ?? SavedCameraSettings(deviceID: id)
                saved.hardware["zoom"] = actual
                if changed {
                    self.clearSeedDetail(index: index)
                    saved.focusLocked = false
                    saved.subjectFocus = nil
                    saved.hardware.merge(focusState) { _, value in value }
                    camera.focusLocked = false
                    self.linkedFocusLocked = false
                }
                self.document.cameras[id] = saved
                camera.desired["zoom"] = actual
                camera.pendingHardware.remove("zoom")
                try self.persist()
                self.refreshHardware(index: index)
            }
        }
        zoomWork[index] = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: pending)
    }

    func scheduleManualFocus(index: Int, value: Double) {
        let camera = cameras[index]
        guard !camera.focusLocked, camera.desired["focusAuto"] == 0 else { return }
        camera.desired["focus"] = Int(value.rounded())
        manualFocusWork[index]?.cancel()
        let pending = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.busy { self.scheduleManualFocus(index: index, value: value) }
            else { self.setManualFocus(index: index, value: Int(value.rounded())) }
        }
        manualFocusWork[index] = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: pending)
    }

    func setManualFocus(index: Int, value: Int? = nil, locked: Bool = false, scan: Bool = false,
                        target: NormalizedPoint? = nil) {
        focusWork?.cancel()
        manualFocusWork[index]?.cancel()
        let camera = cameras[index]
        guard let focus = camera.controls.first(where: { $0.key == "focus" && $0.writable }),
              camera.controls.contains(where: { $0.key == "focusAuto" && $0.writable }) else {
            report(PreviewError(message: "请先连接支持手动对焦的摄像头。"))
            return
        }
        let requested = value ?? camera.desired["focus"] ?? focus.value
        let position = min(focus.max, max(focus.min, focus.min +
            Int((Double(requested - focus.min) / Double(max(1, focus.step))).rounded()) * max(1, focus.step)))
        let id = camera.deviceID
        var actual = position
        let previousApproach = document.cameras[id]?.focusApproach
        let subject = target.flatMap { camera.adjustments.rawSubjectPoint($0) }
            ?? (scan && target == nil
                ? camera.seedDetailCenter.flatMap { camera.adjustments.rawSubjectPoint($0) }
                    ?? document.cameras[id]?.subjectFocus
                : nil)
        var approach = previousApproach
        operate("camera-\(index + 1) \(locked ? "焦点已锁定" : "手动对焦已应用")") {
            let usb = try self.uvc(id)
            let controls = try usb.controls()
            let original = Dictionary(uniqueKeysWithValues: controls.filter { ["focus", "focusAuto"].contains($0.key) }.map { ($0.key, $0.value) })
            do {
                try self.panes[index].feed.setAutomaticFocus(false)
                try usb.set(key: "focusAuto", value: 0)
                if scan, let subject {
                    approach = try self.panes[index].feed.focusLiveSubject(subject, target: original["focus"] ?? position, usb: usb, fullRange: true)
                } else if scan {
                    approach = try self.findSharpFocus(index: index, usb: usb, target: target)
                } else {
                    try usb.set(key: "focus", value: position)
                }
                guard let readBack = try usb.controls().first(where: { $0.key == "focus" }) else {
                    throw PreviewError(message: "未能读回手动对焦位置。")
                }
                actual = readBack.value
            } catch {
                let failure = error
                do {
                    try self.panes[index].feed.setAutomaticFocus(original["focusAuto"] == 1)
                    if let previousApproach, let focus = original["focus"], previousApproach != focus,
                       original["focusAuto"] == 0, let device = self.panes[index].feed.device {
                        try usb.set(key: "focusAuto", value: 0)
                        try approachLockedFocus(device: device, from: previousApproach, to: focus)
                    } else {
                        try usb.apply(original)
                    }
                } catch { previewLog("手动调焦恢复异常：\(error.localizedDescription)") }
                throw failure
            }
        } completion: {
            var saved = self.document.cameras[id] ?? SavedCameraSettings(deviceID: id)
            saved.hardware["focusAuto"] = 0
            saved.hardware["focus"] = actual
            saved.focusLocked = locked
            saved.focusApproach = locked ? approach : nil
            saved.subjectFocus = locked ? subject : nil
            self.document.cameras[id] = saved
            camera.desired["focusAuto"] = 0
            camera.desired["focus"] = actual
            camera.focusLocked = locked
            camera.pendingHardware.subtract(["focus", "focusAuto"])
            try self.persist()
            self.refreshHardware(index: index)
        }
    }

    func enableAutomaticFocus(index: Int) {
        manualFocusWork[index]?.cancel()
        focusWork?.cancel()
        let camera = cameras[index]
        let id = camera.deviceID
        guard camera.controls.contains(where: { $0.key == "focusAuto" && $0.writable }) else {
            report(PreviewError(message: "该设备尚未开放自动对焦控制。")); return
        }
        operate("camera-\(index + 1) 已启用自动对焦") {
            let usb = try self.uvc(id)
            let oldAutomatic = try usb.controls().first(where: { $0.key == "focusAuto" })?.value ?? 0
            do {
                try self.panes[index].feed.setAutomaticFocus(true)
                try usb.apply(["focusAuto": 1])
            } catch {
                try? self.panes[index].feed.setAutomaticFocus(oldAutomatic == 1)
                throw error
            }
        } completion: {
            var saved = self.document.cameras[id] ?? SavedCameraSettings(deviceID: id)
            saved.focusLocked = false
            saved.hardware["focusAuto"] = 1
            self.document.cameras[id] = saved
            camera.focusLocked = false
            self.linkedFocusLocked = false
            try self.persist()
            self.refreshHardware(index: index)
        }
    }

    func applyLinkedFocus(automatic: Bool) {
        focusWork?.cancel()
        changeLinkedFocus(automatic: automatic, reset: false)
    }

    func scheduleLinkedFocus() {
        focusWork?.cancel()
        guard !linkedAutoFocus, !linkedFocusLocked else { return }
        let pending = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.busy { self.scheduleLinkedFocus() }
            else { self.applyLinkedFocus(automatic: false) }
        }
        focusWork = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: pending)
    }

    func lockCurrentFocus(scan: Bool = false) {
        focusWork?.cancel()
        manualFocusWork.values.forEach { $0.cancel() }
        guard cameras.allSatisfy({ !$0.deviceID.isEmpty }) else {
            report(PreviewError(message: "请先连接两路摄像头。"))
            return
        }
        let devices = cameras.map(\.deviceID)
        var lockedPositions = [Int]()
        var approaches = devices.map { document.cameras[$0]?.focusApproach }
        var recoveredFromJump = false
        operate("两路当前焦点已锁定并保存") {
            var originals: [[String: Int]] = []
            for device in devices {
                let controls = try self.uvc(device).controls()
                originals.append(Dictionary(uniqueKeysWithValues: controls.filter { ["focusAuto", "focus"].contains($0.key) }.map { ($0.key, $0.value) }))
            }
            do {
                for index in devices.indices {
                    let beforeQuality = try self.panes[index].feed.focusQuality()
                    try self.panes[index].feed.setAutomaticFocus(false)
                    let usb = try self.uvc(devices[index])
                    try usb.apply(["focusAuto": 0])
                    Thread.sleep(forTimeInterval: 0.25)
                    let afterQuality = try self.panes[index].feed.focusQuality()
                    if scan || afterQuality < beforeQuality * 0.8 {
                        recoveredFromJump = true
                        DispatchQueue.main.async { self.feedback = "正在为 camera-\(index + 1) 寻焦…" }
                        approaches[index] = try self.findSharpFocus(index: index, usb: usb)
                    }
                    guard let focus = try usb.controls().first(where: { $0.key == "focus" }) else {
                        throw PreviewError(message: "无法读回 camera-\(index + 1) 的焦点位置。")
                    }
                    lockedPositions.append(focus.value)
                }
            } catch {
                let failure = error
                for index in devices.indices {
                    try? self.uvc(devices[index]).apply(originals[index])
                    try? self.panes[index].feed.setAutomaticFocus(originals[index]["focusAuto"] == 1)
                }
                throw failure
            }
        } completion: {
            self.linkedAutoFocus = false
            self.linkedFocusLocked = true
            for index in devices.indices {
                var saved = self.document.cameras[devices[index]] ?? SavedCameraSettings(deviceID: devices[index])
                saved.focusLocked = true
                saved.hardware["focusAuto"] = 0
                saved.hardware["focus"] = lockedPositions[index]
                saved.focusApproach = approaches[index]
                self.document.cameras[devices[index]] = saved
                self.refreshHardware(index: index)
            }
            self.focusStatus = "\(recoveredFromJump ? "已寻焦并锁定" : "已锁定") · camera-1 \(lockedPositions[0]) / camera-2 \(lockedPositions[1])"
            try self.persist()
        }
    }

    private func findSharpFocus(index: Int, usb: UVCDevice, target: NormalizedPoint? = nil) throws -> Int {
        guard let focus = try usb.controls().first(where: { $0.key == "focus" }) else {
            throw PreviewError(message: "无法读取手动对焦范围。")
        }
        var best = focus.value
        var bestQuality = -Double.infinity
        let step = max(1, focus.step)
        let coarseStep = max(step, (focus.max - focus.min) / 25)
        func sampleQuality() throws -> Double {
            var samples: [Double] = []
            for _ in 0..<3 {
                samples.append(try panes[index].feed.focusQuality(around: target))
                Thread.sleep(forTimeInterval: 0.045)
            }
            return samples.sorted()[1]
        }
        @discardableResult
        func evaluate(_ requested: Int) throws -> Double {
            let position = min(focus.max, max(focus.min, focus.min +
                Int((Double(requested - focus.min) / Double(step)).rounded()) * step))
            do { try usb.set(key: "focus", value: position) }
            catch {
                previewLog("camera-\(index + 1) 未确认寻焦点位 \(position)：\(error.localizedDescription)")
                return -.infinity
            }
            Thread.sleep(forTimeInterval: 0.40)
            let quality = try sampleQuality()
            if quality > bestQuality { best = position; bestQuality = quality }
            return quality
        }
        let baseline = try evaluate(focus.value)
        for value in stride(from: focus.min, through: focus.max, by: coarseStep) { try evaluate(value) }
        try evaluate(focus.max)
        let center = best
        let fineStep = max(step, coarseStep / 5)
        for value in stride(from: max(focus.min, center - coarseStep), through: min(focus.max, center + coarseStep), by: fineStep) {
            try evaluate(value)
        }
        if target != nil {
            let center = best
            for value in stride(from: max(focus.min, center - fineStep), through: min(focus.max, center + fineStep), by: max(step, fineStep / 4)) {
                try evaluate(value)
            }
        }
        guard bestQuality.isFinite, bestQuality > 0, let device = panes[index].feed.device else {
            throw PreviewError(message: "未取得可用的寻焦画面。")
        }
        let distance = max(step, (2 * coarseStep / step) * step)
        for approach in [max(focus.min, best - distance), min(focus.max, best + distance)] where approach != best {
            do { try approachLockedFocus(device: device, from: approach, to: best) }
            catch { continue }
            Thread.sleep(forTimeInterval: 0.6)
            let settled = try sampleQuality()
            if settled >= bestQuality * 0.82 {
                previewLog("camera-\(index + 1) 寻焦完成，原位置 \(focus.value) 指标 \(baseline)，新位置 \(best) 指标 \(settled)")
                return approach
            }
        }
        throw PreviewError(message: "镜头未能重复达到寻焦时的清晰度，未保存本次焦点。")
    }

    func unlockManualFocus() {
        linkedFocusLocked = false
        for camera in cameras {
            document.cameras[camera.deviceID]?.focusLocked = false
            camera.focusLocked = false
        }
        do { try persist(); focusStatus = "手动调节已解锁，拖动滑杆可同时调整" }
        catch { report(error) }
    }

    private func changeLinkedFocus(automatic: Bool, reset: Bool) {
        manualFocusWork.values.forEach { $0.cancel() }
        guard cameras.allSatisfy({ !$0.deviceID.isEmpty && $0.controls.contains(where: { $0.key == "focusAuto" && $0.writable }) }) else {
            report(PreviewError(message: "请先连接两路摄像头。"))
            return
        }
        let position = linkedFocus
        var requests: [[String: Int]] = []
        for camera in cameras {
            guard let focus = camera.controls.first(where: { $0.key == "focus" && $0.writable }) else {
                report(PreviewError(message: "该设备没有开放手动对焦。"))
                return
            }
            let scaled = Double(focus.min) + position * Double(focus.max - focus.min)
            let value = reset ? focus.defaultValue : focus.min + Int(((scaled - Double(focus.min)) / Double(focus.step)).rounded()) * focus.step
            requests.append(["focusAuto": automatic ? 1 : 0, "focus": min(focus.max, max(focus.min, value))])
        }
        let commands = requests
        let devices = cameras.map(\.deviceID)
        operate(automatic ? "两路已启用自动对焦" : "两路手动对焦已应用") {
            var originals: [[String: Int]] = []
            for device in devices {
                let controls = try self.uvc(device).controls()
                originals.append(Dictionary(uniqueKeysWithValues: controls.filter { ["focusAuto", "focus"].contains($0.key) }.map { ($0.key, $0.value) }))
            }
            do {
                for index in devices.indices {
                    let usb = try self.uvc(devices[index])
                    try self.panes[index].feed.setAutomaticFocus(false)
                    if reset {
                        try usb.apply(["focusAuto": 0, "focus": commands[index]["focus"]!])
                    }
                    try usb.apply(commands[index])
                    try self.panes[index].feed.setAutomaticFocus(automatic)
                }
            } catch {
                let failure = error
                for index in devices.indices {
                    do { try self.uvc(devices[index]).apply(originals[index]) }
                    catch { previewLog("两路对焦恢复异常：\(error.localizedDescription)") }
                    do { try self.panes[index].feed.setAutomaticFocus(originals[index]["focusAuto"] == 1) }
                    catch { previewLog("采集层对焦恢复异常：\(error.localizedDescription)") }
                }
                throw failure
            }
        } completion: {
            self.linkedAutoFocus = automatic
            self.linkedFocusLocked = false
            if reset { self.linkedFocus = 0.5 }
            self.focusStatus = automatic ? "两路自动对焦" : "两路手动对焦 · \(Int(position * 100))%"
            for index in self.cameras.indices {
                let camera = self.cameras[index]
                var saved = self.document.cameras[camera.deviceID] ?? SavedCameraSettings(deviceID: camera.deviceID)
                saved.hardware.merge(commands[index]) { _, value in value }
                saved.focusLocked = false
                self.document.cameras[camera.deviceID] = saved
                self.refreshHardware(index: index)
            }
            try self.persist()
        }
    }

    func scheduleFormat(index: Int) {
        formatWork[index]?.cancel()
        let camera = cameras[index]
        guard !camera.deviceID.isEmpty,
              camera.formatID != camera.appliedFormatID || camera.fps != camera.appliedFPS else { return }
        let pending = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.busy { self.scheduleFormat(index: index) }
            else { self.applyFormat(index: index) }
        }
        formatWork[index] = pending
        feedback = "将自动应用所选格式…"
        error = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: pending)
    }

    func applyFormat(index: Int) {
        formatWork[index]?.cancel()
        let camera = cameras[index]
        guard let format = camera.formats.first(where: { $0.id == camera.formatID }),
              format.rates.contains(camera.fps) else {
            report(PreviewError(message: "请选择该分辨率支持的帧率。"))
            return
        }
        let fps = camera.fps
        operate("已验证视频流 \(format.id) · 目标 \(Int(fps)) fps") {
            try self.panes[index].feed.setFormat(width: format.width, height: format.height, fps: fps)
        } completion: {
            var saved = self.document.cameras[camera.deviceID] ?? SavedCameraSettings(deviceID: camera.deviceID)
            saved.width = format.width
            saved.height = format.height
            saved.fps = fps
            camera.appliedFormatID = format.id
            camera.appliedFPS = fps
            self.document.cameras[camera.deviceID] = saved
            try self.persist()
        }
    }

    func applyHardware(index: Int, defaults: Bool = false) {
        let camera = cameras[index]
        var values: [String: Int] = [:]
        for control in camera.controls where control.writable && (defaults || camera.pendingHardware.contains(control.key)) {
            values[control.key] = defaults ? control.defaultValue : camera.desired[control.key]
        }
        guard !values.isEmpty else { feedback = "请先修改硬件参数。"; error = false; return }
        for key in ["focusAuto", "whiteBalanceAuto"] where !defaults {
            if let value = camera.desired[key], values[key] == nil { values[key] = value }
        }
        let requested = values
        let changesFocus = defaults || camera.pendingHardware.contains("focus") || camera.pendingHardware.contains("focusAuto")
        operate("硬件参数已写入并读回核对") {
            if let automatic = requested["focusAuto"] {
                try self.panes[index].feed.setAutomaticFocus(automatic == 1)
            }
            try self.uvc(camera.deviceID).apply(requested)
        } completion: {
            var saved = self.document.cameras[camera.deviceID] ?? SavedCameraSettings(deviceID: camera.deviceID)
            saved.hardware.merge(requested) { _, new in new }
            if changesFocus { saved.focusLocked = false; self.linkedFocusLocked = false }
            self.document.cameras[camera.deviceID] = saved
            camera.pendingHardware.removeAll()
            try self.persist()
            self.refreshHardware(index: index)
        }
    }

    func alignTemperature() {
        guard cameras.allSatisfy({ $0.controls.contains(where: { $0.key == "temperature" && $0.writable }) &&
            $0.controls.contains(where: { $0.key == "whiteBalanceAuto" && $0.writable }) }) else {
            report(PreviewError(message: "需要先连接两路摄像头并读到色温控制。"))
            return
        }
        let target = cameras[0].desired["temperature"] ?? 5100
        operate("两路已使用 \(target) K 手动白平衡") {
            for camera in self.cameras {
                try self.uvc(camera.deviceID).apply(["whiteBalanceAuto": 0, "temperature": target])
            }
        } completion: {
            for (index, camera) in self.cameras.enumerated() {
                var saved = self.document.cameras[camera.deviceID] ?? SavedCameraSettings(deviceID: camera.deviceID)
                saved.hardware.merge(["whiteBalanceAuto": 0, "temperature": target]) { _, value in value }
                self.document.cameras[camera.deviceID] = saved
                self.refreshHardware(index: index)
            }
            try self.persist()
        }
    }

    func resetSoftware(index: Int) {
        cameras[index].adjustments = CameraAdjustments()
        cameras[index].sample = nil
        cameras[index].picking = ""
        cameras[index].pickedPoints = []
        panes[index].surface.points = []
        softwareChanged(index: index)
    }

    func beginPick(_ mode: String, index: Int) {
        for other in cameras.indices where !cameras[other].picking.isEmpty {
            cancelPick(index: other)
        }
        selected = index
        setPreviewMagnification(index: index, value: 1)
        cameras[index].picking = mode
        cameras[index].pickedPoints = []
        panes[index].surface.points = []
        if mode == "corners" {
            cameras[index].adjustments.perspective = []
            softwareChanged(index: index)
            feedback = "在该路画面依次点选托盘的左上、右上、右下、左下四角。"
        } else if mode == "focus" {
            feedback = "点击 camera-\(index + 1) 画面里的种子附近，保持托盘静止。"
        } else if mode == "seedDetail" {
            feedback = "在 camera-\(index + 1) 画面点击同一颗种子的中心。"
        } else {
            cameras[index].sample = nil
            feedback = "请在\(index == 0 ? "上方" : "下方") camera-\(index + 1) 画面点击白纸空白处或灰卡。"
        }
        error = false
    }

    func cancelPick(index: Int) {
        let cancelingPair = cameras[index].picking == "seedDetail"
        cameras[index].picking = ""
        cameras[index].pickedPoints = []
        panes[index].surface.points = []
        if cancelingPair {
            for cameraIndex in cameras.indices {
                clearSeedDetail(index: cameraIndex)
                setPreviewMagnification(index: cameraIndex, value: 1)
            }
        }
        feedback = "已取消取点。"
    }

    private func pick(_ point: NormalizedPoint, camera index: Int) {
        let camera = cameras[index]
        if camera.picking == "focus" {
            camera.picking = ""
            panes[index].surface.points = [point]
            setManualFocus(index: index, locked: true, scan: true, target: point)
        } else if camera.picking == "seedDetail" {
            camera.picking = ""
            camera.seedDetailCenter = point
            panes[index].feed.seedDetailCenter = point
            setPreviewMagnification(index: index, value: 4)
            if index == 0 {
                beginPick("seedDetail", index: 1)
            } else {
                feedback = "两路种子局部已对准。可保存两张全幅原图和两张原尺寸局部图。"
            }
        } else if camera.picking == "neutral" {
            operate("已记录 camera-\(index + 1) 的中性参照") {
                let sample = try self.panes[index].feed.neutralSample(at: point)
                DispatchQueue.main.async { camera.sample = sample }
            } completion: {
                camera.picking = ""
                self.panes[index].surface.points = [point]
            }
        } else if camera.picking == "corners" {
            camera.pickedPoints.append(point)
            panes[index].surface.points = camera.pickedPoints
            if camera.pickedPoints.count == 4 {
                if validQuadrilateral(camera.pickedPoints) {
                    camera.adjustments.perspective = camera.pickedPoints
                    softwareChanged(index: index)
                    feedback = "已将选中的四边形校正为矩形。"
                    error = false
                } else { report(PreviewError(message: "四角顺序或范围无效，请重新选择。")) }
                camera.picking = ""
                camera.pickedPoints = []
                panes[index].surface.points = []
            }
        }
    }

    func neutralizeSample(index: Int) {
        let camera = cameras[index]
        guard let sample = camera.sample else { return }
        let target = sample[0] * 0.2126 + sample[1] * 0.7152 + sample[2] * 0.0722
        var adjustments = camera.adjustments
        adjustments.enabled = true
        adjustments.exposureEV = 0
        adjustments.red = min(4, max(0.25, target / sample[0]))
        adjustments.green = min(4, max(0.25, target / sample[1]))
        adjustments.blue = min(4, max(0.25, target / sample[2]))
        camera.adjustments = adjustments
        softwareChanged(index: index)
        feedback = "camera-\(index + 1) 的色偏校正已保存。"
        error = false
    }

    func matchSamples() {
        guard let first = cameras[0].sample, let second = cameras[1].sample else {
            report(PreviewError(message: "请先在两路画面各选一次相同的中性材料。"))
            return
        }
        let firstMean = first.reduce(0.0, +) / 3.0
        let secondMean = second.reduce(0.0, +) / 3.0
        let samples = first + second
        let lowerTarget = samples.max()! * 0.25
        let upperTarget = samples.min()! * 4.0
        guard lowerTarget <= upperTarget else {
            report(PreviewError(message: "参照区域的色偏或亮度差超出安全增益范围，请重选中性区域。"))
            return
        }
        let luminance = min(upperTarget, max(lowerTarget, (firstMean * secondMean).squareRoot()))
        let gains = [first, second].map { $0.map { min(4, max(0.25, luminance / $0)) } }
        for index in cameras.indices {
            cameras[index].adjustments.enabled = true
            cameras[index].adjustments.red = gains[index][0]
            cameras[index].adjustments.green = gains[index][1]
            cameras[index].adjustments.blue = gains[index][2]
            cameras[index].adjustments.exposureEV = 0
            softwareChanged(index: index)
        }
        feedback = "已按两路中性参照对齐白平衡与亮度。"
        error = false
    }

    func exportSnapshots(includeMagnified: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = includeMagnified ? "选择存放原图和局部图的目录" : "选择存放原始画面和校正版的目录"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = parent.appendingPathComponent("双摄像头对照-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4))")
        let profile = document
        operate("对照快照已导出") {
            try self.exportSnapshots(to: folder, document: profile, includeMagnified: includeMagnified)
        } completion: {
            NSWorkspace.shared.open(folder)
        }
    }

    func exportSnapshots(to folder: URL, document: CameraSettingsDocument, includeMagnified: Bool = false) throws {
        let files = FileManager.default
        let staging = folder.deletingLastPathComponent().appendingPathComponent(".snapshot-\(UUID().uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        for index in panes.indices {
            let target = staging.appendingPathComponent("camera-\(index + 1)")
            try files.createDirectory(at: target, withIntermediateDirectories: false)
            try panes[index].feed.export(to: target, includeMagnified: includeMagnified)
            if let device = panes[index].feed.device {
                let actual = try uvc(device.uniqueID).controls()
                let data = try JSONEncoder().encode(actual.map { ["key": $0.key, "value": String($0.value)] })
                try data.write(to: target.appendingPathComponent("hardware.json"))
            }
        }
        try JSONEncoder().encode(document).write(to: staging.appendingPathComponent("camera-settings.json"))
        try files.moveItem(at: staging, to: folder)
    }

    func exportProfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "camera-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONEncoder().encode(document).write(to: url, options: .atomic); feedback = "参数已导出。"; error = false }
        catch { report(error) }
    }

    func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try JSONDecoder().decode(CameraSettingsDocument.self, from: Data(contentsOf: url))
            try imported.validate()
            guard cameras.allSatisfy({ !$0.deviceID.isEmpty }) else { throw PreviewError(message: "请先连接两路摄像头。") }
            for index in cameras.indices {
                let camera = cameras[index]
                guard let saved = imported.cameras[camera.deviceID] else { continue }
                if let width = saved.width, let height = saved.height {
                    let key = "\(width)×\(height)"
                    guard camera.formats.contains(where: { $0.id == key && $0.rates.contains(saved.fps) }) else {
                        throw PreviewError(message: "导入参数包含这台设备不支持的格式。")
                    }
                    camera.formatID = key
                    camera.fps = saved.fps
                }
            }
            for index in cameras.indices {
                let camera = cameras[index]
                guard let saved = imported.cameras[camera.deviceID] else { continue }
                camera.adjustments = saved.adjustments
                camera.desired.merge(saved.hardware) { _, value in value }
                camera.pendingHardware.formUnion(saved.hardware.keys)
                softwareChanged(index: index)
            }
            feedback = "校正已导入。硬件参数与分辨率可检查后点击「应用」。"
            error = false
        } catch { report(error) }
    }

    func importLens(index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let calibration = try JSONDecoder().decode(LensCalibration.self, from: Data(contentsOf: url))
            try calibration.validate()
            guard calibration.deviceID == cameras[index].deviceID else {
                throw PreviewError(message: "标定文件的设备 ID 与这台摄像头不一致。")
            }
            cameras[index].adjustments.lensCalibration = calibration
            cameras[index].adjustments.radialK1 = 0
            cameras[index].adjustments.radialK2 = 0
            softwareChanged(index: index)
            feedback = "已导入镜头标定，重投影 RMS \(String(format: "%.3f", calibration.reprojectionRMS)) px。"
            error = false
        } catch { report(error) }
    }

    private func operate(_ success: String, action: @escaping () throws -> Void, completion: @escaping () throws -> Void) {
        guard !busy else { return }
        busy = true
        feedback = "正在处理…"
        error = false
        queue.async {
            let result = Result { try CaptureScheduler().whileIdle(action) }
            DispatchQueue.main.async {
                self.busy = false
                do {
                    try result.get()
                    try completion()
                    self.feedback = success
                    self.error = false
                } catch {
                    self.report(error)
                    for index in self.cameras.indices { self.refreshHardware(index: index) }
                }
            }
        }
    }
}

enum CameraPanelStep: String, CaseIterable {
    case framing = "取景", focus = "对焦", color = "色彩", geometry = "校正"
    var hint: String {
        switch self {
        case .framing: return "先选分辨率，再调整取景范围与方向。"
        case .focus: return "放大查看细节，调清晰后锁定焦点。"
        case .color: return "固定照明后，先取样对齐，再微调颜色。"
        case .geometry: return "需要时校正镜头畸变或托盘透视。"
        }
    }
}

struct CameraControlsView: View {
    @ObservedObject var model: CameraTuningModel
    @State private var step: CameraPanelStep = .framing

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("相机设置").font(.headline)
                Picker("调整哪台相机", selection: $model.selected) {
                    Text("camera-1").tag(0); Text("camera-2").tag(1)
                }.pickerStyle(.segmented)
                Picker("调整步骤", selection: $step) {
                    ForEach(CameraPanelStep.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Text(step.hint).font(.caption).foregroundStyle(.secondary)
            }.padding(12)
            Divider()
            CameraSettingsPanel(camera: model.cameras[model.selected], model: model, index: model.selected, step: step)
                .id("\(model.selected)-\(step.rawValue)")
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("保存测试对照") { model.exportSnapshots() }
                        .help("选择文件夹，保存两路原图和校正图。预览放大不影响照片。")
                        .disabled(!model.allCamerasConnected)
                    Spacer()
                    Menu("参数配置") {
                        Button("导出全部参数…") { model.exportProfile() }
                        Button("导入参数…") { model.importProfile() }
                        Divider()
                        Button("读回当前设备参数") { model.refreshHardware(index: model.selected) }
                        Button("重置该路软件校正") { model.resetSoftware(index: model.selected) }
                    }.fixedSize()
                }
                if model.busy {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("正在应用设置…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if !model.feedback.isEmpty {
                    Text(model.feedback).font(.caption)
                        .foregroundStyle(model.error ? Color.orange : Color.secondary)
                        .lineLimit(3).help(model.feedback).textSelection(.enabled)
                }
            }.padding(12)
        }
        .frame(width: 330)
        .disabled(model.busy)
        .onChange(of: model.linkedFocus) { _, _ in model.scheduleLinkedFocus() }
    }
}

private struct CameraSettingsPanel: View {
    @ObservedObject var camera: CameraControlState
    @ObservedObject var model: CameraTuningModel
    let index: Int
    let step: CameraPanelStep

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func softwareSlider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title); Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 5) {
                    Circle().fill(camera.isConnected ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(camera.isConnected ? "camera-\(index + 1) · \(camera.statistics.resolution) · \(Int(camera.statistics.fps.rounded())) fps" : "等待相机连接")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if camera.statistics.black {
                    Label("画面接近全黑，请检查照明和连接。", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                switch step {
                case .framing: formatControls; deviceZoom; directionControls
                case .focus: magnifier; manualFocus; linkedFocus; focusMetrics
                case .color: colorMatch; colorControls; hardwareControls
                case .geometry: geometryControls
                }
                if !camera.hardwareError.isEmpty { Text(camera.hardwareError).font(.caption).foregroundStyle(.orange) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!camera.isConnected)
        }
        .onChange(of: camera.adjustments) { _, _ in model.softwareChanged(index: index) }
        .onChange(of: camera.grid) { _, _ in model.softwareChanged(index: index) }
        .onChange(of: camera.formatID) { _, _ in
            if let format = camera.formats.first(where: { $0.id == camera.formatID }), !format.rates.contains(camera.fps) {
                camera.fps = format.rates.first ?? 25
            }
            model.scheduleFormat(index: index)
        }
        .onChange(of: camera.fps) { _, _ in model.scheduleFormat(index: index) }
    }

    private var formatControls: some View {
        GroupBox("采集画质") {
            VStack(alignment: .leading, spacing: 9) {
                Picker("分辨率", selection: $camera.formatID) {
                    ForEach(camera.formats) { Text($0.id).tag($0.id) }
                }
                Picker("帧率", selection: $camera.fps) {
                    ForEach(camera.formats.first(where: { $0.id == camera.formatID })?.rates ?? [25], id: \.self) {
                        Text("\(Int($0)) fps").tag($0)
                    }
                }
                note("选择后自动应用，以实际视频流为准。")
                DisclosureGroup("连接与格式详情") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(camera.deviceID).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("重新应用当前格式") { model.applyFormat(index: index) }
                    }.padding(.top, 6)
                }.font(.caption)
            }.padding(5)
        }
    }

    private var deviceZoom: some View {
        GroupBox("设备变焦 · 调整取景范围") {
            VStack(alignment: .leading, spacing: 9) {
                if let zoom = camera.controls.first(where: { $0.key == "zoom" }) {
                    HStack {
                        Text("拉近 / 拉远")
                        Spacer()
                        Text("\(camera.desired["zoom"] ?? zoom.value)").monospacedDigit()
                        Button("复位") { model.scheduleDeviceZoom(index: index, value: Double(zoom.defaultValue)) }
                            .disabled(!zoom.writable)
                    }
                    if zoom.max > zoom.min {
                        Slider(value: Binding(get: { Double(camera.desired["zoom"] ?? zoom.value) },
                            set: { model.scheduleDeviceZoom(index: index, value: $0) }),
                            in: Double(zoom.min)...Double(zoom.max), step: Double(max(1, zoom.step)))
                            .disabled(!zoom.writable || !camera.picking.isEmpty)
                    }
                    note("影响预览和后续采集。变焦后到「对焦」重新调清晰并锁定。")
                    DisclosureGroup("设备刻度说明") {
                        note("范围 \(zoom.min)…\(zoom.max)。设备未提供光学倍率，数值不是手机的 × 倍率。")
                            .padding(.top, 6)
                    }.font(.caption)
                } else { note("当前设备未读到变焦控制。") }
            }.padding(5)
        }
    }

    private var directionControls: some View {
        GroupBox("预览方向") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("顺时针旋转", selection: $camera.adjustments.rotation) {
                    Text("0°").tag(0); Text("90°").tag(1); Text("180°").tag(2); Text("270°").tag(3)
                }
                Toggle("水平镜像", isOn: $camera.adjustments.mirror)
                note("用于预览和采集校正图。数据浏览可以切换相机原图。")
            }.padding(5)
        }
    }

    private var magnifier: some View {
        GroupBox("放大检查细节") {
            VStack(alignment: .leading, spacing: 9) {
                if model.cameras.contains(where: { $0.picking == "seedDetail" }) {
                    Button("取消点选种子") { model.cancelSeedDetail() }
                } else {
                    Button("双路点选同一颗种子") { model.beginSeedDetail() }
                        .disabled(!model.allCamerasConnected)
                }
                HStack {
                    Text("预览放大"); Spacer()
                    Text(String(format: "%.2f×", camera.previewMagnification)).monospacedDigit()
                }
                HStack {
                    ForEach([1.0, 1.25, 1.5, 2.0, 4.0], id: \.self) { factor in
                        Button(String(format: "%g×", factor)) { model.setPreviewMagnification(index: index, value: factor) }
                    }
                }
                Slider(value: Binding(get: { camera.previewMagnification },
                    set: { model.setPreviewMagnification(index: index, value: $0) }), in: 1...4, step: 0.05)
                Button(camera.seedDetailCenter == nil ? "保存原图和当前倍率放大图" : "保存原图和种子局部") {
                    model.exportSnapshots(includeMagnified: true)
                }.disabled(!model.allCamerasConnected || (camera.previewMagnification <= 1 && camera.seedDetailCenter == nil))
                note(camera.seedDetailCenter == nil ? "选定种子后可放大查看，并另存原像素局部。" :
                     "保留全幅原图。局部 PNG 以原像素裁切，并记录在校正图中的坐标。")
            }.padding(5)
        }.disabled(!camera.picking.isEmpty && camera.picking != "seedDetail")
    }

    private var manualFocus: some View {
        GroupBox("对焦与锁定") {
            VStack(alignment: .leading, spacing: 10) {
                if let focus = camera.controls.first(where: { $0.key == "focus" && $0.writable }) {
                    HStack {
                        Label(camera.focusLocked ? "焦点已锁定" : (camera.desired["focusAuto"] == 1 ? "自动对焦中" : "手动调节中"),
                              systemImage: camera.focusLocked ? "lock.fill" : "camera.aperture")
                        Spacer()
                        Text("\(camera.desired["focus"] ?? focus.value)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("自动对焦") { model.enableAutomaticFocus(index: index) }
                            .disabled(camera.desired["focusAuto"] == 1)
                        Button(camera.focusLocked ? "解锁调节" : "手动对焦") { model.setManualFocus(index: index) }
                    }
                    VStack(spacing: 7) {
                        Slider(value: Binding(get: { Double(camera.desired["focus"] ?? focus.value) },
                            set: { model.scheduleManualFocus(index: index, value: $0) }),
                            in: Double(focus.min)...Double(focus.max), step: Double(max(1, focus.step)))
                        HStack {
                            ForEach([-10, -1, 1, 10], id: \.self) { offset in
                                Button(offset > 0 ? "+\(offset)" : "\(offset)") {
                                    model.setManualFocus(index: index,
                                        value: (camera.desired["focus"] ?? focus.value) + offset * max(1, focus.step))
                                }
                            }
                        }
                    }.disabled(camera.focusLocked || camera.desired["focusAuto"] != 0)
                    Button("锁定此路焦点") { model.setManualFocus(index: index, locked: true) }
                        .disabled(camera.focusLocked || camera.desired["focusAuto"] != 0)
                    Button("重新寻焦并锁定此路") { model.setManualFocus(index: index, locked: true, scan: true) }
                    if camera.picking == "focus" {
                        Button("取消局部寻焦") { model.cancelPick(index: index) }
                    } else {
                        Button("点选种子附近寻焦并锁定") { model.beginPick("focus", index: index) }
                    }
                    note("手动锁定会恢复焦点刻度。点选种子寻焦后，采集时还会复核该处的边缘。")
                } else { note("连接后读取对焦能力。") }
            }.padding(5)
        }
    }

    private var linkedFocus: some View {
        DisclosureGroup("高级 · 两路同步对焦") {
            VStack(alignment: .leading, spacing: 9) {
                Toggle("两路自动对焦", isOn: Binding(get: { model.linkedAutoFocus },
                    set: { model.applyLinkedFocus(automatic: $0) }))
                HStack {
                    Button(model.linkedFocusLocked ? "解锁两路" : "寻焦并锁定两路") {
                        if model.linkedFocusLocked { model.unlockManualFocus() }
                        else { model.lockCurrentFocus() }
                    }
                    Button("恢复默认") { model.restoreLinkedFocus() }
                }
                Button("重新寻焦并锁定两路") { model.lockCurrentFocus(scan: true) }
                Slider(value: $model.linkedFocus, in: 0...1)
                    .disabled(model.linkedAutoFocus || model.cameras.contains(where: { $0.focusLocked }))
                note(model.focusStatus)
                note("同步滑杆按各自设备范围换算，同时移动两路镜头。")
            }.padding(.top, 8)
        }
    }

    private var focusMetrics: some View {
        DisclosureGroup("对焦参考指标") {
            VStack(alignment: .leading, spacing: 7) {
                Text("亮度 \(camera.statistics.mean.formatted(.number.precision(.fractionLength(1)))) / 255")
                Text("边缘指标 \(camera.statistics.sharpness.formatted(.number.precision(.fractionLength(1))))")
                note("仅用于同机位、同光照下比较。")
            }.font(.callout).padding(.top, 8)
        }
    }

    private var colorMatch: some View {
        GroupBox("先对齐两路颜色") {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Button("取色 1 · 上方") { model.beginPick("neutral", index: 0) }
                    Button("取色 2 · 下方") { model.beginPick("neutral", index: 1) }
                }
                Button("校正 camera-\(index + 1) 色偏") { model.neutralizeSample(index: index) }
                    .disabled(camera.sample == nil)
                Button("匹配两路颜色") { model.matchSamples() }
                    .disabled(model.cameras.contains(where: { $0.sample == nil }))
                if !camera.picking.isEmpty { Button("取消取样") { model.cancelPick(index: index) } }
                note("点取色按钮，再点对应画面里没有文字或反光的白纸或灰卡。成功时显示黄点。")
            }.padding(5)
        }
    }

    private var colorControls: some View {
        GroupBox("软件色彩校正") {
            VStack(alignment: .leading, spacing: 9) {
                Toggle("启用软件校正", isOn: $camera.adjustments.enabled)
                note("预览和采集校正图使用同一套设置。")
                softwareSlider("亮度补偿（EV）", $camera.adjustments.exposureEV, -3...3)
                softwareSlider("饱和度", $camera.adjustments.saturation, 0...2)
                DisclosureGroup("手动微调") {
                    VStack(spacing: 9) {
                        softwareSlider("红色增益", $camera.adjustments.red, 0.25...4)
                        softwareSlider("绿色增益", $camera.adjustments.green, 0.25...4)
                        softwareSlider("蓝色增益", $camera.adjustments.blue, 0.25...4)
                        softwareSlider("色相（弧度）", $camera.adjustments.hue, -0.5...0.5)
                        softwareSlider("对比度", $camera.adjustments.contrast, 0.5...1.5)
                        softwareSlider("锐化", $camera.adjustments.sharpness, 0...0.6)
                    }.padding(.top, 8)
                }
            }.padding(5)
        }
    }

    private var hardwareControls: some View {
        DisclosureGroup("高级 · 硬件图像参数") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(camera.controls.filter { !["focus", "focusAuto", "zoom"].contains($0.key) }) { control in
                    if control.isToggle {
                        Toggle(control.title, isOn: Binding(get: { camera.desired[control.key] == 1 },
                            set: { camera.desired[control.key] = $0 ? 1 : 0; camera.pendingHardware.insert(control.key) }))
                            .disabled(!control.writable)
                    } else if control.max > control.min {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(control.title + (control.writable ? "" : "（只读）")); Spacer()
                                Text("\(camera.desired[control.key] ?? control.value)").monospacedDigit().foregroundStyle(.secondary)
                            }
                            Slider(value: camera.controlBinding(control.key), in: Double(control.min)...Double(control.max),
                                   step: Double(max(1, control.step)))
                        }.disabled(!control.writable || (control.key == "temperature" && camera.desired["whiteBalanceAuto"] == 1))
                    }
                }
                note("硬件参数影响相机输出，需要点击应用。只读项未通过写入确认；全部能力与范围见顶部「设备信息」。")
                HStack {
                    Button("应用硬件参数") { model.applyHardware(index: index) }
                    Button("读回") { model.refreshHardware(index: index) }
                }
                Button("两路固定为 camera-1 的色温") { model.alignTemperature() }
                Button("恢复硬件默认值") { model.applyHardware(index: index, defaults: true) }
            }.padding(.top, 8)
        }
    }

    private var geometryControls: some View {
        GroupBox("镜头与托盘几何校正") {
            VStack(alignment: .leading, spacing: 10) {
                note("用于预览与校正导出。建议先固定分辨率、变焦和焦点。")
                Toggle("显示校准网格", isOn: $camera.grid)
                Button("点选四角，校正托盘透视") { model.beginPick("corners", index: index) }
                if !camera.picking.isEmpty { Button("取消取点") { model.cancelPick(index: index) } }
                Button("导入棋盘格镜头标定…") { model.importLens(index: index) }
                if let calibration = camera.adjustments.lensCalibration {
                    note("已标定 · RMS \(calibration.reprojectionRMS.formatted(.number.precision(.fractionLength(3)))) px")
                }
                DisclosureGroup("高级 · 手动畸变参数") {
                    VStack(spacing: 9) {
                        softwareSlider("径向系数 k₁", $camera.adjustments.radialK1, -0.35...0.35)
                        softwareSlider("径向系数 k₂", $camera.adjustments.radialK2, -0.15...0.15)
                        softwareSlider("光心 X", $camera.adjustments.centerX, 0.2...0.8)
                        softwareSlider("光心 Y", $camera.adjustments.centerY, 0.2...0.8)
                    }.padding(.top, 8)
                }
                Button("清除几何校正") {
                    camera.adjustments.radialK1 = 0; camera.adjustments.radialK2 = 0
                    camera.adjustments.perspective = []; camera.adjustments.lensCalibration = nil
                }
                note("直线弯曲可调整径向系数；平行线汇聚可点选四角。校正边缘可能出现黑边。")
            }.padding(5)
        }
    }
}
