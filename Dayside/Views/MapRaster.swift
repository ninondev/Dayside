// SPDX-License-Identifier: GPL-3.0-only
//
//  MapRaster.swift
//  Dayside
//
//  昼夜地图的底图不再是「陆地多边形 + 半透明的昼色」，而是 Rust 按此刻的太阳逐像素上的色
//  （`sky.rs`：夜是墨、白天是纸，颜色只在晨昏线附近；海陆与地形来自随包的 Natural Earth 灰度地形；城市灯火也画在里面）。
//  这里只做三件宿主的事：把随包的 `relief.png` 解码成灰度交给 Rust（第一次画地图时，最后一张地图消失 10 秒后放掉）、
//  向 Rust 要一张位图并包成 `CGImage`、以及在位图上量一块地方的明暗（地图上的字据此选墨或纸）。
//

import AppKit
import CoreGraphics
import Darwin
import ImageIO
import IOSurface
import QuartzCore
import Synchronization
import SwiftUI

/// 地形什么时候放掉（纯状态，`MapReliefTests` 直接钉住）：屏幕上的地图出现记一个、消失减一个；每次出现、消失、
/// 离屏出图都换一代。到点时没人在看、这期间也没人再碰过，才放。
nonisolated struct ReliefLifecycle: Equatable {
    var loaded = false
    var users = 0
    var generation = 0

    mutating func retain() {
        users += 1
        generation += 1
    }

    /// 返回这一代，到点时拿它问 `releaseIfIdle`。
    mutating func release() -> Int {
        users = max(0, users - 1)
        generation += 1
        return generation
    }

    mutating func touch() -> Int {
        generation += 1
        return generation
    }

    mutating func releaseIfIdle(since generation: Int) -> Bool {
        guard users == 0, self.generation == generation, loaded else { return false }
        loaded = false
        return true
    }
}

/// 随包的地形（`relief.png`，1800 × 690 灰度，覆盖 80°N … 58°S）→ Rust。第一次画地图时读进来（解码加上
/// Rust 算地形约 20 ms），最后一张地图消失 10 秒后放掉（空闲时不占内存：发布门量的是面板关着的时候）。
/// 导出名片这类不在屏幕上的地图也会读它，读完同样 10 秒后放掉。
nonisolated enum MapRelief {
    static let north = 80.0
    static let south = -58.0
    static let releaseDelay: TimeInterval = 10

    private static let state = Mutex(ReliefLifecycle())
    private static let loading = Mutex(())

    static var isLoaded: Bool { state.withLock { $0.loaded } }

    /// 画之前调：还没读就读（同一时刻只读一次）。
    static func ensureLoaded() {
        loading.withLock { _ in
            guard !state.withLock({ $0.loaded }) else { return }
            let ok = loadTerrain()
            state.withLock { $0.loaded = ok }
            DiagnosticsLog.note("map", ok ? "relief loaded" : "relief.png could not be loaded; the map draws without coastlines")
        }
    }

    /// 地图出现 / 消失（面板、地球窗、帮助页、欢迎页）。
    static func retain() {
        let users = state.withLock { s -> Int in s.retain(); return s.users }
        DiagnosticsLog.note("map", "map shown (\(users) on screen)")
    }

    static func release() {
        let (generation, users) = state.withLock { s -> (Int, Int) in (s.release(), s.users) }
        DiagnosticsLog.note("map", "map hidden (\(users) on screen)")
        scheduleRelease(after: generation)
    }

    /// 不在屏幕上的一次性出图（名片、海报）用过之后：没人在看就照样 10 秒后放掉。
    static func usedOffscreen() {
        scheduleRelease(after: state.withLock { $0.touch() })
    }

    private static func scheduleRelease(after generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseDelay) {
            if state.withLock({ $0.releaseIfIdle(since: generation) }) {
                mt_sky_relief_release()
                MapRaster.clearCache()
                PixelPool.drain()
                // 地形、各尺寸的画布地形与每帧的 JSON 都是 malloc 来的；释放后分配器仍把空页留着（`MALLOC_LARGE / SMALL (empty)`，
                // 算在常驻里）。没人在看地图了，请分配器把空页交还系统。
                let returned = malloc_zone_pressure_relief(nil, 0)
                DiagnosticsLog.note("map", "relief released; \(returned / 1024) KB returned to the system")
            }
        }
    }

    private static func loadTerrain() -> Bool {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Dayside", isDirectory: true).appendingPathComponent("terrain-1.bin")
        var mapped = false
        var reused = false
        defer {
            let environment = ProcessInfo.processInfo.environment
            if environment["MEANTIME_UI_TEST_MEMORY_TOUR"] == "1", environment["MEANTIME_TEST_HOST"] == "1" {
                let bytes: UInt64
                if let cache, let attributes = try? FileManager.default.attributesOfItem(atPath: cache.path),
                   let size = attributes[.size] as? NSNumber {
                    bytes = size.uint64Value
                } else {
                    bytes = 0
                }
                FileHandle.standardOutput.write(Data("MEANTIME_TOUR_TERRAIN_CACHE mapped=\(mapped) reused=\(reused) bytes=\(bytes)\n".utf8))
            }
        }
        if let cache, cache.path.withCString({ mt_sky_terrain_map($0) }) {
            mapped = true
            reused = true
            return true
        }
        guard load() else { return false }
        if let cache {
            do {
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                if cache.path.withCString({ mt_sky_terrain_save($0) }) {
                    // 映射成功时 Rust 原子替换现算的表；失败仍保留它，地图照常画。
                    mapped = cache.path.withCString { mt_sky_terrain_map($0) }
                }
            } catch {
                DiagnosticsLog.note("map", "terrain cache unavailable; using computed terrain")
            }
        }
        return true
    }

    /// 解码成 8 位灰度（按行紧排），交给 Rust。
    private static func load() -> Bool {
        guard let url = Bundle.main.url(forResource: "relief", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let (width, height) = (image.width, image.height)
        var gray = [UInt8](repeating: 0, count: width * height)
        // 随包那张就是 8 位灰度、无透明：直接拷原始字节（不经色彩管理）；别的格式再画进灰度画布。
        if image.bitsPerComponent == 8, image.bitsPerPixel == 8, image.colorSpace?.model == .monochrome, image.bytesPerRow >= width,
           let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data), CFDataGetLength(data) >= image.bytesPerRow * height {
            for y in 0..<height {
                for x in 0..<width { gray[y * width + x] = bytes[y * image.bytesPerRow + x] }
            }
            return gray.withUnsafeBufferPointer { mt_sky_relief_set($0.baseAddress, UInt32(width), UInt32(height), north, south) }
        }
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        return gray.withUnsafeBufferPointer { mt_sky_relief_set($0.baseAddress, UInt32(width), UInt32(height), north, south) }
    }
}

