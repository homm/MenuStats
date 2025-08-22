import AppKit

final class StreamedProcess: ObservableObject {
    private var task: Process?
    private var stdoutPipe: Pipe?
    @Published var isRunning = false

    func start(
        command: String,
        args: [String] = [],
        workingDir: URL? = nil,
        lineHandler: @escaping (String) -> Void
    ) {
        stop()

        let task = Process()
        task.launchPath = command
        task.arguments = args
        if let wd = workingDir { task.currentDirectoryURL = wd }

        let out = Pipe()
        task.standardOutput = out
        self.stdoutPipe = out

        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) {
                s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    .forEach { line in 
                        lineHandler(String(line))
                    }
            }
        }

        do {
            try task.run()
            self.task = task
            self.isRunning = true
        } catch {
            lineHandler("[error] failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let t = task else { return }
        t.terminate()
        t.waitUntilExit()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        task = nil
        isRunning = false
    }
}

func run_once(_ cmd: String, _ args: [String]) -> String? {
    let p = Process()
    p.launchPath = cmd
    p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return "[error] \(error.localizedDescription)" }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}
