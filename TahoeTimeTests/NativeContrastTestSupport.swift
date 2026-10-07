// SPDX-License-Identifier: GPL-3.0-only
// 测试夹具写入原生对比度的可写入口，并在绘图时读回真正的环境值。

import Foundation
import SwiftUI
import Testing
@testable import TahoeTime

// 泛型保持值类型不固定，调用框架的 WritableKeyPath 重载，不再进下面的专用重载。
private nonisolated func nativeContrastEnvironment<Content: View, Value>(
    _ content: Content, keyPath: WritableKeyPath<EnvironmentValues, Value>, value: Value
) -> some View {
    content.environment(keyPath, value)
}

extension View {
    nonisolated func environment(
        _ keyPath: KeyPath<EnvironmentValues, ColorSchemeContrast>, _ value: ColorSchemeContrast
    ) -> some View {
        precondition(keyPath == \EnvironmentValues.colorSchemeContrast,
                     "只读入口只允许原生对比度夹具")
        return nativeContrastEnvironment(self, keyPath: \._colorSchemeContrast, value: value)
    }
}

@MainActor
struct NativeContrastTestSupportTests {
    private nonisolated struct Witness: ShapeStyle {
        let expectedContrast: ColorSchemeContrast
        let expectedScheme: ColorScheme

        func resolve(in environment: EnvironmentValues) -> Color {
            #expect(environment.colorSchemeContrast == expectedContrast,
                    "绘图读取的原生对比度与夹具不一致")
            #expect(environment.colorScheme == expectedScheme,
                    "绘图读取的原生外观与夹具不一致")
            return LightPalette.ink
        }
    }

    @Test(arguments: ["light", "dark"], [false, true])
    func theReadOnlyFixtureReachesTheActualNativeRenderEnvironment(appearance: String, increased: Bool) {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        let contrast: ColorSchemeContrast = increased ? .increased : .standard
        let renderer = ImageRenderer(content: Rectangle()
            .fill(Witness(expectedContrast: contrast, expectedScheme: scheme))
            .frame(width: 2, height: 2)
            .environment(\.colorScheme, scheme)
            .environment(\.colorSchemeContrast, contrast))
        #expect(renderer.cgImage != nil, "原生对比度见证图没有画出来")
    }
}
