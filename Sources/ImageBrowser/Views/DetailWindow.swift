import AppKit

/// 详情窗口（单张图片浏览 / 自动播放）。
///
/// **为什么需要这个子类**：详情窗口用 `.fullSizeContentView` + 透明标题栏，
/// SwiftUI 内容铺满整窗（连标题栏下面都是内容）。此前"双击返回列表"是挂在
/// 根视图上的 `.onTapGesture(count: 2)`，判定范围等于**整个窗口**，把标题栏
/// 也算进去了。而标题栏里的标题文字是系统画的 `NSTextField`：
///
/// - 它 `acceptsFirstMouse == true`，所以窗口失焦时点它不会被当成"激活点击"吞掉，
///   事件会继续落到内容层；
/// - 标题栏空白处的命中结果则是 `NSThemeFrame`，激活点击会被窗口边框消费。
///
/// 这正是"失焦时点标题栏文字会触发双击返回列表、点空白处不会"的来源。
///
/// **现在的判定**：双击返回下沉到窗口的 `sendEvent(_:)`，并加两条硬条件：
/// 1. 必须是真正的双击（`clickCount == 2`，单次激活点击不算）；
/// 2. 必须落在标题栏以下的内容区（`contentLayoutRect.maxY` 之下）。
///
/// 于是标题栏（文字与空白都算）不再参与"返回列表"，标题栏自带的拖动 /
/// 双击行为也不会被 SwiftUI 手势抢走。
final class DetailWindow: NSWindow {

    /// 内容区发生真正的双击时回调（已在主线程、且在本轮事件派发之后）。
    var onContentDoubleClick: (() -> Void)?

    /// 事件是否落在标题栏（含标题文字）区域。
    ///
    /// `contentLayoutRect` 是 AppKit 给出的"标题栏 + 工具栏以下"区域：
    /// - 普通标题栏窗口：高度 = 窗口高 - 标题栏高，原点在内容区左下；
    /// - `.fullSizeContentView` 窗口（本应用）：内容视图铺满整窗，但
    ///   `contentLayoutRect` 仍然只到标题栏下沿（实测 600×400 的详情窗口为
    ///   `(0, 0, 600, 372)`，即顶部 28pt 属于标题栏）。
    ///
    /// 全屏时标题栏不存在，不做排除。
    private func isInTitlebar(_ event: NSEvent) -> Bool {
        if styleMask.contains(.fullScreen) { return false }
        return event.locationInWindow.y >= contentLayoutRect.maxY
    }

    /// 判定一次事件是否构成"内容区双击返回列表"。
    ///
    /// 两条硬条件缺一不可：
    /// - `clickCount == 2`：窗口失焦时的激活点击 `clickCount` 仍是 1，
    ///   不会因为"点了一下标题文字"就当成双击；
    /// - 不在标题栏内：标题文字、标题空白、红绿灯所在的那一条都不参与返回列表。
    func isContentDoubleClick(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 2 else { return false }
        return !isInTitlebar(event)
    }

    override func sendEvent(_ event: NSEvent) {
        if isContentDoubleClick(event) {
            // 不在这里同步执行：回调会 orderOut 本窗口，事件派发中途隐藏窗口
            // 容易让 AppKit 停在半截状态；挪到下一轮 runloop 更稳。
            let handler = onContentDoubleClick
            DispatchQueue.main.async {
                handler?()
            }
        }
        super.sendEvent(event)
    }
}
