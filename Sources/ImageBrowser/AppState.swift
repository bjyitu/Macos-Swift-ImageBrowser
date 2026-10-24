import Foundation
import SwiftUI
import Combine

class AppState: ObservableObject {
    static let shared = AppState()
    
    @Published var selectedFolderURL: URL?
    // 注：原先这里还有一个 `selectedImageItem`，但它**只写不读**（2 处写入、0 处读取），
    // 是彻底失效的死属性，已删除。
    // 详情页"当前显示哪张图"的权威来源是 `ImageDetailViewModel.imageItem`；
    // 列表页的选中态则是 `browserWindowState.selectedImageID`（详情页导航时也会同步更新它，
    // 以便返回列表能定位）——两者已足够，不需要再来一个中间副本。
    
    // MARK: - 图片列表（P0-1 修复）
    
    /// 当前图片列表。
    ///
    /// **线程约定：该属性只允许在主线程访问（读与写）。**
    ///
    /// 之所以把它声明成 `private(set)`，是为了让所有写入都必须经过下面
    /// `setImages` / `appendImages` / `removeImages` 这三个带主线程校验的
    /// 方法，从编译期就杜绝"后台线程直接赋值"的可能。
    ///
    /// 背景：修复前 `ImageLoaderService.loadImagesFromFolder`（后台线程）
    /// 与 `ImageDetailViewModel.cleanupCache`（cacheQueue 后台队列）会直接
    /// 读取本属性，而主线程正在 `append(contentsOf:)` / `removeAll`，构成
    /// 数据竞争，可能读到中间状态甚至数组越界崩溃。
    /// 后台任务若需要这份列表，必须由主线程先取出**快照**再作为参数传入，
    /// 禁止跨线程直接读取（参见 `ImageLoaderService.loadImagesFromFolder`
    /// 的 `reusableItems` 参数）。
    @Published private(set) var images: [ImageItem] = []
    
    /// 列表内容的版本号：每次**整体替换**（`setImages`）时自增。
    ///
    /// 作用：给分批装填任务一个"我上屏时列表长什么样"的凭据。分批任务启动时记下
    /// 当前版本号，每次追加前核对；一旦列表被**外部整体替换**（典型场景：Finder
    /// 双击图片时 `AppDelegate.loadImagesInBackground` 直接把完整列表写进来），
    /// 旧任务就立刻停止，不会再把同一批 URL 追加到一份已经包含它们的列表里。
    ///
    /// 这正是「同一目录的内容在列表里出现两遍」的根因：完整列表先上屏、随后
    /// 旧的分批任务又从第 0 批开始 append，于是前 200 张（按时间排序时正好包含
    /// 最新的整个子目录）被重复了一遍。
    private(set) var imagesRevision: Int = 0
    
    // MARK: - 图片列表的主线程写入接口
    
    /// 整体替换图片列表。**必须在主线程调用。**
    func setImages(_ newValue: [ImageItem]) {
        assertMainThread("setImages")
        images = Self.deduplicatedByURL(newValue, context: "setImages")
        imagesRevision &+= 1
    }
    
    /// 追加一批图片。**必须在主线程调用。**
    ///
    /// 按 URL 去重：同一路径在列表里只应出现一次。即使上层还有未覆盖的竞态，
    /// 这里也能保证 UI 不会拿到重复项（重复的 `id` 会触发 SwiftUI 的
    /// "ID occurs multiple times" 警告，并让同一张图显示两次）。
    func appendImages(_ newItems: [ImageItem]) {
        assertMainThread("appendImages")
        guard !newItems.isEmpty else { return }
        
        var seen = Set(images.map { $0.url.path })
        var accepted: [ImageItem] = []
        accepted.reserveCapacity(newItems.count)
        var firstDuplicate: String?
        for item in newItems {
            if seen.insert(item.url.path).inserted {
                accepted.append(item)
            } else if firstDuplicate == nil {
                firstDuplicate = item.url.path
            }
        }
        
        if let firstDuplicate = firstDuplicate {
            let dropped = newItems.count - accepted.count
            print("⚠️ appendImages: 丢弃 \(dropped) 张重复图片（路径已在列表中）：\(firstDuplicate)")
        }
        
        guard !accepted.isEmpty else { return }
        images.append(contentsOf: accepted)
    }
    
    /// 按 `url.path` 去重，保留首次出现的项。用于所有整体替换入口。
    private static func deduplicatedByURL(_ items: [ImageItem], context: String) -> [ImageItem] {
        guard items.count > 1 else { return items }
        
        var seen = Set<String>()
        var result: [ImageItem] = []
        result.reserveCapacity(items.count)
        var firstDuplicate: String?
        
        for item in items {
            if seen.insert(item.url.path).inserted {
                result.append(item)
            } else if firstDuplicate == nil {
                firstDuplicate = item.url.path
            }
        }
        
        if result.count != items.count, let firstDuplicate = firstDuplicate {
            print("⚠️ \(context): 列表含 \(items.count - result.count) 个重复路径，已去重：\(firstDuplicate)")
        }
        return result
    }
    
