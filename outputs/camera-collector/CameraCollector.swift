import AppKit
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Vision

enum CollectorError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

struct CollectorCameraSettings: Decodable {
    var deviceID: String
    var width: Int?
    var height: Int?
    var fps: Double
    var hardware: [String: Int]
    var focusLocked: Bool?
    var focusApproach: Int?
    var subjectFocus: SubjectFocusPoint?
    #if COLLECTOR_LIBRARY
    var adjustments: CameraAdjustments?
    #endif
}

struct SubjectFocusPoint: Codable {
    var x: Double
    var y: Double

    var isValid: Bool {
        (0...1).contains(x) && (0...1).contains(y)
    }
}

struct CapturedFocus: Encodable {
    let position: Int
    let edgeScore: Double
}

struct CollectorSettingsFile: Decodable {
    var version: Int
    var cameras: [String: CollectorCameraSettings]
}

struct CollectorUSBControl: Decodable {
    var key: String
    var value: Int
    var min: Int?
    var max: Int?
    var step: Int?
}

func cameraControl(device: AVCaptureDevice, command: [String]) throws -> String {
    guard let binary = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("uvc-control"),
          FileManager.default.isExecutableFile(atPath: binary.path) else {
        throw CollectorError.message("采集程序缺少 USB 控制组件。")
    }
    let id = device.uniqueID.lowercased().replacingOccurrences(of: "0x", with: "")
    let process = Process()
    let pipe = Pipe()
    process.executableURL = binary
    process.arguments = [String(id.dropLast(8))] + command
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: bytes, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw CollectorError.message("摄像头参数设置失败：\(text)")
    }
    return text
}

func applyCaptureSettings(_ saved: CollectorCameraSettings?, device: AVCaptureDevice) throws {
    guard let saved else { return }
    guard saved.deviceID == device.uniqueID, saved.fps.isFinite, (1...120).contains(saved.fps),
          (saved.width == nil) == (saved.height == nil) else {
        throw CollectorError.message("采集参数中的设备 ID 或帧率无效。")
    }
    if saved.focusLocked == true && (saved.hardware["focusAuto"] != 0 || saved.hardware["focus"] == nil) {
        throw CollectorError.message("焦点锁定参数不完整，请在预览软件重新锁定。")
    }
    if let width = saved.width, let height = saved.height {
        guard let format = device.formats.first(where: {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return size.width == width && size.height == height &&
                $0.videoSupportedFrameRateRanges.contains { saved.fps >= $0.minFrameRate - 0.01 && saved.fps <= $0.maxFrameRate + 0.01 }
        }) else {
            throw CollectorError.message("采集设备没有提供保存的分辨率和帧率。")
        }
        try device.lockForConfiguration()
        device.activeFormat = format
        let range = format.videoSupportedFrameRateRanges.first {
            saved.fps >= $0.minFrameRate - 0.01 && saved.fps <= $0.maxFrameRate + 0.01
        }!
        let wanted = CMTime(seconds: 1 / saved.fps, preferredTimescale: 1_000_000_000)
        let duration = CMTimeCompare(wanted, range.minFrameDuration) < 0 ? range.minFrameDuration :
            (CMTimeCompare(wanted, range.maxFrameDuration) > 0 ? range.maxFrameDuration : wanted)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }
    if let automatic = saved.hardware["focusAuto"] {
        let mode: AVCaptureDevice.FocusMode = automatic == 0 ? .locked : .continuousAutoFocus
        guard device.isFocusModeSupported(mode) else {
            throw CollectorError.message("设备不支持保存的对焦模式。")
        }
        try device.lockForConfiguration()
        device.focusMode = mode
        device.unlockForConfiguration()
    }
    let automaticKeys = ["focusAuto", "whiteBalanceAuto", "exposureAuto", "zoom"]
    let keys = automaticKeys.filter { saved.hardware[$0] != nil } +
        saved.hardware.keys.sorted().filter { !automaticKeys.contains($0) }
    for key in keys {
        if key == "focus" && (saved.hardware["focusAuto"] == 1 ||
                              (saved.focusLocked == true && saved.focusApproach != nil &&
                               saved.focusApproach != saved.hardware["focus"])) { continue }
        if key == "temperature" && saved.hardware["whiteBalanceAuto"] == 1 { continue }
        _ = try cameraControl(device: device, command: ["set", key, String(saved.hardware[key]!)])
    }
}

