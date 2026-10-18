#if os(macOS)
import AppKit
import Metal
import QuartzCore
import IOSurface
import CoreVideo
import SwiftUI

/// A moving background or visualizer on the Mac, drawn with Metal straight to a layer, once
/// for each frame the display shows, from the display link of the screen it's on.
///
/// SwiftUI only says what to draw and whether it moves. A frame that SwiftUI drew would lay
/// out the whole window again, sixty or a hundred and twenty times a second; drawn here, the
/// window is left alone. `draw` is called with the frame's time and returns what to draw;
/// it's replaced each time SwiftUI updates the view, so it always draws from the latest.
///
/// It draws while `isMoving`, and also once whenever it's updated or resized, so a still
/// frame is always the latest. Off screen it doesn't draw at all.
struct BackdropCanvas: NSViewRepresentable {
    let isMoving: Bool
    /// Frames a second, or nil for every frame the display shows.
    var frameRate: Double?
    /// Drawn at this fraction of its size and stretched to fill it: a soft field looks the
    /// same, for a small part of the work.
    var factor: CGFloat = 1
    /// Whether what's behind shows through.
    var isOpaque = true
    let draw: @MainActor (BackdropFrame) -> BackdropDrawing?

    @Environment(\.isOnScreen) private var isOnScreen

    func makeNSView(context: Context) -> BackdropCanvasView {
        BackdropCanvasView()
    }

    func updateNSView(_ view: BackdropCanvasView, context: Context) {
        view.configure(factor: factor, isOpaque: isOpaque, frameRate: frameRate, draw: draw)
        view.isMoving = isMoving && isOnScreen
        view.isShown = isOnScreen
        view.redraw()
    }

    static func dismantleNSView(_ view: BackdropCanvasView, coordinator: ()) {
        view.stop()
    }
}

/// When a frame is drawn: the moment it will be seen, as a reference date's seconds, and the
/// view's size in points.
struct BackdropFrame {
    let time: Double
    let size: CGSize
}

/// What a frame draws: a full-view fragment function, or a mesh, its inputs, and the picture
/// it samples.
struct BackdropDrawing {
    enum Shape {
        /// The fragment function over the whole view.
        case fill
        /// A mesh gradient's triangles, cut from `columns` by `rows` points, `m` as `meshVertex`
        /// takes it.
        case mesh(columns: Int, rows: Int, steps: Int, m: [SIMD4<Float>])
    }

    var function: String
    var shape: Shape = .fill
    /// The fragment function's inputs. The first, the size and pixels to a point, is filled in.
    var inputs: [SIMD4<Float>] = []
    /// A second list of numbers, for the bars and the waveform.
    var values: [Float] = []
    var picture: CGImage?
}

/// A mesh gradient's points and colours as `meshVertex` takes them.
enum MeshInputs {
    /// `points` in parts of the size, row by row; `colours` not premultiplied; `scale` about
    /// the middle, as `scaleEffect` does.
    static func make(columns: Int, rows: Int, points: [SIMD2<Float>], colours: [SIMD4<Float>], scale: Float = 1) -> [SIMD4<Float>] {
        var m = [SIMD4<Float>](repeating: .zero, count: 34)
        m[1].w = scale
        for (index, point) in points.prefix(16).enumerated() { m[2 + index] = SIMD4(point.x, point.y, 0, 0) }
        for (index, colour) in colours.prefix(16).enumerated() { m[18 + index] = colour }
        return m
    }
}

final class BackdropCanvasView: NSView {
    var isMoving = false {
        didSet { if isMoving != oldValue { updateLink() } }
    }
    var isShown = true

    private var factor: CGFloat = 1
    private var frameRate: Double?
    private var draw: (@MainActor (BackdropFrame) -> BackdropDrawing?)?
    private var link: CADisplayLink?
    private var isRedrawPending = false
    private let gpu = BackdropGPU.shared
    /// Three pictures to draw into in turn: one on screen, one being drawn, one to spare.
    private var surfaces: [BackdropSurface] = []
    private var pixels = CGSize.zero
    private var shown: Int?
    /// Drawn, and waiting for the next frame to be shown.
    private var ready: Int?
    /// Being drawn: the GPU's work for each, and which frame it is.
    private var drawing: [Int: (commands: MTLCommandBuffer, frame: Int)] = [:]
    private var frames = 0
    private var readyFrame = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.magnificationFilter = .linear
        layer?.contentsGravity = .resize
        layer?.actions = ["contents": NSNull()]
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {}

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(factor: CGFloat, isOpaque: Bool, frameRate: Double?, draw: @escaping @MainActor (BackdropFrame) -> BackdropDrawing?) {
        self.draw = draw
        layer?.isOpaque = isOpaque
        if factor != self.factor {
            self.factor = factor
            resize()
        }
        if frameRate != self.frameRate {
            self.frameRate = frameRate
            applyFrameRate()
        }
    }

