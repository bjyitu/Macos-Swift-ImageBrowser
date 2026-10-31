import SwiftUI
import AppKit

/// 标题栏渐变底板：让系统绘制的窗口标题在任意图片上都保持可读。
///
/// **为什么需要**：两个窗口都用了 `.fullSizeContentView` + `titlebarAppearsTransparent`，
/// 内容一直铺到窗口顶边，标题文字就直接压在图片上。而系统标题的颜色只跟随窗口外观
/// （深色外观白字、浅色外观黑字），不会感知下方图片的明暗——于是深色外观 + 浅色图片
/// 时白字糊在浅色背景里。AppKit 没有给标准窗口标题开放字色 / 描边 / 阴影
/// （`NSWindow` 只有 `title`、`titleVisibility`、`titlebarAppearsTransparent` 这几个开关），
/// 所以官方可行的"显示增强"手段就是**在标题下面垫一层材质或渐变**，本视图就是那层渐变。
///
/// **层级**：图片内容 → 本视图 → 系统标题。系统标题由 AppKit 画在窗口标题栏层，
/// 永远在这层 overlay 之上，因此本视图既盖不住标题、也不需要去盖。
///
/// **参数依据**：
/// - 顶部 0.55 的纯黑，在纯白图上对白字的对比度约 4.8:1（≥ WCAG 正文 4.5:1）；
/// - 前 30% 基本不衰减（平台段），避免标题基线处只剩 0.3 多一点；
/// - 之后快速衰减到 0，避免画面里出现一条可辨认的硬边；
/// - 高度默认 52pt = 标准标题栏 28pt + 24pt 收尾；窗口特别矮（超宽全景图）时按比例压缩。
struct TitleScrim: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var layout = ScrimLayout()

    var body: some View {
        ZStack(alignment: .top) {
            // 量取「本视图上边缘 → 窗口内容区顶部」的距离。
            // 详情窗口的内容铺满整窗，距离是 0；列表窗口的内容位于标题栏安全区之内，
            // 距离约等于标题栏高度。有了它，同一个组件在两种窗口里都能贴到窗口最顶部，
            // 不必硬编码 28pt，也不必依赖 safeAreaInsets 的具体取值。
            Color.clear
                .frame(height: 1)
                .background(
                    WindowLayoutProbe { result in
                        layout.apply(result)
                    }
                )

            gradient
                .frame(height: layout.height)
                .offset(y: -layout.topGap)
                .opacity(layout.isFullScreen ? 0 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 深色外观压黑（白字），浅色外观压白（黑字）。
    /// 两侧都只在“背景与标题同色”时才会被看见，因此不会给画面加不必要的雾感。
    private var tint: Color {
        colorScheme == .dark ? .black : .white
    }

    private var gradient: some View {
        LinearGradient(
            stops: [
                .init(color: tint.opacity(0.55), location: 0.00),
                .init(color: tint.opacity(0.50), location: 0.30),
                .init(color: tint.opacity(0.24), location: 0.55),
                .init(color: tint.opacity(0.06), location: 0.80),
                .init(color: tint.opacity(0.00), location: 1.00),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - 布局度量

private struct ScrimLayout: Equatable {
    /// 本视图上边缘到窗口内容区顶部的距离（0 表示内容已经铺到窗口顶部）。
    var topGap: CGFloat = 0
    /// 渐变总高度。
    var height: CGFloat = 52
    /// 全屏时标题栏不存在，底板会变成一条没来由的暗带，直接隐藏。
    var isFullScreen = false

    mutating func apply(_ result: WindowProbeResult) {
        // 窗口特别矮时（例如 10:1 的全景图）按比例压缩，避免底板吃掉半个画面。
        let clampedHeight = min(52, max(26, result.contentHeight * 0.22))
        let next = ScrimLayout(
            topGap: result.topGap,
            height: clampedHeight,
            isFullScreen: result.isFullScreen
        )
        if next != self {
            self = next
        }
    }
}

private struct WindowProbeResult: Equatable {
    var topGap: CGFloat
    var contentHeight: CGFloat
    var isFullScreen: Bool
}

// MARK: - 窗口度量探针

/// 一个零视觉影响的 NSView，只用来回答两件事：我在窗口的哪个位置、窗口是不是全屏。
private struct WindowLayoutProbe: NSViewRepresentable {
    let onUpdate: (WindowProbeResult) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onUpdate = onUpdate
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onUpdate = onUpdate
        nsView.report()
    }
}

private final class ProbeView: NSView {
    var onUpdate: ((WindowProbeResult) -> Void)?
    private var lastResult: WindowProbeResult?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        report()
    }

    override func layout() {
        super.layout()
        report()
    }

    func report() {
        guard let window = window, let content = window.contentView else { return }

        // convert(_:to: nil) 得到的是窗口坐标（原点左下、y 向上），
        // 因此「距顶部多远」= 内容区高度 - 本视图顶边的 y。
        let rectInWindow = convert(bounds, to: nil)
        let topGap = max(0, content.bounds.height - rectInWindow.maxY)

        let result = WindowProbeResult(
            topGap: topGap,
            contentHeight: content.bounds.height,
            isFullScreen: window.styleMask.contains(.fullScreen)
        )

        // 视图更新期间直接改 SwiftUI 状态会触发 "Modifying state during view update" 警告，
        // 因此统一挪到下一轮 runloop；值没变则直接丢弃，避免 report → 状态 → 重绘 → report 的循环。
        guard result != lastResult else { return }
        lastResult = result
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(result)
        }
    }
}
