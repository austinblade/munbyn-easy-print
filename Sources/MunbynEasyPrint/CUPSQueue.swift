import Foundation

/// Registers the virtual printer with the system CUPS daemon.
enum CUPSQueue {
    static let name = "MUNBYN_941BP"
    static let displayName = "MUNBYN 941BP"

    enum Failure: LocalizedError {
        case command(String)
        var errorDescription: String? {
            if case .command(let s) = self { return s }
            return nil
        }
    }

    static func isInstalled() async -> Bool {
        let r = await run("/usr/bin/lpstat", ["-v", name])
        return r.status == 0 && r.output.contains(IPPPrinterService.printerURI)
    }

    /// `lpadmin -m everywhere` asks our IPP server for its attributes and builds
    /// the PPD from them, so the server must already be listening.
    static func install() async throws {
        let args = [
            "-p", name, "-E",
            "-v", IPPPrinterService.printerURI,
            "-m", "everywhere",
            "-D", displayName,
            "-L", "Bluetooth via Munbyn Easy Print",
            "-o", "printer-is-shared=false",
            // If the app isn't running, keep the job and retry instead of pausing the queue.
            "-o", "printer-error-policy=retry-job",
        ]
        let direct = await run("/usr/sbin/lpadmin", args)
        if direct.status == 0 { return }

        // Non-admin accounts need an authenticated lpadmin.
        let shell = (["/usr/sbin/lpadmin"] + args).map(shellQuote).joined(separator: " ")
        let script = "do shell script \(appleScriptQuote(shell)) with administrator privileges"
        let elevated = await run("/usr/bin/osascript", ["-e", script])
        if elevated.status != 0 {
            throw Failure.command("lpadmin failed: \(direct.output.isEmpty ? elevated.output : direct.output)")
        }
    }

    static func remove() async throws {
        let r = await run("/usr/sbin/lpadmin", ["-x", name])
        if r.status != 0 { throw Failure.command("lpadmin -x failed: \(r.output)") }
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func run(_ path: String, _ args: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do {
                    try p.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
                } catch {
                    cont.resume(returning: (-1, error.localizedDescription))
                }
            }
        }
    }
}
