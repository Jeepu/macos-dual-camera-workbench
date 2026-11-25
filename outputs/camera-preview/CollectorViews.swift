import AppKit
import ImageIO
import SwiftUI

final class CollectorModel: ObservableObject {
    let scheduler = CaptureScheduler()
    private let work = DispatchQueue(label: "local.dataset.camera.schedule")
    private let historyWork = DispatchQueue(label: "local.dataset.camera.history")
    private var loadingStatus = false
    private var loadingHistory = false
    private var activity: NSObjectProtocol?
    @Published private(set) var status: CaptureStatus?
    @Published private(set) var busy = false
    @Published private(set) var feedback = ""
    @Published private(set) var feedbackIsError = false
    @Published private(set) var statusError: String?
    @Published private(set) var historyError: String?
    @Published private(set) var captureFolders: [CaptureFolder] = []
    var batches: [CaptureBatch] { captureFolders.flatMap(\.batches).sorted { $0.timestamp > $1.timestamp } }
    @Published var keepAwake = UserDefaults.standard.object(forKey: "keepAwakeWhileCollecting") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: "keepAwakeWhileCollecting")
            updateSleepAssertion()
        }
    }

    private func updateSleepAssertion() {
        if keepAwake && status?.enabled == true {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: .idleSystemSleepDisabled, reason: "保持定时摄像头采集运行"
                )
            }
        } else {
            endSleepAssertion()
        }
    }

    func endSleepAssertion() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    func refreshStatus() {
        guard !busy, !loadingStatus else { return }
        loadingStatus = true
        let scheduler = self.scheduler
        work.async { [weak self] in
            let result = Result { try scheduler.status() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loadingStatus = false
                switch result {
                case .success(let current):
                    self.statusError = nil
                    if self.status != current { self.status = current }
                    self.updateSleepAssertion()
                case .failure(let error):
                    self.statusError = error.localizedDescription
                }
            }
        }
    }

    func startMonitoring() {
        let scheduler = self.scheduler
        work.async { [weak self] in
            let recovery = Result { try scheduler.recoverIfEnabled() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if case .failure(let error) = recovery {
                    self.feedback = "无法恢复后台任务。\(error.localizedDescription)"
                    self.feedbackIsError = true
                }
                self.refreshStatus()
            }
        }
    }

    func refreshHistory() {
        guard !loadingHistory else { return }
        loadingHistory = true
        let library = scheduler.library
        historyWork.async { [weak self] in
            let result = Result { try library.captureFolders() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loadingHistory = false
                switch result {
                case .success(let latest):
                    self.historyError = nil
                    if self.captureFolders != latest { self.captureFolders = latest }
                case .failure(let error):
                    self.historyError = error.localizedDescription
                }
            }
        }
    }

    func setSchedule(minutes: Int) {
        perform("定时采集已启用", pending: "正在检查相机权限并保存定时设置…") {
            try $0.authorizeCapture()
            try $0.configure(minutes: minutes)
        }
    }

    func authorizeCapture() {
        perform("采集相机权限已确认", pending: "请在 macOS 提示中确认采集程序的相机访问…") {
            try $0.authorizeCapture()
        }
    }

    func pause() {
        perform("定时采集已暂停", pending: "正在暂停…") { try $0.pause() }
    }

    func capture() {
        perform("两路照片已保存，可在「数据浏览」查看。", pending: "等待两台摄像头画面稳定后拍摄…") { try $0.capture() }
    }

    func startBatch() {
        perform("新批次已建立，后续采集将保存到此批次。", pending: "正在创建批次文件夹…") { try $0.startBatch() }
    }

    private func perform(_ success: String, pending: String, action: @escaping (CaptureScheduler) throws -> Void) {
        guard !busy else { return }
        busy = true
        feedback = pending
        feedbackIsError = false
        let scheduler = self.scheduler
        work.async { [weak self] in
            let result = Result { try action(scheduler) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                switch result {
                case .success: self.feedback = success
                case .failure(let error):
                    self.feedback = error.localizedDescription
                    self.feedbackIsError = true
                }
                self.refreshStatus()
                self.refreshHistory()
            }
        }
    }

    func openDataset() {
        open(scheduler.library.folder)
    }

    func openLog() {
        open(scheduler.log)
    }

    private func open(_ location: URL) {
        guard NSWorkspace.shared.open(location) else {
            feedback = "暂时无法打开 \(location.lastPathComponent)。"
            feedbackIsError = true
            return
        }
    }
}

