import Foundation
import SwiftUI
import Combine

class AppState: ObservableObject {
    static let shared = AppState()
    
    @Published var selectedFolderURL: URL?
    @Published var selectedImageItem: ImageItem?
    
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
    
    // MARK: - 图片列表的主线程写入接口
    
    /// 整体替换图片列表。**必须在主线程调用。**
    func setImages(_ newValue: [ImageItem]) {
        assertMainThread("setImages")
        images = newValue
    }
    
    /// 追加一批图片。**必须在主线程调用。**
    func appendImages(_ newItems: [ImageItem]) {
        assertMainThread("appendImages")
        guard !newItems.isEmpty else { return }
        images.append(contentsOf: newItems)
    }
    
    /// 按条件移除图片。**必须在主线程调用。**
    func removeImages(where shouldRemove: (ImageItem) -> Bool) {
        assertMainThread("removeImages")
        images.removeAll(where: shouldRemove)
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
