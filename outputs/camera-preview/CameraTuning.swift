import AppKit
import AVFoundation
import CoreImage
import Foundation

func detailCropBounds(in bounds: CGRect, factor: Double, center: NormalizedPoint) -> CGRect {
    let zoom = factor.isFinite ? min(4, max(1, factor)) : 1
    let width = floor((floor(bounds.maxX) - ceil(bounds.minX)) / zoom)
    let height = floor((floor(bounds.maxY) - ceil(bounds.minY)) / zoom)
    let x = round(bounds.minX + center.x * bounds.width - width / 2)
    let y = round(bounds.minY + (1 - center.y) * bounds.height - height / 2)
    return CGRect(x: min(max(x, ceil(bounds.minX)), floor(bounds.maxX) - width),
                  y: min(max(y, ceil(bounds.minY)), floor(bounds.maxY) - height),
                  width: width, height: height)
}

func previewCrop(_ image: CIImage, factor: Double, center: NormalizedPoint? = nil) -> CIImage {
    guard factor.isFinite, factor > 1 else { return image }
    let bounds = image.extent
    let crop: CGRect
    if let center {
        crop = detailCropBounds(in: bounds, factor: factor, center: center)
    } else {
        let zoom = min(4, factor)
        crop = CGRect(x: bounds.midX - bounds.width / zoom / 2,
                      y: bounds.midY - bounds.height / zoom / 2,
                      width: bounds.width / zoom, height: bounds.height / zoom)
    }
    return image.cropped(to: crop)
        .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
}

struct SeedDetailInfo: Encodable {
    let sourceFile = "adjusted.jpg"
    let outputFile = "seed-detail.png"
    let sourceX: Int
    let sourceY: Int
    let width: Int
    let height: Int

    init(crop: CGRect, source: CGRect) {
        sourceX = Int(crop.minX - source.minX)
        sourceY = Int(source.maxY - crop.maxY)
        width = Int(crop.width)
        height = Int(crop.height)
    }
}

// Capture coordinates use the sensor orientation and pixel centers, as OpenCV does.
struct MagnifiedCaptureInfo: Encodable {
    let sourceFile = "original.jpg"
    let outputFile = "zoomed.jpg"
    let factor: Double
    let width: Int
    let height: Int
    let outputToSourceOffsetX: Double
    let outputToSourceOffsetY: Double

    init(raw: CIImage, factor: Double) {
        self.factor = factor
        width = Int(raw.extent.width)
        height = Int(raw.extent.height)
        outputToSourceOffsetX = Double(width - 1) / 2 * (1 - 1 / factor)
        outputToSourceOffsetY = Double(height - 1) / 2 * (1 - 1 / factor)
    }
}

func magnifiedCapture(_ image: CIImage, factor: Double) -> CIImage {
    let bounds = image.extent
    let transform = CGAffineTransform(a: factor, b: 0, c: 0, d: factor,
                                      tx: bounds.midX * (1 - factor),
                                      ty: bounds.midY * (1 - factor))
    return image.transformed(by: transform).cropped(to: bounds)
}

struct NormalizedPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

struct LensCalibration: Codable, Equatable {
    var version: Int
    var deviceID: String
    var width: Int
    var height: Int
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    var distortion: [Double]
    var reprojectionRMS: Double
    var imagesUsed: Int

    func validate() throws {
        guard version == 1, !deviceID.isEmpty, width > 0, height > 0, imagesUsed >= 8,
              [fx, fy, cx, cy, reprojectionRMS].allSatisfy(\.isFinite),
              fx > 0, fy > 0, distortion.count == 5,
              distortion.allSatisfy({ $0.isFinite && abs($0) <= 5 }), reprojectionRMS <= 2 else {
            throw PreviewError(message: "镜头标定文件无效或重投影误差过大。")
        }
    }
}

struct CameraAdjustments: Codable, Equatable {
    var enabled = true
    var rotation = 1
    var mirror = false
    var exposureEV = 0.0
    var red = 1.0
    var green = 1.0
    var blue = 1.0
    var saturation = 1.0
    var hue = 0.0
    var contrast = 1.0
    var sharpness = 0.0
    var radialK1 = 0.0
    var radialK2 = 0.0
    var centerX = 0.5
    var centerY = 0.5
    var perspective: [NormalizedPoint] = []
    var lensCalibration: LensCalibration?