struct ScheduleView: View {
    @ObservedObject var model: CollectorModel
    @State private var minutes = "60"
    @State private var loaded = false

    private var validInterval: Int? {
        guard let interval = Int(minutes.trimmingCharacters(in: .whitespaces)), (1...1440).contains(interval) else { return nil }
        return interval
    }
    private var canConfigure: Bool {
        validInterval != nil && !model.busy && model.status != nil && model.statusError == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("定时采集").font(.title2.bold())
                        Text("确认两路相机已调好，再设置频率并启动任务。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(model.status.map { $0.running ? "正在采集" : ($0.enabled ? "任务运行中" : "任务已停止") } ?? "读取中",
                          systemImage: model.status?.enabled == true ? "checkmark.circle.fill" : "pause.circle")
                        .foregroundStyle(model.status?.enabled == true ? Color.green : Color.secondary)
                }
                if let error = model.statusError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }

                GroupBox("1 · 设置采集频率") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("每隔")
                            TextField("60", text: $minutes).frame(width: 64)
                                .accessibilityLabel("采集间隔（分钟）")
                            Text("分钟拍摄一组")
                            Spacer()
                            ForEach([15, 30, 60], id: \.self) { interval in
                                Button("\(interval) 分钟") { minutes = String(interval) }
                            }
                        }
                        Text("60 分钟按每小时整点拍摄；其他间隔从启用或保存时起算。范围 1–1440 分钟。")
                            .font(.caption).foregroundStyle(.secondary)
                        if validInterval == nil {
                            Text("请输入 1 到 1440 之间的整数。").font(.caption).foregroundStyle(.orange)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("2 · 确认运行条件") {
                    VStack(alignment: .leading, spacing: 9) {
                        Toggle("任务运行时防止 Mac 闲置睡眠", isOn: $model.keepAwake)
                        Text("保持 Mac 接电并开盖，可以锁屏。防闲置睡眠在本程序打开且任务启用时生效。")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("后台定时由 macOS 在已登录的会话中执行；退出程序后，程序提供的防睡眠会结束。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("3 · 测试并启动") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button("拍摄一组测试照片") { model.capture() }.disabled(model.busy)
                            Spacer()
                            if model.status?.enabled == true {
                                Button("暂停任务") { model.pause() }.disabled(model.busy)
                            }
                            Button(model.status?.enabled == true ? "保存采集频率" : "启动定时采集") {
                                if let validInterval { model.setSchedule(minutes: validInterval) }
                            }.buttonStyle(.borderedProminent).disabled(!canConfigure)
                        }
                        if model.status?.enabled == true, let status = model.status {
                            Label(status.timing, systemImage: "clock").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("测试拍摄只保存一组照片，不会启用定时任务。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if model.busy {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.feedback).font(.callout) }
                        } else if !model.feedback.isEmpty {
                            Text(model.feedback).font(.callout)
                                .foregroundStyle(model.feedbackIsError ? Color.orange : Color.secondary).textSelection(.enabled)
                        }
                        if let code = model.status?.lastExit, code != 0 {
                            Label("上次采集失败（\(code)），请在下方诊断中查看日志。", systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("采集结果") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let time = model.batches.first?.timestamp {
                            LabeledContent("最近拍摄") { Text(time.formatted(date: .abbreviated, time: .standard)) }
                        } else { Text("尚无采集记录。").foregroundStyle(.secondary) }
                        HStack {
                            Text("历史照片在顶部「数据浏览」按时间查看。").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("打开数据文件夹") { model.openDataset() }
                        }
                        Text(model.scheduler.library.folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                DisclosureGroup("高级 · 权限与运行诊断") {
                    HStack {
                        Button("检查相机权限") { model.authorizeCapture() }.disabled(model.busy)
                        Button("查看采集日志") { model.openLog() }
                            .disabled(!FileManager.default.fileExists(atPath: model.scheduler.log.path))
                    }.padding(.top, 8)
                }.font(.callout)
            }.padding(22).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onReceive(model.$status) { status in
            if !loaded, let status { minutes = String(status.minutes); loaded = true }
            else if let status, !model.busy, minutes.isEmpty { minutes = String(status.minutes) }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: CollectorModel
    @State private var folderID: URL?
    @State private var selectedID: URL?
    @State private var showOriginal = false
    @State private var confirmNewBatch = false
    @State private var cropMode: HistoryCropMode = .full
    @State private var regions: [Int: CGRect] = [:]
    @State private var fixedCropSize: CGSize?
    @State private var cropOriginals = false
    @State private var showZoom = true
    @State private var exportInProgress = false
    @State private var exportFeedback = ""
    @State private var exportedFolder: URL?

    private var folder: CaptureFolder? {
        model.captureFolders.first { $0.id == folderID } ?? model.captureFolders.first
    }

    private var selected: CaptureBatch? {
        folder?.batches.first { $0.id == selectedID } ?? folder?.batches.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("数据浏览").font(.title2.bold())
                    Text("\(model.captureFolders.count) 个批次文件夹 · \(model.batches.count) 组照片")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("新建批次") { confirmNewBatch = true }.disabled(model.busy)
                Button("刷新") { model.refreshHistory() }
                Button("打开数据目录") { model.openDataset() }
            }
            .padding(14)
            Divider()
            if let error = model.historyError {
                ContentUnavailableView("无法读取采集记录", systemImage: "folder.badge.questionmark", description: Text(error))
            } else if let folder {
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(folder.title).font(.headline)
                            if folder.isActive {
                                Text("当前采集").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("打开批次文件夹") { NSWorkspace.shared.open(folder.id) }
                        }
                        if let selected {
                            captureDetails(selected)
                        } else {
                            ContentUnavailableView("此批次还没有照片", systemImage: "photo.on.rectangle.angled",
                                                   description: Text("采集后会在此显示两路照片。"))
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("还没有采集批次", systemImage: "folder",
                                       description: Text("新建批次后，可在此浏览每组采集照片。"))
            }
            if !model.feedback.isEmpty {
                Divider()
                Text(model.feedback)
                    .font(.callout)
                    .foregroundStyle(model.feedbackIsError ? Color.orange : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .confirmationDialog("新建采集批次？", isPresented: $confirmNewBatch, titleVisibility: .visible) {
            Button("创建并设为当前批次") { model.startBatch() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("下一组采集照片会进入新的批次文件夹。")
        }
        .onChange(of: model.captureFolders.first(where: \.isActive)?.id) { previous, current in
            if let current, previous != current { folderID = current }
        }
        .onChange(of: folder?.id, initial: true) {
            folderID = folder?.id
            selectedID = folder?.batches.first?.id
            cropMode = .full
            regions.removeAll()
            fixedCropSize = nil
            exportFeedback = ""
            exportedFolder = nil
        }
        .onChange(of: selected?.id, initial: true) { selectedID = selected?.id }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("批次文件夹").font(.headline).padding(10)
            List(model.captureFolders, selection: $folderID) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Label(entry.title, systemImage: entry.isActive ? "folder.fill" : "folder")
                        .lineLimit(1)
                    Text(entry.isActive ? "当前采集 · \(entry.batches.count) 组" : "\(entry.batches.count) 组")
                        .font(.caption).foregroundStyle(.secondary)
                }.tag(entry.id)
            }
            .frame(minHeight: 90, idealHeight: 140, maxHeight: 180)
            Divider()
            Text("采集记录").font(.headline).padding(10)
            List(folder?.batches ?? [], selection: $selectedID) { batch in
                VStack(alignment: .leading, spacing: 2) {
                    Text(batch.timestamp, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second())
                        .monospacedDigit()
                    if let hour = batch.hour {
                        Text("第 \(hour) 个整点小时").font(.caption).foregroundStyle(.secondary)
                    }
                }.tag(batch.id)
            }
        }
        .frame(width: 205)
    }

    private func captureDetails(_ selected: CaptureBatch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selected.timestamp.formatted(date: .abbreviated, time: .standard)).font(.headline)
                Spacer()
                if selected.adjustedFileNames != nil || cropMode != .full {
                    Picker("照片版本", selection: $showOriginal) {
                        Text("校正图").tag(false)
                        Text("相机原图").tag(true)
                    }.pickerStyle(.segmented).frame(width: 210)
                } else {
                    Text("相机原图").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Picker("裁剪方式", selection: $cropMode) {
                    ForEach(HistoryCropMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 216)
                Spacer()
                if cropMode != .full {
                    Button(showZoom ? "查看全图" : "查看放大") { showZoom.toggle() }.disabled(regions.isEmpty)
                    Button("重选区域") { resetRegions() }.disabled(regions.isEmpty)
                }
            }
            if cropMode != .full {
                Text(cropMode == .seed ? "在两路照片各点一次同一颗种子。切换时间点会沿用所选位置。"
                                      : "先在左图框选，再拖动右图上的等大裁剪框。切换时间点会沿用所选范围。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let size = fixedCropSize {
                        Text("\(Int(size.width)) × \(Int(size.height)) px")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button("保存本组裁剪") { export([selected]) }.disabled(regions.count != 2 || exportInProgress)
                    Button("保存本批次裁剪") { export(folder?.batches ?? []) }.disabled(regions.count != 2 || exportInProgress)
                    if let exportedFolder {
                        Button("打开裁剪结果") { NSWorkspace.shared.open(exportedFolder) }
                    }
                }
            }
            if !exportFeedback.isEmpty {
                Text(exportFeedback).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach(1...2, id: \.self) { camera in
                    let adjusted = (cropMode == .full ? showOriginal : cropOriginals) ? nil : selected.adjustedPhoto(camera)
                    if cropMode != .full, !cropOriginals, adjusted == nil {
                        ContentUnavailableView("此时间点缺少校正图", systemImage: "photo",
                                               description: Text("切换相机原图后可重新选择裁剪区域。"))
                            .frame(maxWidth: .infinity)
                    } else {
                        let region = cropMode == .full ? nil : regions[camera]
                        BatchPhoto(url: adjusted ?? selected.photo(camera), camera: camera, adjusted: adjusted != nil,
                                   mode: cropMode, region: region, fixedSize: fixedCropSize,
                                   referenceRegion: regions[1],
                                   zoomed: showZoom && region != nil && (cropMode != .row || regions.count == 2)) { newRegion, imageSize in
                            if cropMode == .row && camera == 1 {
                                fixedCropSize = CGSize(width: max(1, (newRegion.width * imageSize.width).rounded()),
                                                       height: max(1, (newRegion.height * imageSize.height).rounded()))
                                regions[2] = nil
                            }
                            regions[camera] = newRegion
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .onChange(of: cropMode) {
            resetRegions()
            cropOriginals = showOriginal || selected.adjustedFileNames == nil
            if cropMode != .full && cropOriginals { showOriginal = true }
        }
        .onChange(of: showOriginal) {
            if cropMode != .full && cropOriginals != showOriginal {
                resetRegions()
                cropOriginals = showOriginal
            }
        }
    }

    private func resetRegions() {
        regions.removeAll()
        fixedCropSize = nil
        showZoom = true
    }

    private func export(_ records: [CaptureBatch]) {
        guard let folder, !exportInProgress else { return }
        let job = HistoryCropExport(folder: folder.id, records: records, regions: regions,
                                    mode: cropMode, originals: cropOriginals, fixedSize: fixedCropSize)
        exportInProgress = true
        exportFeedback = "正在保存双路裁剪…"
        exportedFolder = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try job.save() } }.value
            exportInProgress = false
            switch result {
            case .success(let saved):
                exportFeedback = "已保存 \(saved.saved) 组，每组含两张裁剪图和一张双路对照。"
                if saved.skipped > 0 { exportFeedback += " 有 \(saved.skipped) 组缺少校正图。" }
                exportedFolder = saved.folder
            case .failure(let error):
                exportFeedback = error.localizedDescription
            }
        }
    }
}

private struct BatchPhoto: View {
    let url: URL
    let camera: Int
    let adjusted: Bool
    let mode: HistoryCropMode
    let region: CGRect?
    let fixedSize: CGSize?
    let referenceRegion: CGRect?
    let zoomed: Bool
    let onSelect: (CGRect, CGSize) -> Void
    @State private var loadedImage: CGImage?
    @State private var imageSize: CGSize?
    @State private var failed = false
    @State private var dragRegion: CGRect?

    private var source: HistoryCropSource {
        .init(url: url, region: zoomed ? region : nil, fixedSize: zoomed ? fixedSize : nil)
    }

    private var movesFixedFrame: Bool { mode == .row && camera == 2 }

    private var outline: CGRect? {
        guard let imageSize, let fixedSize, let referenceRegion else { return region }
        return placedFrame(at: region?.origin ?? referenceRegion.origin, size: fixedSize, in: imageSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("camera-\(camera)").font(.headline)
                Spacer()
                Button(adjusted ? "打开校正图" : "打开原图") { NSWorkspace.shared.open(url) }
            }
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).textSelection(.enabled)
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.black)
                    if let loadedImage {
                        let scale = min(geometry.size.width / Double(loadedImage.width),
                                        geometry.size.height / Double(loadedImage.height))
                        let width = Double(loadedImage.width) * scale
                        let height = Double(loadedImage.height) * scale
                        if width > 0 && height > 0 {
                            imageSurface(loadedImage, width: width, height: height)
                        }
                    } else if failed {
                        Text("照片读取失败").foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: source) {
            let request = source
            loadedImage = nil
            imageSize = nil
            failed = false
            dragRegion = nil
            let result = await Task.detached(priority: .userInitiated) {
                try? (request.image(), request.pixelSize())
            }.value
            if !Task.isCancelled {
                loadedImage = result?.0
                imageSize = result?.1
                failed = result == nil
            }
        }
    }

    private func imageSurface(_ image: CGImage, width: CGFloat, height: CGFloat) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) {
                if !zoomed, let outline = dragRegion ?? (mode == .full ? nil : outline) {
                    Rectangle()
                        .fill(.cyan.opacity(0.15))
                        .overlay { Rectangle().strokeBorder(.cyan, lineWidth: 2) }
                        .frame(width: outline.width * width, height: outline.height * height)
                        .offset(x: outline.minX * width, y: outline.minY * height)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if !zoomed && mode != .full && (!movesFixedFrame || outline != nil) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(selection(width: width, height: height))
                        .accessibilityLabel("camera-\(camera) 裁剪取景")
                } else if !zoomed && movesFixedFrame && fixedSize != nil && outline == nil {
                    Text("右图放不下此尺寸，请在左图重选。")
                        .font(.caption).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
    }

    private func selection(width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: mode == .seed || movesFixedFrame ? 0 : 4)
            .onChanged { value in
                if mode == .row { dragRegion = proposedRegion(value, width: width, height: height) }
            }
            .onEnded { value in
                defer { dragRegion = nil }
                guard let imageSize else { return }
                if mode == .seed {
                    let side = 0.25
                    let x = min(1 - side, max(0, value.location.x / width - side / 2))
                    let y = min(1 - side, max(0, value.location.y / height - side / 2))
                    onSelect(CGRect(x: x, y: y, width: side, height: side), imageSize)
                } else {
                    guard let chosen = proposedRegion(value, width: width, height: height) else { return }
                    if movesFixedFrame || (chosen.width * width >= 5 && chosen.height * height >= 5) {
                        onSelect(chosen, imageSize)
                    }
                }
            }
    }

    private func proposedRegion(_ value: DragGesture.Value, width: CGFloat, height: CGFloat) -> CGRect? {
        let start = CGPoint(x: value.startLocation.x / width, y: value.startLocation.y / height)
        let end = CGPoint(x: value.location.x / width, y: value.location.y / height)
        if movesFixedFrame {
            guard let outline, let fixedSize, let imageSize else { return nil }
            let origin = outline.contains(start)
                ? CGPoint(x: outline.minX + end.x - start.x, y: outline.minY + end.y - start.y)
                : CGPoint(x: end.x - outline.width / 2, y: end.y - outline.height / 2)
            return placedFrame(at: origin, size: fixedSize, in: imageSize)
        }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
                          height: abs(end.y - start.y)).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return rect.isEmpty ? nil : rect
    }

    private func placedFrame(at origin: CGPoint, size: CGSize, in bounds: CGSize) -> CGRect? {
        guard let rect = HistoryCropSource.place(origin, size: size, in: bounds) else { return nil }
        return CGRect(x: rect.minX / bounds.width, y: rect.minY / bounds.height,
                      width: rect.width / bounds.width, height: rect.height / bounds.height)
    }
}
