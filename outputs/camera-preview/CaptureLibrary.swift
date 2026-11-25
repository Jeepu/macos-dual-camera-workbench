import AppKit
import Foundation

struct CaptureBatch: Identifiable, Equatable {
    let folder: URL
    let timestamp: Date
    let fileNames: [String]
    let taskID: String?
    let hour: Int?
    var adjustedFileNames: [String]? = nil
    var id: URL { photo(1) }

    func photo(_ camera: Int) -> URL {
        folder.appendingPathComponent(fileNames[camera - 1])
    }

    func adjustedPhoto(_ camera: Int) -> URL? {
        adjustedFileNames.map { folder.appendingPathComponent($0[camera - 1]) }
    }
}

private struct TaskIndex: Decodable {
    struct Entry: Decodable {
        let legacyFolder: String
        let timestamp: String
        let hour: Int
        let files: [String]
        let adjustedFiles: [String]?
    }
    let taskID: String
    let batches: [Entry]
}

struct CaptureFolder: Identifiable, Equatable {
    let id: URL
    let taskID: String?
    let isActive: Bool
    let batches: [CaptureBatch]

    var title: String { taskID ?? id.lastPathComponent }
}

struct CaptureLibrary {
    var folder: URL

    func batches() throws -> [CaptureBatch] {
        try captureFolders().flatMap(\.batches).sorted { $0.timestamp > $1.timestamp }
    }

    func captureFolders() throws -> [CaptureFolder] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS_Z"
        let files = FileManager.default
        let folders = try files.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let indexedDate = ISO8601DateFormatter()
        indexedDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        struct ActiveTask: Decodable { let id: String }
        let taskURL = folder.deletingLastPathComponent().appendingPathComponent("dataset-task.json")
        let activeTaskID = (try? JSONDecoder().decode(ActiveTask.self, from: Data(contentsOf: taskURL)))?.id
        var archived: [CaptureFolder] = []
        var retired = Set<String>()
        for entry in folders {
            let indexURL = entry.appendingPathComponent(".captures.json")
            guard files.fileExists(atPath: indexURL.path) else { continue }
            let index = try JSONDecoder().decode(TaskIndex.self, from: Data(contentsOf: indexURL))
            var indexedBatches: [CaptureBatch] = []
            for record in index.batches {
                guard let time = indexedDate.date(from: record.timestamp),
                      record.files.count == 2,
                      record.files.allSatisfy({ !$0.contains("/") && $0.hasSuffix(".jpg") }) else { continue }
                let batch = CaptureBatch(folder: entry, timestamp: time, fileNames: record.files,
                                         taskID: index.taskID, hour: record.hour,
                                         adjustedFileNames: availableAdjustedFiles(record.adjustedFiles, in: entry))
                if photosExist(batch) {
                    indexedBatches.append(batch)
                    retired.insert(record.legacyFolder)
                }
            }
            archived.append(CaptureFolder(id: entry, taskID: index.taskID, isActive: index.taskID == activeTaskID,
                                          batches: indexedBatches.sorted { $0.timestamp > $1.timestamp }))
        }
        let legacy = folders.compactMap { entry -> CaptureFolder? in
            let name = entry.lastPathComponent
            guard !retired.contains(name),
                  let separator = name.lastIndex(of: "_"),
                  let time = formatter.date(from: String(name[..<separator])) else { return nil }
            let batch = CaptureBatch(folder: entry, timestamp: time, fileNames: ["camera-1.jpg", "camera-2.jpg"],
                                     taskID: nil, hour: nil, adjustedFileNames: availableAdjustedFiles(
                                         ["camera-1-adjusted.jpg", "camera-2-adjusted.jpg"], in: entry))
            return photosExist(batch) ? CaptureFolder(id: entry, taskID: nil, isActive: false, batches: [batch]) : nil
        }
        return (archived + legacy).sorted { left, right in
            if left.isActive != right.isActive { return left.isActive }
            return left.id.lastPathComponent > right.id.lastPathComponent
        }
    }

    private func availableAdjustedFiles(_ names: [String]?, in folder: URL) -> [String]? {
        guard let names, names.count == 2, names.allSatisfy({ name in
            !name.contains("/") && name.hasSuffix("-adjusted.jpg") &&
                FileManager.default.isReadableFile(atPath: folder.appendingPathComponent(name).path)
        }) else { return nil }
        return names
    }

    private func photosExist(_ batch: CaptureBatch) -> Bool {
        (1...2).allSatisfy { FileManager.default.isReadableFile(atPath: batch.photo($0).path) }
    }
}

