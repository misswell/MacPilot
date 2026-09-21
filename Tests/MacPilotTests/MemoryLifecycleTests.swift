//
//  MemoryLifecycleTests.swift
//  MacPilotTests
//
//  锁住「空闲时必须交还」和「峰值必须有预算」这几条边界：主窗口的内容、
//  切换器浮层与缩略图的去留判定、滚动截图的字节预算、共享内存压力回调的
//  登记与注销。
//
//  刻意不断言绝对内存占用：分配器把内存还给内核的时机不由代码决定，
//  `Scripts/measure-memory.sh` 才是量实际占用的地方。这里只锁状态机。
//

import CoreGraphics
import Foundation
import MacPilotDockGroupsCore
import Testing
@testable import MacPilot

struct MainWindowContentStateTests {
    /// 登录启动不该带着一整份设置界面在后台待命。
    @Test func startsUnloadedWhenLaunchedAtLogin() {
        let state = MainWindowContentState(loadedAtLaunch: false)
        #expect(!state.isLoaded)
    }

    /// 手动双击启动时 SwiftUI 会把窗口开出来，内容必须已经在。
    @Test func startsLoadedWhenTheWindowOpensAtLaunch() {
        let state = MainWindowContentState(loadedAtLaunch: true)
        #expect(state.isLoaded)
    }

    @Test func presentingLoadsContentAndClosingReleasesIt() {
        var state = MainWindowContentState(loadedAtLaunch: false)
        state.load()
        #expect(state.isLoaded)

        let closing = state.beginClose()
        state.completeClose(requestedGeneration: closing)
        #expect(!state.isLoaded)
    }

    /// 关闭要延后一拍执行（不等动画跑完会把窗口刷白），
    /// 因此这一拍里用户重新打开时，那次关闭必须作废。
    @Test func reopenDuringDeferredCloseKeepsContentLoaded() {
        var state = MainWindowContentState(loadedAtLaunch: true)
        let closing = state.beginClose()

        state.load()
        state.completeClose(requestedGeneration: closing)

        #expect(state.isLoaded)
    }

    /// 关闭之后再延后一拍收到的旧关闭通知，不能把内容再关掉一次——
    /// `isLoaded` 已经是 false，重复释放不该被记成一次新的状态变化。
    @Test func repeatedCloseLeavesUnloadedContentAlone() {
        var state = MainWindowContentState(loadedAtLaunch: true)
        let first = state.beginClose()
        state.completeClose(requestedGeneration: first)
        let generationAfterClose = state.generation

        state.completeClose(requestedGeneration: first)
        #expect(!state.isLoaded)
        #expect(state.generation == generationAfterClose)
    }
}

struct WindowSwitcherPanelLifetimeTests {
    @Test func panelIsReleasedOnlyWhileNothingIsShowing() {
        #expect(WindowSwitcherPanelLifetimePolicy.canRelease(isShowing: false, hasPendingSession: false))
        // 正在显示：面板就是界面本身。
        #expect(!WindowSwitcherPanelLifetimePolicy.canRelease(isShowing: true, hasPendingSession: false))
        // 按下快捷键还没松手，下一轮候选随时要上屏。
        #expect(!WindowSwitcherPanelLifetimePolicy.canRelease(isShowing: false, hasPendingSession: true))
    }

    /// 空转回收必须明显短于一次工作间隔，又长到能吃下「连按」的 bursts。
    @Test func releaseIntervalsStayWithinTheBurstWindow() {
        #expect(WindowSwitcherPanelLifetimePolicy.thumbnailReleaseInterval >= 10)
        #expect(WindowSwitcherPanelLifetimePolicy.panelReleaseInterval >= 30)
        #expect(WindowSwitcherPanelLifetimePolicy.panelReleaseInterval <= 120)
        #expect(
            WindowSwitcherPanelLifetimePolicy.panelReleaseInterval
                > WindowSwitcherPanelLifetimePolicy.thumbnailReleaseInterval
        )
    }

    /// 缩略图缓存的上界是「切换器用完还留着多少像素」的唯一约束。
    @Test func thumbnailCacheKeepsAtMostThePolicyCount() {
        let ids = (0..<100).map { "window-\($0)" }
        let retained = WindowSwitcherThumbnailCachePolicy.retainedIDs(
            currentIDs: ids,
            cachedIDs: Set(ids)
        )
        #expect(retained.count == WindowSwitcherThumbnailCachePolicy.maximumCount)
    }
}

