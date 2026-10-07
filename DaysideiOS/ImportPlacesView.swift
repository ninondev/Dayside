// SPDX-License-Identifier: GPL-3.0-only
//
//  ImportPlacesView.swift
//  DaysideiOS
//
//  从 Mac 导入地点清单：扫码（VisionKit，真机才有相机）、
//  粘贴链接、或系统把 `dayside://import#dp1.…` 交给本 App（onOpenURL）三条路都汇到这里，
//  解码走 Rust `sharing.places_decode`，确认后合并或替换本机清单。
//

import SwiftUI
import UIKit
#if canImport(VisionKit)
import VisionKit
#endif

struct ImportPlacesView: View {
    let existing: [TimeZoneEntry]
    /// 系统按链接打开本 App 时带进来的文本；nil 表示用户自己从工具栏进来。
    var initialText: String? = nil
    /// 用户确认后的结果：合并或替换后的完整清单。
    let apply: ([TimeZoneEntry]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pending: PlacesTransferResult?
    @State private var failure: String?
    @State private var scanning = false
    @State private var replace = false

    var body: some View {
        NavigationStack {
            List {
                if let pending {
                    Section {
                        ForEach(Array(pending.places.enumerated()), id: \.offset) { _, place in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name)
                                Text(place.timeZoneID).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Mac 上的 \(pending.places.count) 个地点")
                    } footer: {
                        if pending.dropped > 0 { Text("有 \(pending.dropped) 条读不出来，已跳过。") }
                    }
                    Section {
                        Toggle("替换本机清单", isOn: $replace)
                        Button(replace ? "替换为这 \(pending.places.count) 个地点" : "合并进本机清单") {
                            apply(replace ? pending.places.map(\.entry) : PlacesTransfer.merge(pending.places, into: existing, displayName: Self.displayName))
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    } footer: {
                        Text(replace ? "本机现有的地点会被清掉。" : "已有的同名同时区地点不会重复添加。")
                    }
                } else {
                    Section {
                        if scannerAvailable {
                            Button { scanning = true } label: { Label("扫描 Mac 上的二维码", systemImage: "qrcode.viewfinder") }
                        }
                        Button { paste() } label: { Label("粘贴链接", systemImage: "doc.on.clipboard") }
                    } header: {
                        Text("从 Mac 导入")
                    } footer: {
                        Text("在 Mac 的 Dayside 里打开「时间工具 › 分享」，最下面有「同步到 iPhone」的二维码和链接。地点只在两台设备之间直接传，不经过任何服务器。")
                    }
                    if let failure {
                        Section { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("导入地点")
            .navigationBarTitleDisplayMode(.inline)
            // 用 id 驱动：导入页已开着时系统又送来一条链接，也要重新解；每次新请求先清掉上一次的预览与错误。
            .task(id: initialText) {
                if let initialText { pending = nil; failure = nil; replace = false; handle(initialText) }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            #if canImport(VisionKit)
            .sheet(isPresented: $scanning) {
                QRScannerSheet { text in
                    scanning = false
                    handle(text)
                }
            }
            #endif
        }
    }

    /// 与列表页同一套显示名：自定义名，否则按当前语言的城市名，再否则原始城市名。
    static func displayName(_ entry: TimeZoneEntry) -> String {
        entry.displayName(localizedCity: CityNameLanguage.name(from: entry.localizedNames ?? [:], locale: .current) ?? entry.cityName)
    }

    private var scannerAvailable: Bool {
        #if canImport(VisionKit)
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
        #else
        false
        #endif
    }

    private func paste() {
        handle(UIPasteboard.general.string ?? "")
    }

    private func handle(_ text: String) {
        switch PlacesTransfer.decode(text) {
        case .success(let result):
            // Rust 只核字符串形状；本机认不认这个时区在这里就定，预览与丢弃数才是真的，
            // 否则「替换」会拿一份全无效的清单把本机清空。
            let valid = result.places.filter { TimeZone(identifier: $0.timeZoneID) != nil }
            let dropped = result.dropped + (result.places.count - valid.count)
            if valid.isEmpty {
                pending = nil
                failure = "链接里的 \(result.places.count) 个地点这台设备一个都认不出（时区数据太旧？），什么都没改。"
            } else {
                pending = PlacesTransferResult(places: valid, generatedAt: result.generatedAt, dropped: dropped); failure = nil
            }
        case .failure(let error):
            failure = Self.message(for: error.code)
        }
    }

    static func message(for code: String) -> String {
        switch code {
        case "notAPlaceList": "这不是 Dayside 的地点链接。剪贴板里要有 Mac 上复制的「同步到 iPhone」链接。"
        case "tooLong", "corrupt", "unsupported": "链接读不出来，回 Mac 重新生成一次。"
        default: "导入失败（\(code)）。"
        }
    }
}

#if canImport(VisionKit)
/// 只认二维码里的文本，认到第一条 `dp1.` 就收工。模拟器没有相机，`isAvailable` 为 false 时按钮根本不显示。
struct QRScannerSheet: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let text = code.payloadStringValue, text.contains("dp1.") {
                    done = true
                    dataScanner.stopScanning()
                    found(text)
                    return
                }
            }
        }
    }
}
#endif
