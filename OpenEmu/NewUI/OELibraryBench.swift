// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


import AppKit
import QuartzCore
import Darwin.Mach

/// SPIKE. Measures the library window without a person driving it: when the first big scroll view fills, it scrolls it
/// down at two speeds while counting the frames the main thread manages, then writes the numbers and quits.
/// Works on any library window (the AppKit grid or the SwiftUI one) because both draw inside an `NSScrollView`.
///
/// Run: `OpenEmu -databasePath <folder> -OELibraryBench YES [-OESwiftUILibrary YES] [-OELibraryBenchOutput <file>]`
@MainActor
enum OELibraryBench {

    static var isOn: Bool { UserDefaults.standard.bool(forKey: "OELibraryBench") }
    private static var lines = [String]()
    private static var link: Any?
    private static var intervals = [Double]()
    private static var lastFrame = 0.0

    /// Seconds since this process started.
    static var sinceLaunch: Double {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_un.__p_starttime
        return Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
    }

    static func note(_ text: String) {
        guard isOn else { return }
        lines.append(String(format: "%7.2fs  ", sinceLaunch) + text)
        writeOut()
    }

    static func start(window: NSWindow) {
        guard isOn else { return }
        note("window created")
        poll(window: window, tries: 0)
    }

    private static func poll(window: NSWindow, tries: Int) {
        if let scroll = biggestScrollView(in: window.contentView), (scroll.documentView?.frame.height ?? 0) > 3000 {
            note("grid ready: document height \(Int(scroll.documentView!.frame.height)) pt")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { run(scroll, window: window) }
        } else if tries % 100 == 50 {
            note("waiting: scroll views seen \(describeScrollViews(in: window.contentView))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll(window: window, tries: tries + 1) }
        } else if tries > 1200 {
            note("gave up: no scroll view filled in 120 s"); finish()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll(window: window, tries: tries + 1) }
        }
    }

    private static func describeScrollViews(in view: NSView?) -> String {
        var out = [String]()
        func walk(_ v: NSView, _ depth: Int) {
            if v is NSScrollView || String(describing: type(of: v)).contains("Scroll") {
                out.append("\(type(of: v)) frame \(Int(v.frame.width))x\(Int(v.frame.height)) doc \((v as? NSScrollView)?.documentView.map { "\(Int($0.frame.height))" } ?? "-")")
            }
            v.subviews.forEach { walk($0, depth + 1) }
        }
        if let view { walk(view, 0) }
        return out.joined(separator: "; ")
    }

    private static func biggestScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, s.documentView != nil, s.frame.width > 300,
               (s.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = s }
            v.subviews.forEach(walk)
        }
        walk(view)
        return best
    }

    private static func run(_ scroll: NSScrollView, window: NSWindow) {
        note("window \(Int(window.frame.width))x\(Int(window.frame.height)), visible \(window.isVisible), screen \(window.screen?.maximumFramesPerSecond ?? 0) Hz")
        guard #available(macOS 14.0, *) else { note("needs macOS 14 for display links"); return finish() }
        pass(name: "slow  2000 pt/s", speed: 2000, seconds: 5, scroll: scroll, window: window) {
            pass(name: "fast  8000 pt/s", speed: 8000, seconds: 4, scroll: scroll, window: window) {
                pass(name: "warm  2000 pt/s (same range as slow)", speed: 2000, seconds: 5, scroll: scroll, window: window, from: 0) { finish() }
            }
        }
    }

    @available(macOS 14.0, *)
    private static func pass(name: String, speed: Double, seconds: Double, scroll: NSScrollView, window: NSWindow,
                             from: CGFloat? = nil, then: @escaping () -> Void) {
        let clip = scroll.contentView
        let startY = from ?? clip.bounds.origin.y
        let limit = (scroll.documentView?.frame.height ?? 0) - clip.bounds.height
        clip.scroll(to: NSPoint(x: 0, y: startY)); scroll.reflectScrolledClipView(clip)
        intervals = []; lastFrame = 0
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let cpuStart = cpu(usage), wallStart = CACurrentMediaTime()
        let target = DisplayTarget { now in
            if lastFrame > 0 { intervals.append(now - lastFrame) }
            lastFrame = now
            let y = min(startY + (now - wallStart) * speed, limit)
            clip.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(clip)
            if now - wallStart >= seconds {
                (link as? CADisplayLink)?.invalidate(); link = nil
                var u = rusage(); getrusage(RUSAGE_SELF, &u)
                report(name: name, wall: now - wallStart, cpu: cpu(u) - cpuStart, travelled: y - startY)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: then)
            }
        }
        let l = window.contentView!.displayLink(target: target, selector: #selector(DisplayTarget.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        keepAlive = target
    }
    private static var keepAlive: AnyObject?

    private static func cpu(_ u: rusage) -> Double {
        Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    private static func report(name: String, wall: Double, cpu: Double, travelled: CGFloat) {
        let sorted = intervals.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
        let nominal = sorted.isEmpty ? 1.0 / 60 : sorted[sorted.count / 2]
        let dropped = intervals.reduce(0) { $0 + max(0, Int(($1 / nominal).rounded()) - 1) }
        let slow = intervals.filter { $0 > nominal * 1.5 }.count
        note(String(format: "%@: %d frames in %.1fs (%.1f fps), travelled %d pt | frame ms p50 %.1f p95 %.1f p99 %.1f max %.1f | late frames %d, dropped %d (%.1f%%) | main-thread CPU %.0f%% | footprint %d MB",
                    name, intervals.count, wall, Double(intervals.count) / wall, Int(travelled), pct(0.5), pct(0.95), pct(0.99), pct(1) ,
                    slow, dropped, 100 * Double(dropped) / Double(max(1, dropped + intervals.count)), 100 * cpu / wall, footprintMB()))
    }

    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }

    private static func writeOut() {
        let path = UserDefaults.standard.string(forKey: "OELibraryBenchOutput") ?? NSTemporaryDirectory() + "oe-library-bench.txt"
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func finish() {
        note("done")
        if !UserDefaults.standard.bool(forKey: "OELibraryBenchKeepOpen") { exit(0) }
    }
}

@MainActor private final class DisplayTarget: NSObject {
    let handler: (Double) -> Void
    init(_ handler: @escaping (Double) -> Void) { self.handler = handler }
    @available(macOS 14.0, *)
    @objc func tick(_ link: CADisplayLink) { handler(CACurrentMediaTime()) }
}