func verifyCaptureFocus(_ saved: CollectorCameraSettings?, device: AVCaptureDevice) throws {
    guard let saved, saved.hardware["focusAuto"] == 0, let position = saved.hardware["focus"] else { return }
    let data = Data(try cameraControl(device: device, command: ["list"]).utf8)
    let actual = try JSONDecoder().decode([CollectorUSBControl].self, from: data)
    guard actual.first(where: { $0.key == "focusAuto" })?.value == 0,
          let focus = actual.first(where: { $0.key == "focus" })?.value,
          abs(focus - position) <= 4 else {
        throw CollectorError.message("设备的实际焦点与锁定参数不符，本轮采集失败。")
    }
}

func approachLockedFocus(device: AVCaptureDevice, from approach: Int, to target: Int) throws {
    guard approach != target else { return }
    for attempt in 0..<3 {
        do {
            _ = try cameraControl(device: device, command: ["set", "focus", String(approach)])
            Thread.sleep(forTimeInterval: 1.25)
            _ = try cameraControl(device: device, command: ["set", "focus", String(target)])
            return
        } catch {
            guard attempt < 2 else { throw error }
            Thread.sleep(forTimeInterval: 0.7)
        }
    }
}

private func hasFocusOverlay(_ buffer: CVPixelBuffer) throws -> Bool {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.regionOfInterest = CGRect(x: 0, y: 0.75, width: 0.85, height: 0.25)
    try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
    return request.results?.contains { observation in
        guard let text = observation.topCandidates(1).first?.string else { return false }
        return text.contains("聚焦模式") || text.contains("对焦模式")
    } ?? false
}

func subjectEdgeScore(_ buffer: CVPixelBuffer, point: SubjectFocusPoint, context: CIContext, requireContrast: Bool = false) -> Double {
    let colorSpace = CGColorSpace(name: CGColorSpace.linearGray)!
    let image = CIImage(cvPixelBuffer: buffer)
    let extent = image.extent
    let radius = (Swift.min(extent.width, extent.height) * 0.075).rounded()
    let roi = CGRect(x: extent.width * point.x - radius,
                     y: extent.height * (1 - point.y) - radius,
                     width: radius * 2, height: radius * 2).integral.intersection(extent)
    guard roi.width > 8, roi.height > 8 else { return 0 }
    let width = Int(roi.width)
    let height = Int(roi.height)
    var pixels = [UInt8](repeating: 0, count: width * height)
    context.render(image, toBitmap: &pixels, rowBytes: width, bounds: roi,
                   format: .L8, colorSpace: colorSpace)
    var fine = 0.0
    var broad = 0.0
    for y in 4..<(height - 4) {
        for x in 4..<(width - 4) {
            let p = y * width + x
            let dx = Double(pixels[p + 1]) - Double(pixels[p - 1])
            let dy = Double(pixels[p + width]) - Double(pixels[p - width])
            let wideX = Double(pixels[p + 4]) - Double(pixels[p - 4])
            let wideY = Double(pixels[p + width * 4]) - Double(pixels[p - width * 4])
            let wideEnergy = wideX * wideX + wideY * wideY
            if requireContrast && wideEnergy < 144 { continue }
            fine += dx * dx + dy * dy
            broad += wideEnergy
        }
    }
    if requireContrast { return fine / Double(width * height) }
    return broad > 0 ? fine / broad : 0
}