    init() {}

    func rawSubjectPoint(_ point: NormalizedPoint) -> SubjectFocusPoint? {
        if enabled && (lensCalibration != nil || radialK1 != 0 || radialK2 != 0 || !perspective.isEmpty) {
            return nil
        }
        let x = mirror ? 1 - point.x : point.x
        let y = point.y
        switch rotation {
        case 1: return .init(x: y, y: 1 - x)
        case 2: return .init(x: 1 - x, y: 1 - y)
        case 3: return .init(x: 1 - y, y: x)
        default: return .init(x: x, y: y)
        }
    }

    enum CodingKeys: String, CodingKey {
        case enabled, rotation, mirror, exposureEV, red, green, blue, saturation, hue, contrast, sharpness
        case radialK1, radialK2, centerX, centerY, perspective, lensCalibration
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        rotation = try values.decodeIfPresent(Int.self, forKey: .rotation) ?? rotation
        mirror = try values.decodeIfPresent(Bool.self, forKey: .mirror) ?? mirror
        exposureEV = try values.decodeIfPresent(Double.self, forKey: .exposureEV) ?? exposureEV
        red = try values.decodeIfPresent(Double.self, forKey: .red) ?? red
        green = try values.decodeIfPresent(Double.self, forKey: .green) ?? green
        blue = try values.decodeIfPresent(Double.self, forKey: .blue) ?? blue
        saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
        hue = try values.decodeIfPresent(Double.self, forKey: .hue) ?? hue
        contrast = try values.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
        sharpness = try values.decodeIfPresent(Double.self, forKey: .sharpness) ?? sharpness
        radialK1 = try values.decodeIfPresent(Double.self, forKey: .radialK1) ?? radialK1
        radialK2 = try values.decodeIfPresent(Double.self, forKey: .radialK2) ?? radialK2
        centerX = try values.decodeIfPresent(Double.self, forKey: .centerX) ?? centerX
        centerY = try values.decodeIfPresent(Double.self, forKey: .centerY) ?? centerY
        perspective = try values.decodeIfPresent([NormalizedPoint].self, forKey: .perspective) ?? perspective
        lensCalibration = try values.decodeIfPresent(LensCalibration.self, forKey: .lensCalibration)
    }

    func validate() throws {
        let ranges: [(Double, ClosedRange<Double>)] = [
            (exposureEV, -3...3), (red, 0.25...4), (green, 0.25...4), (blue, 0.25...4),
            (saturation, 0...2), (hue, -0.5...0.5), (contrast, 0.5...1.5), (sharpness, 0...0.6),
            (radialK1, -0.35...0.35), (radialK2, -0.15...0.15),
            (centerX, 0.2...0.8), (centerY, 0.2...0.8)
        ]
        guard (0...3).contains(rotation), ranges.allSatisfy({ $0.0.isFinite && $0.1.contains($0.0) }),
              perspective.isEmpty || validQuadrilateral(perspective) else {
            throw PreviewError(message: "校正参数越界或四角选择无效。")
        }
        // Radial mapping must remain monotone over the whole displayed frame.
        for i in 0...100 {
            let r2 = 2.0 * Double(i) / 100
            guard 1 + 3 * radialK1 * r2 + 5 * radialK2 * r2 * r2 > 0.1 else {
                throw PreviewError(message: "该畸变参数会折叠画面，请减小校正强度。")
            }
        }
        try lensCalibration?.validate()
    }
}

func validQuadrilateral(_ points: [NormalizedPoint]) -> Bool {
    guard points.count == 4, points.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
    var signs: [Double] = []
    var area = 0.0
    for i in 0..<4 {
        let a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4]
        signs.append((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x))
        area += a.x * b.y - b.x * a.y
    }
    return signs.allSatisfy { $0 > 0.0001 } && area > 0.02
}

