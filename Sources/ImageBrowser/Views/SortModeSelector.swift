import SwiftUI

/// 三个排序按钮的常态透明度。
///
/// **需要微调观感时只改这里**（三个数值集中在一处，避免散落在视图代码里）：
/// - `unselected`：未选中项，与详情页播放按钮的常态保持一致（0.3）；
/// - `selected`：当前选中的模式。**数值越大越"实"、越醒目**；
/// - `hover`：鼠标悬停时的目标值，用来提示"这个可以点"。
private enum ButtonOpacity {
    static let unselected: Double = 0.3
    static let selected: Double = 0.85
    static let hover: Double = 1.0
}

/// 列表页排序选择器（1010需求）：三个按钮**竖列**排布，点哪个就是哪种排序。
///
/// ## 为什么不是弹层
/// 最初用 `Menu`，真机反馈"弹层太宽"——`Menu` 的宽度由系统 `NSMenuItem` 决定，SwiftUI 侧
/// 加不了约束。中间一版改成 `Button + popover` 来约束宽度，现在按维护者要求彻底去掉弹层，
/// 改为三个按钮直接平铺：没有弹层，也就没有宽度问题，且当前排序状态是一眼可见的。
///
/// ## 视觉
/// 每个按钮沿用详情页播放按钮 `PlayPauseButton` 的画法：
/// `.font(.system(size: 30))` + `.frame(width: 50, height: 50)` +
/// `Circle().fill(Color.black.opacity(0.3))` + `.buttonStyle(PlainButtonStyle())`。
///
/// 透明度由上面的 `ButtonOpacity` 统一控制。
struct SortModeSelector: View {
    @Binding var sortType: ImageSortType
    
    /// 三个按钮之间的间距
    private let spacing: CGFloat = 12
    
    var body: some View {
        VStack(spacing: spacing) {
            ForEach(ImageSortType.allCases) { type in
                SortModeOptionButton(
                    type: type,
                    isSelected: type == sortType,
                    action: {
                        // 只在真的换了模式时才写：@Published 每次赋值都会发信，
                        // 重复点当前项会白白触发一次整表重排。
                        if type != sortType {
                            sortType = type
                        }
                    }
                )
            }
        }
    }
}

/// 单个排序按钮。悬停与按压状态各自独立，因此需要单独一个 View 持有 `@State`。
private struct SortModeOptionButton: View {
    let type: ImageSortType
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovering = false
    @State private var buttonScale: CGFloat = 1.0
    
    var body: some View {
        Button(action: handleTap) {
            Image(systemName: type.iconName)
                .font(.system(size: 30))
                .frame(width: 50, height: 50)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.3))
                )
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(buttonScale)
        .opacity(buttonOpacity)
        .onHover { hovering in
            isHovering = hovering
        }
        .help("排序方式：\(type.displayName)")
    }
    
    /// 常态：选中 / 未选中；悬停统一提到更高
    private var buttonOpacity: Double {
        if isHovering { return ButtonOpacity.hover }
        return isSelected ? ButtonOpacity.selected : ButtonOpacity.unselected
    }
    
    private func handleTap() {
        // 与播放按钮一致的按压回弹
        buttonScale = 0.9
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.linear(duration: 0.1)) {
                buttonScale = 1.0
            }
        }
        action()
    }
}
