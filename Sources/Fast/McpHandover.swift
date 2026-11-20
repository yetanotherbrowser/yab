import Foundation
import MachO
import Security
import YabStore

// A `yab mcp` that outlived its own app: hands its client to one started
// from the copy at its path now.
//
// An agent's server lives as long as the agent's chat, for hours, and Claude
// Code or Codex never start it again on their own. An update (Update.Swap)
// renames yab.app aside to yab.app.old, moves the new one in, and sweeps the
// .old once the browser is closed. A running process follows the rename, so
// until the sweep the old server still validates as Yab's code. After it,
// its code has no file left: Code Signing can't make a code object for it
// at all, BenchCaller answers that it isn't Yab's, and the browser that
// came back refused every call with BenchCaller.refusal for the rest of the
// chat, while `yab` in the same shell, started from the new copy, worked.
// A new copy written over the old in place (cp, a build script) ends the
// same way, as errSecCSStaticCodeChanged.
//
// The check is right: that process is not the code on disk. So the server
// refused while another file stands at its own path starts `yab mcp` again
// from that path, with its own arguments, says the client's `initialize` to
// it, and from then on only carries lines both ways. The new server is an
// ordinary one, checked by the browser as any other; nothing it is handed is
// anything a program couldn't already give `yab mcp` by starting it.

final class McpHandover: @unchecked Sendable {
    /// Whether the file at `path`, where this process was started from, is
    /// no longer the one it runs: set aside and swept by an update, replaced
    /// by a new copy, or written over in place. Nothing at `path` is not a
    /// replacement: there is nothing to start. Asked only after a refusal.
    static func replacedOnDisk(_ path: String) -> Bool {
        guard let running = runningFile() else { return false }
        var now = stat()
        guard stat(path, &now) == 0 else { return false }
        if UInt64(now.st_dev) != running.device || UInt64(now.st_ino) != running.inode { return true }
        // The same file with new contents. Validating a whole bundle takes
        // a fifth of a second, so this is asked last.
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return false }
        return SecCodeCheckValidity(me, [], nil) == errSecCSStaticCodeChanged
    }

    /// The file this process's own code is mapped from, as the kernel keeps
    /// it: still the same file after a rename, and after it was removed,
    /// when Code Signing and proc_pidpath no longer find it.
    static func runningFile() -> (device: UInt64, inode: UInt64)? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        var info = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, UInt64(UInt(bitPattern: header)), &info, size) == size
        else { return nil }
        let stat = info.prp_vip.vip_vi.vi_stat
        return (UInt64(stat.vst_dev), stat.vst_ino)
    }

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let client: (Data) -> Void
    private let lock = NSLock()

    /// Starts `executable` with `arguments` and has it take over from the
    /// client's `greeting` (its `initialize`, whose answer the client
    /// already has) and the `initialized` that followed. Lines it says go to
    /// `client`. Nil when it can't be started or doesn't answer the greeting.
    init?(executable: String, arguments: [String], greeting: [String: Any],
          client: @escaping (Data) -> Void) {
        guard let url = ProcessLaunch.executableURL(executable) else { return nil }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // The new copy checks for itself whether its app is whole.
        environment[LaunchCopy.relaunched] = nil
        process.environment = environment
        let toChild = Pipe(), fromChild = Pipe()
        process.standardInput = toChild
        process.standardOutput = fromChild
        guard (try? process.runValidated()) != nil else { return nil }
        self.process = process
        input = toChild.fileHandleForWriting
        // A new server that died early is a failed write, not SIGPIPE.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        output = fromChild.fileHandleForReading
        self.client = client
        // Its answer to the greeting is the client's already, so it is read
        // here and dropped.
        guard send(greeting), let answer = Self.line(output), !answer.isEmpty,
              send(["jsonrpc": "2.0", "method": "notifications/initialized"]) else {
            process.terminate()
            return nil
        }
    }

    /// One message to the new server, as the client sent it.
    @discardableResult
    func send(_ message: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(0x0A)
        return send(data)
    }

    /// One line from the client, carried as it came.
    @discardableResult
    func send(line: String) -> Bool {
        send(Data((line + "\n").utf8))
    }

    private func send(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (try? input.write(contentsOf: data)) != nil
    }

    /// Carries what the new server says to the client until it ends, on a
    /// thread of its own; `ended` once it has.
    func carry(ended: @escaping @Sendable () -> Void) {
        let output = output, client = client
        Thread.detachNewThread {
            while true {
                let data = output.availableData
                if data.isEmpty { break }
                client(data)
            }
            ended()
        }
    }

    /// The client has gone: so does the new server's input, and this waits
    /// for it to say goodbye to the browser and leave.
    func finish() {
        lock.lock()
        try? input.close()
        lock.unlock()
        process.waitUntilExit()
    }

    /// The next line `handle` says, read a byte at a time so nothing after
    /// it is taken from what `carry` passes on.
    private static func line(_ handle: FileHandle) -> Data? {
        var line = Data()
        while true {
            guard let byte = try? handle.read(upToCount: 1), let first = byte.first else { return nil }
            if first == 0x0A { return line }
            line.append(first)
        }
    }
}
