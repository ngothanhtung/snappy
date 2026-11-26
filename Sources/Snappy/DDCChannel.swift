import Foundation
import SnappyCore
import SnappyDisplayPrivate

/// DDC/CI to one external monitor.
///
/// All channels share one serial queue: concurrent I2C transactions to
/// different monitors make them answer nothing (seen on M1 Max with three
/// monitors probed at once), sequential ones work.
///
/// Monitors answer "null message" when transactions come too fast (measured:
/// back-to-back reads 50 ms apart fail on Dell/Samsung, ~150 ms apart work,
/// each request written twice),
/// so every transaction waits for a gap after the previous one. Writes are
/// coalesced per VCP code: dragging a slider only sends the latest value.
final class DDCChannel: @unchecked Sendable {
    private let service: SDPI2CService
    private let queue = DDCChannel.sharedQueue
    private static let sharedQueue = DispatchQueue(label: "Snappy.DDC", qos: .userInitiated)
    private let lock = NSLock()
    private var pendingWrites: [VCPCode: UInt16] = [:]
    private var draining = false
    /// Last I2C transaction; touched only on `queue`.
    private var lastIO: TimeInterval = 0

    private static let writeGap: TimeInterval = 0.05
    private static let readGap: TimeInterval = 0.15
    private static let replyDelay: useconds_t = 60_000

    init(service: SDPI2CService) {
        self.service = service
    }

    func write(_ code: VCPCode, _ value: UInt16) {
        lock.lock()
        pendingWrites[code] = value
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drainWrites() } }
    }

    private func drainWrites() {
        while true {
            lock.lock()
            guard let (code, value) = pendingWrites.first else {
                draining = false
                lock.unlock()
                return
            }
            pendingWrites.removeValue(forKey: code)
            lock.unlock()
            waitForGap(Self.writeGap)
            let ok = send(DDCPacket.setVCP(code, value: value))
            lastIO = ProcessInfo.processInfo.systemUptime
            if !ok { NSLog("Snappy: DDC write 0x%02X failed", code.rawValue) }
        }
    }

    /// Reads a VCP feature (up to 3 attempts); completion runs on the main queue.
    func read(_ code: VCPCode, completion: @escaping @Sendable (DDCReading?) -> Void) {
        queue.async {
            let result = self.readNow(code)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Reads several features in order, then calls back once with all that answered.
    /// Gives up after the first code if that one doesn't answer (a monitor
    /// without DDC would otherwise cost 3 attempts per code).
    func read(_ codes: [VCPCode], completion: @escaping @Sendable ([VCPCode: DDCReading]) -> Void) {
        queue.async {
            var out: [VCPCode: DDCReading] = [:]
            for (i, c) in codes.enumerated() {
                if let r = self.readNow(c) { out[c] = r } else if i == 0 { break }
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    private func readNow(_ code: VCPCode) -> DDCReading? {
        for attempt in 0..<3 {
            waitForGap(attempt == 0 ? Self.readGap : Self.readGap * 2)
            defer { lastIO = ProcessInfo.processInfo.systemUptime }
            guard send(DDCPacket.getVCP(code)) else { continue }
            usleep(Self.replyDelay)
            if let data = service.readChip(DDCPacket.chipAddress, offset: DDCPacket.hostAddress,
                                           length: UInt(DDCPacket.replyLength)),
               let reading = DDCPacket.parseReply([UInt8](data), for: code) {
                return reading
            }
        }
        return nil
    }

    /// Writes a packet twice, 10 ms apart. Dell U4320Q and Samsung S32B80P
    /// ignore a single Get VCP request (they keep answering "null message").
    private func send(_ packet: [UInt8]) -> Bool {
        let data = Data(packet)
        var ok = false
        for i in 0..<2 {
            if i > 0 { usleep(10_000) }
            ok = service.writeChip(DDCPacket.chipAddress, offset: DDCPacket.hostAddress, data: data) || ok
        }
        return ok
    }

    private func waitForGap(_ gap: TimeInterval) {
        let wait = lastIO + gap - ProcessInfo.processInfo.systemUptime
        if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
    }
}
