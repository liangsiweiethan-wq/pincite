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

private final class OcrProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var didTimeOut = false
    private var didResume = false

    func markTimedOut() {
        lock.lock()
        didTimeOut = true
        lock.unlock()
    }

    func completeOnce(terminationReason: Process.TerminationReason,
                      terminationStatus: Int32) -> Result<Void, OcrDriverError>? {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return nil }
        didResume = true
        if didTimeOut && terminationReason == .uncaughtSignal {
            return .failure(.timedOut)
        }
        if terminationStatus != 0 {
            return .failure(.processFailed(terminationStatus))
        }
        return .success(())
    }
}

private func runOcrSubprocess(executable: URL,
                              arguments: [String],
                              inputPDF: URL,
                              outputDir: URL,
                              timeoutSeconds: TimeInterval) async throws -> URL {
    guard FileManager.default.fileExists(atPath: executable.path),
          FileManager.default.fileExists(atPath: inputPDF.path) else {
        throw OcrDriverError.invalidPath
    }
    do { try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true) }
    catch { throw OcrDriverError.invalidPath }

    let binDir = executable.deletingLastPathComponent()
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments

    var env = process.environment ?? [:]
    env["PATH"] = [binDir.path, env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
    process.environment = env

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { handle in
        _ = handle.availableData
    }

    let state = OcrProcessState()
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { proc in
            timer.cancel()
            pipe.fileHandleForReading.readabilityHandler = nil
            _ = try? pipe.fileHandleForReading.readToEnd()
            if let outcome = state.completeOnce(terminationReason: proc.terminationReason,
                                                terminationStatus: proc.terminationStatus) {
                switch outcome {
                case .success: continuation.resume()
                case .failure(let err): continuation.resume(throwing: err)
                }
            }
        }

        let clampedTimeout = max(timeoutSeconds, 0.01)
        timer.schedule(deadline: .now() + clampedTimeout)
        timer.setEventHandler {
            state.markTimedOut()
            if process.isRunning { process.terminate() }
        }

        timer.resume()
        do {
            try process.run()
        } catch {
            timer.cancel()
            pipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
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

struct MinerUDriver {
    let mineruPath: URL
    let timeoutSeconds: TimeInterval

    init(mineruPath: URL, timeoutSeconds: TimeInterval = 1800) {
        self.mineruPath = mineruPath
        self.timeoutSeconds = timeoutSeconds
    }

    func run(on inputPDF: URL, outputDir: URL) async throws -> URL {
        try await runOcrSubprocess(executable: mineruPath,
                                   arguments: ["-p", inputPDF.path, "-o", outputDir.path],
                                   inputPDF: inputPDF,
                                   outputDir: outputDir,
                                   timeoutSeconds: timeoutSeconds)
    }
}

struct DoclingDriver {
    let doclingPath: URL
    let timeoutSeconds: TimeInterval

    init(doclingPath: URL, timeoutSeconds: TimeInterval = 1800) {
        self.doclingPath = doclingPath
        self.timeoutSeconds = timeoutSeconds
    }

    func run(on inputPDF: URL, outputDir: URL) async throws -> URL {
        try await runOcrSubprocess(executable: doclingPath,
                                   arguments: [inputPDF.path, "--output-dir", outputDir.path],
                                   inputPDF: inputPDF,
                                   outputDir: outputDir,
                                   timeoutSeconds: timeoutSeconds)
    }
}

#endif
