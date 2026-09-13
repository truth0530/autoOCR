import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Foundation
import Darwin

enum Timed {
    enum Failure: Error { case timeout }

    static func run<T>(seconds: TimeInterval, _ operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Failure.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

/// `SCStream`을 감싸 캡처된 프레임을 픽셀 버퍼의 async 스트림으로 전달한다.
///
/// 이 객체 자신이 `SCStreamOutput`이므로 OCRManager가 이 서비스를 강하게 참조하는 한
/// 스트림 출력 대상도 살아 있다. (별도 output 객체가 조기 해제되던 기존 버그를 제거)
final class ScreenCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.srd.capture.samples")

    // continuation은 샘플 큐(yield)와 메인 액터(start/stop) 양쪽에서 접근하므로 락으로 보호한다.
    private let lock = NSLock()
    private var _continuation: AsyncStream<CVPixelBuffer>.Continuation?

    private func setContinuation(_ value: AsyncStream<CVPixelBuffer>.Continuation?) {
        lock.lock(); defer { lock.unlock() }
        _continuation = value
    }

    private func withContinuation(_ body: (AsyncStream<CVPixelBuffer>.Continuation) -> Void) {
        lock.lock()
        let continuation = _continuation
        lock.unlock()
        if let continuation { body(continuation) }
    }

    /// 지정한 영역(top-left screen points)을 캡처하기 시작한다.
    /// - Returns: 완성된 프레임마다 픽셀 버퍼를 방출하는 async 스트림.
    func start(region: CGRect, display: SCDisplay, pixelScale: CGFloat) async throws -> AsyncStream<CVPixelBuffer> {
        // 이전 스트림이 남아 있으면 먼저 정리한다. (재시작 시 이중 캡처·멈춤 방지)
        await stop()

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.sourceRect = region                                   // screen points 단위
        config.width = max(1, Int(region.width * pixelScale))        // 출력 픽셀 크기
        config.height = max(1, Int(region.height * pixelScale))
        config.showsCursor = false
        config.queueDepth = 3
        // OCR은 어차피 프레임을 솎아내므로, 스트림 자체도 최대 2fps로 제한해 부하를 낮춘다.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        // 캡처 시작 전에 continuation을 설정해 초기 프레임 유실을 막는다.
        let frames = AsyncStream<CVPixelBuffer>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            setContinuation(continuation)
        }

        do {
            try await Timed.run(seconds: 8) {
                try await Task.detached {
                    try await stream.startCapture()
                }.value
            }
        } catch {
            setContinuation(nil)
            try? await Timed.run(seconds: 3) { try await stream.stopCapture() }
            throw error
        }
        self.stream = stream
        return frames
    }

    func stop() async {
        withContinuation { $0.finish() }
        setContinuation(nil)
        if let stream {
            self.stream = nil
            try? await Timed.run(seconds: 3) {
                try await stream.stopCapture()
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              Self.isComplete(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // 샘플 콜백이 끝나면 원본 버퍼가 재사용될 수 있어 복사본을 OCR에 넘긴다.
        let payload = Self.copyPixelBuffer(pixelBuffer) ?? pixelBuffer
        withContinuation { $0.yield(payload) }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        withContinuation { $0.finish() }
        setContinuation(nil)
    }

    /// 프레임 상태가 `.complete`인지 확인한다. (빈/유휴 프레임 인식을 방지)
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw) else {
            // 상태 정보를 못 읽으면 일단 유효한 프레임으로 간주한다.
            return true
        }
        return status == .complete
    }

    private static func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        var copy: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                  attrs as CFDictionary, &copy) == kCVReturnSuccess,
              let copy else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let planes = CVPixelBufferGetPlaneCount(source)
        if planes == 0 {
            copyPlane(from: source, to: copy, plane: nil)
        } else {
            for plane in 0..<planes {
                copyPlane(from: source, to: copy, plane: plane)
            }
        }
        return copy
    }

    private static func copyPlane(from source: CVPixelBuffer, to dest: CVPixelBuffer, plane: Int?) {
        let height: Int
        let srcBPR: Int
        let dstBPR: Int
        let srcBase: UnsafeMutableRawPointer?
        let dstBase: UnsafeMutableRawPointer?
        if let plane {
            height = CVPixelBufferGetHeightOfPlane(source, plane)
            srcBPR = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            dstBPR = CVPixelBufferGetBytesPerRowOfPlane(dest, plane)
            srcBase = CVPixelBufferGetBaseAddressOfPlane(source, plane)
            dstBase = CVPixelBufferGetBaseAddressOfPlane(dest, plane)
        } else {
            height = CVPixelBufferGetHeight(source)
            srcBPR = CVPixelBufferGetBytesPerRow(source)
            dstBPR = CVPixelBufferGetBytesPerRow(dest)
            srcBase = CVPixelBufferGetBaseAddress(source)
            dstBase = CVPixelBufferGetBaseAddress(dest)
        }
        guard let srcBase, let dstBase, height > 0, srcBPR > 0, dstBPR > 0 else { return }
        let rowBytes = min(srcBPR, dstBPR)
        for y in 0..<height {
            memcpy(dstBase.advanced(by: y * dstBPR),
                   srcBase.advanced(by: y * srcBPR),
                   rowBytes)
        }
    }
}
