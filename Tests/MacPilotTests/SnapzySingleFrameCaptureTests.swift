import CoreGraphics
import Foundation
import Testing
@testable import MacPilot

/// Regression coverage for the Snapzy single-frame SCStream fallback.
///
/// These tests drive the copied state machine directly, so they do not need a
/// real Screen Recording grant or a live SCStream callback.
struct SnapzySingleFrameCaptureTests {
    private func makeTestImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    @Test func firstFinishWinsAndLateFinishIsIgnored() async throws {
        let session = SnapzySingleFrameCaptureSession()
        let image = makeTestImage()

        let result: CGImage = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<CGImage, Error>) in
            session.arm(continuation: continuation, timeout: 60)
            session.finish(.success(image))
            session.finish(.failure(ScreenCaptureError.captureFailed("late")))
        }

        #expect(result.width == 1)
        #expect(result.height == 1)
    }

    @Test func timeoutEndsAStalledCapture() async {
        let session = SnapzySingleFrameCaptureSession()
        let startedAt = Date()

        do {
            let _: CGImage = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CGImage, Error>) in
                session.arm(continuation: continuation, timeout: 0.05)
            }
            Issue.record("Expected the stalled capture to time out")
        } catch let error as ScreenCaptureError {
            guard case .captureFailed(let detail) = error else {
                Issue.record("Expected a capture failure, got \(error)")
                return
            }
            #expect(detail == AppText.value("scCaptureTimedOut", language: .system))
            #expect(Date().timeIntervalSince(startedAt) < 2)
        } catch {
            Issue.record("Expected ScreenCaptureError, got \(error)")
        }
    }

    @Test func cancellationEndsPendingCapturePromptly() async {
        let session = SnapzySingleFrameCaptureSession()
        let startedAt = Date()

        do {
            let _: CGImage = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CGImage, Error>) in
                session.arm(continuation: continuation, timeout: 60)
                session.cancel()
            }
            Issue.record("Expected cancellation to fail the capture")
        } catch let error as ScreenCaptureError {
            guard case .captureFailed(let detail) = error else {
                Issue.record("Expected a capture failure, got \(error)")
                return
            }
            #expect(detail == AppText.value("scCaptureCancelled", language: .system))
            #expect(Date().timeIntervalSince(startedAt) < 2)
        } catch {
            Issue.record("Expected ScreenCaptureError, got \(error)")
        }
    }

    @Test func cancellationBeforeContinuationIsArmedStillTerminates() async {
        let session = SnapzySingleFrameCaptureSession()
        session.cancel()

        do {
            let _: CGImage = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CGImage, Error>) in
                session.arm(continuation: continuation, timeout: 60)
            }
            Issue.record("Expected pre-cancelled capture to fail")
        } catch let error as ScreenCaptureError {
            guard case .captureFailed(let detail) = error else {
                Issue.record("Expected a capture failure, got \(error)")
                return
            }
            #expect(detail == AppText.value("scCaptureCancelled", language: .system))
        } catch {
            Issue.record("Expected ScreenCaptureError, got \(error)")
        }
    }

    @Test func timeoutCannotResumeAfterSuccessfulCapture() async throws {
        let session = SnapzySingleFrameCaptureSession()

        let _: CGImage = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<CGImage, Error>) in
            session.arm(continuation: continuation, timeout: 0.05)
            session.finish(.success(makeTestImage()))
        }

        try await Task.sleep(for: .milliseconds(100))
        session.finish(.failure(ScreenCaptureError.captureFailed("late")))
    }
}