final class FrameCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "local.dataset.camera.frames")
    private let frameReady = DispatchSemaphore(value: 0)
    private var earliestFrame = DispatchTime.distantFuture
    private var pixelBuffer: CVPixelBuffer?
    private(set) var capturedFocus: CapturedFocus?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard pixelBuffer == nil, DispatchTime.now() >= earliestFrame,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        pixelBuffer = buffer
        frameReady.signal()
    }

    private func sampleFrame(after delay: DispatchTimeInterval, timeout: Int) throws -> CVPixelBuffer {
        queue.sync {
            pixelBuffer = nil
            earliestFrame = .now() + delay
        }
        guard frameReady.wait(timeout: .now() + .seconds(timeout)) == .success,
              let buffer = queue.sync(execute: { pixelBuffer }) else {
            throw CollectorError.message("等待摄像头视频帧超时。")
        }
        return buffer
    }

    private func bestSubjectFrame(_ original: CVPixelBuffer, point: SubjectFocusPoint,
                                  target: Int, device: AVCaptureDevice) throws -> CVPixelBuffer {
        let data = Data(try cameraControl(device: device, command: ["list"]).utf8)
        let controls = try JSONDecoder().decode([CollectorUSBControl].self, from: data)
        guard let control = controls.first(where: { $0.key == "focus" }),
              let min = control.min, let max = control.max, let step = control.step, step > 0, max > min else { return original }
        let interval = Swift.max(step, ((max - min) / 36 / step) * step)
        let positions = Set((-4...4).map { offset in Swift.min(max, Swift.max(min, target + offset * interval)) })
        let context = CIContext()


        var best = original
        let initialScore = subjectEdgeScore(original, point: point, context: context)
        var reading = CapturedFocus(position: control.value, edgeScore: initialScore)
        defer { _ = try? cameraControl(device: device, command: ["set", "focus", String(target)]) }
        for position in positions.sorted() {
            do { _ = try cameraControl(device: device, command: ["set", "focus", String(position)]) }
            catch { continue }
            let candidate = try sampleFrame(after: .milliseconds(650), timeout: 4)
            guard CVPixelBufferGetWidth(candidate) == CVPixelBufferGetWidth(original),
                  CVPixelBufferGetHeight(candidate) == CVPixelBufferGetHeight(original) else { continue }
            let quality = subjectEdgeScore(candidate, point: point, context: context)
            guard quality > reading.edgeScore * 1.025 else { continue }
            guard try !hasFocusOverlay(candidate) else { continue }
            best = candidate
            reading = CapturedFocus(position: position, edgeScore: quality)
        }
        capturedFocus = reading
        return best
    }

    func frame(from device: AVCaptureDevice, settings: CollectorCameraSettings?) throws -> CVPixelBuffer {
        let session = AVCaptureSession()
        if settings?.width == nil && session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddInput(input) else {
            throw CollectorError.message("无法打开输入 \(device.localizedName) [\(device.uniqueID)]。")
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            throw CollectorError.message("无法从 \(device.localizedName) 接收视频帧。")
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        try applyCaptureSettings(settings, device: device)
        try device.lockForConfiguration()
        session.startRunning()
        device.unlockForConfiguration()
        defer {
            output.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
        }

        try applyCaptureSettings(settings, device: device)
        if let settings, settings.focusLocked == true,
           let approach = settings.focusApproach, let target = settings.hardware["focus"], approach != target {
            Thread.sleep(forTimeInterval: 0.6)
            try approachLockedFocus(device: device, from: approach, to: target)
        }
        // This camera draws a temporary focus-mode message into its video
        // after the capture session or focus mode changes.
        for attempt in 0..<3 {
            let buffer = try sampleFrame(after: .seconds(7), timeout: 20)
            if let width = settings?.width, let height = settings?.height {
                guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else {
                    throw CollectorError.message("采集到的图像尺寸与保存的分辨率不符。")
                }
            }
            do {
                try verifyCaptureFocus(settings, device: device)
            } catch {
                guard attempt < 2, let target = settings?.hardware["focus"] else { throw error }
                _ = try cameraControl(device: device, command: ["set", "focusAuto", "0"])
                if let approach = settings?.focusApproach, approach != target {
                    try approachLockedFocus(device: device, from: approach, to: target)
                } else {
                    _ = try cameraControl(device: device, command: ["set", "focus", String(target)])
                }
                continue
            }
            if try hasFocusOverlay(buffer) {
                guard attempt < 2 else {
                    throw CollectorError.message("摄像头仍在画面中显示对焦提示，本轮采集未保存。")
                }
                continue
            }
            if let settings, settings.focusLocked == true, let point = settings.subjectFocus, point.isValid,
               let position = settings.hardware["focus"] {
                return (try? bestSubjectFrame(buffer, point: point, target: position, device: device)) ?? buffer
            }
            return buffer
        }
        throw CollectorError.message("无法核对采集焦点。")
    }
}

