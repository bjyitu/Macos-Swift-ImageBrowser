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
    
    
    // 发送显示浏览器窗口的通知
    func openBrowserWindow() {
        print("Sending openBrowserWindow notification")
        NotificationManager.shared.post(name: .openBrowserWindow)
    }
    
    // 发送显示详情窗口的通知
    func showDetailWindow(with imageItem: ImageItem) {
        print("AppState.showDetailWindow called with image: \(imageItem.name)")
        NotificationManager.shared.post(name: .openDetailWindow, userInfo: ["imageItem": imageItem])
        print("Notification posted for openDetailWindow")
    }
    
    // 发送隐藏浏览器窗口的通知
    func hideBrowserWindow() {
        NotificationManager.shared.post(name: .hideBrowserWindow)
    }
    
    // 发送隐藏详情窗口的通知
    func hideDetailWindow() {
        NotificationManager.shared.post(name: .hideDetailWindow)
    }
    
    // 发送显示启动窗口的通知
    func showLaunchWindow() {
        print("Sending showLaunchWindow notification")
        NotificationManager.shared.post(name: .showLaunchWindow)
    }
    
    // 发送打开图片文件夹的通知
    func openImageFolder() {
        NotificationManager.shared.post(name: .openImageFolder)
    }
    
    // 发送直接打开图片文件的通知
    func openImageFile(_ fileURL: URL) {
        print("AppState.openImageFile called with file: \(fileURL.path)")
        NotificationManager.shared.post(name: .openImageFile, userInfo: ["fileURL": fileURL])
        print("Notification posted for openImageFile")
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