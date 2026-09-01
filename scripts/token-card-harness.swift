import SwiftUI
import AppKit

// Measures the real TokenUsageCard at the width it gets in the panel: does the
// "↳ sub-agents" label still wrap to two lines (which doubled that row's height
// and broke alignment with the neighbouring column)?
func report(withSubAgents: Bool) -> TokenUsageReport {
    var today = TokenTotals(input: 444_900, output: 539_300, cacheRead: 396_500_000, cacheWrite: 0)
    today.costUSD = 240.50
    var sub = TokenTotals(input: 25_200, output: 28_100, cacheRead: 32_900_000, cacheWrite: 0)
    sub.costUSD = 17.58
    return TokenUsageReport(
        today: today, thisMonth: today,
        modelBreakdown: [ModelShare(model: "opus-5", share: 100, totals: today)],
        showsCost: true,
        todaySubAgent: withSubAgents ? sub : .zero,
        thisMonthSubAgent: withSubAgents ? sub : .zero
    )
}

func height(_ withSubAgents: Bool) -> CGFloat {
    var measured: CGFloat = 0
    let view = TokenUsageCard(report: report(withSubAgents: withSubAgents), accent: .orange)
        .frame(width: 420)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { measured = $0 }
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    for _ in 0..<8 {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return measured
}

let plain = height(false)
let withSub = height(true)
let rowPair = (withSub - plain) / 2   // height added per sub-agent row
print("card without sub-agent rows: \(plain)")
print("card with two sub-agent rows: \(withSub)  -> \(rowPair)pt per sub-agent row")
// A wrapped label costs roughly a second line of text (~13pt at Typo.footer).
if rowPair > 24 {
    print("FAIL: sub-agent row is \(rowPair)pt tall — the label is wrapping")
    exit(1)
}
print("ALL PASS")