struct CommandOutput {
    let status: Int32
    let text: String

    func checked() throws {
        guard status == 0 else {
            throw PreviewError(message: text.isEmpty ? "命令退出码 \(status)。" : text)
        }
    }

    static func run(_ command: String, _ arguments: [String]) throws -> Self {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Self(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct CaptureStatus: Equatable {
    var minutes = 60
    var enabled = false
    var running = false
    var lastExit: Int?

    var timing: String {
        minutes == 60 ? "每小时整点" : "每 \(minutes) 分钟"
    }
}

struct CaptureScheduler {
    static let userLibrary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
    static let defaultRoot = userLibrary.appendingPathComponent("Application Support/CameraCollector", isDirectory: true)

    var root = defaultRoot
    var agentDirectory = userLibrary.appendingPathComponent("LaunchAgents", isDirectory: true)
    var label = "local.dataset.dual-camera-collector"

    private var domain: String { "gui/\(getuid())" }
    var target: String { "\(domain)/\(label)" }
    var plist: URL { agentDirectory.appendingPathComponent("\(label).plist") }
    var log: URL { root.appendingPathComponent("capture.log") }
    var library: CaptureLibrary { CaptureLibrary(folder: root.appendingPathComponent("dataset", isDirectory: true)) }
    private var script: URL { root.appendingPathComponent("camera-collector.sh") }

    func authorizeCapture() throws {
        let receipt = FileManager.default.temporaryDirectory.appendingPathComponent("camera-authorization-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: receipt) }
        var app = root.appendingPathComponent("CameraCollector.app")
        var arguments = ["authorize", root.path, receipt.path]
        if let data = try? Data(contentsOf: root.appendingPathComponent("capture-runtime.json")),
           let runtime = try? JSONDecoder().decode([String: String].self, from: data),
           runtime["runtime"] == "preview", let path = runtime["appPath"],
           FileManager.default.fileExists(atPath: path) {
            app = URL(fileURLWithPath: path)
            arguments.insert("--camera-collector", at: 0)
        }
        try CommandOutput.run("/usr/bin/open", ["-n", "-g", "-W", "-a", app.path, "--args"] + arguments).checked()
        guard let result = try? String(contentsOf: receipt, encoding: .utf8) else {
            throw PreviewError(message: "采集组件没有返回权限结果，请检查组件安装。")
        }
        guard result.hasPrefix("OK\n") else {
            throw PreviewError(message: result.replacingOccurrences(of: "ERROR\n", with: ""))
        }
    }

    private func launch(_ arguments: [String]) throws -> CommandOutput {
        try CommandOutput.run("/bin/launchctl", arguments)
    }

    private func configuration(_ data: Data) throws -> [String: Any] {
        guard let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              values["Label"] as? String == label,
              values["ProgramArguments"] as? [String] == ["/bin/bash", script.path, "capture"] else {
            throw PreviewError(message: "现有后台任务与摄像头采集脚本不匹配。")
        }
        return values
    }

    func status() throws -> CaptureStatus {
        let info = try launch(["print", target])
        var status = CaptureStatus()
        if FileManager.default.fileExists(atPath: plist.path) {
            let values = try configuration(Data(contentsOf: plist))
            if let seconds = values["StartInterval"] as? Int {
                status.minutes = seconds / 60
            }
        }
        guard info.status == 0 else {
            if info.status == 113 || info.text.contains("Could not find service") { return status }
            try info.checked()
            return status
        }
        status.enabled = true
        for line in info.text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("pid = ") || line == "state = running" { status.running = true }
            if line.hasPrefix("last exit code = ") {
                status.lastExit = Int(line.dropFirst("last exit code = ".count))
            }
        }
        return status
    }

    func whileIdle(_ operation: () throws -> Void) throws {
        let lockPath = root.appendingPathComponent(".camera.lock").path
        let lock = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw PreviewError(message: "正在保存一批照片，请稍等几秒再修改定时任务。")
        }
        try operation()
    }

    func configure(minutes: Int) throws {
        guard (1...1440).contains(minutes) else {
            throw PreviewError(message: "请输入 1 到 1440 分钟之间的整数。")
        }
        guard FileManager.default.isReadableFile(atPath: script.path),
              FileManager.default.isReadableFile(atPath: root.appendingPathComponent("cameras.json").path) else {
            throw PreviewError(message: "找不到已配置的采集脚本，请先运行摄像头采集 setup。")
        }

        try whileIdle {
            let original = try status()
            if original.enabled && original.minutes == minutes { return }
            guard !original.running else {
                throw PreviewError(message: "后台正在采集，请稍等几秒再保存间隔。")
            }
            let files = FileManager.default
            let hadPlist = files.fileExists(atPath: plist.path)
            let oldData = try hadPlist ? Data(contentsOf: plist) : nil
            var values = try oldData.map(configuration) ?? [
                "Label": label,
                "ProgramArguments": ["/bin/bash", script.path, "capture"],
                "StandardOutPath": log.path,
                "StandardErrorPath": log.path
            ]
            values.removeValue(forKey: "StartInterval")
            values.removeValue(forKey: "StartCalendarInterval")
            if minutes == 60 {
                values["StartCalendarInterval"] = ["Minute": 0]
            } else {
                values["StartInterval"] = minutes * 60
            }
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            try files.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
            if original.enabled {
                try launch(["bootout", target]).checked()
            }

            do {
                try data.write(to: plist, options: .atomic)
                try launch(["enable", target]).checked()
                try launch(["bootstrap", domain, plist.path]).checked()
            } catch let updateError {
                do {
                    if let oldData {
                        try oldData.write(to: plist, options: .atomic)
                    } else if files.fileExists(atPath: plist.path) {
                        try files.removeItem(at: plist)
                    }
                    if original.enabled {
                        try launch(["enable", target]).checked()
                        try launch(["bootstrap", domain, plist.path]).checked()
                    } else if hadPlist {
                        try launch(["disable", target]).checked()
                    }
                } catch let recoveryError {
                    throw PreviewError(message: "保存失败，恢复原任务时也出错。\n\(updateError.localizedDescription)\n\(recoveryError.localizedDescription)")
                }
                throw updateError
            }
        }
    }

    func pause() throws {
        try whileIdle {
            let current = try status()
            guard current.enabled else { return }
            guard !current.running else {
                throw PreviewError(message: "后台正在采集，请稍等几秒再暂停。")
            }
            try launch(["disable", target]).checked()
            do {
                try launch(["bootout", target]).checked()
            } catch {
                try launch(["enable", target]).checked()
                throw error
            }
        }
    }

    func recoverIfEnabled() throws {
        guard FileManager.default.fileExists(atPath: plist.path), try !status().enabled else { return }
        let disabled = try launch(["print-disabled", domain])
        try disabled.checked()
        let entry = disabled.text.split(separator: "\n").first { $0.contains("\"\(label)\"") }
        if let entry, entry.contains("disabled") || entry.contains("=> true") { return }
        try launch(["bootstrap", domain, plist.path]).checked()
    }

    func capture() throws {
        try CommandOutput.run("/bin/bash", [script.path, "capture"]).checked()
    }

    func startBatch() throws {
        try whileIdle {
            let organizer = root.appendingPathComponent("organize-dataset.py")
            try CommandOutput.run("/usr/bin/python3", [organizer.path, root.path, "new-batch"]).checked()
        }
    }
}
