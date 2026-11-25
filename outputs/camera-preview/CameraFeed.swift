import AppKit
import AVFoundation
import CoreImage

final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "local.dataset.dual-camera-preview.frames")
    private let lock = NSLock()
    private let processor = CameraProcessor()
    private var settings = CameraAdjustments()
    private var magnification = 1.0
    private var detailCenter: NormalizedPoint?
    private var latestBuffer: CVPixelBuffer?
    private var latestStats = FrameStatistics()
    private var presentationPending = false
    private var generation = 0
    private var lastRender = Date.distantPast
    private var lastMetric = Date.distantPast
    private var frames = 0
    private var metricStart = Date()
    private let frameCondition = NSCondition()
    private var frameSequence = 0
    private var deliveredWidth = 0
    private var deliveredHeight = 0
    private(set) var device: AVCaptureDevice?
    var onImage: ((CGImage) -> Void)?
    var onError: ((String) -> Void)?

    var adjustments: CameraAdjustments {
        get { lock.withLock { settings } }
        set { lock.withLock { settings = newValue } }
    }

    var statistics: FrameStatistics { lock.withLock { latestStats } }

    // View-only inspection; raw buffers and exported/captured images keep their full field of view.
    var previewMagnification: Double {
        get { lock.withLock { magnification } }
        set { lock.withLock { magnification = newValue.isFinite ? min(4, max(1, newValue)) : 1 } }
    }

    var seedDetailCenter: NormalizedPoint? {
        get { lock.withLock { detailCenter } }
        set { lock.withLock { detailCenter = newValue } }
    }

    static func formats(for device: AVCaptureDevice) -> [CameraFormat] {
        var resolutions: [String: CameraFormat] = [:]
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let key = "\(dimensions.width)×\(dimensions.height)"
            let rates = format.videoSupportedFrameRateRanges.flatMap { range in
                [25.0, 30.0, 50.0, 60.0].filter { $0 >= range.minFrameRate - 0.01 && $0 <= range.maxFrameRate + 0.01 }
            }
            let existing = resolutions[key]?.rates ?? []
            resolutions[key] = CameraFormat(width: Int(dimensions.width), height: Int(dimensions.height),
                                            rates: Array(Set(existing + rates)).sorted())
        }
        return resolutions.values.sorted {
            $0.width * $0.height == $1.width * $1.height ? $0.width < $1.width : $0.width * $0.height < $1.width * $1.height
        }
    }

    // Called exclusively on the application's capture-session queue.
    func start(device: AVCaptureDevice, saved: SavedCameraSettings?) throws {
        self.device = device
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        for oldInput in session.inputs { session.removeInput(oldInput) }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw PreviewError(message: "无法打开摄像头，请检查 USB 连接。")
        }
        session.addInput(input)
        if session.outputs.isEmpty {
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw PreviewError(message: "无法读取摄像头的视频帧。")
            }
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)
            session.addOutput(output)
        }
        session.commitConfiguration()
        if let saved { adjustments = saved.adjustments }
        let defaultSize = CameraFeed.formats(for: device).first { $0.width == 1080 && $0.height == 1920 }
        try setFormat(width: saved?.width ?? defaultSize?.width ?? 1920,
                      height: saved?.height ?? defaultSize?.height ?? 1080, fps: saved?.fps ?? 25)
        try setAutomaticFocus(saved?.hardware["focusAuto"] != 0)
        try device.lockForConfiguration()
        session.startRunning()
        device.unlockForConfiguration()
        guard session.isRunning else { throw PreviewError(message: "预览启动失败，请检查连接后重连。") }
        try waitForFrames(width: saved?.width ?? defaultSize?.width ?? 1920,
                          height: saved?.height ?? defaultSize?.height ?? 1080, after: 0)
    }

    func setAutomaticFocus(_ enabled: Bool) throws {
        guard let device else { throw PreviewError(message: "摄像头尚未连接。") }
        let mode: AVCaptureDevice.FocusMode = enabled ? .continuousAutoFocus : .locked
        guard device.isFocusModeSupported(mode) else {
            throw PreviewError(message: "摄像头不支持所选的对焦模式。")
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.focusMode = mode
        guard device.focusMode == mode else {
            throw PreviewError(message: "macOS 没有接受对焦模式设置。")
        }
        previewLog("\(device.uniqueID) 对焦模式 \(enabled ? "连续自动" : "手动锁定")，已核对")
    }

    func setFormat(width: Int, height: Int, fps: Double) throws {
        guard let device, let format = device.formats.first(where: {
            let dimensions = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dimensions.width == width && dimensions.height == height &&
                $0.videoSupportedFrameRateRanges.contains { fps >= $0.minFrameRate - 0.01 && fps <= $0.maxFrameRate + 0.01 }
        }) else {
            throw PreviewError(message: "摄像头没有提供所选分辨率与帧率组合。")
        }
        let old = device.activeFormat
        let oldMin = device.activeVideoMinFrameDuration
        let oldMax = device.activeVideoMaxFrameDuration
        frameCondition.lock()
        let beforeChange = frameSequence
        frameCondition.unlock()
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        session.beginConfiguration()
        device.activeFormat = format
        let range = format.videoSupportedFrameRateRanges.first { fps >= $0.minFrameRate - 0.01 && fps <= $0.maxFrameRate + 0.01 }!
        let duration = CMTime(seconds: 1 / fps, preferredTimescale: 1_000_000_000)
        // Discrete USB rates can be fractional (e.g. 30.00003).
        let actual = CMTimeCompare(duration, range.minFrameDuration) < 0 ? range.minFrameDuration :
            (CMTimeCompare(duration, range.maxFrameDuration) > 0 ? range.maxFrameDuration : duration)
        device.activeVideoMinFrameDuration = actual
        device.activeVideoMaxFrameDuration = actual
        session.commitConfiguration()
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        do {
            guard dimensions.width == width && dimensions.height == height else {
                throw PreviewError(message: "系统没有接受所选格式。")
            }
            if session.isRunning {
                try waitForFrames(width: width, height: height, after: beforeChange)
            }
        } catch {
            session.beginConfiguration()
            device.activeFormat = old
            device.activeVideoMinFrameDuration = oldMin
            device.activeVideoMaxFrameDuration = oldMax
            session.commitConfiguration()
            throw PreviewError(message: "\(error.localizedDescription) 已恢复原格式。")
        }
    }

    private func waitForFrames(width: Int, height: Int, after sequence: Int) throws {
        let deadline = Date().addingTimeInterval(8)
        frameCondition.lock()
        defer { frameCondition.unlock() }
        while frameSequence < sequence + 3 || deliveredWidth != width || deliveredHeight != height {
            guard frameCondition.wait(until: deadline) else {
                throw PreviewError(message: "视频流没有输出请求的 \(width)×\(height)，实测为 \(deliveredWidth)×\(deliveredHeight)。")
            }
        }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
        frameQueue.sync {
            lock.withLock {
                generation += 1
                latestBuffer = nil
                latestStats = FrameStatistics()
            }
            frameCondition.lock()
            frameSequence = 0
            deliveredWidth = 0
            deliveredHeight = 0
            frameCondition.unlock()
            frames = 0
            metricStart = Date()
            lastMetric = .distantPast
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        frameCondition.lock()
        frameSequence += 1
        deliveredWidth = width
        deliveredHeight = height
        frameCondition.broadcast()
        frameCondition.unlock()
        lock.withLock {
            latestBuffer = buffer
            latestStats.receivedAt = now
            latestStats.resolution = "\(width)×\(height)"
        }
        frames += 1
        if now.timeIntervalSince(lastMetric) >= 1 {
            let metrics = processor.statistics(CIImage(cvPixelBuffer: buffer))
            lock.withLock {
                latestStats.resolution = "\(CVPixelBufferGetWidth(buffer))×\(CVPixelBufferGetHeight(buffer))"
                latestStats.fps = Double(frames) / max(0.1, now.timeIntervalSince(metricStart))
                latestStats.mean = metrics.0
                latestStats.sharpness = metrics.1
                latestStats.black = metrics.2
            }
            frames = 0
            metricStart = now
            lastMetric = now
        }
        guard now.timeIntervalSince(lastRender) >= 1 / 15.0 else { return }
        let current: (CameraAdjustments, Int, Double, NormalizedPoint?)? = lock.withLock {
            guard !presentationPending else { return nil }
            presentationPending = true
            return (settings, generation, magnification, detailCenter)
        }
        guard let current else { return }
        lastRender = now
        do {
            let image = try processor.process(CIImage(cvPixelBuffer: buffer), settings: current.0)
            let bitmap = try processor.render(previewCrop(image, factor: current.2, center: current.3), maxDimension: 1400)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let valid = self.lock.withLock {
                    self.presentationPending = false
                    return self.generation == current.1
                }
                if valid { self.onImage?(bitmap) }
            }
        } catch {
            lock.withLock { presentationPending = false }
            DispatchQueue.main.async { [weak self] in self?.onError?(error.localizedDescription) }
        }
    }

    func neutralSample(at point: NormalizedPoint) throws -> [Double] {
        let (buffer, current) = lock.withLock { (latestBuffer, settings) }
        guard let buffer else { throw PreviewError(message: "尚未收到画面。") }
        let image = try processor.geometry(CIImage(cvPixelBuffer: buffer), settings: current)
        let edge = min(image.extent.width, image.extent.height) * 0.012
        let region = CGRect(x: point.x * image.extent.width - edge / 2,
                            y: (1 - point.y) * image.extent.height - edge / 2, width: edge, height: edge)
            .intersection(image.extent)
        let bounds = region.integral.intersection(image.extent)
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { throw PreviewError(message: "请点击画面内的白纸或灰卡。") }
        var values = [Float](repeating: 0, count: width * height * 4)
        processor.context.render(image, toBitmap: &values, rowBytes: width * 16, bounds: bounds,
                                 format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        var channels = [[Float]](repeating: [], count: 3)
        for pixel in stride(from: 0, to: values.count, by: 4) {
            let rgb = values[pixel..<(pixel + 3)]
            guard values[pixel + 3] > 0.99, rgb.allSatisfy({ $0.isFinite && $0 > 0.015 && $0 < 0.985 }) else { continue }
            for channel in 0..<3 { channels[channel].append(values[pixel + channel]) }
        }
        guard channels[0].count > width * height / 2 else {
            throw PreviewError(message: "点选处多数像素太暗或已过曝。请在同一画面点未反光的白纸空白处或灰卡。")
        }
        return channels.map { Double($0.sorted()[$0.count / 2]) }
    }

    @discardableResult
    func focusLiveSubject(_ point: SubjectFocusPoint, target: Int, usb: UVCDevice, fullRange: Bool = false) throws -> Int {
        guard let control = try usb.controls().first(where: { $0.key == "focus" }) else {
            throw PreviewError(message: "无法读取实时焦点。")
        }

        func measure() throws -> Double {
            Thread.sleep(forTimeInterval: 0.75)
            var samples = [Double]()
            for _ in 0..<5 {
                let (buffer, time) = lock.withLock { (latestBuffer, latestStats.receivedAt) }
                guard let buffer, Date().timeIntervalSince(time) < 1 else {
                    throw PreviewError(message: "等待种子实时画面。")
                }
                samples.append(subjectEdgeScore(buffer, point: point, context: processor.context, requireContrast: true))
                Thread.sleep(forTimeInterval: 0.065)
            }
            return samples.sorted()[2]
        }

        let step = max(1, control.step)
        let interval = max(step, ((control.max - control.min) / 36 / step) * step)
        let local = (-5...5).map { min(control.max, max(control.min, target + $0 * interval)) }
        let wide = fullRange ? Array(stride(from: control.min, through: control.max, by: 2 * interval)) + [control.max] : []
        let positions = Set(local + wide).sorted()
        let baseline = try measure()
        var candidates = [(position: Int, origin: Int, quality: Double)]()
        var previous = control.value

        func scan(_ positions: [Int]) throws {
            for position in positions {
                do { try usb.set(key: "focus", value: position) } catch { continue }
                let quality = try measure()
                if previous != position { candidates.append((position, previous, quality)) }
                previous = position
            }
        }

        func replay(_ position: Int, from origin: Int) throws -> Double? {
            do {
                try usb.set(key: "focus", value: origin)
                Thread.sleep(forTimeInterval: 0.75)
                try usb.set(key: "focus", value: position)
            } catch { return nil }
            return try measure()
        }

        try scan(positions)
        if let peak = candidates.max(by: { $0.quality < $1.quality }), peak.quality > 0 {
            let fineStep = max(step, (interval / 4 / step) * step)
            let fine = (-3...3).map { offset in
                min(control.max, max(control.min, peak.position + offset * fineStep))
            }
            try scan(Set(fine).sorted())
        }
        let ranked = candidates.sorted { $0.quality > $1.quality }
        var verified = [(position: Int, origin: Int, quality: Double)]()
        for candidate in ranked.prefix(5) where candidate.quality > 0 {
            guard let settled = try replay(candidate.position, from: candidate.origin) else { continue }
            previewLog("实时种子对焦：起始 \(baseline)，候选 \(candidate.quality)，复核 \(settled)，位置 \(candidate.position)")
            if settled >= baseline * 0.95 && settled >= candidate.quality * 0.70 {
                verified.append((candidate.position, candidate.origin, settled))
            }
        }
        for candidate in verified.sorted(by: { $0.quality > $1.quality }) {
            guard let settled = try replay(candidate.position, from: candidate.origin) else { continue }
            previewLog("实时种子对焦最终复核：\(settled)，位置 \(candidate.position)")
            if settled >= baseline * 0.95 && settled >= candidate.quality * 0.85 {
                return candidate.origin
            }
        }
        throw PreviewError(message: "种子边缘在复测时仍有变化。请保持托盘静止，点选种子附近寻焦。")
    }

    func focusQuality(around point: NormalizedPoint? = nil) throws -> Double {
        let (buffer, time, current) = lock.withLock { (latestBuffer, latestStats.receivedAt, settings) }
        guard let buffer, Date().timeIntervalSince(time) < 2 else {
            throw PreviewError(message: "对焦校验需要实时画面。")
        }
        let raw = CIImage(cvPixelBuffer: buffer)
        let source = point == nil ? raw : try processor.geometry(raw, settings: current)
        let extent = source.extent
        let region: CGRect
        if let point {
            let side = min(extent.width, extent.height) * 0.18
            let x = extent.minX + point.x * extent.width
            let y = extent.minY + (1 - point.y) * extent.height
            region = CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side).intersection(extent)
        } else {
            region = extent.insetBy(dx: extent.width * 0.04, dy: extent.height * 0.04)
        }
        let scale = min(1, 1440 / max(region.width, region.height))
        let width = Int(region.width * scale)
        let height = Int(region.height * scale)
        let crop = source.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        processor.context.render(crop, toBitmap: &pixels, rowBytes: width * 4,
                                 bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                 format: .RGBA8, colorSpace: processor.colorSpace)
        var luma = [Double](repeating: 0, count: width * height)
        for i in luma.indices {
            let offset = i * 4
            luma[i] = 0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset + 2])
        }
        let mean = luma.reduce(0, +) / Double(luma.count)
        guard mean > 3 else { throw PreviewError(message: "当前画面太暗，请照亮托盘后锁定。") }
        var energy = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let edge = luma[i - 1] + luma[i + 1] + luma[i - width] + luma[i + width] - 4 * luma[i]
                energy += edge * edge
            }
        }
        return energy / Double((width - 2) * (height - 2)) / (mean * mean)
    }

    func export(to folder: URL, includeMagnified: Bool = false) throws {
        let (buffer, current, stats, zoom, center) = lock.withLock {
            (latestBuffer, settings, latestStats, magnification, detailCenter)
        }
        guard let buffer, Date().timeIntervalSince(stats.receivedAt) < 3 else {
            throw PreviewError(message: "当前没有新鲜画面，请先重新连接。")
        }
        guard !processor.statistics(CIImage(cvPixelBuffer: buffer)).2 else {
            throw PreviewError(message: "当前画面接近全黑，请检查照明或相机连接。")
        }
        let raw = CIImage(cvPixelBuffer: buffer)
        let processed = try processor.process(raw, settings: current)
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        var images = [("original.jpg", raw), ("adjusted.jpg", processed)]
        if includeMagnified, let center {
            let crop = detailCropBounds(in: processed.extent, factor: zoom > 1 ? zoom : 4, center: center)
            let detail = processed.cropped(to: crop)
            guard let bytes = processor.context.pngRepresentation(of: detail, format: .RGBA8,
                                                                  colorSpace: processor.colorSpace) else {
                throw PreviewError(message: "保存种子局部失败。")
            }
            try bytes.write(to: folder.appendingPathComponent("seed-detail.png"), options: .withoutOverwriting)
            let metadata = SeedDetailInfo(crop: crop, source: processed.extent)
            try JSONEncoder().encode(metadata).write(to: folder.appendingPathComponent("seed-detail.json"),
                                                     options: .withoutOverwriting)
        } else if includeMagnified && zoom > 1 {
            images.append(("zoomed.jpg", magnifiedCapture(raw, factor: zoom)))
            let metadata = MagnifiedCaptureInfo(raw: raw, factor: zoom)
            try JSONEncoder().encode(metadata).write(to: folder.appendingPathComponent("zoom-info.json"), options: .withoutOverwriting)
        }
        for (name, image) in images {
            guard let bytes = processor.context.jpegRepresentation(of: image, colorSpace: processor.colorSpace, options: [quality: 0.97]) else {
                throw PreviewError(message: "保存图片失败。")
            }
            try bytes.write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
        }
        try JSONEncoder().encode(current).write(to: folder.appendingPathComponent("adjustments.json"), options: .withoutOverwriting)
        let metadata: [String: Any] = [
            "deviceID": device?.uniqueID ?? "",
            "receivedAt": ISO8601DateFormatter().string(from: stats.receivedAt),
            "resolution": stats.resolution, "measuredFPS": stats.fps,
            "meanLuminance": stats.mean, "edgeScore": stats.sharpness
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
            .write(to: folder.appendingPathComponent("capture-info.json"), options: .withoutOverwriting)
    }

    var frameSize: String? {
        let stats = statistics
        return Date().timeIntervalSince(stats.receivedAt) < 3 ? stats.resolution : nil
    }
}