/// 位图的像素缓冲：直接向系统要页（`vm_allocate`），不经 malloc——malloc 会把释放掉的大块留着备用
/// （`MALLOC_LARGE (empty)`，照样算常驻），拖动地球窗时每帧一块 5 MB，实测关窗后几十 MB 占着不还（内存巡回）。
/// 同样大小的缓冲在帧之间复用：CoreGraphics 放掉一张图时它的缓冲回到池里（每种大小最多留两块），
/// 地形放掉时（最后一张地图消失 10 秒后）池整个还给系统。
nonisolated enum PixelPool {
    private static let free = Mutex<[Int: [UInt]]>([:])
    private static let keep = 2

    static func take(_ length: Int) -> UnsafeMutableRawPointer? {
        if let reused = free.withLock({ pool -> UInt? in pool[length]?.popLast() }) {
            return UnsafeMutableRawPointer(bitPattern: reused)
        }
        var address: vm_address_t = 0
        guard vm_allocate(mach_task_self_, &address, vm_size_t(length), VM_FLAGS_ANYWHERE) == KERN_SUCCESS else { return nil }
        return UnsafeMutableRawPointer(bitPattern: UInt(address))
    }

    static func give(_ pointer: UnsafeRawPointer, length: Int) {
        let address = UInt(bitPattern: pointer)
        // 地形已经放掉（没有地图在看）：不再留着备用，直接还给系统。
        let idle = !MapRelief.isLoaded
        let kept = free.withLock { pool -> Bool in
            guard !idle, (pool[length]?.count ?? 0) < keep else { return false }
            pool[length, default: []].append(address)
            return true
        }
        if !kept { vm_deallocate(mach_task_self_, vm_address_t(address), vm_size_t(length)) }
    }

    static func drain() {
        let all = free.withLock { pool -> [(Int, [UInt])] in
            defer { pool.removeAll() }
            return pool.map { ($0.key, $0.value) }
        }
        for (length, addresses) in all {
            for address in addresses { vm_deallocate(mach_task_self_, vm_address_t(address), vm_size_t(length)) }
        }
    }
}

