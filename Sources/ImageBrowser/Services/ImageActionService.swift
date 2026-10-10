import SwiftUI
import AppKit

class ImageActionService {
    static let shared = ImageActionService()
    
    private init() {}
    
    // 显示删除确认对话框
    func showDeleteConfirmation(for imageItem: ImageItem, in window: NSWindow? = nil, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "确认删除"
        alert.informativeText = "确定要将图片 \"\(imageItem.name)\" 移动到回收站吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        
        let targetWindow = window ?? NSApp.keyWindow
        
        if let targetWindow = targetWindow {
            alert.beginSheetModal(for: targetWindow) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }
    
    // 执行删除图片操作
    func deleteImageItem(_ imageItem: ImageItem, completion: @escaping (Bool, Error?) -> Void) {
        NSWorkspace.shared.recycle([imageItem.url]) { urls, error in
            // P0-1 修复：NSWorkspace 的回调在任意线程执行，这里显式切回主线程，
            // 保证对 AppState.images 的读取与写入都发生在主线程上。
            DispatchQueue.main.async {
                if let error = error {
                    // 显示错误信息
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "删除失败"
                    errorAlert.informativeText = "无法删除图片：\(error.localizedDescription)"
                    errorAlert.alertStyle = .critical
                    errorAlert.addButton(withTitle: "确定")
                    errorAlert.runModal()
                    completion(false, error)
                } else {
                    // 从应用状态中移除图片
                    // P0-1 修复：已切回主线程，仍统一通过 AppState 的主线程写入接口，
                    // 避免绕过主线程校验直接改动 images。
                    AppState.shared.removeImages { $0.id == imageItem.id }
                    
                    // 如果删除的是当前选中的图片，清除选中状态
                    if AppState.shared.browserWindowState.selectedImageID == imageItem.id {
                        AppState.shared.browserWindowState.selectedImageID = nil
                    }
                    
                    completion(true, nil)
                }
            }
        }
    }
    
    // 导航到上一张图片
    func navigateToPreviousImage(from currentImage: ImageItem, loop: Bool = false) -> ImageItem? {
        guard let currentIndex = AppState.shared.images.firstIndex(of: currentImage),
              !AppState.shared.images.isEmpty else { return nil }
        
        if currentIndex == 0 {
            return loop ? AppState.shared.images.last : nil
        }
        
        let previousIndex = currentIndex - 1
        return AppState.shared.images[previousIndex]
    }
    
    // 导航到下一张图片
    func navigateToNextImage(from currentImage: ImageItem, loop: Bool = false) -> ImageItem? {
        guard let currentIndex = AppState.shared.images.firstIndex(of: currentImage),
              !AppState.shared.images.isEmpty else { return nil }
        
        if currentIndex == AppState.shared.images.count - 1 {
            return loop ? AppState.shared.images.first : nil
        }
        
        let nextIndex = currentIndex + 1
        return AppState.shared.images[nextIndex]
    }
    
    // 打开图片所在目录
    func openImageDirectory(for imageItem: ImageItem) {
        NSWorkspace.shared.selectFile(imageItem.url.path, inFileViewerRootedAtPath: "")
    }
    
    // MARK: - 删除后导航处理
    
    /// 删除图片并处理后续导航。
    ///
    /// **P0-4 修复**：导航目标不再用"删除前的下标"来定位。
    ///
    /// 原实现先记下 `deletedIndex`，而 `NSWorkspace.recycle` 的完成回调是**异步**的；
    /// 等回调执行时 `AppState.shared.images` 可能已经被别的操作改变
    ///（连续删除多张、切换目录重新加载等），此时再拿旧下标去索引当前数组，
    /// 就会选中一个完全无关的图片（或取到越界/错位的结果）。
    ///
    /// 现在改为**在删除前记下相邻图片的 `id`**（后继优先，其次前驱），
    /// 删除完成后按 `id` 在当前列表中重新定位。`id` 是 `ImageItem` 的稳定标识，
    /// 不受插入 / 删除 / 重排影响，因此即使列表已经变化也能找到真正的邻居。
    func deleteImageItemWithNavigation(
        _ imageItem: ImageItem,
        completion: @escaping (Bool, ImageItem?, Error?) -> Void
    ) {
        // P0-4 修复：先记下"同位置下一张 / 否则上一张"的稳定标识。
        // 这里读取 AppState 发生在主线程（本方法由删除确认回调在主线程调用），
        // 符合 P0-1 的线程契约。
        let neighbors = Self.neighborIDs(of: imageItem, in: AppState.shared.images)
        
        // 执行实际的删除操作
        deleteImageItem(imageItem) { success, error in
            if success {
                // 处理删除后的导航逻辑
                DispatchQueue.main.async {
                    let nextImage = self.handleNavigationAfterDeletion(neighbors: neighbors)
                    completion(true, nextImage, nil)
                }
            } else {
                completion(false, nil, error)
            }
        }
    }
    
    /// 记录被删除图片的相邻项标识（P0-4 修复新增）。
    ///
    /// - Returns: `successor` 对应原实现"同位置下一张"的语义（删除后占据原位置的那张），
    ///   `predecessor` 对应"删除的是最后一张时回退到上一张"。两者都不存在说明
    ///   被删图片不在当前列表中。
    private static func neighborIDs(
        of imageItem: ImageItem,
        in images: [ImageItem]
    ) -> (successor: UUID?, predecessor: UUID?) {
        guard let index = images.firstIndex(of: imageItem) else {
            return (nil, nil)
        }
        
        let successor = index + 1 < images.count ? images[index + 1].id : nil
        let predecessor = index > 0 ? images[index - 1].id : nil
        return (successor, predecessor)
    }
    
    /// 处理删除图片后的导航逻辑（P0-4 修复：改为按 `id` 在当前列表中重新定位）
    private func handleNavigationAfterDeletion(
        neighbors: (successor: UUID?, predecessor: UUID?)
    ) -> ImageItem? {
        let images = AppState.shared.images
        
        // 如果删除后没有图片了
        guard !images.isEmpty else {
            // 清除选中状态
            AppState.shared.browserWindowState.selectedImageID = nil
            // P1-14 修复：不再发 `.updateBrowserWindowTitle` 通知——列表窗口标题
            // 已由 AppDelegate 直接订阅 `AppState.shared.$images` 自动刷新。
            return nil
        }
        
        // P0-4 修复：按删除前记下的 id 重新定位，而不是用旧下标直接索引。
        // 优先级与原实现保持一致：同位置下一张（后继）→ 上一张（前驱）→ 兜底第一张。
        // 若两者都找不到（例如删除期间整个列表已被换掉/重新加载），同样兜底到第一张。
        var nextImage: ImageItem?
        if let successorID = neighbors.successor,
           let successor = images.first(where: { $0.id == successorID }) {
            nextImage = successor
        } else if let predecessorID = neighbors.predecessor,
                  let predecessor = images.first(where: { $0.id == predecessorID }) {
            nextImage = predecessor
        } else {
            nextImage = images.first
        }
        
        // 更新选中状态
        if let image = nextImage {
            AppState.shared.browserWindowState.selectedImageID = image.id
        }
        
        // P1-14 修复：不再发 `.updateBrowserWindowTitle` 通知。
        // 删除本身会改变 `AppState.shared.images`，AppDelegate 订阅的 `$images`
        // 已经会刷新列表窗口标题；原来这里再发一次属于重复通道。
        
        return nextImage
    }
    
    // MARK: - 统一导航处理
    
    // 在浏览器视图中导航到上一张图片
    func navigateToPreviousImageInBrowser() {
        guard !AppState.shared.images.isEmpty else { return }
        
        if let selectedID = AppState.shared.browserWindowState.selectedImageID,
           let currentIndex = AppState.shared.images.firstIndex(where: { $0.id == selectedID }) {
            // 不再循环，如果已经是第一张图片则不处理
            if currentIndex > 0 {
                let previousIndex = currentIndex - 1
                let previousImage = AppState.shared.images[previousIndex]
                AppState.shared.browserWindowState.selectedImageID = previousImage.id
            }
        } else if let firstImage = AppState.shared.images.first {
            // 如果没有选中的图片，选择第一张图片
            AppState.shared.browserWindowState.selectedImageID = firstImage.id
        }
    }
    
    // 在浏览器视图中导航到下一张图片
    func navigateToNextImageInBrowser() {
        guard !AppState.shared.images.isEmpty else { return }
        
        if let selectedID = AppState.shared.browserWindowState.selectedImageID,
           let currentIndex = AppState.shared.images.firstIndex(where: { $0.id == selectedID }) {
            // 不再循环，如果已经是最后一张图片则不处理
            if currentIndex < AppState.shared.images.count - 1 {
                let nextIndex = currentIndex + 1
                let nextImage = AppState.shared.images[nextIndex]
                AppState.shared.browserWindowState.selectedImageID = nextImage.id
            }
        } else if let firstImage = AppState.shared.images.first {
            // 如果没有选中的图片，选择第一张图片
            AppState.shared.browserWindowState.selectedImageID = firstImage.id
        }
    }
    
    // 在详情视图中导航到上一张图片
    func navigateToPreviousImageInDetail(
        viewModel: ImageDetailViewModel,
        stopPlayback: Bool = true,
        isPlaying: Bool,
        togglePlayPause: @escaping () -> Void,
        updateWindowTitle: @escaping () -> Void
    ) {
        // 如果正在播放且需要停止，停止自动播放
        if stopPlayback && isPlaying {
            togglePlayPause()
        }
        
        guard let currentImageItem = viewModel.imageItem,
              let previousImage = navigateToPreviousImage(from: currentImageItem) else { 
            print("已经是第一张图片，无法继续向前浏览")
            return 
        }
        
        // 优化：先更新列表页选中状态，再切换图片
        AppState.shared.browserWindowState.selectedImageID = previousImage.id
        
        // 使用新的切换方法，自动管理缓存
        viewModel.switchToImage(previousImage, shouldAdjustWindow: false)
        
        // 异步更新窗口标题，避免阻塞切换
        DispatchQueue.main.async {
            updateWindowTitle()
        }
    }
    
    // 在详情视图中导航到下一张图片
    func navigateToNextImageInDetail(
        viewModel: ImageDetailViewModel,
        stopPlayback: Bool = true,
        isPlaying: Bool,
        togglePlayPause: @escaping () -> Void,
        updateWindowTitle: @escaping () -> Void,
        resetProgress: (() -> Void)? = nil
    ) {
        // 如果正在播放且需要停止，停止自动播放
        if stopPlayback && isPlaying {
            togglePlayPause()
        }
        
        // 如果是自动播放模式，立即重置进度，避免闪现
        if !stopPlayback, let resetProgress = resetProgress {
            resetProgress()
        }
        
        guard let currentImageItem = viewModel.imageItem,
              let currentIndex = AppState.shared.images.firstIndex(of: currentImageItem),
              !AppState.shared.images.isEmpty else { return }
        
        // 循环浏览：如果是最后一张图片，则跳转到第一张
        let nextImage: ImageItem
        if currentIndex == AppState.shared.images.count - 1 {
            nextImage = AppState.shared.images[0] // 使用第一张图片
            print("到底了 = \(currentIndex)")
            // 循环滚动时，通知列表页返回顶部
            // 确保通知在主线程发送，避免从Timer后台线程发送导致通知丢失
            DispatchQueue.main.async {
                NotificationManager.shared.post(name: .scrollToTop)
            }
        } else {
            // 使用现有的导航方法获取下一张图片
            if let serviceNextImage = navigateToNextImage(from: currentImageItem) {
                nextImage = serviceNextImage
            } else {
                return
            }
        }
        
        // 优化：先更新列表页选中状态，再切换图片
        AppState.shared.browserWindowState.selectedImageID = nextImage.id
        
        // 使用新的切换方法，自动管理缓存
        viewModel.switchToImage(nextImage, shouldAdjustWindow: false)
        
        // 异步更新窗口标题，避免阻塞切换
        DispatchQueue.main.async {
            updateWindowTitle()
        }
    }
}