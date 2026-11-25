import AppKit

/// 详情窗口（单张图片浏览 / 自动播放）。
///
/// **为什么需要这个子类**：详情窗口用 `.fullSizeContentView` + 透明标题栏，
/// SwiftUI 内容铺满整窗（连标题栏下面都是内容）。
///
/// 双击返回列表的判定放在窗口层，而不是挂在 SwiftUI 根视图上，原因有两个：
///
/// 1. **标题栏不能参与**：标题栏里的标题文字是系统画的 `NSTextField`，它
///    `acceptsFirstMouse == true`，窗口失焦时点它不会被"激活点击"吞掉、会落到
///    内容层。挂在根视图上的双击手势会把这种单击当成双击，出现"失焦时点一下
///    标题文字就退回列表"（v39 修复）。
/// 2. **不能只信 `NSEvent.clickCount`**：`clickCount` 是**系统**对"双击"的判定，
///    要求两次按下的间隔小于 `NSEvent.doubleClickInterval`、且位置几乎不动。
///    自动播放时画面每 3 秒换一张，用户的手很容易跟着画面走、两次按下略慢或略偏，
///    第二下拿到的 `clickCount` 就是 1；窗口失焦时第一下还要先用于激活窗口，
///    同样可能打断系统的点击序列。只要 `clickCount != 2`，v39 的实现就完全没反应，
///    表现就是"偶尔双击不生效"。
///
/// **现在的判定**：自己记时间与位置，只要两次落在内容区的左键按下满足
/// "间隔 ≤ `NSEvent.doubleClickInterval`、位移 ≤ `doubleClickSlop`"就算双击，
/// 不再依赖系统给的 `clickCount`；同时继续排除标题栏。坐标用**窗口坐标**，
/// 所以即使两次按下之间窗口被拖动了，判定也不受影响。
final class DetailWindow: NSWindow {

    /// 内容区发生真正的双击时回调（在主线程、且在本轮事件派发之后执行）。
    var onContentDoubleClick: (() -> Void)?

    /// 自行判定双击时，两次按下允许的最大位移（point）。
    /// 系统阈值通常只有几个点，这里放宽到 10pt，容忍自动播放时手臂/触控板的小幅移动。
    private static let doubleClickSlop: CGFloat = 10

    /// 两次按下之间的最小间隔。
    /// 正常人手双击不会快于 20ms；设下限是为了防止同一个物理按下被 AppKit 重复投递时
    /// （时间戳相同）被我们自己凑成一对，变成"单击就返回列表"。
    private static let minimumClickGap: TimeInterval = 0.02

    /// 上一次落在内容区的左键按下（nil 表示没有待配对的按下）。
    private var lastContentDownTime: TimeInterval?
    private var lastContentDownPoint: NSPoint = .zero

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

    /// 清掉待配对的按下。标题栏点击、窗口隐藏、判定成功之后都要清，
    /// 避免标题栏的点击和后面的内容点击被凑成一对。
    private func resetPendingClick() {
        lastContentDownTime = nil
    }

    /// 判定一次事件是否构成"内容区双击返回列表"。
    ///
    /// 规则：
    /// - 只看 `leftMouseDown`，且必须落在标题栏以下的内容区；
    /// - 两次内容区按下间隔 ≤ `NSEvent.doubleClickInterval`（跟随系统双击速度设置）；
    /// - 两次按下的窗口坐标位移 ≤ `doubleClickSlop`；
    /// - 判定成功后清空状态，三连击只会返回一次列表。
    func isContentDoubleClick(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown else { return false }

        guard !isInTitlebar(event) else {
            // 标题栏的按下不参与配对，并且要把之前待配对的内容点击作废，
            // 否则"先点内容、再快速点标题栏"会被误判成一次双击。
            resetPendingClick()
            return false
        }

        let time = event.timestamp
        let point = event.locationInWindow
        let interval = NSEvent.doubleClickInterval

        if let last = lastContentDownTime {
            let elapsed = time - last
            let distance = hypot(point.x - lastContentDownPoint.x, point.y - lastContentDownPoint.y)
            if elapsed >= Self.minimumClickGap, elapsed <= interval, distance <= Self.doubleClickSlop {
                resetPendingClick()
                return true
            }
        }

        lastContentDownTime = time
        lastContentDownPoint = point
        return false
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

    override func orderOut(_ sender: Any?) {
        // 窗口隐藏后，之前那次单击不应该再和"重新打开后的第一次点击"配对。
        resetPendingClick()
        super.orderOut(sender)
    }
}