/// Rust 画好的一张地图：`CGImage`（sRGB）与它的像素（量明暗用；与图共用同一块内存，不另存一份）。
/// 按（时刻、像素尺寸、纬度、灯火）缓存最近两张：同一刻 SwiftUI 重算视图（悬停、换标签）、海报量题字位置再画图都不必重画；
/// 拖动时每帧都是新的时刻。地球窗一张 1800 × 690 约 5 MB，面板一张约 0.5 MB；缓冲来自 `PixelPool`。
nonisolated final class MapRaster: @unchecked Sendable {
    let image: CGImage
    let width: Int
    let height: Int
    /// 位图像素 / 视图点。
    let scale: CGFloat
    /// 像素（图还活着它就活着：缓冲由图的数据源在释放时交回 `PixelPool`）。
    private let pixels: UnsafeRawPointer

    private init(image: CGImage, width: Int, height: Int, scale: CGFloat, pixels: UnsafeRawPointer) {
        self.image = image
        self.width = width
        self.height = height
        self.scale = scale
        self.pixels = pixels
    }

    /// 位图宽度的上限：地形图本身 1800 像素宽，再宽也画不出更多的海岸，交给图像缩放。
    static let maxWidth = 1800

    private struct Key: Hashable {
        let instant: Double; let width: Int; let height: Int; let north: Double; let south: Double; let lights: Double; let large: Bool
    }
    private static let cache = Mutex<[(Key, MapRaster)]>([])
    private static let cacheLimit = 2

    static func clearCache() {
        cache.withLock { $0.removeAll() }
    }

    /// 视图 `size`（点）在 `scale` 倍屏上的位图尺寸（像素，宽度封顶 `maxWidth`）。
    static func pixelSize(_ size: CGSize, scale: CGFloat) -> (width: Int, height: Int)? {
        guard size.width >= 1, size.height >= 1, scale > 0 else { return nil }
        var width = Int((size.width * scale).rounded())
        var height = Int((size.height * scale).rounded())
        if width > maxWidth {
            height = max(1, Int((Double(height) * Double(maxWidth) / Double(width)).rounded()))
            width = maxWidth
        }
        return (width, height)
    }

    /// 地图上一块地方（视图坐标，点）的平均相对亮度（WCAG），Rust 按出图的同一套颜色取样（不含灯火），
    /// 不必读回位图；地图上的字据此选墨或纸。算不出时当作深色（写纸）。
    static func luminance(instant: Date, size: CGSize, scale: CGFloat, latitudes: ClosedRange<Double>, in rect: CGRect) -> Double {
        guard let (width, height) = pixelSize(size, scale: scale) else { return 0 }
        let k = Double(width) / Double(size.width)
        let value = mt_sky_map_luminance(instant.timeIntervalSince1970, UInt32(width), UInt32(height), latitudes.upperBound, latitudes.lowerBound,
                                         Double(rect.minX) * k, Double(rect.minY) * k, Double(rect.maxX) * k, Double(rect.maxY) * k)
        return value < 0 ? 0 : value
    }

    /// 视图 `size`（点）在 `scale` 倍屏上的一张图；`lights` 是城市灯火的大小倍数（0 不画）。离屏出图（名片、海报）用；
    /// 屏幕上的地图走 `MapSurfaceView`（直接画进 IOSurface）。
    static func render(instant: Date, size: CGSize, scale: CGFloat, latitudes: ClosedRange<Double>, lights: Double, large: Bool = false) -> MapRaster? {
        guard let (width, height) = pixelSize(size, scale: scale) else { return nil }
        let key = Key(instant: instant.timeIntervalSince1970, width: width, height: height,
                      north: latitudes.upperBound, south: latitudes.lowerBound, lights: lights, large: large)
        if let hit = cache.withLock({ entries in entries.first { $0.0 == key }?.1 }) { return hit }
        MapRelief.ensureLoaded()
        let length = width * height * 4
        guard let buffer = PixelPool.take(length) else { return nil }
        #if DEBUG
        let performanceStart = PerformanceRustCalls.begin()
        defer { PerformanceRustCalls.end("ffi.sky_map_raster", started: performanceStart) }
        #endif
        guard mt_sky_map_raster(key.instant, UInt32(width), UInt32(height), key.north, key.south, lights,
                                buffer.assumingMemoryBound(to: UInt8.self), length, Double(width) / Double(size.width), large),
              let provider = CGDataProvider(dataInfo: nil, data: buffer, size: length, releaseData: { _, data, size in
                  PixelPool.give(data, length: size)
              }) else {
            PixelPool.give(buffer, length: length)
            return nil
        }
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let raster = MapRaster(image: image, width: width, height: height, scale: CGFloat(width) / size.width, pixels: UnsafeRawPointer(buffer))
        cache.withLock { entries in
            entries.removeAll { $0.0 == key }
            entries.append((key, raster))
            if entries.count > cacheLimit { entries.removeFirst(entries.count - cacheLimit) }
        }
        return raster
    }

    /// 一块地方（视图坐标，点）的平均相对亮度（WCAG），隔点取样。
    func luminance(in rect: CGRect) -> Double {
        let x0 = max(0, Int((rect.minX * scale).rounded(.down))), x1 = min(width, Int((rect.maxX * scale).rounded(.up)))
        let y0 = max(0, Int((rect.minY * scale).rounded(.down))), y1 = min(height, Int((rect.maxY * scale).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return 0.5 }
        let step = max(1, min(x1 - x0, y1 - y0) / 6)
        var total = 0.0, count = 0.0
        let bytes = pixels.assumingMemoryBound(to: UInt8.self)
        for y in stride(from: y0, to: y1, by: step) {
            for x in stride(from: x0, to: x1, by: step) {
                let o = (y * width + x) * 4
                total += Self.luminance(r: Double(bytes[o]) / 255, g: Double(bytes[o + 1]) / 255, b: Double(bytes[o + 2]) / 255)
                count += 1
            }
        }
        return count > 0 ? total / count : 0.5
    }

    /// sRGB（0…1）的相对亮度（WCAG 2）。
    static func luminance(r: Double, g: Double, b: Double) -> Double {
        let linear = { (c: Double) in c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}

/// 屏幕上的地图底图（省内存一轮）：Rust 直接画进 IOSurface（与窗口服务器共享的像素面），图层直接显示它，
/// 两块轮换（画背面那块时正面那块在显示）。不逐帧分配内存、不经 CGImage，CoreAnimation 也不另存一份拷贝——
/// 此前走 `Image(CGImage)`，内存巡回量出拖地球窗之后 CoreAnimation 与图形区多留几十 MB。视图拆掉时两块一起还。
/// 无障碍转储的截图（`cacheDisplay`）不经图层，走 `draw(_:)`：把正面那块画成位图。
struct MapSurface: NSViewRepresentable {
    let seconds: Double
    let size: CGSize
    let scale: CGFloat
    let latitudes: ClosedRange<Double>
    let lights: Double
    /// 大图（地球窗）：太阳的光晕大一号（晨昏线与光晕都由 Rust 画进像素面）。
    let large: Bool

    func makeNSView(context: Context) -> MapSurfaceView { MapSurfaceView(frame: .zero) }

    func updateNSView(_ view: MapSurfaceView, context: Context) {
        view.render(seconds: seconds, size: size, scale: scale, latitudes: latitudes, lights: lights, large: large)
    }

    static func dismantleNSView(_ view: MapSurfaceView, coordinator: ()) {
        view.releaseSurfaces()
    }
}

final class MapSurfaceView: NSView {
    private struct Key: Equatable {
        let seconds: Double; let width: Int; let height: Int; let north: Double; let south: Double; let lights: Double; let large: Bool
    }
    private var surfaces: [IOSurface] = []
    private var front = -1
    private var last: Key?
    private var redrawTimes: [TimeInterval] = []
    private var releaseSpare: DispatchWorkItem?

    #if DEBUG
    var ownedSurfaceCount: Int { surfaces.count }
    #endif

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
        layer?.isOpaque = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { true }

    /// 最后一次要画的参数：窗口看不见时像素面还掉，再看得见时按它重画（SwiftUI 不一定再调 `updateNSView`）。
    private var wanted: (seconds: Double, size: CGSize, scale: CGFloat, latitudes: ClosedRange<Double>, lights: Double, large: Bool)?
    private var observers: [NSObjectProtocol] = []

    /// 窗口关掉（地球窗关了，SwiftUI 可能把整棵视图留着备用）或整个被遮住 / 收起（菜单栏面板关了）：像素面立刻还掉。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { releaseSurfaces(); return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseSurfaces() }
        })
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                // 截图窗口可以离屏画图；性能量尺按生产窗口的遮挡状态处理。
                if window.occlusionState.contains(.visible) || (ApplicationSession.drawsOccludedMaps && window.isVisible) {
                    if self.surfaces.isEmpty, let w = self.wanted {
                        self.render(seconds: w.seconds, size: w.size, scale: w.scale, latitudes: w.latitudes, lights: w.lights, large: w.large)
                    }
                } else {
                    #if DEBUG
                    // 窗口截图可能在遮挡时取图，隔离副本保留这一帧的底图。
                    if ApplicationSession.drawsOccludedMaps,
                       ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_CAPTURE"] == "1" { return }
                    #endif
                    self.releaseSurfaces()
                }
            }
        })
    }

    override func updateLayer() {
        if surfaces.indices.contains(front) { layer?.contents = surfaces[front] }
    }

    func render(seconds: Double, size: CGSize, scale: CGFloat, latitudes: ClosedRange<Double>, lights: Double, large: Bool) {
        wanted = (seconds, size, scale, latitudes, lights, large)
        // 窗口看不见就不画（面板收起后 SwiftUI 仍可能每分钟调一次更新）；再看得见时按 `wanted` 补画。
        // 无障碍截图不受遮挡限制，性能量尺仍遵守生产行为。
        if !ApplicationSession.drawsOccludedMaps, let window, !window.occlusionState.contains(.visible) { return }
        guard let (width, height) = MapRaster.pixelSize(size, scale: scale) else { return }
        let key = Key(seconds: seconds, width: width, height: height, north: latitudes.upperBound, south: latitudes.lowerBound, lights: lights, large: large)
        guard key != last else { return }
        if last?.width != width || last?.height != height || surfaces.isEmpty {
            releaseSurfaces()
            if let surface = Self.makeSurface(width: width, height: height) { surfaces = [surface] }
        }
        guard !surfaces.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        redrawTimes.append(now)
        if redrawTimes.count > 3 { redrawTimes.removeFirst(redrawTimes.count - 3) }
        let rapidBurst = redrawTimes.count == 3 && now - redrawTimes[0] < 0.25
        if surfaces.count == 1, rapidBurst,
           let spare = Self.makeSurface(width: width, height: height) {
            surfaces.append(spare)
        }
        MapRelief.ensureLoaded()
        let back = surfaces.count == 1 ? 0 : (front == 0 ? 1 : 0)
        let surface = surfaces[back]
        surface.lock(options: [], seed: nil)
        #if DEBUG
        let performanceStart = PerformanceRustCalls.begin()
        defer { PerformanceRustCalls.end("ffi.sky_map_raster_into", started: performanceStart) }
        #endif
        let drawn = mt_sky_map_raster_into(seconds, UInt32(width), UInt32(height), key.north, key.south, lights,
                                           surface.baseAddress.assumingMemoryBound(to: UInt8.self), surface.bytesPerRow, true,
                                           Double(width) / Double(size.width), large)
        surface.unlock(options: [], seed: nil)
        guard drawn else { return }
        front = back
        last = key
        if surfaces.count == 1 { layer?.contents = nil }
        layer?.contents = surface
        // 秒钟的自然更新不延后动画停下后的归还。
        if surfaces.count == 2, rapidBurst || releaseSpare == nil {
            releaseSpare?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.surfaces.indices.contains(self.front) else { return }
                    self.surfaces = [self.surfaces[self.front]]
                    self.front = 0
                    self.redrawTimes = []
                    self.releaseSpare = nil
                }
            }
            releaseSpare = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    func releaseSurfaces() {
        releaseSpare?.cancel()
        releaseSpare = nil
        redrawTimes = []
        layer?.contents = nil
        surfaces = []
        front = -1
        last = nil
    }

    /// BGRA、按 sRGB 解释（Rust 给的是 sRGB 8 位值）。
    private static func makeSurface(width: Int, height: Int) -> IOSurface? {
        let properties: [IOSurfacePropertyKey: any Sendable] = [.width: width, .height: height, .bytesPerElement: 4,
                                                       .pixelFormat: UInt32(0x4247_5241)]   // 'BGRA'
        guard let surface = IOSurface(properties: properties) else { return nil }
        if let colors = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, colors)
        }
        return surface
    }

    override func draw(_ dirtyRect: NSRect) {
        guard surfaces.indices.contains(front), let context = NSGraphicsContext.current?.cgContext else { return }
        let surface = surfaces[front]
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let length = surface.bytesPerRow * surface.height
        guard let data = CFDataCreate(nil, surface.baseAddress.assumingMemoryBound(to: UInt8.self), length),
              let provider = CGDataProvider(data: data),
              let image = CGImage(width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: surface.bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        context.draw(image, in: bounds)
    }
}