struct SavedCameraSettings: Codable {
    var deviceID: String
    var width: Int?
    var height: Int?
    var fps: Double = 25
    var hardware: [String: Int] = [:]
    var focusLocked: Bool?
    var focusApproach: Int?
    var subjectFocus: SubjectFocusPoint?
    var adjustments = CameraAdjustments()
}

struct CameraSettingsDocument: Codable {
    var version = 1
    var cameras: [String: SavedCameraSettings] = [:]

    func validate() throws {
        guard version == 1, cameras.count <= 8 else { throw PreviewError(message: "参数文件版本不支持。") }
        for (id, settings) in cameras {
            guard id == settings.deviceID, settings.fps.isFinite, (1...120).contains(settings.fps),
                  settings.width == nil || (1...8192).contains(settings.width!),
                  settings.height == nil || (1...8192).contains(settings.height!),
                  (settings.width == nil) == (settings.height == nil) else {
                throw PreviewError(message: "参数文件中的设备或分辨率无效。")
            }
            if settings.focusLocked == true &&
                (settings.hardware["focusAuto"] != 0 || settings.hardware["focus"] == nil) {
                throw PreviewError(message: "锁定焦点需要保存手动对焦模式和各自的位置。")
            }
            if let point = settings.subjectFocus, !point.isValid {
                throw PreviewError(message: "对焦参照点超出原画面。")
            }
            try settings.adjustments.validate()
        }
    }
}

struct UVCControl: Decodable, Identifiable {
    let key: String
    var value: Int
    let min: Int
    let max: Int
    let step: Int
    let defaultValue: Int
    var writable: Bool
    var id: String { key }

    var title: String {
        [
            "focusAuto": "自动对焦", "focus": "对焦位置", "zoom": "设备变焦",
            "exposureAuto": "曝光模式", "exposure": "曝光时间（100 µs）",
            "brightness": "亮度", "contrast": "对比度", "hue": "色相",
            "saturation": "饱和度", "sharpness": "锐度", "gamma": "伽马",
            "temperature": "白平衡色温（K）", "whiteBalanceAuto": "自动白平衡",
            "backlight": "背光补偿", "gain": "传感器增益", "powerLine": "防频闪",
            "roll": "设备旋转刻度", "privacy": "隐私遮挡", "scanningMode": "扫描模式",
            "exposurePriority": "自动曝光优先级", "iris": "光圈刻度", "simpleFocus": "简化对焦模式",
            "hueAuto": "自动色相", "whiteBalanceComponentAuto": "自动白平衡分量",
            "digitalMultiplier": "数字放大刻度", "digitalMultiplierLimit": "数字放大上限",
            "analogVideoStandard": "模拟视频标准", "analogLockStatus": "模拟信号锁定",
            "contrastAuto": "自动对比度"
        ][key] ?? key
    }

    var isToggle: Bool { key == "focusAuto" || key == "whiteBalanceAuto" }
}

struct UVCDevice {
    let deviceID: String
    let helper: URL

    private var location: String {
        let clean = deviceID.lowercased().replacingOccurrences(of: "0x", with: "")
        return String(clean.dropLast(8))
    }

    func controls() throws -> [UVCControl] {
        let output = try CommandOutput.run(helper.path, [location, "list"])
        try output.checked()
        var controls = try JSONDecoder().decode([UVCControl].self, from: Data(output.text.utf8))
        if let reportURL = Bundle.main.resourceURL?.appendingPathComponent("uvc-write-verification.json"),
           let data = try? Data(contentsOf: reportURL),
           let report = try? JSONDecoder().decode([String: [String: Bool]].self, from: data),
           let verified = report[deviceID] {
            for index in controls.indices where verified[controls[index].key] == false {
                controls[index].writable = false
            }
        }
        return controls
    }

    func description() throws -> USBDeviceDescription {
        let result = try CommandOutput.run(helper.path, [location, "describe"])
        try result.checked()
        return try JSONDecoder().decode(USBDeviceDescription.self, from: Data(result.text.utf8))
    }

    func set(key: String, value: Int) throws {
        try CommandOutput.run(helper.path, [location, "set", key, String(value)]).checked()
    }

