import Foundation

/// 列表页排序方式（1010需求）。
///
/// 从 `ImageLoaderService.SortType` 提升为独立类型，原因是它现在需要：
/// - 被 UI 直接使用（菜单选项、图标、显示名）
/// - 被 `AppState` 持有并持久化
/// - 在 `ImageSorter` 中以纯函数方式消费
enum ImageSortType: String, CaseIterable, Identifiable {
    /// 随机：整库拉平后整体洗牌（保持原有行为，不做目录分组）
    case random
    /// 按名称：目录优先，目录内按名称升序
    case name
    /// 按时间：目录优先。目录块按"加入父目录的时间"新→旧；
    /// 目录内的文件按**创建时间**新→旧（批量移动会重置添加时间，不能反映生成顺序）
    case addedTime
    
    var id: String { rawValue }
    
    /// 菜单中显示的名称
    var displayName: String {
        switch self {
        case .random:    return "随机"
        case .name:      return "按名称"
        case .addedTime: return "按时间"
        }
    }
    
    /// 按钮图标（三种模式各一个，让"当前是哪种排序"一眼可见）
    ///
    /// 图标选择经过实际渲染比对（30pt 图标 + 50pt 圆 + 30% 黑底 + 白底照片）：
    /// - `textformat`（"Aa" 带下划线）比 `textformat.abc` 笔画更粗、字形更居中，
    ///   与 `shuffle`、`clock.arrow.circlepath` 的视觉重量更一致；
    /// - 未采用 `character` / `a.circle`——它们自带圆圈，套在圆形底上会变成同心双圆；
    /// - 未采用 `arrow.up.and.down.text.horizontal`——该符号在 30pt 下会溢出 50pt 圆；
    /// - 未采用 `line.3.horizontal.decrease`——它是"筛选"图标，含义会误导。
    var iconName: String {
        switch self {
        case .random:    return "shuffle"
        case .name:      return "textformat"
        case .addedTime: return "clock.arrow.circlepath"
        }
    }
}