struct SmartScrollingCaptureBudgetTests {
    /// 一帧全屏 Retina 约 24 MB，按「最多 30 帧」算就是 ~700 MB 峰值。
    /// 预算必须按字节收口，而不是按帧数。
    @Test func fullDisplayFramesAreCappedByBytes() {
        let frame = SmartScrollingCaptureBudget.bytes(
            of: gradientImage(width: 3024, height: 1964, startRow: 0)
        )
        #expect(frame > 20 * 1024 * 1024)

        var captured = 0
        var count = 0
        while SmartScrollingCaptureBudget.accepts(capturedBytes: captured, frameCount: count, adding: frame) {
            captured += frame
            count += 1
        }
        #expect(count < 30)
        #expect(captured <= SmartScrollingCaptureBudget.maximumBytes)
    }

    /// 窄区域（聊天栏那种）本来花不了多少内存，不该被字节预算提前掐掉。
    @Test func narrowSelectionStillGetsEveryFrame() {
        let frame = SmartScrollingCaptureBudget.bytes(
            of: gradientImage(width: 600, height: 1200, startRow: 0)
        )
        var captured = 0
        var count = 0
        while SmartScrollingCaptureBudget.accepts(capturedBytes: captured, frameCount: count, adding: frame) {
            captured += frame
            count += 1
        }
        #expect(count == SmartScrollingCaptureBudget.maximumFrames)
    }
}

struct ScrollShotStitcherTests {
    /// 重叠检测把帧横向缩到 256 列。窄帧走不到这条路，所以宽帧要单独钉住：
    /// 上一页的底部正好接上这一页的顶部时，重叠量必须按行数精确对上；
    /// 两帧内容不同时不能误报。
    @Test func findsOverlapOnWideFrames() {
        let previous = gradientImage(width: 1200, height: 400, startRow: 0)
        let scrolled = gradientImage(width: 1200, height: 400, startRow: 150)
        #expect(ScreenCaptureVerticalStitcher.bestOverlap(previous: previous, current: scrolled) == 250)
        #expect(ScreenCaptureVerticalStitcher.bestOverlap(previous: previous, current: previous) == 0)
    }

    /// 拼接的高度必须等于「两帧之和减去重叠」——这是缩放后仍然对齐的证据。
    @Test func stitchesWideFramesWithoutLosingRows() {
        let first = gradientImage(width: 1200, height: 400, startRow: 0)
        let second = gradientImage(width: 1200, height: 400, startRow: 150)
        let overlap = ScreenCaptureVerticalStitcher.bestOverlap(previous: first, current: second)
        let stitched = ScreenCaptureVerticalStitcher.stitch([first, second])
        #expect(overlap == 250)
        #expect(stitched?.height == first.height + second.height - overlap)
        #expect(stitched?.width == first.width)
    }
}

struct DockHelperLifetimeTests {
    /// 验收口径是「浮层关掉后 60 秒内退出」；下限则是热展开仍然划算。
    /// 曾经是 5 分钟，正是「后台留了一堆 Helper 进程」的来源。
    @Test func warmResidencyIsBounded() {
        #expect(DockHelperWarmLifetimePolicy.seconds > 10)
        #expect(DockHelperWarmLifetimePolicy.seconds <= 60)
    }
}

/// A frame whose every row is one flat, unique value, so a horizontal downscale
/// cannot change what the overlap search sees.
private func gradientImage(width: Int, height: Int, startRow: Int) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for row in 0..<height {
        // A row's colour is a splitmix64 hash of its page position: neighbours
        // must look unrelated, or a wrong overlap would score inside the
        // tolerance. (A plain multiply only shifts the high bits, which does
        // exactly that.)
        var mixed = UInt64(truncatingIfNeeded: startRow + row)
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        mixed = mixed ^ (mixed >> 31)
        let low = UInt8(truncatingIfNeeded: mixed >> 32)
        let high = UInt8(truncatingIfNeeded: mixed >> 48)
        for column in 0..<width {
            let base = row * width * 4 + column * 4
            pixels[base] = low
            pixels[base + 1] = low
            pixels[base + 2] = high
            pixels[base + 3] = 255
        }
    }
    let data = Data(pixels)
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

@MainActor
struct MemoryPressureTests {
    @Test func subscribingAndCancellingBalances() {
        let pressure = MemoryPressure()
        #expect(pressure.subscriberCount == 0)

        let token = pressure.observe {}
        #expect(pressure.subscriberCount == 1)

        pressure.cancel(token)
        #expect(pressure.subscriberCount == 0)
    }

    /// 取消不存在的 token 是常态（功能从未启动、或已经注销过两次），
    /// 但不能因此把别人的回调一起带走。
    @Test func cancellingUnknownTokenKeepsSubscribers() {
        let pressure = MemoryPressure()
        let token = pressure.observe {}
        pressure.cancel(UUID())
        pressure.cancel(nil)
        #expect(pressure.subscriberCount == 1)
        pressure.cancel(token)
        #expect(pressure.subscriberCount == 0)
    }
}