    /// Draws the latest once, soon, if it isn't drawing every frame anyway.
    func redraw() {
        guard !isMoving, !isRedrawPending else { return }
        isRedrawPending = true
        RunLoop.main.perform { [weak self] in
            guard let self else { return }
            isRedrawPending = false
            if !isMoving { render(at: Date.now.timeIntervalSinceReferenceDate) }
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    // MARK: - The display link

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        resize()
        updateLink()
        redraw()
    }

    private func updateLink() {
        guard isMoving, window != nil else {
            link?.isPaused = true
            return
        }
        if link == nil {
            // Its screen's own link, so the frames keep its refresh rate, and follow the
            // window to another screen.
            let made = displayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
            made.add(to: .main, forMode: .common)
            link = made
            applyFrameRate()
        }
        link?.isPaused = false
    }

    /// Posted on whichever thread changed it.
    @objc nonisolated private func powerChanged() {
        Task { @MainActor [weak self] in self?.applyFrameRate() }
    }

    private func applyFrameRate() {
        guard let link else { return }
        // Low Power Mode keeps the motion, at fewer frames.
        let frameRate = ProcessInfo.processInfo.isLowPowerModeEnabled ? min(frameRate ?? 20, 20) : frameRate
        if let frameRate {
            let rate = Float(frameRate)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        } else {
            link.preferredFrameRateRange = .default
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        // What was drawn last time goes up with this frame, in the commit the window makes
        // anyway; what's drawn now goes up with the next, so it's drawn for the moment then.
        showReady()
        let ahead = link.targetTimestamp - CACurrentMediaTime() + (link.targetTimestamp - link.timestamp)
        render(at: Date.now.timeIntervalSinceReferenceDate + ahead)
    }

    // MARK: - Drawing

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resize()
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resize()
        redraw()
    }

    /// Pixels to a point as drawn.
    private var scale: CGFloat {
        (window?.backingScaleFactor ?? 2) / factor
    }

    private func resize() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        // Drawn whole pixels across, stretched to the view: the last pixel may reach a little past.
        let pixels = CGSize(width: (size.width * scale).rounded(.up), height: (size.height * scale).rounded(.up))
        layer?.contentsRect = CGRect(x: 0, y: 0, width: min(1, size.width * scale / pixels.width), height: min(1, size.height * scale / pixels.height))
        guard pixels != self.pixels else { return }
        self.pixels = pixels
        // New pictures at the new size; the one on screen stays until the first is drawn.
        surfaces = []
        drawing = [:]
        shown = nil
        ready = nil
    }

    /// A picture that isn't on screen or being drawn, or nil if none is free: then this frame
    /// is skipped rather than waited for.
    private func freeSurface() -> Int? {
        if surfaces.isEmpty {
            surfaces = (0..<3).compactMap { _ in BackdropSurface(pixels: pixels, device: gpu.device) }
        }
        return surfaces.indices.first { $0 != shown && $0 != ready && drawing[$0] == nil }
    }

    private func render(at time: Double) {
        let size = bounds.size
        guard isShown, window != nil, size.width >= 1, size.height >= 1, let draw,
              let index = freeSurface() else { return }
        guard let drawing = draw(BackdropFrame(time: time, size: size)) else {
            // Nothing to draw, as for the visualizer turned off: nothing shown.
            layer?.contents = nil
            shown = nil
            // And nothing drawn before it goes up after it.
            ready = nil
            readyFrame = frames
            return
        }
        guard let pipeline = gpu.pipeline(drawing),
              let commands = gpu.frameCommands() else { return }
        let surface = surfaces[index]
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = surface.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        let first = SIMD4<Float>(Float(size.width), Float(size.height), Float(scale), 1)
        switch drawing.shape {
        case .fill:
            var inputs = [first] + drawing.inputs
            encoder.setFragmentBytes(&inputs, length: inputs.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
            if !drawing.values.isEmpty {
                var values = drawing.values
                encoder.setFragmentBytes(&values, length: values.count * MemoryLayout<Float>.stride, index: 1)
            }
            if let picture = drawing.picture, let texture = gpu.texture(for: picture) {
                encoder.setFragmentTexture(texture, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        case .mesh(let columns, let rows, let steps, var m):
            m[0] = SIMD4(Float(columns), Float(rows), Float(steps), 0)
            m[1] = SIMD4(first.x, first.y, first.z, m[1].w)
            let length = m.count * MemoryLayout<SIMD4<Float>>.stride
            encoder.setVertexBytes(&m, length: length, index: 0)
            encoder.setFragmentBytes(&m, length: length, index: 0)
            var inputs = drawing.inputs.isEmpty ? [SIMD4<Float>()] : drawing.inputs
            encoder.setFragmentBytes(&inputs, length: inputs.count * MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: (columns - 1) * (rows - 1) * steps * steps * 6)
        }
        encoder.endEncoding()
        frames += 1
        self.drawing[index] = (commands, frames)
        // The main thread never waits for the GPU. Moving, the next frame looks for what's
        // done; still, the GPU says when it's done, which costs a thread's wake each time.
        if !isMoving {
            commands.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finished(surface, at: index) }
                }
            }
        }
    }