    func apply(_ values: [String: Int]) throws {
        let available = try controls()
        let automatic = ["focusAuto", "whiteBalanceAuto", "exposureAuto"]
        let priority = automatic + ["zoom"]
        let ordered = priority.filter { values[$0] != nil } + values.keys.sorted().filter { !priority.contains($0) }
        for key in ordered {
            guard let control = available.first(where: { $0.key == key }), control.writable,
                  let value = values[key], (control.min...control.max).contains(value) else {
                throw PreviewError(message: "该设备没有开放 \(key) 或请求值越界。")
            }
        }
        var changed: [String] = []
        do {
            for key in ordered {
                if key == "focus", values["focusAuto"] == 1 { continue }
                if key == "temperature", values["whiteBalanceAuto"] == 1 { continue }
                changed.append(key)
                try set(key: key, value: values[key]!)
            }
        } catch {
            let originalError = error
            var rollbackErrors: [String] = []
            for key in changed.reversed() {
                if let original = available.first(where: { $0.key == key }) {
                    do { try set(key: key, value: original.value) }
                    catch { rollbackErrors.append(key) }
                }
            }
            let recovery = rollbackErrors.isEmpty ? "已恢复本次写入前的硬件值。" :
                "请读回检查这些参数：\(rollbackErrors.joined(separator: "、"))。"
            throw PreviewError(message: "\(originalError.localizedDescription)\n\(recovery)")
        }
    }
}

struct CameraFormat: Identifiable, Equatable {
    let width: Int
    let height: Int
    let rates: [Double]
    var id: String { "\(width)×\(height)" }
}

struct FrameStatistics {
    var resolution = ""
    var fps = 0.0
    var mean = 0.0
    var sharpness = 0.0
    var black = false
    var receivedAt = Date.distantPast
}

final class CameraProcessor {
    let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let radial: CIWarpKernel?
    private let calibratedLens: CIWarpKernel?

    init() {
        radial = CIWarpKernel(source: """
        kernel vec2 radialMap(vec2 center, vec2 scale, float k1, float k2) {
            vec2 p = (destCoord() - center) / scale;
            float r2 = dot(p, p);
            return center + p * (1.0 + k1 * r2 + k2 * r2 * r2) * scale;
        }
        """)
        calibratedLens = CIWarpKernel(source: """
        kernel vec2 calibratedLensMap(vec2 center, vec2 focal, vec4 coefficients, float k3) {
            vec2 p = (destCoord() - center) / focal;
            p.y = -p.y;
            float r2 = dot(p, p);
            float scale = 1.0 + coefficients.x*r2 + coefficients.y*r2*r2 + k3*r2*r2*r2;
            vec2 t;
            t.x = 2.0*coefficients.z*p.x*p.y + coefficients.w*(r2 + 2.0*p.x*p.x);
            t.y = coefficients.z*(r2 + 2.0*p.y*p.y) + 2.0*coefficients.w*p.x*p.y;
            vec2 result = p * scale + t;
            result.y = -result.y;
            return center + result * focal;
        }
        """)
    }

