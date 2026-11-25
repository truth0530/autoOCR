import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Foundation
import Darwin

enum Timed {
    enum Failure: Error { case timeout }

    /// 한 번만 continuation을 재개한다. 제한 시간과 작업 완료가 겹쳐도 이중 재개하지 않는다.
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    /// 제한 시간이 지나면 작업이 남아 있어도 반환한다.
    ///
    /// `withThrowingTaskGroup`은 `cancelAll()` 뒤에도 자식이 끝날 때까지 기다리므로,
    /// `SCStream.stopCapture()`처럼 취소를 무시하는 호출에 쓰면 종료와 영역 변경이 멈춘다.
    static func run<T>(seconds: TimeInterval, _ operation: @escaping () async throws -> T) async throws -> T {
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            let task = Task {
                do {
                    let value = try await operation()
                    if gate.claim() { continuation.resume(returning: value) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: nanos)
                if gate.claim() {
                    task.cancel()
                    continuation.resume(throwing: Failure.timeout)
                }
            }
        }
    }
}

/// 스트림이 밖에서 끊긴 이유. 메뉴막대 ‘공유 중단’은 `.userStopped`다.
enum CaptureStopKind: Equatable {
    case userStopped
    case systemStopped
    /// 절전·화면 변경처럼 앱이 다시 붙여도 되는 끊김.
    case interrupted

    var restartsAutomatically: Bool { self == .interrupted }

    static func classify(domain: String, code: Int) -> CaptureStopKind {
        guard domain == SCStreamErrorDomain else { return .interrupted }
        switch SCStreamError.Code(rawValue: code) {
        case .userStopped:
            return .userStopped
        case .systemStoppedStream:
            return .systemStopped
        default:
            return .interrupted
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
    /// 앱이 `stopCapture`를 호출한 스트림. 이 종료는 사용자의 ‘공유 중단’이 아니다.
    private var ignoredStopIDs: Set<ObjectIdentifier> = []
    private var externalStop: CaptureStopKind?

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
    /// - Parameter excluding: 캡처에서 뺄 앱. 영역 조절 오버레이와 캡션 미러가 다시 인식되지 않게 자기 자신을 넘긴다.
    /// - Returns: 완성된 프레임마다 픽셀 버퍼를 방출하는 async 스트림.
    func start(region: CGRect,
               display: SCDisplay,
               pixelScale: CGFloat,
               excluding: [SCRunningApplication] = []) async throws -> AsyncStream<CVPixelBuffer> {
        // 이전 스트림이 남아 있으면 먼저 정리한다. (재시작 시 이중 캡처·멈춤 방지)
        await stop()

        let filter = SCContentFilter(display: display,
                                     excludingApplications: excluding,
                                     exceptingWindows: [])

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
        lock.lock()
        externalStop = nil
        self.stream = stream
        lock.unlock()

        // 캡처 시작 전에 continuation을 설정해 초기 프레임 유실을 막는다.
        let frames = AsyncStream<CVPixelBuffer>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            setContinuation(continuation)
        }

        do {
            try await Timed.run(seconds: 8) {
                try await Self.startCapture(stream)
            }
        } catch {
            await stop()
            throw error
        }
        return frames
    }

    func stop() async {
        let stopping: SCStream? = {
            lock.lock()
            defer { lock.unlock() }
            guard let stream else { return nil }
            ignoredStopIDs.insert(ObjectIdentifier(stream))
            self.stream = nil
            return stream
        }()
        withContinuation { $0.finish() }
        setContinuation(nil)
        if let stopping {
            await Self.stopCapture(stopping)
            lock.lock()
            ignoredStopIDs.remove(ObjectIdentifier(stopping))
            lock.unlock()
        }
    }

    /// 사용자가 메뉴막대에서 끊었는지 한 번만 꺼낸다.
    func takeExternalStop() -> CaptureStopKind? {
        lock.lock()
        defer { lock.unlock() }
        let kind = externalStop
        externalStop = nil
        return kind
    }

    /// 메인 스레드에서 `stopCapture`를 직접 기다리면 샘플 큐와 서로 대기하며 멈춘다.
    /// 멈추지 않는 호출은 제한 시간 뒤에 버리고, 스트림 참조는 이미 비워 둔다.
    private static func startCapture(_ stream: SCStream) async throws {
        try await Task.detached {
            try await stream.startCapture()
        }.value
    }

    private static func stopCapture(_ stream: SCStream) async {
        try? await Timed.run(seconds: 0.8) {
            try await Task.detached {
                try await stream.stopCapture()
            }.value
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
        // 에러 객체는 XPC로 넘어온다. 코드를 바로 값으로 복사해 두고 객체를 붙잡지 않는다.
        let ns = error as NSError
        let kind = CaptureStopKind.classify(domain: ns.domain, code: ns.code)
        let id = ObjectIdentifier(stream)
        lock.lock()
        let ignored = ignoredStopIDs.contains(id)
        if ignored { ignoredStopIDs.remove(id) }
        let isCurrent = self.stream === stream
        if !ignored && isCurrent {
            externalStop = kind
            self.stream = nil
        }
        lock.unlock()
        guard !ignored, isCurrent else { return }
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
