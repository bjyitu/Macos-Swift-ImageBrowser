import Foundation
import SwiftUI
import Combine

class AppState: ObservableObject {
    static let shared = AppState()
    
    @Published var selectedFolderURL: URL?
    @Published var selectedImageItem: ImageItem?
    @Published var images: [ImageItem] = []
    
    // 保存列表窗口的状态
    @Published var browserWindowState: BrowserWindowState = BrowserWindowState()
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupNotifications()
    }
    
    private func setupNotifications() {
        // 使用NotificationManager监听各种通知并处理
        NotificationManager.shared.publisher(for: .showDetailWindow)
            .sink { notification in
                // 处理显示详情窗口的逻辑
                if let userInfo = notification.userInfo,
                   let imageItem = userInfo["imageItem"] as? ImageItem {
                    self.selectedImageItem = imageItem
                }
            }
            .store(in: &cancellables)
    }
}

extension Notification.Name {
    static let showDetailWindow = Notification.Name("com.imagebrowser.showDetailWindow")
    static let hideBrowserWindow = Notification.Name("com.imagebrowser.hideBrowserWindow")
    static let hideDetailWindow = Notification.Name("com.imagebrowser.hideDetailWindow")
    static let openImageFolder = Notification.Name("com.imagebrowser.openImageFolder")
    static let openBrowserWindow = Notification.Name("com.imagebrowser.openBrowserWindow")
    static let openDetailWindow = Notification.Name("com.imagebrowser.openDetailWindow")
    static let showLaunchWindow = Notification.Name("com.imagebrowser.showLaunchWindow")
    static let updateBrowserWindowTitle = Notification.Name("com.imagebrowser.updateBrowserWindowTitle")
    static let scrollWheel = Notification.Name("com.imagebrowser.scrollWheel")
    static let openImageFile = Notification.Name("com.imagebrowser.openImageFile")
    static let reloadImages = Notification.Name("com.imagebrowser.reloadImages")
    static let adjustWindowSize = Notification.Name("com.imagebrowser.adjustWindowSize")
    static let imageSelectionChanged = Notification.Name("com.imagebrowser.imageSelectionChanged")
    static let scrollToTop = Notification.Name("com.imagebrowser.scrollToTop")
}

// 列表窗口状态管理
class BrowserWindowState: ObservableObject {
    @Published var selectedImageID: UUID?
    @Published var scrollOffset: CGPoint = .zero
}