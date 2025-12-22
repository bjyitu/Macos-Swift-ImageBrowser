import Foundation
import AppKit
import Combine

/// 统一的通知管理器，完全基于Publisher模式处理所有通知
class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    
    private var cancellables = Set<AnyCancellable>()
    private let notificationQueue = DispatchQueue(label: "com.imagebrowser.notification", qos: .userInitiated)
    
    // 使用Subject作为通知发布中心
    private let notificationSubject = PassthroughSubject<Notification, Never>()
    
    private init() {
        // 将Subject连接到NotificationCenter
        notificationSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.logNotification(name: notification.name, type: "POST", object: notification.object, userInfo: notification.userInfo)
                NotificationCenter.default.post(notification)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - 通知发送（基于Publisher）
    
    /// 发送通知（统一使用Publisher模式）
    /// - Parameters:
    ///   - name: 通知名称
    ///   - object: 通知发送者
    ///   - userInfo: 附加信息
    func post(name: Notification.Name, object: Any? = nil, userInfo: [AnyHashable: Any]? = nil) {
        let notification = Notification(name: name, object: object, userInfo: userInfo)
        notificationQueue.async { [weak self] in
            self?.notificationSubject.send(notification)
        }
    }
    
    // MARK: - 通知订阅（基于Publisher）
    
    /// 订阅通知（返回Publisher，支持链式操作）
    /// - Parameter name: 通知名称
    /// - Returns: 通知Publisher
    func publisher(for name: Notification.Name) -> Publishers.HandleEvents<Publishers.ReceiveOn<NotificationCenter.Publisher, DispatchQueue>> {
        let publisher = NotificationCenter.default.publisher(for: name)
            .receive(on: DispatchQueue.main)
            .handleEvents(
                receiveSubscription: { [weak self] _ in
                    self?.logNotification(name: name, type: "SUBSCRIBE", object: nil, userInfo: nil)
                },
                receiveOutput: { [weak self] notification in
                    self?.logNotification(name: name, type: "RECEIVE", object: notification.object, userInfo: notification.userInfo)
                }
            )
        
        return publisher
    }
    
    /// 订阅通知并处理（简化版本）
    /// - Parameters:
    ///   - name: 通知名称
    ///   - handler: 通知处理闭包
    /// - Returns: 可取消的订阅
    func subscribe(to name: Notification.Name, handler: @escaping (Notification) -> Void) -> AnyCancellable {
        return publisher(for: name)
            .sink { notification in
                handler(notification)
            }
    }
    
    // MARK: - 便捷方法
    
    /// 发送显示详情窗口通知
    func showDetailWindow(with imageItem: ImageItem) {
        post(name: .openDetailWindow, userInfo: ["imageItem": imageItem])
    }
    
    /// 发送隐藏浏览器窗口通知
    func hideBrowserWindow() {
        post(name: .hideBrowserWindow)
    }
    
    /// 发送隐藏详情窗口通知
    func hideDetailWindow() {
        post(name: .hideDetailWindow)
    }
    
    /// 发送打开图片文件夹通知
    func openImageFolder() {
        post(name: .openImageFolder)
    }
    
    /// 发送打开浏览器窗口通知
    /// - Parameter shouldReloadImages: 是否重新加载图片
    func openBrowserWindow(shouldReloadImages: Bool = true) {
        post(name: .openBrowserWindow, userInfo: ["shouldReloadImages": shouldReloadImages])
    }
    
    /// 发送重新加载图片通知
    /// - Parameter folderURL: 文件夹URL
    func reloadImages(from folderURL: URL? = nil) {
        var userInfo: [AnyHashable: Any] = [:]
        if let folderURL = folderURL {
            userInfo["folderURL"] = folderURL
        }
        post(name: .reloadImages, userInfo: userInfo)
    }
    
    /// 发送图片选择变更通知
    /// - Parameters:
    ///   - selectedIndex: 选中索引
    ///   - totalCount: 总数量
    func imageSelectionChanged(selectedIndex: Int, totalCount: Int) {
        post(name: .imageSelectionChanged, userInfo: [
            "selectedIndex": selectedIndex,
            "totalCount": totalCount
        ])
    }
    
    /// 发送鼠标滚轮事件通知
    /// - Parameter event: 鼠标事件
    func scrollWheel(event: NSEvent) {
        post(name: .scrollWheel, object: event)
    }
    
    /// 发送打开图片文件通知
    /// - Parameter fileURL: 文件URL
    func openImageFile(_ fileURL: URL) {
        post(name: .openImageFile, userInfo: ["fileURL": fileURL])
    }
    
    /// 发送调整窗口大小通知
    /// - Parameters:
    ///   - size: 窗口大小
    ///   - image: 图片对象
    func adjustWindowSize(to size: NSSize, for image: NSImage) {
        post(name: .adjustWindowSize, userInfo: [
            "size": size,
            "image": image
        ])
    }
    
    /// 发送滚动到顶部通知
    func scrollToTop() {
        post(name: .scrollToTop)
    }
    
    /// 发送更新浏览器窗口标题通知
    /// - Parameter title: 窗口标题
    func updateBrowserWindowTitle(_ title: String) {
        post(name: .updateBrowserWindowTitle, userInfo: ["title": title])
    }
    
    /// 发送显示启动窗口通知
    func showLaunchWindow() {
        post(name: .showLaunchWindow)
    }
    
    // MARK: - 日志记录
    
    private func logNotification(name: Notification.Name, type: String, object: Any?, userInfo: [AnyHashable: Any]?) {
        // let formatter = ISO8601DateFormatter()
        // let timestamp = formatter.string(from: Date())
        // let objectInfo = object != nil ? String(describing: Swift.type(of: object!)) : "nil"
        // let userInfoInfo = userInfo != nil ? "\(userInfo!.count) keys" : "nil"
        
        // print("[\(timestamp)] [\(type)] \(name.rawValue) - Object: \(objectInfo), UserInfo: \(userInfoInfo)")
    }
}