    private func finished(_ surface: BackdropSurface, at index: Int) {
        // Drawn for an old size: let it go.
        guard index < surfaces.count, surfaces[index] === surface, drawing[index] != nil else { return }
        if !isMoving { showReady() }
    }

    private func showReady() {
        // The newest that's done; any older one done too is let go.
        for (index, entry) in drawing where entry.commands.status == .completed {
            drawing[index] = nil
            if entry.frame > readyFrame {
                ready = index
                readyFrame = entry.frame
            }
        }
        guard let ready else { return }
        self.ready = nil
        shown = ready
        layer?.contents = surfaces[ready].surface
    }
}

/// A picture the GPU draws into and the layer shows.
private final class BackdropSurface {
    let surface: IOSurfaceRef
    let texture: MTLTexture

    init?(pixels: CGSize, device: MTLDevice) {
        let width = Int(pixels.width), height = Int(pixels.height)
        guard width > 0, height > 0, let surface = IOSurfaceCreate([
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
        ] as CFDictionary) else { return nil }
        // As SwiftUI's shaders work: in sRGB, not converted. By name: Core Animation reads
        // this each time the picture changes, and a name is the quickest for it to read.
        IOSurfaceSetValue(surface, kIOSurfaceColorSpace, CGColorSpace.sRGB)
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        description.usage = .renderTarget
        description.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: description, iosurface: surface, plane: 0) else { return nil }
        self.surface = surface
        self.texture = texture
    }
}

/// The display link's target, so the link doesn't keep the view alive.
private final class DisplayLinkTarget: NSObject {
    weak var view: BackdropCanvasView?

    init(_ view: BackdropCanvasView) {
        self.view = view
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.tick(link)
    }
}

/// The Mac's GPU for the backgrounds: the shaders, made once, and the covers as textures.
@MainActor
final class BackdropGPU {
    static let shared = BackdropGPU()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let library: MTLLibrary?
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var frame: MTLCommandBuffer?
    /// The last few covers, as textures: a cover comes round again as the songs change.
    private let textures = NSCache<CGImage, MTLTexture>()

    private init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        library = device.makeDefaultLibrary()
        textures.countLimit = 16
    }

    /// This frame's GPU work, shared by every view drawing it: one submission a frame,
    /// however many are on screen. Sent once they've all drawn.
    func frameCommands() -> MTLCommandBuffer? {
        if let frame { return frame }
        guard let made = queue.makeCommandBuffer() else { return nil }
        frame = made
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                self?.frame?.commit()
                self?.frame = nil
            }
        }
        return made
    }

    func pipeline(_ drawing: BackdropDrawing) -> MTLRenderPipelineState? {
        let isMesh = if case .mesh = drawing.shape { true } else { false }
        if let made = pipelines[drawing.function] { return made }
        guard let library,
              let vertex = library.makeFunction(name: isMesh ? "meshVertex" : "backdropVertex"),
              let fragment = library.makeFunction(name: drawing.function) else { return nil }
        let description = MTLRenderPipelineDescriptor()
        description.vertexFunction = vertex
        description.fragmentFunction = fragment
        let attachment = description.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        // Premultiplied over what's drawn: a mesh's triangles, or light added with no alpha.
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let made = try? device.makeRenderPipelineState(descriptor: description) else { return nil }
        pipelines[drawing.function] = made
        return made
    }

    /// The picture as it is, its colours not converted, as SwiftUI hands one to a shader.
    func texture(for image: CGImage) -> MTLTexture? {
        if let made = textures.object(forKey: image) { return made }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        description.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: description) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        textures.setObject(texture, forKey: image)
        return texture
    }
}

extension Color {
    /// This colour as a shader takes it: sRGB, not premultiplied.
    var shaderComponents: SIMD4<Float> {
        let resolved = resolve(in: EnvironmentValues())
        guard let colour = resolved.cgColor.converted(to: CGColorSpace(name: CGColorSpace.extendedSRGB)!, intent: .defaultIntent, options: nil),
              let parts = colour.components, parts.count >= 4 else {
            return SIMD4(resolved.red, resolved.green, resolved.blue, resolved.opacity)
        }
        return SIMD4(Float(parts[0]), Float(parts[1]), Float(parts[2]), Float(parts[3]))
    }
}
#endif
