import Foundation
import CoreGraphics
import Vision
import CoreText

enum PhoneVisualRaster {
    static func warmUp() throws {
        guard let context = CGContext(data: nil, width: 722, height: 256, bitsPerComponent: 8, bytesPerRow: 722 * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PhoneVisualError.layout
        }
        context.setFillColor(CGColor(gray: 0.15, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 722, height: 256))
        let text = NSAttributedString(string: "SYNTHETIC OCR WARMUP", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 60, y: 180); CTLineDraw(CTLineCreateWithAttributedString(text), context)
        guard let image = context.makeImage() else { throw PhoneVisualError.layout }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request()])
    }
    private static func request() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]; return request
    }
    static func pixels(_ image: CGImage) throws -> Data {
        guard image.width == 722, image.height == 256 else { throw PhoneVisualError.layout }
        var data = Data(count: image.width * image.height * 4)
        let ok = data.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        guard ok else { throw PhoneVisualError.layout }; return data
    }
    /// Locate the sole neutral opaque Phone pill before passing any pixels to OCR.
    /// Transparent/black host background is excluded; a second notification component is rejected.
    static func pill(_ pixels: Data, width: Int = 722, height: Int = 256) throws -> CGRect {
        let bytes = [UInt8](pixels)
        guard width == 722, height == 256, bytes.count == width * height * 4 else { throw PhoneVisualError.layout }
        func neutral(_ offset: Int) -> Bool {
            let i = offset * 4, r = bytes[i], g = bytes[i + 1], b = bytes[i + 2]
            return bytes[i + 3] > 204 && min(r, g, b) > 18 && max(r, g, b) < 85
                && Int(max(r, g, b)) - Int(min(r, g, b)) < 20
        }
        var visited = [Bool](repeating: false, count: width * height), components: [CGRect] = []
        for offset in 0..<(width * height) where !visited[offset] && neutral(offset) {
            var queue = [offset], cursor = 0, left = width, right = 0, top = height, bottom = 0
            visited[offset] = true
            while cursor < queue.count {
                let current = queue[cursor]; cursor += 1
                let x = current % width, y = current / width
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                for next in [x > 0 ? current - 1 : -1, x + 1 < width ? current + 1 : -1,
                             y > 0 ? current - width : -1, y + 1 < height ? current + width : -1]
                    where next >= 0 && !visited[next] && neutral(next) {
                    visited[next] = true; queue.append(next)
                }
            }
            if queue.count > 2_000 {
                components.append(CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1))
            }
        }
        guard components.count == 1, let component = components.first,
              (300...361).contains(component.width / 2), (60...115).contains(component.height / 2),
              (0...30).contains(component.minX / 2), (0...8).contains(component.minY / 2)
        else { throw PhoneVisualError.panel }
        return component
    }

    static func frame(_ image: CGImage, capturedAt: Double) throws -> PhoneVisualFrame {
        let data = try pixels(image), component = try pill(data)
        guard let cropped = image.cropping(to: component) else { throw PhoneVisualError.layout }
        let request = request()
        let start = ProcessInfo.processInfo.systemUptime
        try VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])
        guard ProcessInfo.processInfo.systemUptime - start < 3 else { throw PhoneVisualError.deadline }
        let results = request.results ?? []
        guard results.count <= 32 else { throw PhoneVisualError.panel }
        let text = results.compactMap { observation -> PhoneVisualText? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return PhoneVisualText(value: candidate.string, confidence: candidate.confidence,
                                   bounds: PhoneVisualRect(x: (component.minX + box.minX * component.width) / 2,
                                                           y: (component.minY + (1 - box.maxY) * component.height) / 2,
                                                           width: box.width * component.width / 2, height: box.height * component.height / 2))
        }
        return PhoneVisualFrame(width: image.width, height: image.height, rgba: data, text: text, capturedAt: capturedAt)
    }
}