func externalCameras() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external], mediaType: .video, position: .unspecified
    ).devices.sorted { $0.uniqueID < $1.uniqueID }
}

func ensureCameraAccess(canPrompt: Bool) throws {
    let authorization = AVCaptureDevice.authorizationStatus(for: .video)
    if authorization == .authorized { return }
    if authorization == .notDetermined && canPrompt {
        let answered = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            NSApp.activate()
            AVCaptureDevice.requestAccess(for: .video) { _ in answered.signal() }
        }
        guard answered.wait(timeout: .now() + 120) == .success else {
            throw CollectorError.message("等待相机授权超时。请重新运行 setup 并允许相机访问。")
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { return }
    }
    throw CollectorError.message(
        "相机权限状态为 \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)（2 代表拒绝）。请在系统设置 → 隐私与安全性 → 相机里允许 Camera Collector。"
    )
}

func savePair(cameras: [AVCaptureDevice], settings: [String: CollectorCameraSettings], in dataset: URL) throws -> URL {
    let files = FileManager.default
    try files.createDirectory(at: dataset, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS_Z"
    let identifier = UUID().uuidString.prefix(8)
    let batch = dataset.appendingPathComponent("\(formatter.string(from: Date()))_\(identifier)", isDirectory: true)
    let staging = dataset.appendingPathComponent(".pending-\(identifier)", isDirectory: true)
    try files.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: staging) }

    let context = CIContext()
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
    func saveJPEG(_ image: CIImage, name: String, context: CIContext) throws {
        guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: 0.97]) else {
            throw CollectorError.message("JPEG 编码失败。")
        }
        try data.write(to: staging.appendingPathComponent(name))
    }
    #if COLLECTOR_LIBRARY
    let processor = CameraProcessor()
    let saveAdjustedPair = cameras.allSatisfy { settings[$0.uniqueID]?.adjustments != nil }
    #endif
    var chosenFocus: [String: CapturedFocus] = [:]
    for (index, camera) in cameras.enumerated() {
        let saved = settings[camera.uniqueID]
        let capture = FrameCapture()
        let image = CIImage(cvPixelBuffer: try capture.frame(from: camera, settings: saved))
        chosenFocus["camera-\(index + 1)"] = capture.capturedFocus
        try saveJPEG(image, name: "camera-\(index + 1).jpg", context: context)
        #if COLLECTOR_LIBRARY
        if saveAdjustedPair, let adjustments = saved?.adjustments {
            try adjustments.validate()
            let adjusted = try processor.process(image, settings: adjustments)
            try saveJPEG(adjusted, name: "camera-\(index + 1)-adjusted.jpg", context: processor.context)
        }
        #endif
    }
    if !chosenFocus.isEmpty {
        let data = try JSONEncoder().encode(chosenFocus)
        try data.write(to: staging.appendingPathComponent("capture-focus.json"))
    }
    try files.moveItem(at: staging, to: batch)
    return batch
}

