import Darwin
import Foundation

enum MiniDisplayError: Error, CustomStringConvertible {
    case io(String)
    var description: String {
        switch self { case .io(let s): return s }
    }
}

/// Minimal POSIX serial port for the panel's USB CDC-ACM device (/dev/cu.usbmodem*).
final class MiniDisplaySerialPort {
    let path: String
    private var fd: Int32 = -1

    init(path: String) { self.path = path }

    var isOpen: Bool { fd >= 0 }

    static func findPorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
    }

    func open() throws {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw MiniDisplayError.io("open \(path): \(Self.errText())") }

        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B115200))  // advisory on CDC-ACM
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &t)

        // Blocking writes; reads use poll() with a timeout.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        tcflush(fd, TCIOFLUSH)
    }

    func write(_ data: Data) throws {
        guard fd >= 0 else { throw MiniDisplayError.io("port closed") }
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, base + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { usleep(1000); continue }
                    throw MiniDisplayError.io("write: \(Self.errText())")
                }
                off += n
            }
        }
    }

    /// Reads whatever is available, waiting up to `timeout` seconds.
    func read(timeout: TimeInterval) -> Data {
        guard fd >= 0 else { return Data() }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&pfd, 1, Int32(timeout * 1000))
        guard r > 0 else { return Data() }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &buf, buf.count)
        return n > 0 ? Data(buf[0..<n]) : Data()
    }

    func flushInput() {
        if fd >= 0 { tcflush(fd, TCIFLUSH) }
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private static func errText() -> String { String(cString: strerror(errno)) }
}