final class VideoSurface: NSView {
    private let imageLayer = CALayer()
    private var bitmap: CGImage?
    private let gridLayer = CAShapeLayer()
    private let pointLayer = CAShapeLayer()
    var grid = false { didSet { needsLayout = true } }
    var points: [NormalizedPoint] = [] { didSet { needsLayout = true } }
    var onPick: ((NormalizedPoint) -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(imageLayer)
        gridLayer.strokeColor = NSColor.white.withAlphaComponent(0.45).cgColor
        gridLayer.fillColor = nil
        gridLayer.lineWidth = 0.5
        pointLayer.fillColor = NSColor.systemYellow.cgColor
        layer?.addSublayer(gridLayer)
        layer?.addSublayer(pointLayer)
    }

    required init?(coder: NSCoder) { nil }

    var imageRect: CGRect {
        guard let bitmap else { return bounds }
        let scale = min(bounds.width / Double(bitmap.width), bounds.height / Double(bitmap.height))
        let size = CGSize(width: Double(bitmap.width) * scale, height: Double(bitmap.height) * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    func present(_ image: CGImage) {
        bitmap = image
        imageLayer.contents = image
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = imageRect
        gridLayer.frame = bounds
        pointLayer.frame = bounds
        let rect = imageRect
        let path = CGMutablePath()
        if grid {
            for i in 1..<8 {
                let fraction = Double(i) / 8
                path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
            }
        }
        gridLayer.path = path
        let markers = CGMutablePath()
        for point in points {
            let center = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
            markers.addEllipse(in: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
        }
        pointLayer.path = markers
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        let position = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard rect.contains(position) else { return }
        onPick?(NormalizedPoint(x: (position.x - rect.minX) / rect.width, y: (position.y - rect.minY) / rect.height))
    }
}

final class CameraPane {
    let feed = CameraFeed()
    let surface = VideoSurface()
    let view = NSView()
    let name: String
    private let status = NSTextField(wrappingLabelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private var monitoring = false
    private var startedAt = Date()

    init(number: Int) {
        name = "camera-\(number)"
        title.stringValue = name
        title.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        status.alignment = .center
        status.textColor = .white
        for item in [title, surface, status] { item.translatesAutoresizingMaskIntoConstraints = false }
        view.addSubview(title)
        view.addSubview(surface)
        surface.addSubview(status)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            title.topAnchor.constraint(equalTo: view.topAnchor),
            surface.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            status.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            status.widthAnchor.constraint(equalTo: surface.widthAnchor, constant: -30)
        ])
        feed.onImage = { [weak self] image in self?.surface.present(image) }
        feed.onError = { [weak self] error in self?.show(error) }
    }

    func show(_ message: String) {
        monitoring = false
        status.stringValue = message
        status.isHidden = false
    }

    func watch(id: String) {
        previewLog("\(name) [\(id)] 开始预览")
        monitoring = true
        startedAt = Date()
    }

    func update() {
        guard monitoring else { return }
        let stats = feed.statistics
        title.stringValue = "\(name)  \(stats.resolution)  \(Int(stats.fps.rounded())) fps  亮度 \(Int(stats.mean))"
        if Date().timeIntervalSince(stats.receivedAt) > 4 && Date().timeIntervalSince(startedAt) > 5 {
            status.stringValue = "视频流已中断，请点「重新连接」。"
            status.isHidden = false
        } else if stats.black {
            status.stringValue = "画面接近全黑，请检查照明和相机。"
            status.isHidden = false
        } else {
            status.isHidden = true
        }
    }
}
