import Foundation

/// 列表排序（1010需求）。
///
/// 设计要点：
///
/// 1. **纯函数**：只依赖 `ImageItem` 上已有的字段（`relativeDirectory` / `name` /
///    `createdAt` / `directoryAddedDates`），既不访问 `AppState`，也不碰磁盘。
///    因此"切换排序方式"可以在内存里瞬时完成（20000 张实测约 40 ms），
///    不需要重新扫描目录。
///
/// 2. **目录优先**：确定性的两种排序都先逐级比较 `relativeDirectory`（短前缀在前），
///    再比较目录内的图片。这保证同一子目录的图片必然连续、不会被其他目录的图片穿插，
///    等价于"按排好序的目录树做深度优先遍历，且每个目录内先列图片"——即需求中的
///    "先对目录进行排序，再对目录内的图片进行排序"。
///
/// 3. **随机保持原有行为**：整库拉平后整体洗牌，不做目录分组（方案甲），
///    因此不改变用户已经习惯的体验。
enum ImageSorter {
    
    /// 按指定方式排序。不修改入参，返回新数组。
    static func sort(_ items: [ImageItem], by sortType: ImageSortType) -> [ImageItem] {
        switch sortType {
        case .random:
            return shuffled(items)
        case .name:
            return items.sorted { isOrderedBeforeByName($0, $1) }
        case .addedTime:
            return items.sorted { isOrderedBeforeByAddedTime($0, $1) }
        }
    }
    
    // MARK: - 随机
    
    /// Fisher-Yates 洗牌（沿用原有算法）
    private static func shuffled(_ items: [ImageItem]) -> [ImageItem] {
        guard items.count > 1 else { return items }
        
        var result = items
        for i in stride(from: result.count - 1, through: 1, by: -1) {
            let j = Int.random(in: 0...i)
            result.swapAt(i, j)
        }
        return result
    }
    
    // MARK: - 比较器
    
    /// 目录优先比较：逐级比较相对目录，**短前缀在前**；目录完全相同则返回 `.orderedSame`。
    ///
    /// 例：`[]`（根目录）< `["2023"]` < `["2023","summer"]` < `["zz"]`
    private static func compareDirectory(_ lhs: ImageItem, _ rhs: ImageItem) -> ComparisonResult {
        let a = lhs.relativeDirectory
        let b = rhs.relativeDirectory
        
        let shared = min(a.count, b.count)
        var i = 0
        while i < shared {
            let result = a[i].localizedStandardCompare(b[i])
            if result != .orderedSame { return result }
            i += 1
        }
        
        if a.count != b.count {
            return a.count < b.count ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
    
    private static func isOrderedBeforeByName(_ lhs: ImageItem, _ rhs: ImageItem) -> Bool {
        let directoryResult = compareDirectory(lhs, rhs)
        if directoryResult != .orderedSame {
            return directoryResult == .orderedAscending
        }
        
        let nameResult = lhs.name.localizedStandardCompare(rhs.name)
        if nameResult != .orderedSame {
            return nameResult == .orderedAscending
        }
        
        // 名称也相同时（同名不同目录、或极端情况）用完整路径兜底，保证排序确定、可复现
        return lhs.url.path < rhs.url.path
    }
    
    private static func isOrderedBeforeByAddedTime(_ lhs: ImageItem, _ rhs: ImageItem) -> Bool {
        let a = lhs.relativeDirectory
        let b = rhs.relativeDirectory
        let shared = min(a.count, b.count)
        
        // 目录层：**目录自身也按加入时间排序**（新→旧），而不是永远按名称。
        // 例：同样两个子目录，最近才加进父目录的那个会排到前面。
        var i = 0
        while i < shared {
            let lhsDirectoryDate = lhs.directoryAddedDates[safe: i]
            let rhsDirectoryDate = rhs.directoryAddedDates[safe: i]
            if let lhsDirectoryDate = lhsDirectoryDate,
               let rhsDirectoryDate = rhsDirectoryDate,
               lhsDirectoryDate != rhsDirectoryDate {
                return lhsDirectoryDate > rhsDirectoryDate
            }
            
            // 目录时间相同（或缺失）时退回名称，保证顺序确定、可复现
            let nameResult = a[i].localizedStandardCompare(b[i])
            if nameResult != .orderedSame {
                return nameResult == .orderedAscending
            }
            i += 1
        }
        
        // 同一层里"图片"排在"子目录内容"之前：短前缀在前
        if a.count != b.count {
            return a.count < b.count
        }
        
        // 同一目录内：文件按**创建时间**新→旧。
        //
        // 注意这里刻意不用 `addedToDirectoryDate`：批量复制 / 移动会把整批文件的
        // 该值重置到同一秒，抹掉真实生成顺序（实测 `/output/2025-12-25` 最新 24 个
        // 文件同属 16:40:48，彼此只能靠名称排，导致最新创建的图被挤到第 24 位）。
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        
        // 创建时间相同（或缺失）时用名称兜底，避免每次刷新顺序都在变
        let nameResult = lhs.name.localizedStandardCompare(rhs.name)
        if nameResult != .orderedSame {
            return nameResult == .orderedAscending
        }
        return lhs.url.path < rhs.url.path
    }
}

private extension Array {
    /// 越界返回 nil，用于逐层比较目录时容忍两侧深度不同
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
