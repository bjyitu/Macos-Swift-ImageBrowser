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
                    AppState.shared.images.removeAll { $0.id == imageItem.id }
                    
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
    
    // 删除图片并处理后续导航
    func deleteImageItemWithNavigation(
        _ imageItem: ImageItem, 
        from viewType: ViewType,
        completion: @escaping (Bool, ImageItem?, Error?) -> Void
    ) {
        // 先获取被删除图片的索引
        let deletedIndex = AppState.shared.images.firstIndex(of: imageItem)
        
        // 执行实际的删除操作
        deleteImageItem(imageItem) { success, error in
            if success {
                // 处理删除后的导航逻辑
                DispatchQueue.main.async {
                    let nextImage = self.handleNavigationAfterDeletion(
                        deletedImage: imageItem,
                        deletedIndex: deletedIndex,
                        viewType: viewType
                    )
                    completion(true, nextImage, nil)
                }
            } else {
                completion(false, nil, error)
            }
        }
    }
    
    // 处理删除图片后的导航逻辑
    private func handleNavigationAfterDeletion(
        deletedImage: ImageItem,
        deletedIndex: Int?,
        viewType: ViewType
    ) -> ImageItem? {
        // 如果删除后没有图片了
        guard !AppState.shared.images.isEmpty else {
            // 清除选中状态
            AppState.shared.browserWindowState.selectedImageID = nil
            
            // 发送通知更新窗口标题
            NotificationManager.shared.post(name: .updateBrowserWindowTitle)
            return nil
        }
        
        var nextImage: ImageItem?
        
        // 根据视图类型处理删除后的导航
        switch viewType {
        case .browser:
            nextImage = handleBrowserViewNavigationAfterDeletion(deletedIndex: deletedIndex)
        case .detail:
            nextImage = handleDetailViewNavigationAfterDeletion(deletedIndex: deletedIndex)
        }
        
        // 更新选中状态
        if let image = nextImage {
            AppState.shared.browserWindowState.selectedImageID = image.id
        }
        
        // 发送通知更新窗口标题
        NotificationManager.shared.post(name: .updateBrowserWindowTitle)
        
        return nextImage
    }
    
    // 浏览器视图删除后的导航处理
    private func handleBrowserViewNavigationAfterDeletion(deletedIndex: Int?) -> ImageItem? {
        if let index = deletedIndex {
            if index < AppState.shared.images.count {
                // 选择下一张（原来位置的图片）
                return AppState.shared.images[index]
            } else if index > 0 {
                // 如果删除的是最后一张，选择上一张
                return AppState.shared.images[index - 1]
            }
        }
        
        // 如果无法获取索引，选择第一张图片
        return AppState.shared.images.first
    }
    
    // 详情视图删除后的导航处理
    private func handleDetailViewNavigationAfterDeletion(deletedIndex: Int?) -> ImageItem? {
        if let index = deletedIndex {
            if index < AppState.shared.images.count {
                // 优先选择下一张（原来位置的图片）
                return AppState.shared.images[index]
            } else if index > 0 {
                // 如果删除的是最后一张，选择上一张
                return AppState.shared.images[index - 1]
            }
        }
        
        // 如果无法获取索引，选择第一张图片
        return AppState.shared.images.first
    }
    
    // 视图类型枚举
    enum ViewType {
        case browser
        case detail
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