import AppKit
import Foundation
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized, .enabled(if: MetalCameraRawVolume.shared != nil, "Metal volume deformation is available on this Mac"))
struct CameraRawVolumeGPUTests {
    private struct ErrorStats {
        var maxChannel: Int = 0
        var meanChannel: Double = 0
        var mismatchedPixels: Int = 0
        var pixels: Int = 0
    }

    /// Float sqrt and float strengths can land on the other side of a rounding boundary. A one-level
    /// channel difference is that boundary. A larger difference means the sample moved.
    private let maximumChannelError = 1

    @Test func gpuMatchesCPUForEveryModeStrengthAndShape() throws {
        let metal = try #require(MetalCameraRawVolume.shared)
        let shapes = [(17, 13), (48, 32), (32, 48), (1, 1), (2, 3), (64, 64)]
        let sliders = [0.0, 20.0, 100.0, 200.0]
        let modes: [(CameraRawVolumeMode, Int32)] = [(.radial, 0), (.horizontal, 1), (.vertical, 2), (.horizontalAndVertical, 3)]
        for (width, height) in shapes {
            for (mode, kernel) in modes {
                for slider in sliders {
                    let stats = try compare(metal, width: width, height: height, stride: width * 4, mode: kernel, slider: slider) { bytes, stride in
                        paint(bytes, width: width, height: height, stride: stride)
                    }
                    #expect(stats.maxChannel <= maximumChannelError,
                            "\(mode) \(slider) \(width)x\(height) max \(stats.maxChannel) mean \(stats.meanChannel) mismatches \(stats.mismatchedPixels)/\(stats.pixels)")
                }
            }
        }
    }

    @Test func gpuMatchesCPUOnTransparentEdgesGradientsAndALargePicture() throws {
        let metal = try #require(MetalCameraRawVolume.shared)
        let edge = try compare(metal, width: 80, height: 60, stride: 80 * 4, mode: 1, slider: 200) { bytes, stride in
            for y in 0..<60 {
                for x in 0..<80 {
                    let at = y * stride + x * 4
                    let inside = x < 6
                    bytes[at] = inside ? 220 : 0
                    bytes[at + 1] = inside ? 20 : 0
                    bytes[at + 2] = inside ? 20 : 0
                    bytes[at + 3] = inside ? 255 : 0
                }
            }
        }
        #expect(edge.maxChannel <= maximumChannelError, "edge max \(edge.maxChannel)")

        let gradient = try compare(metal, width: 128, height: 96, stride: 128 * 4 + 32, mode: 0, slider: 160) { bytes, stride in
            for y in 0..<96 {
                for x in 0..<128 {
                    let at = y * stride + x * 4
                    let alpha = UInt8(40 + (x * 160) / 127)
                    bytes[at] = UInt8(x * Int(alpha) / 127)
                    bytes[at + 1] = UInt8(y * Int(alpha) / 95)
                    bytes[at + 2] = alpha / 2
                    bytes[at + 3] = alpha
                }
            }
        }
        #expect(gradient.maxChannel <= maximumChannelError, "gradient max \(gradient.maxChannel) mean \(gradient.meanChannel)")

        let wide = try compare(metal, width: 1920, height: 1080, stride: 1920 * 4, mode: 3, slider: 80) { bytes, stride in
            paint(bytes, width: 1920, height: 1080, stride: stride)
        }
        #expect(wide.maxChannel <= maximumChannelError,
                "1920x1080 max \(wide.maxChannel) mean \(wide.meanChannel) mismatches \(wide.mismatchedPixels)/\(wide.pixels)")
    }

    @Test func paddedBytesAndARejectedBufferStayOnTheCPU() throws {
        let metal = try #require(MetalCameraRawVolume.shared)
        let width = 15, height = 9, stride = width * 4 + 20
        let stats = try compare(metal, width: width, height: height, stride: stride, mode: 2, slider: 180) { bytes, stride in
            paint(bytes, width: width, height: height, stride: stride)
            for y in 0..<height {
                for x in width * 4..<stride { bytes[y * stride + x] = 173 }
            }
        }
        #expect(stats.maxChannel <= maximumChannelError)

        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
        defer { source.deallocate(); destination.deallocate() }
        destination.initialize(repeating: 9, count: 16)
        #expect(metal.apply(source: source, destination: destination, width: 4, height: 2, stride: 8,
                            strengthH: 0.2, strengthV: 0, strengthR: 0, mode: 1) == false)
        #expect(destination[0] == 9)
    }

    @Test func applicationPathMatchesTheCPUReference() throws {
        let picture = try picture(width: 96, height: 64)
        for mode in CameraRawVolumeMode.allCases {
            var settings = CameraRawGeometrySettings()
            settings.volumeMode = mode
            switch mode {
            case .radial: settings.volumeRadial = 140
            case .horizontal: settings.volumeHorizontal = 180
            case .vertical: settings.volumeVertical = 180
            case .horizontalAndVertical:
                settings.volumeHorizontal = 90
                settings.volumeVertical = 70
            }
            let gpu = try pixels(settings.apply(picture))
            let cpu = try cpuVolume(picture, settings)
            let stats = difference(gpu, cpu, width: picture.width)
            #expect(stats.maxChannel <= maximumChannelError, "\(mode) apply max \(stats.maxChannel)")
        }
        var identity = CameraRawGeometrySettings()
        identity.volumeMode = .radial
        identity.volumeRadial = 0
        let original = try pixels(picture)
        let unchanged = try pixels(identity.apply(picture))
        #expect(unchanged == original)
    }

    /// Warm runs after one discarded pass. Kernel time is the wait, GPU time is the device interval.
    @Test func warmRunIsFasterThanTheCPUBaseline() throws {
        let metal = try #require(MetalCameraRawVolume.shared)
        let sizes = [(1024, 1024), (4000, 3000), (6000, 4000)]
        let before = residentMegabytes()
        var lines: [String] = []
        for (width, height) in sizes {
            let stride = width * 4
            let bytes = stride * height
            let source = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
            let cpu = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
            let gpu = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
            defer { source.deallocate(); cpu.deallocate(); gpu.deallocate() }
            paint(source, width: width, height: height, stride: stride)
            let strength = CameraRawGeometrySettings.volumeStrength(80)
            volume_deform(source, cpu, width, height, stride, 0, 0, strength, 0)
            var ignored = MetalCameraRawVolume.Sample()
            _ = metal.apply(source: source, destination: gpu, width: width, height: height, stride: stride,
                            strengthH: 0, strengthV: 0, strengthR: strength, mode: 0, sample: &ignored)
            var cpuTimes: [Double] = []
            var gpuTimes: [Double] = []
            var samples: [MetalCameraRawVolume.Sample] = []
            for _ in 0..<3 {
                let cpuStarted = CFAbsoluteTimeGetCurrent()
                volume_deform(source, cpu, width, height, stride, 0, 0, strength, 0)
                cpuTimes.append((CFAbsoluteTimeGetCurrent() - cpuStarted) * 1000)
                var sample = MetalCameraRawVolume.Sample()
                let gpuStarted = CFAbsoluteTimeGetCurrent()
                let ok = metal.apply(source: source, destination: gpu, width: width, height: height, stride: stride,
                                     strengthH: 0, strengthV: 0, strengthR: strength, mode: 0, sample: &sample)
                gpuTimes.append((CFAbsoluteTimeGetCurrent() - gpuStarted) * 1000)
                #expect(ok)
                samples.append(sample)
            }
            let stats = difference(gpu, cpu, width: width, height: height, stride: stride)
            #expect(stats.maxChannel <= maximumChannelError, "\(width)x\(height) max \(stats.maxChannel)")
            let cpuMedian = median(cpuTimes)
            let gpuMedian = median(gpuTimes)
            let upload = median(samples.map(\.uploadMilliseconds))
            let kernel = median(samples.map(\.kernelMilliseconds))
            let gpuDevice = median(samples.map(\.gpuMilliseconds))
            let readback = median(samples.map(\.readbackMilliseconds))
            lines.append(String(format: "volume %dx%d cpu %.1f ms gpu-end %.1f ms upload %.1f kernel-wait %.1f gpu %.1f readback %.1f max-error %d",
                                width, height, cpuMedian, gpuMedian, upload, kernel, gpuDevice, readback, stats.maxChannel))
            #expect(gpuMedian < cpuMedian, "\(width)x\(height) GPU \(gpuMedian) ms, CPU \(cpuMedian) ms")
        }
        if let before, let after = residentMegabytes() {
            lines.append(String(format: "volume resident %.0f MB before, %.0f MB after", before, after))
        }
        if let footprint = footprintMegabytes() {
            lines.append(String(format: "volume footprint %.0f MB, peak %.0f MB", footprint.current, footprint.peak))
        }
        for line in lines { print(line) }
        #if DEBUG
        let noteName = "volume-gpu-timings.txt"
        #else
        let noteName = "volume-gpu-timings-release.txt"
        #endif
        let note = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(noteName)
        try? lines.joined(separator: "\n").write(to: note, atomically: true, encoding: .utf8)
        #expect(lines.count >= 3)
    }

    /// The editor's order: lens distortion, volume, perspective, constrain crop. The GPU result is
    /// `CameraRawSettings.apply`. The CPU result uses `volume_deform`, then the same perspective and crop.
    @Test func geometryPipelineMatchesTheCPUReference() throws {
        let structural = try picture(width: 360, height: 240)
        try expectSameGeometry(structural, "volume") {
            $0.geometry.volumeMode = .horizontalAndVertical
            $0.geometry.volumeHorizontal = 120
            $0.geometry.volumeVertical = 80
        }
        try expectSameGeometry(structural, "volume and perspective") {
            $0.geometry.volumeMode = .radial
            $0.geometry.volumeRadial = 160
            $0.geometry.vertical = 28
            $0.geometry.horizontal = -18
        }
        try expectSameGeometry(structural, "distortion and volume") {
            $0.optics.distortion = 40
            $0.geometry.volumeMode = .vertical
            $0.geometry.volumeVertical = 150
        }
        try expectSameGeometry(structural, "distortion, volume, perspective, and crop") {
            $0.optics.distortion = 30
            $0.geometry.volumeMode = .radial
            $0.geometry.volumeRadial = 100
            $0.geometry.vertical = 22
            $0.geometry.horizontal = 12
            $0.geometry.constrainCrop = true
        }
        var filterSettings = FilterSettings()
        filterSettings.cameraRaw.geometry.volumeMode = .radial
        filterSettings.cameraRaw.geometry.volumeRadial = 90
        let job = FilterJob(kind: .cameraRaw, image: structural, settings: filterSettings, scale: 1,
                            selection: nil, mapping: .identity)
        let throughTheFilter = try PixelFilter.run(job)
        let direct = try filterSettings.cameraRaw.apply(structural)
        let filterStats = difference(try pixels(throughTheFilter), try pixels(direct), width: structural.width)
        #expect(filterStats.maxChannel == 0, "preview and commit share apply; max \(filterStats.maxChannel)")
    }

    /// A refused GPU call returns before it copies, and a later valid call still completes.
    @Test func aRefusedGPUCallLeavesTheDestinationAndTheQueue() throws {
        let metal = try #require(MetalCameraRawVolume.shared)
        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
        defer { source.deallocate(); destination.deallocate() }
        source.initialize(repeating: 1, count: 16)
        destination.initialize(repeating: 9, count: 16)
        #expect(metal.apply(source: source, destination: destination, width: 0, height: 2, stride: 8,
                            strengthH: 0.2, strengthV: 0, strengthR: 0, mode: 1) == false)
        #expect(metal.apply(source: source, destination: destination, width: 2, height: -1, stride: 8,
                            strengthH: 0.2, strengthV: 0, strengthR: 0, mode: 1) == false)
        let limit = try #require(MTLCreateSystemDefaultDevice()).maxBufferLength
        let tooTall = limit / 4 + 1
        #expect(metal.apply(source: source, destination: destination, width: 1, height: tooTall, stride: 4,
                            strengthH: 0, strengthV: 0, strengthR: 0.2, mode: 0) == false)
        #expect((0..<16).allSatisfy { destination[$0] == 9 })
        let stats = try compare(metal, width: 24, height: 16, stride: 24 * 4, mode: 0, slider: 80) { bytes, stride in
            paint(bytes, width: 24, height: 16, stride: stride)
        }
        #expect(stats.maxChannel <= maximumChannelError)
    }

    /// Window-wall is a full-resolution photograph with structure at the edges. The rendered file is
    /// decoded and compared, then removed. Auto Full on the original is unchanged.
    @Test(.enabled(if: GeometryValidationFixtures.hasLocalPhotographs, "window-wall.jpg is a local fixture"))
    func fullResolutionPhotographMatchesTheCPUReference() throws {
        let root = try #require(GeometryValidationFixtures.rootContaining("originals/window-wall.jpg"))
        let jpeg = root.appendingPathComponent("originals/window-wall.jpg")
        let source = try #require(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let full = CameraRawUprightDetection.observe(in: image, mode: .autoFull)
        let vertical = CameraRawUprightDetection.observe(in: image, mode: .autoVertical)
        #expect(full.fallback == .vertical)
        #expect(full.note.contains("kept verticals"))
        #expect(vertical.fallback != .identity)
        var settings = CameraRawSettings()
        settings.optics.distortion = 20
        settings.geometry.volumeMode = .radial
        settings.geometry.volumeRadial = 80
        settings.geometry.vertical = 16
        settings.geometry.constrainCrop = true
        let gpu = try settings.apply(image)
        let cpu = try cpuPipeline(image, settings)
        #expect(gpu.width == image.width && gpu.height == image.height)
        #expect(cpu.width == gpu.width && cpu.height == gpu.height)
        let stats = difference(try pixels(gpu), try pixels(cpu), width: gpu.width)
        #expect(stats.maxChannel <= maximumChannelError,
                "window-wall max \(stats.maxChannel) mean \(String(format: "%.4f", stats.meanChannel)) mismatches \(stats.mismatchedPixels)/\(stats.pixels)")
        let exported = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("volume-pipeline-window-wall.tiff")
        defer { try? FileManager.default.removeItem(at: exported) }
        let destination = CGImageDestinationCreateWithURL(exported as CFURL, "public.tiff" as CFString, 1, nil)
        let created = try #require(destination)
        CGImageDestinationAddImage(created, gpu, nil)
        #expect(CGImageDestinationFinalize(created))
        #expect(FileManager.default.fileExists(atPath: exported.path))
        let opened = try #require(CGImageSourceCreateWithURL(exported as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(opened, 0, nil))
        #expect(decoded.width == gpu.width && decoded.height == gpu.height)
        let decodedStats = difference(try pixels(decoded), try pixels(gpu), width: gpu.width)
        #expect(decodedStats.maxChannel == 0)
    }

    private func compare(_ metal: MetalCameraRawVolume, width: Int, height: Int, stride: Int, mode: Int32, slider: Double,
                         fill: (UnsafeMutablePointer<UInt8>, Int) -> Void) throws -> ErrorStats {
        let bytes = stride * height
        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
        let cpu = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
        let gpu = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
        defer { source.deallocate(); cpu.deallocate(); gpu.deallocate() }
        source.initialize(repeating: 0, count: bytes)
        cpu.initialize(repeating: 173, count: bytes)
        gpu.initialize(repeating: 173, count: bytes)
        fill(source, stride)
        let strength = CameraRawGeometrySettings.volumeStrength(slider)
        let horizontal = mode == 1 || mode == 3 ? strength : 0
        let vertical = mode == 2 || mode == 3 ? strength : 0
        let radial = mode == 0 ? strength : 0
        volume_deform(source, cpu, width, height, stride, horizontal, vertical, radial, mode)
        #expect(metal.apply(source: source, destination: gpu, width: width, height: height, stride: stride,
                            strengthH: horizontal, strengthV: vertical, strengthR: radial, mode: mode))
        if stride != width * 4 {
            for y in 0..<height {
                for x in width * 4..<stride {
                    #expect(gpu[y * stride + x] == 173)
                    #expect(cpu[y * stride + x] == 173)
                }
            }
        }
        return difference(gpu, cpu, width: width, height: height, stride: stride)
    }

    private func paint(_ bytes: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int) {
        for y in 0..<height {
            for x in 0..<width {
                let at = y * stride + x * 4
                let checker = ((x / 8) + (y / 8)) % 2 == 0
                let alpha: UInt8 = x < 2 || y < 2 ? 0 : 255
                let red = checker ? Int(alpha) : Int(alpha) / 5
                let green = ((x * 255) / max(width, 1)) * Int(alpha) / 255
                let blue = ((y * 255) / max(height, 1)) * Int(alpha) / 255
                bytes[at] = UInt8(red)
                bytes[at + 1] = UInt8(green)
                bytes[at + 2] = UInt8(blue)
                bytes[at + 3] = alpha
            }
        }
    }

    private func difference(_ gpu: UnsafePointer<UInt8>, _ cpu: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) -> ErrorStats {
        var stats = ErrorStats()
        var total = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let at = y * stride + x * 4
                var pixelError = 0
                for channel in 0..<4 {
                    let delta = abs(Int(gpu[at + channel]) - Int(cpu[at + channel]))
                    pixelError = max(pixelError, delta)
                    stats.maxChannel = max(stats.maxChannel, delta)
                    total += Double(delta)
                }
                if pixelError != 0 { stats.mismatchedPixels += 1 }
                stats.pixels += 1
            }
        }
        stats.meanChannel = total / Double(max(stats.pixels * 4, 1))
        return stats
    }

    private func difference(_ gpu: [[UInt8]], _ cpu: [[UInt8]], width: Int) -> ErrorStats {
        var stats = ErrorStats()
        var total = 0.0
        for index in gpu.indices {
            var pixelError = 0
            for channel in 0..<4 {
                let delta = abs(Int(gpu[index][channel]) - Int(cpu[index][channel]))
                pixelError = max(pixelError, delta)
                stats.maxChannel = max(stats.maxChannel, delta)
                total += Double(delta)
            }
            if pixelError != 0 { stats.mismatchedPixels += 1 }
        }
        stats.pixels = gpu.count
        stats.meanChannel = total / Double(max(gpu.count * 4, 1))
        _ = width
        return stats
    }

    private func picture(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        for index in 0..<8 {
            let x = CGFloat(index) * CGFloat(width) / 8
            context.fill(CGRect(x: x, y: 0, width: 3, height: CGFloat(height)))
            let y = CGFloat(index) * CGFloat(height) / 8
            context.fill(CGRect(x: 0, y: y, width: CGFloat(width), height: 3))
        }
        return try #require(context.makeImage())
    }

    private func pixels(_ image: CGImage) throws -> [[UInt8]] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var samples: [[UInt8]] = []
        samples.reserveCapacity(image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let at = y * context.bytesPerRow + x * 4
                samples.append([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
            }
        }
        return samples
    }

    private func expectSameGeometry(_ image: CGImage, _ label: String, configure: (inout CameraRawSettings) -> Void) throws {
        var settings = CameraRawSettings()
        configure(&settings)
        let gpu = try settings.apply(image)
        let cpu = try cpuPipeline(image, settings)
        #expect(gpu.width == cpu.width && gpu.height == cpu.height, Comment(rawValue: label))
        let stats = difference(try pixels(gpu), try pixels(cpu), width: gpu.width)
        #expect(stats.maxChannel <= maximumChannelError,
                "\(label) max \(stats.maxChannel) mean \(String(format: "%.4f", stats.meanChannel)) mismatches \(stats.mismatchedPixels)/\(stats.pixels)")
    }

    /// Distortion, then the CPU volume kernel, then the shared perspective and crop with volume off.
    private func cpuPipeline(_ image: CGImage, _ settings: CameraRawSettings) throws -> CGImage {
        let normalized = settings.normalized
        guard normalized.adjustsGeometry else { return image }
        var source = image
        let distortion = normalized.optics.distortionK(profileStrength: PixelFilter.lensStrength)
        if distortion != 0 {
            source = try CameraRawSettings.applyLensDistort(source, k: distortion)
        }
        source = try cpuVolumeImage(source, normalized.geometry)
        var tail = normalized.geometry
        tail.volumeHorizontal = 0
        tail.volumeVertical = 0
        tail.volumeRadial = 0
        return try tail.apply(source)
    }

    private func cpuVolumeImage(_ image: CGImage, _ settings: CameraRawGeometrySettings) throws -> CGImage {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let destination = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        let from = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let into = try #require(destination.data).assumingMemoryBound(to: UInt8.self)
        volume_deform(from, into, image.width, image.height, context.bytesPerRow,
                      CameraRawGeometrySettings.volumeStrength(settings.volumeHorizontal),
                      CameraRawGeometrySettings.volumeStrength(settings.volumeVertical),
                      CameraRawGeometrySettings.volumeStrength(settings.volumeRadial),
                      settings.volumeMode.kernelValue)
        return try #require(destination.makeImage())
    }

    private func cpuVolume(_ image: CGImage, _ settings: CameraRawGeometrySettings) throws -> [[UInt8]] {
        try pixels(cpuVolumeImage(image, settings))
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func footprintMegabytes() -> (current: Double, peak: Double)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (Double(info.phys_footprint) / (1024 * 1024), Double(info.ledger_phys_footprint_peak) / (1024 * 1024))
    }

    private func residentMegabytes() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / (1024 * 1024)
    }
}