func run(mode: String, root: URL) throws -> String {
    if mode == "authorize" {
        try ensureCameraAccess(canPrompt: true)
        return "采集程序的相机权限已允许。"
    }
    if mode == "probe" {
        let list = externalCameras().map { "\($0.localizedName) [\($0.uniqueID)]" }
        return ([
            "相机权限状态：\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)（0 未请求，1 受限，2 拒绝，3 允许）",
            "AVFoundation 识别的外接摄像头：\(list.count) 台"
        ] + list).joined(separator: "\n")
    }

    let lock = open(root.appendingPathComponent(".camera.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        throw CollectorError.message("已有采集进程在使用摄像头。")
    }
    try ensureCameraAccess(canPrompt: mode == "setup")
    let cameras = externalCameras()
    let config = root.appendingPathComponent("cameras.json")
    let selected: [AVCaptureDevice]
    if mode == "setup" {
        let matching = cameras.filter { $0.localizedName == "4K USB Camera" }
        guard matching.count == 2, matching[0].uniqueID != matching[1].uniqueID else {
            let devices = cameras.map { "\($0.localizedName) [\($0.uniqueID)]" }.joined(separator: "、")
            throw CollectorError.message("需要两台能区分的 4K USB Camera，AVFoundation 找到 \(matching.count) 台同名设备。外接设备：\(devices)")
        }
        selected = matching
    } else {
        let ids = try JSONDecoder().decode([String].self, from: Data(contentsOf: config))
        guard ids.count == 2, ids[0] != ids[1] else {
            throw CollectorError.message("摄像头配置无效。请重新运行 setup。")
        }
        selected = try ids.map { id in
            guard let camera = cameras.first(where: { $0.uniqueID == id }) else {
                throw CollectorError.message("找不到已配置的摄像头 [\(id)]。请检查原来的 USB 端口和连接。")
            }
            return camera
        }
    }

    let settingsFile = root.appendingPathComponent("camera-settings.json")
    var settings: [String: CollectorCameraSettings] = [:]
    if FileManager.default.fileExists(atPath: settingsFile.path) {
        let document = try JSONDecoder().decode(CollectorSettingsFile.self, from: Data(contentsOf: settingsFile))
        guard document.version == 1 else { throw CollectorError.message("采集参数文件版本不支持。") }
        settings = document.cameras
    }
    let batch = try savePair(cameras: selected, settings: settings, in: root.appendingPathComponent("dataset", isDirectory: true))
    if mode == "setup" {
        try JSONEncoder().encode(selected.map(\.uniqueID)).write(to: config, options: .atomic)
    }
    let mapping = selected.enumerated().map { "camera-\($0.offset + 1).jpg → \($0.element.localizedName) [\($0.element.uniqueID)]" }
    return (["已保存两张照片：\(batch.path)"] + mapping).joined(separator: "\n")
}

#if !COLLECTOR_LIBRARY
@main
struct CameraCollectorMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, ["probe", "setup", "capture", "authorize"].contains(arguments[1]) else {
            FileHandle.standardError.write(Data("请通过 camera-collector.sh 启动。\n".utf8))
            exit(64)
        }
        startCollector(mode: arguments[1], root: arguments[2], receipt: arguments[3])
    }
}
#endif

func startCollector(mode: String, root: String, receipt: String) {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.finishLaunching()
    DispatchQueue.global(qos: .userInitiated).async {
        let result: String
        do {
            result = try "OK\n\(run(mode: mode, root: URL(fileURLWithPath: root, isDirectory: true)))\n"
        } catch {
            result = "ERROR\n\(error.localizedDescription)\n"
        }
        do {
            try Data(result.utf8).write(to: URL(fileURLWithPath: receipt), options: .atomic)
            exit(result.hasPrefix("OK\n") ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    application.run()
}