    /// 按条件移除图片。**必须在主线程调用。**
    func removeImages(where shouldRemove: (ImageItem) -> Bool) {
        assertMainThread("removeImages")
        images.removeAll(where: shouldRemove)
    }
    
    // MARK: - 载入进度（标题栏的"总量（已载入 N）"用）
    //
    // 背景：分批装填期间 `images` 是一批批长起来的，直接拿 `images.count` 当标题里的
    // 总量会显示成"已载入数量"。而其实**总量在装填开始前就已知**——`ImageBrowserViewModel`
    // 是在后台拿到完整列表后，才把它分批推进 `images` 的。
    // 所以这里额外记录"本轮总量"与"是否仍在装填"，让两个窗口的标题都能显示
    // `总量（已载入 N）`，装填结束后自然退回只显示总量。
    
    /// 本轮加载解析出的**总量**。分批装填期间保持不变。
    @Published private(set) var loadTotalCount: Int = 0
    
    /// 分批装填是否仍在进行。进行中时标题会附加"（已载入 N）"。
    @Published private(set) var isBatchFilling: Bool = false
    
    /// 开始一轮分批装填：总量已确定，正在逐批推进 `images`。**必须在主线程调用。**
    func beginBatchFilling(total: Int) {
        assertMainThread("beginBatchFilling")
        loadTotalCount = total
        isBatchFilling = true
    }
    
    /// 分批装填结束（全部批次都已进入 `images`）。**必须在主线程调用。**
    func endBatchFilling() {
        assertMainThread("endBatchFilling")
        isBatchFilling = false
    }
    
    /// 新一轮加载开始：清空进度状态。**必须在主线程调用。**
    func resetLoadProgress() {
        assertMainThread("resetLoadProgress")
        loadTotalCount = 0
        isBatchFilling = false
    }
    
    /// 标题里应当显示的"总量"。
    ///
    /// 装填未完成时是本轮**总量**（此时 `images` 只装了前几批）；完成后与 `images.count` 一致。
    var displayTotalCount: Int {
        (isBatchFilling && loadTotalCount > images.count) ? loadTotalCount : images.count
    }
    
    /// 装填未完成时返回 `"（已载入 N）"`，否则返回空串。
    ///
    /// 抽成属性而不是在两处各写一遍，是因为列表页与详情页的标题**必须保持同一口径**——
    /// P1-14 的教训正是"同一件事被多条通道分别实现"。
    var loadingCountSuffix: String {
        guard isBatchFilling, loadTotalCount > images.count else { return "" }
        return "（已载入 \(images.count)）"
    }
    
    /// 主线程校验。
    ///
    /// Debug 下直接中断，便于在开发阶段立刻暴露越权访问；
    /// Release 下仅打印告警，避免因个别遗漏路径导致用户侧闪退。
    @inline(__always)
    private func assertMainThread(_ function: String) {
        guard !Thread.isMainThread else { return }
        assertionFailure("AppState.\(function) 必须在主线程调用，当前线程：\(Thread.current)")
        print("⚠️ AppState.\(function) 被非主线程调用，存在数据竞争风险")
    }
    
    // 保存列表窗口的状态
    @Published var browserWindowState: BrowserWindowState = BrowserWindowState()
    
    // MARK: - 排序方式（1010需求）
    
    /// 列表页当前排序方式。唯一数据源：UI 读写它，加载器与重排逻辑都以它为准。
    ///
    /// 变更会持久化到 `UserDefaults`，跨启动保留用户上次的选择。
    /// 注意：修改它会驱动 `ImageBrowserViewModel` 在**内存中重排**（不重新扫盘）。
    @Published var sortType: ImageSortType {
        didSet {
            guard oldValue != sortType else { return }
            UserDefaults.standard.set(sortType.rawValue, forKey: Self.sortTypeDefaultsKey)
        }
    }
    
    private static let sortTypeDefaultsKey = "com.imagebrowser.sortType"
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // 读取上次选择的排序方式；首次运行或值非法时回到"随机"（保持原有默认体验）
        let saved = UserDefaults.standard.string(forKey: Self.sortTypeDefaultsKey)
        self.sortType = saved.flatMap(ImageSortType.init(rawValue:)) ?? .random
        setupNotifications()
    }
    
    private func setupNotifications() {
        // 使用NotificationManager监听各种通知并处理
    }
}

// 列表窗口状态管理
class BrowserWindowState: ObservableObject {
    @Published var selectedImageID: UUID?
    @Published var scrollOffset: CGPoint = .zero
}
