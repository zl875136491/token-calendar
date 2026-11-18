import Darwin
import Foundation

enum SourceError: LocalizedError {
    case missing(String), timeout(String), output(String), http(Int), auth

    var errorDescription: String? {
        switch self {
        case let .missing(name): return "找不到 \(name) CLI"
        case let .timeout(name): return "\(name) 响应超时"
        case let .output(message): return message
        case let .http(status): return "Cursor 接口返回 HTTP \(status)"
        case .auth: return "请在 Cursor CLI 登录，并允许读取其 macOS 钥匙串登录项"
        }
    }
}

func executable(_ name: String) throws -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let nvm = home.appending(path: ".nvm/versions/node")
    let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let bins = path.split(separator: ":").map(String.init)
        + [home.appending(path: ".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        + versions.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            .map { nvm.appending(path: "\($0)/bin").path }
    for bin in bins {
        let url = URL(fileURLWithPath: bin, isDirectory: true).appending(path: name)
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    throw SourceError.missing(name)
}

final class Subprocess {
    private let task = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(_ url: URL, _ args: [String], cwd: URL? = nil, extra: [String: String] = [:]) throws {
        task.executableURL = url
        task.arguments = args
        task.currentDirectoryURL = cwd
        task.environment = ProcessInfo.processInfo.environment.merging(extra) { _, new in new }
        task.standardInput = input
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        try task.run()
    }

    deinit { stop() }

    func write(_ value: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data(value.utf8))
    }

    func read(seconds: TimeInterval, until: ((Data) -> Bool)? = nil) throws -> Data {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        let handle = output.fileHandleForReading
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { break }
            var fd = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let status = poll(&fd, 1, Int32((remaining * 1000).rounded(.up)))
            if status == -1 && errno == EINTR { continue }
            guard status > 0 else { break }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd.fd, $0.baseAddress, $0.count) }
            if count == -1 && errno == EINTR { continue }
            guard count > 0 else { break }
            bytes.append(contentsOf: buffer.prefix(count))
            if bytes.count > 2_000_000 { throw SourceError.output("命令输出超出预期") }
            if until?(bytes) == true { break }
        }
        return bytes
    }

    func closeInput() { try? input.fileHandleForWriting.close() }

    func stop() {
        closeInput()
        try? output.fileHandleForReading.close()
        if task.isRunning { task.terminate() }
    }
}