    func geometry(_ input: CIImage, settings: CameraAdjustments) throws -> CIImage {
        var correctedInput = input
        if settings.enabled, let calibration = settings.lensCalibration {
            guard let calibratedLens else { throw PreviewError(message: "镜头标定滤镜无法创建。") }
            let size = input.extent.size
            let scaleX = size.width / Double(calibration.width)
            let scaleY = size.height / Double(calibration.height)
            guard abs(scaleX / scaleY - 1) < 0.01 else {
                throw PreviewError(message: "标定与当前画面宽高比不符，请使用标定时的分辨率或清除标定。")
            }
            let d = calibration.distortion
            guard let mapped = calibratedLens.apply(
                extent: input.extent, roiCallback: { _, _ in input.extent }, image: input.samplingLinear(),
                arguments: [
                    // OpenCV uses integer pixel centers, Core Image uses half-integer centers.
                    CIVector(x: (calibration.cx + 0.5) * scaleX, y: size.height - (calibration.cy + 0.5) * scaleY),
                    CIVector(x: calibration.fx * scaleX, y: calibration.fy * scaleY),
                    CIVector(x: d[0], y: d[1], z: d[2], w: d[3]), d[4]
                ]) else { throw PreviewError(message: "标定校正失败。") }
            correctedInput = mapped
        }
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        var result = correctedInput.oriented(orientations[settings.rotation])
        result = result.transformed(by: CGAffineTransform(translationX: -result.extent.minX, y: -result.extent.minY))
        if settings.mirror {
            result = result.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: result.extent.width, ty: 0))
        }
        guard settings.enabled else { return result }
        if settings.radialK1 != 0 || settings.radialK2 != 0 {
            guard let radial else { throw PreviewError(message: "当前系统无法创建径向畸变滤镜。") }
            let extent = result.extent
            guard let mapped = radial.apply(extent: extent, roiCallback: { _, _ in extent },
                                            image: result.samplingLinear(), arguments: [
                                                CIVector(x: extent.width * settings.centerX, y: extent.height * (1 - settings.centerY)),
                                                CIVector(x: extent.width / 2, y: extent.height / 2),
                                                settings.radialK1, settings.radialK2
                                            ]) else {
                throw PreviewError(message: "畸变校正失败。")
            }
            result = mapped
        }
        if settings.perspective.count == 4 {
            let extent = result.extent
            let corners = settings.perspective.map {
                CIVector(x: $0.x * extent.width, y: (1 - $0.y) * extent.height)
            }
            result = result.applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": corners[0], "inputTopRight": corners[1],
                "inputBottomRight": corners[2], "inputBottomLeft": corners[3],
                "inputCrop": true
            ])
            result = result.transformed(by: CGAffineTransform(translationX: -result.extent.minX, y: -result.extent.minY))
        }
        return result
    }

    func process(_ input: CIImage, settings: CameraAdjustments) throws -> CIImage {
        var image = try geometry(input, settings: settings)
        guard settings.enabled else { return image }
        let scale = pow(2, settings.exposureEV)
        image = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: settings.red * scale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: settings.green * scale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: settings.blue * scale, w: 0)
        ])
        if settings.saturation != 1 || settings.contrast != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                "inputSaturation": settings.saturation, "inputContrast": settings.contrast
            ])
        }
        if settings.hue != 0 {
            image = image.applyingFilter("CIHueAdjust", parameters: ["inputAngle": settings.hue])
        }
        if settings.sharpness > 0 {
            let extent = image.extent
            image = image.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [
                "inputSharpness": settings.sharpness, "inputRadius": 1.6
            ]).cropped(to: extent)
        }
        return image
    }

    func render(_ image: CIImage, maxDimension: Double? = nil) throws -> CGImage {
        var output = image
        if let maxDimension, max(output.extent.width, output.extent.height) > maxDimension {
            let scale = maxDimension / max(output.extent.width, output.extent.height)
            output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let bitmap = context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw PreviewError(message: "画面渲染失败。")
        }
        return bitmap
    }

    func statistics(_ input: CIImage) -> (Double, Double, Bool) {
        let image = input.transformed(by: CGAffineTransform(scaleX: 96 / input.extent.width, y: 96 / input.extent.height))
        var pixels = [UInt8](repeating: 0, count: 96 * 96 * 4)
        context.render(image, toBitmap: &pixels, rowBytes: 96 * 4, bounds: CGRect(x: 0, y: 0, width: 96, height: 96),
                       format: .RGBA8, colorSpace: colorSpace)
        var luma = [Double](repeating: 0, count: 96 * 96)
        var black = 0
        for i in luma.indices {
            let j = i * 4
            luma[i] = 0.2126 * Double(pixels[j]) + 0.7152 * Double(pixels[j + 1]) + 0.0722 * Double(pixels[j + 2])
            if luma[i] <= 8 { black += 1 }
        }
        var edge = 0.0
        for y in 1..<95 {
            for x in 1..<95 {
                let i = y * 96 + x
                let lap = luma[i - 1] + luma[i + 1] + luma[i - 96] + luma[i + 96] - 4 * luma[i]
                edge += lap * lap
            }
        }
        return (luma.reduce(0, +) / Double(luma.count), edge / (94 * 94), black > luma.count * 99 / 100)
    }
}
