import AppKit
import ImageIO
import UniformTypeIdentifiers

enum HistoryCropMode: String, CaseIterable {
    case full = "全图"
    case seed = "点种子"
    case row = "框选区域"
}

struct HistoryCropSource: Equatable {
    let url: URL
    let region: CGRect?
    var fixedSize: CGSize? = nil

    func pixelSize() throws -> CGSize {
        let (_, width, height, orientation) = try readSource()
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    func image() throws -> CGImage {
        let (source, width, height, orientation) = try readSource()
        let image: CGImage?
        if region != nil && orientation == 1 {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: region == nil ? 1200 : max(width, height)
            ] as CFDictionary)
        }
        guard let image else { throw PreviewError(message: "无法解码照片：\(url.lastPathComponent)") }
        guard let region else { return image }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let requested = CGRect(x: region.minX * bounds.width, y: region.minY * bounds.height,
                            width: region.width * bounds.width, height: region.height * bounds.height)
        let pixels: CGRect
        if let fixedSize {
            guard let placed = Self.place(region.origin, size: fixedSize, in: bounds.size) else {
                throw PreviewError(message: "照片尺寸容不下固定裁剪框：\(url.lastPathComponent)")
            }
            pixels = placed
        } else {
            pixels = requested.integral.intersection(bounds)
        }
        guard let crop = image.cropping(to: pixels) else {
            throw PreviewError(message: "裁剪区域无效：\(url.lastPathComponent)")
        }
        return crop
    }

    private func readSource() throws -> (CGImageSource, Int, Int, Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw PreviewError(message: "无法读取照片：\(url.lastPathComponent)")
        }
        return (source, width, height, properties[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    static func place(_ origin: CGPoint, size: CGSize, in bounds: CGSize) -> CGRect? {
        guard size.width > 0, size.height > 0, size.width <= bounds.width, size.height <= bounds.height else { return nil }
        return CGRect(x: max(0, min(bounds.width - size.width, (origin.x * bounds.width).rounded())),
                      y: max(0, min(bounds.height - size.height, (origin.y * bounds.height).rounded())),
                      width: size.width, height: size.height)
    }
}

struct HistoryCropExport {
    let folder: URL
    let records: [CaptureBatch]
    let regions: [Int: CGRect]
    let mode: HistoryCropMode
    let originals: Bool
    var fixedSize: CGSize? = nil

    struct Result {
        let folder: URL
        let saved: Int
        let skipped: Int
    }

    func save() throws -> Result {
        guard let leftRegion = regions[1], let rightRegion = regions[2] else {
            throw PreviewError(message: "请先选择两路的裁剪区域。")
        }
        let eligible = records.filter { originals || $0.adjustedFileNames != nil }.sorted { $0.timestamp < $1.timestamp }
        guard !eligible.isEmpty else { throw PreviewError(message: "没有可裁剪的双路照片。") }
        let files = FileManager.default
        let parent = folder.appendingPathComponent("裁剪结果", isDirectory: true)
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let identifier = UUID().uuidString.prefix(8)
        let staging = parent.appendingPathComponent(".pending-\(identifier)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let output = parent.appendingPathComponent("\(stamp.string(from: Date()))-\(mode.rawValue)-\(identifier)", isDirectory: true)
        var index: [[String: String]] = []
        for (offset, record) in eligible.enumerated() {
            try autoreleasepool {
                let left = (originals ? nil : record.adjustedPhoto(1)) ?? record.photo(1)
                let right = (originals ? nil : record.adjustedPhoto(2)) ?? record.photo(2)
                let camera1 = try HistoryCropSource(url: left, region: leftRegion, fixedSize: fixedSize).image()
                let camera2 = try HistoryCropSource(url: right, region: rightRegion, fixedSize: fixedSize).image()
                let prefix = String(format: "%03d", offset + 1) + "_" + stamp.string(from: record.timestamp)
                let leftName = prefix + "_camera-1.png"
                let rightName = prefix + "_camera-2.png"
                let pairName = prefix + "_双路对照.png"
                try writePNG(camera1, to: staging.appendingPathComponent(leftName))
                try writePNG(camera2, to: staging.appendingPathComponent(rightName))
                try writePNG(sideBySide(camera1, camera2), to: staging.appendingPathComponent(pairName))
                index.append(["camera-1": leftName, "camera-2": rightName, "comparison": pairName,
                              "source-1": left.lastPathComponent, "source-2": right.lastPathComponent])
            }
        }
        var metadata: [String: Any] = [
            "mode": mode.rawValue, "source": originals ? "original" : "adjusted",
            "normalizedRegions": [
                "camera-1": [leftRegion.minX, leftRegion.minY, leftRegion.width, leftRegion.height],
                "camera-2": [rightRegion.minX, rightRegion.minY, rightRegion.width, rightRegion.height],
            ],
            "records": index, "skipped": records.count - eligible.count,
        ]
        if let fixedSize { metadata["cropPixelSize"] = [Int(fixedSize.width), Int(fixedSize.height)] }
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: staging.appendingPathComponent("裁剪记录.json"))
        try files.moveItem(at: staging, to: output)
        return Result(folder: output, saved: eligible.count, skipped: records.count - eligible.count)
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw PreviewError(message: "无法创建裁剪文件：\(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PreviewError(message: "无法保存裁剪文件：\(url.lastPathComponent)")
        }
    }

    private func sideBySide(_ left: CGImage, _ right: CGImage) throws -> CGImage {
        let gap = 12
        let width = left.width + gap + right.width
        let height = max(left.height, right.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PreviewError(message: "无法生成双路对照图。")
        }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(left, in: CGRect(x: 0, y: (height - left.height) / 2, width: left.width, height: left.height))
        context.draw(right, in: CGRect(x: left.width + gap, y: (height - right.height) / 2,
                                       width: right.width, height: right.height))
        guard let comparison = context.makeImage() else { throw PreviewError(message: "无法生成双路对照图。") }
        return comparison
    }
}
