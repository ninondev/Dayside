// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Testing
@testable import TahoeTime

@MainActor
struct PanelTableHighlightTests {
    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 3 }
    }

    @Test func onlyThePanelListLosesItsFillAndBothSelectionsRemain() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        let search = NSTableView(frame: NSRect(x: 0, y: 350, width: 320, height: 100))
        let panel = NSTableView(frame: NSRect(x: 0, y: 100, width: 320, height: 200))
        let probe = TableHighlightOff.Probe(frame: panel.frame)
        let rows = Rows()
        for table in [search, panel] {
            table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("place")))
            table.dataSource = rows
            table.reloadData()
            table.selectionHighlightStyle = .regular
        }
        host.addSubview(search)
        host.addSubview(panel)
        host.addSubview(probe)
        search.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        panel.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        probe.apply()
        #expect(panel.selectionHighlightStyle == .none)
        #expect(search.selectionHighlightStyle == .regular)
        #expect(panel.selectedRow == 1)
        #expect(search.selectedRow == 0)
        #expect(panel.dataSource === rows && search.dataSource === rows)
    }

    @Test func attachmentBeforeItsTableExistsDoesNotTouchSearch() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        let search = NSTableView(frame: NSRect(x: 0, y: 350, width: 320, height: 100))
        search.selectionHighlightStyle = .regular
        let probe = TableHighlightOff.Probe(frame: NSRect(x: 0, y: 100, width: 320, height: 200))
        host.addSubview(search)
        host.addSubview(probe)
        probe.apply()
        #expect(search.selectionHighlightStyle == .regular)
        let panel = NSTableView(frame: probe.frame)
        panel.selectionHighlightStyle = .regular
        host.addSubview(panel)
        probe.layout()
        #expect(panel.selectionHighlightStyle == .none)
        #expect(search.selectionHighlightStyle == .regular)
    }

    @Test func zeroSizedProbeCannotClaimATableAndResizeFindsItsScrollView() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 100, width: 320, height: 200))
        let panel = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 1000))
        panel.selectionHighlightStyle = .regular
        scroll.documentView = panel
        let probe = TableHighlightOff.Probe(frame: NSRect(x: 0, y: 100, width: 0, height: 0))
        host.addSubview(scroll)
        host.addSubview(probe)
        probe.apply()
        #expect(panel.selectionHighlightStyle == .regular)
        probe.setFrameSize(NSSize(width: 320, height: 200))
        #expect(panel.selectionHighlightStyle == .none)
    }
}
