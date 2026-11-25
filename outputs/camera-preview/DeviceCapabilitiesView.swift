import AppKit
import AVFoundation
import SwiftUI

struct USBDeviceDescription: Codable {
    struct ExtensionUnit: Codable, Identifiable {
        let unitID: Int
        let controlCount: Int
        let guid: String
        let controlBitmap: String
        var id: Int { unitID }
    }
    let locationID: String
    let vendorID: Int
    let productID: Int
    let firmwareBCD: Int
    let usbSpeedCode: Int
    let controlInterface: Int
    let cameraTerminalID: Int
    let processingUnitID: Int
    let cameraTerminalBitmap: Int
    let processingUnitBitmap: Int
    let declaredControls: [String]
    let extensionUnits: [ExtensionUnit]?

    var speed: String {
        [0: "低速 · 1.5 Mb/s", 1: "全速 · 12 Mb/s", 2: "高速 · 480 Mb/s",
         3: "SuperSpeed · 5 Gb/s", 4: "SuperSpeedPlus"].first { $0.key == usbSpeedCode }?.value ?? "代码 \(usbSpeedCode)"
    }
}

struct NativeCameraFormat: Identifiable, Codable {
    let index: Int
    let width: Int
    let height: Int
    let pixelFormat: String
    let frameRates: [String]
    var id: Int { index }

    static func read(_ device: AVCaptureDevice) -> [Self] {
        device.formats.enumerated().map { index, format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let codec = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let characters = (0..<4).reversed().map { shift in UInt8((codec >> (shift * 8)) & 0xff) }
            let fourCC = String(bytes: characters, encoding: .ascii) ?? String(codec)
            return Self(index: index, width: Int(dimensions.width), height: Int(dimensions.height),
                        pixelFormat: fourCC,
                        frameRates: format.videoSupportedFrameRateRanges.map {
                            abs($0.minFrameRate - $0.maxFrameRate) < 0.01 ?
                                String(format: "%.2f fps", $0.maxFrameRate) :
                                String(format: "%.2f–%.2f fps", $0.minFrameRate, $0.maxFrameRate)
                        })
        }
    }
}

struct CameraCapabilityReport: Encodable {
    let generatedAt: Date
    let deviceID: String
    let usb: USBDeviceDescription?
    let nativeFormats: [NativeCameraFormat]
    let controls: [CapabilityControl]

    struct CapabilityControl: Encodable {
        let key: String
        let current: Int
        let minimum: Int
        let maximum: Int
        let step: Int
        let defaultValue: Int
        let writable: Bool
    }
}

struct DeviceCapabilitiesView: View {
    @ObservedObject var model: CameraTuningModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("设备信息").font(.title2.bold())
                    Text("底层能力与只读报告；日常调节请前往「相机调试」。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("摄像头", selection: $model.selected) {
                    Text("camera-1").tag(0)
                    Text("camera-2").tag(1)
                }.frame(width: 220)
                Button("重新读取") { model.refreshHardware(index: model.selected) }
                Button("导出设备报告") { model.exportCapabilities(index: model.selected) }
            }.padding(18)
            Divider()
            CameraCapabilityDetail(camera: model.cameras[model.selected])
                .id(model.selected)
        }
    }
}

private struct CameraCapabilityDetail: View {
    @ObservedObject var camera: CameraControlState

    private func value(_ name: String, _ text: String) -> some View {
        LabeledContent(name) { Text(text).textSelection(.enabled) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(camera.deviceID).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                if let device = camera.usbDescription {
                    if let extensions = device.extensionUnits, !extensions.isEmpty {
                        GroupBox("厂商扩展单元") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(extensions) { unit in
                                    Text("单元 \(unit.unitID) · 声明 \(unit.controlCount) 项")
                                    Text("GUID \(unit.guid)\n能力位图 \(unit.controlBitmap)")
                                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                                Text("扩展控制的参数含义由厂商协议定义。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                    GroupBox("USB 与固件") {
                        VStack(spacing: 7) {
                            value("厂商 / 产品 ID", String(format: "%04X / %04X", device.vendorID, device.productID))
                            value("固件 BCD", String(format: "%04X", device.firmwareBCD))
                            value("USB 连接", device.speed)
                            value("端口位置", device.locationID)
                            value("控制接口 / 相机终端 / 处理单元",
                                  "\(device.controlInterface) / \(device.cameraTerminalID) / \(device.processingUnitID)")
                            value("终端 / 处理能力位图",
                                  String(format: "0x%06X / 0x%06X", device.cameraTerminalBitmap, device.processingUnitBitmap))
                        }.padding(8)
                    }
                }
                GroupBox("硬件参数读回") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                        GridRow {
                            Text("参数").bold(); Text("当前").bold(); Text("范围 / 步进").bold()
                            Text("默认").bold(); Text("写入").bold()
                        }
                        ForEach(camera.controls) { control in
                            GridRow {
                                Text(control.title)
                                Text("\(control.value)").monospacedDigit()
                                Text("\(control.min)…\(control.max) / \(control.step)").monospacedDigit()
                                Text("\(control.defaultValue)").monospacedDigit()
                                Text(control.writable ? "可请求并读回" : "只读")
                                    .foregroundStyle(control.writable ? Color.primary : Color.secondary)
                            }
                        }
                    }.font(.callout).padding(8)
                }
                if let device = camera.usbDescription {
                    let unreadable = device.declaredControls.filter { key in !camera.controls.contains { $0.key == key } }
                    if !unreadable.isEmpty {
                        GroupBox("设备声明但未完成读回的控制") {
                            Text(unreadable.joined(separator: "、")).textSelection(.enabled).padding(8)
                        }
                    }
                    GroupBox("自动控制模式") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("对焦模式  \(camera.focusModes)")
                            Text("曝光模式  \(camera.exposureModes)")
                            Text("白平衡模式  \(camera.whiteBalanceModes)")
                        }.frame(maxWidth: .infinity, alignment: .leading).font(.callout).padding(8)
                    }
                }
                GroupBox("原生格式") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                        GridRow {
                            Text("索引").bold(); Text("尺寸").bold(); Text("像素格式").bold(); Text("设备帧率").bold()
                        }
                        ForEach(camera.nativeFormats) { format in
                            GridRow {
                                Text("\(format.index)")
                                Text("\(format.width)×\(format.height)")
                                Text(format.pixelFormat)
                                Text(format.frameRates.joined(separator: " / "))
                            }
                        }
                    }.font(.system(.callout, design: .monospaced)).padding(8)
                }
                Text("焦点锁定保存镜头的对焦位置。设备变焦改变取景范围。是否包含光学变焦，需要镜头规格确认。")
                    .font(.callout).foregroundStyle(.secondary)
                if !camera.hardwareError.isEmpty { Text(camera.hardwareError).foregroundStyle(.orange) }
            }.padding(18).frame(maxWidth: 1050, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}
