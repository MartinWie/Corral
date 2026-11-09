import Foundation
import Testing
@testable import CorralCore

/// Opt-in: CORRAL_REAL_INDEX=<dir> indexes this machine's real transcripts (read-only) into <dir>
/// and prints timings. Skipped otherwise.
struct RealDataBenchmark {
    static func footprint() -> (UInt64, UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return (info.phys_footprint >> 20, UInt64(info.ledger_phys_footprint_peak) >> 20)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CORRAL_REAL_INDEX"] != nil))
    func indexRealTranscripts() async throws {
        let dir = ProcessInfo.processInfo.environment["CORRAL_REAL_INDEX"]!
        let path = (dir as NSString).appendingPathComponent("bench-\(UUID().uuidString.prefix(6)).sqlite")
        let index = SearchIndex(path: path)
        try index.open()
        for source in [SearchIndex.Source.claude, .opencode, .pi] {
            let start = Date()
            await withCheckedContinuation { c in index.refresh([source]) { c.resume() } }
            print("BENCH full \(source): \(String(format: "%.1f", Date().timeIntervalSince(start)))s error=\(index.lastError ?? "none") footprint=\(Self.footprint().0) MB peak=\(Self.footprint().1) MB")
        }
        let again = Date()
        await withCheckedContinuation { c in index.refresh() { c.resume() } }
        print("BENCH incremental no-op: \(String(format: "%.2f", Date().timeIntervalSince(again)))s")
        for q in ["login", "kafka", "gradle test", "refactor"] {
            let t = Date()
            let hits = try index.readQueue.sync { try index.searchSync(q) }
            print("BENCH query '\(q)': \(hits.count) sessions in \(String(format: "%.0f", Date().timeIntervalSince(t) * 1000))ms; top: \(hits.prefix(2).map { "\($0.agent.rawValue) \($0.title.prefix(40))" })")
        }
        let (now, peak) = Self.footprint()
        print("BENCH memory: footprint \(now) MB, peak footprint \(peak) MB")
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        print("BENCH index size: \(size / 1_000_000) MB")
    }
}
