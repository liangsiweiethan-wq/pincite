import Foundation

// MinerU 外部进程驱动。fail-closed 语义：进程失败/超时/无产出
// 一律抛错，绝不静默。产出扫描以 _ocr.pdf 优先、目录内任意 pdf 降级处理
// （MinerU 实际输出名随版本漂移，目录扫描为准）。
//
// 本文件为 macOS 专属（Process/Signal 无 iOS 形态；OCR 外部进程驱动只存在
// 于 Mac 索引管线，iOS 为只读副本形态不跑外部 OCR），整体以 `#if os(macOS)`
// 防护。
#if os(macOS)

enum OcrDriverError: Error {
    case processFailed(Int32)
    case timedOut
    case noOutput
    case invalidPath
}

struct MinerUDriver {
    let mineruPath: URL
    let timeoutSeconds: TimeInterval

    init(mineruPath: URL, timeoutSeconds: TimeInterval = 1800) {
        self.mineruPath = mineruPath
        self.timeoutSeconds = timeoutSeconds
    }

    func run(on inputPDF: URL, outputDir: URL) async throws -> URL {
        // path validation
        guard FileManager.default.fileExists(atPath: mineruPath.path),
              FileManager.default.fileExists(atPath: inputPDF.path) else {
            throw OcrDriverError.invalidPath
        }
        do { try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true) }
        catch { throw OcrDriverError.invalidPath }

        // setup process
        let binDir = mineruPath.deletingLastPathComponent()
        let process = Process()
        process.executableURL = mineruPath
        process.arguments = ["-p", inputPDF.path, "-o", outputDir.path]

        var env = process.environment ?? [:]
        env["PATH"] = [binDir.path, env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = env

        let pipe0 = Pipe()
        process.standardOutput = pipe0
        process.standardError = pipe0

        try process.run()

        let pipe = pipe0
        let readDone = DispatchSemaphore(value: 0)
        let reader = DispatchQueue.global(qos: .utility)
        reader.async {
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
            }
            readDone.signal()
        }
        let timedOut = DispatchSemaphore(value: 0)
        var didTimeOut = false
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(Int(timeoutSeconds)))
        timer.setEventHandler {
            if process.isRunning { process.terminate() }
            timedOut.signal()
            didTimeOut = true
        }
        timer.resume()
        process.waitUntilExit()
        _ = timedOut.wait(timeout: .now() + 5)
        timer.cancel()
        _ = readDone.wait(timeout: .now() + 5)
        if didTimeOut && process.terminationReason == .uncaughtSignal {
            throw OcrDriverError.timedOut
        }
        if process.terminationStatus != 0 {
            throw OcrDriverError.processFailed(process.terminationStatus)
        }

        // scan output PDF
        let basename = inputPDF.deletingPathExtension().lastPathComponent
        let expected = outputDir.appendingPathComponent("\(basename)_ocr.pdf")
        if FileManager.default.fileExists(atPath: expected.path) {
            return expected
        }
        if let pdfs = try? FileManager.default.contentsOfDirectory(at: outputDir,
            includingPropertiesForKeys: nil).filter({ $0.pathExtension.lowercased() == "pdf" }),
            let pdf = pdfs.first {
            return pdf
        }
        throw OcrDriverError.noOutput
    }
}

// Docling 备胎引擎驱动。与 MinerUDriver 同构，仅类名/参数名/调用行不同。
struct DoclingDriver {
    let doclingPath: URL
    let timeoutSeconds: TimeInterval

    init(doclingPath: URL, timeoutSeconds: TimeInterval = 1800) {
        self.doclingPath = doclingPath
        self.timeoutSeconds = timeoutSeconds
    }

    func run(on inputPDF: URL, outputDir: URL) async throws -> URL {
        guard FileManager.default.fileExists(atPath: doclingPath.path),
              FileManager.default.fileExists(atPath: inputPDF.path) else {
            throw OcrDriverError.invalidPath
        }
        do { try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true) }
        catch { throw OcrDriverError.invalidPath }

        let process = Process()
        process.executableURL = doclingPath
        process.arguments = [inputPDF.path, "--output-dir", outputDir.path]

        var env = process.environment ?? [:]
        let binDir = doclingPath.deletingLastPathComponent()
        env["PATH"] = [binDir.path, env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        let readDone = DispatchSemaphore(value: 0)
        let reader = DispatchQueue.global(qos: .utility)
        reader.async {
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
            }
            readDone.signal()
        }
        let timedOut = DispatchSemaphore(value: 0)
        var didTimeOut = false
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(Int(timeoutSeconds)))
        timer.setEventHandler {
            if process.isRunning { process.terminate() }
            timedOut.signal()
            didTimeOut = true
        }
        timer.resume()
        process.waitUntilExit()
        _ = timedOut.wait(timeout: .now() + 5)
        timer.cancel()
        _ = readDone.wait(timeout: .now() + 5)
        if didTimeOut && process.terminationReason == .uncaughtSignal {
            throw OcrDriverError.timedOut
        }
        if process.terminationStatus != 0 {
            throw OcrDriverError.processFailed(process.terminationStatus)
        }

        let basename = inputPDF.deletingPathExtension().lastPathComponent
        let expected = outputDir.appendingPathComponent("\(basename)_ocr.pdf")
        if FileManager.default.fileExists(atPath: expected.path) {
            return expected
        }
        if let pdfs = try? FileManager.default.contentsOfDirectory(at: outputDir,
            includingPropertiesForKeys: nil).filter({ $0.pathExtension.lowercased() == "pdf" }),
            let pdf = pdfs.first {
            return pdf
        }
        throw OcrDriverError.noOutput
    }
}

#endif
