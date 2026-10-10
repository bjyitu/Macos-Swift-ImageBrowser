import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit

@main
@available(macOS 12.0, *)
struct ImageBrowserApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // 设置应用激活策略为常规应用，使其在 Dock 中显示并能够正常显示窗口
        print("Initializing ImageBrowserApp")
        NSApplication.shared.setActivationPolicy(.regular)
    }
    
    var body: some Scene {
        // 启动窗口
        // P0-2 修复：原先在 `LaunchView` 上挂了 `.onAppear { onAppear() }` 来注册 6 个
        // 全局通知订阅。该回调每次触发都会**追加**一批新订阅且永不释放，
        // 而 `LaunchView` 所在的启动窗口会被 `hideAllWindows()` 反复 `orderOut`，
        // 回调可能多次触发，导致同一条通知被重复处理。
        // 应用级订阅已移入 `AppDelegate.applicationDidFinishLaunching`（整生命周期只注册一次）。
        WindowGroup {
            LaunchView()
        }
        .windowStyle(.hiddenTitleBar)
        // 防止文件打开时创建新窗口
        .handlesExternalEvents(matching: [])
        .commands {
            // 移除新建窗口命令，因为我们有自己的窗口管理
            CommandGroup(replacing: .newItem) { }
            
            // 添加自定义文件菜单
            CommandGroup(after: .newItem) {
                Button("打开...") {
                    // 调用打开对话框
                    appDelegate.openImageFolder()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

// AppDelegate 用于处理 macOS 12 的窗口管理
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var browserWindow: NSWindow?
    var detailWindow: NSWindow?
    
    /// P0-2 修复：应用级通知订阅的持有者。
    /// 由 `AppDelegate`（生命周期等同于整个进程）持有，而不再放在 `App`/`View` 的
    /// `@State` 里——后者会在每次 `onAppear` 时被追加新订阅且无法回收。
    private var cancellables = Set<AnyCancellable>()
    
    /// 注册应用级通知订阅。
    ///
    /// **P0-2 修复**：本方法只在 `applicationDidFinishLaunching` 中调用一次，
    /// 从结构上保证「整个应用生命周期内恰好订阅一次」。
    ///
    /// 原实现把这些订阅放在 `ImageBrowserApp.onAppear()` 里，由 `LaunchView`
    /// 的 `.onAppear` 驱动；而启动窗口会被 `hideAllWindows()` 反复 `orderOut`、
    /// 再由 `openLaunchWindow()` 重新前置，`.onAppear` 可能多次触发，
    /// 于是每次触发都会多出一批订阅——同一条通知会被处理多次。
    private func setupNotificationSubscriptions() {
        let manager = NotificationManager.shared
        
        // 监听打开文件夹选择对话框的通知
        manager.publisher(for: .openImageFolder)
            .sink { [weak self] _ in
                self?.openImageFolder()
            }
            .store(in: &cancellables)
        
        // 监听打开列表窗口的通知
        manager.publisher(for: .openBrowserWindow)
            .sink { [weak self] notification in
                // 默认情况下需要重新加载图片，除非明确指定不需要
                let shouldReloadImages = (notification.userInfo?["shouldReloadImages"] as? Bool) ?? true
                self?.openBrowserWindow(shouldReloadImages: shouldReloadImages)
            }
            .store(in: &cancellables)
        
        // 监听打开详情窗口的通知
        manager.publisher(for: .openDetailWindow)
            .sink { [weak self] notification in
                if let userInfo = notification.userInfo,
                   let imageItem = userInfo["imageItem"] as? ImageItem {
                    AppState.shared.selectedImageItem = imageItem
                    print("Opening detail window for image: \(imageItem.name)")
                    // 打开详情窗口
                    self?.openDetailWindow(with: imageItem)
                } else {
                    print("Failed to extract imageItem from notification")
                }
            }
            .store(in: &cancellables)
        
        // 监听直接打开图片文件的通知
        manager.publisher(for: .openImageFile)
            .sink { [weak self] notification in
                if let userInfo = notification.userInfo,
                   let fileURL = userInfo["fileURL"] as? URL {
                    self?.openImageFile(fileURL)
                } else {
                    print("Failed to extract fileURL from notification")
                }
            }
            .store(in: &cancellables)
        
        // 监听显示启动窗口的通知
        manager.publisher(for: .showLaunchWindow)
            .sink { [weak self] _ in
                print("Opening launch window")
                self?.openLaunchWindow()
            }
            .store(in: &cancellables)
        
        // **P1-14 修复**：列表窗口标题改为直接订阅 `AppState.images`，单一数据源。
        //
        // 原来由三条通道驱动同一个 `updateBrowserWindowTitle()`：
        //   1. `ImageBrowserView.onChange(of: appState.images)` 发 `.updateBrowserWindowTitle` 通知
        //   2. `ImageActionService` 在删除导航后发同一通知
        //   3. `openBrowserWindow` 里直接调用
        // 其中 1 与 2 会在"删除图片"时重复触发（删除本身就会改变 images）。
        //
        // 现在只要 `images` 发生变化就会自动刷新标题，无论变化来自哪里、视图是否可见。
        // 由于 P0-1 已保证 `images` 的所有写入都发生在主线程，这里的订阅也在主线程回调。
        AppState.shared.$images
            .receive(on: DispatchQueue.main)
            .sink { [weak self] images in
                self?.applyBrowserWindowTitle(imageCount: images.count)
            }
            .store(in: &cancellables)
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 注册Apple事件处理器（用于"Open With"功能）
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleAppleEvent(_:with:)),
            forEventClass: kCoreEventClass,
            andEventID: kAEOpenDocuments
        )
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 应用启动完成后的初始化工作
        print("Application did finish launching")  
        
        // P0-2 修复：应用级通知订阅在这里注册，整生命周期恰好一次。
        // 必须放在下方那些 `return`（Apple Event / 命令行参数提前打开文件）**之前**，
        // 否则带文件参数启动时这些订阅根本不会被注册，后续通知全部失效。
        setupNotificationSubscriptions()
        
        // 添加本地滚轮事件监听（针对应用内窗口）
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // 只在详情窗口显示时处理滚轮事件
            if let detailWindow = self.detailWindow, detailWindow.isVisible {
                // 转发滚轮事件到通知中心
                NotificationManager.shared.post(name: .scrollWheel, object: event)
            }
            return event
        }
        
        // 检查是否有启动时传递的文件URL（适用于Open With机制）
        if let url = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyDirectObject)?.stringValue {
            let fileURL = URL(fileURLWithPath: url)
            if ImageLoaderService.shared.isImageFile(fileURL) {
                openImageFile(fileURL)
                return
            }
        }
        
        // 检查命令行参数（适用于直接执行可执行文件的情况）
        let arguments = CommandLine.arguments
        // print("Command line arguments: \(arguments)")
        
        if arguments.count > 1 {
            for i in 1..<arguments.count {
                let arg = arguments[i]
                let fileURL = URL(fileURLWithPath: arg)
                
                if ImageLoaderService.shared.isImageFile(fileURL) {
                    openImageFile(fileURL)
                    return
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            // 检查是否有窗口已经显示
            let visibleWindows = NSApplication.shared.windows.filter { $0.isVisible }
            if visibleWindows.isEmpty {
                self.openLaunchWindow()
            } else {
                print("Windows already visible, skipping launch window")
            }
        }
    }
    
    // 处理从Finder或其他应用打开图片文件
    func application(_ application: NSApplication, open urls: [URL]) {
        print("=== Application open called ===")
        print("Files: \(urls.map { $0.path })")
        // 确保应用成为前台应用
        NSApp.activate(ignoringOtherApps: true)
        // 延迟处理，确保应用已经完全启动
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            self.handleFileOpen(urls)
        }
    }
    
    // 统一的文件打开处理方法
    private func handleFileOpen(_ urls: [URL]) {
        for url in urls {
            
            // 检查文件类型
            let fileType = getFileType(url)
            
            switch fileType {
            case .file:
                if ImageLoaderService.shared.isImageFile(url) {
                    print("filetype: image, Opening image file: \(url.path)")
                    // P1-13：不再走 `openImageFileWithRetry`——那个"重试"包装存在的唯一理由
                    // 是"同步扫描完可能仍找不到图片项"，现在扫描已异步化且会等目标出现，
                    // 重试机制随之作废（已删除）。这里直接复用 `openImageFile`。
                    self.openImageFile(url)
                    return
                }
            case .directory:
                print("filetype: folder, Opening folder: \(url.path)")
                // P1-9 修复：不再在主线程同步预加载整个目录。
                //
                // 原实现是 `loadImagesFromFolder(url)`（阻塞至全部文件头读完）
                // 再 `openBrowserWindow(shouldReloadImages: false)`，意图是"窗口一出现就带着数据"。
                // 但第一次开窗时 `shouldReloadImages` 参数在 `openBrowserWindow` 里并不生效
                //（它只在窗口已存在的分支被读取），`ImageBrowserView.onAppear` 仍会重新加载
                // 并先 `setImages([])` 清空列表——那次同步扫描的结果被直接丢弃，纯属白等。
                //
                // 现在与菜单 / 拖拽路径完全统一：只设好目录，交给 `openBrowserWindow`，
                // 由 `ImageBrowserView` 在后台加载并显示"加载中"。
                AppState.shared.selectedFolderURL = url
                self.openBrowserWindow(shouldReloadImages: true)
                return
            case .unknown:
                print("Unknown file type: \(url.path)")
            }
        }
    }
    
    // 文件类型判断
    private func getFileType(_ url: URL) -> FileType {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .unknown
        }
        
        return isDirectory.boolValue ? .directory : .file
    }
    
    // 延迟计算
    // P1-13：`calculateDelay(for:)` 原为 `openImageFileWithRetry` 的退避重试服务，
    // 随该重试包装一并删除（10/20/30ms 的延迟本就过短，无法规避任何真实问题）。
    
    // 文件类型枚举
    private enum FileType {
        case file
        case directory
        case unknown
    }
    
    // 处理单个文件打开（兼容旧API）
    func application(_ application: NSApplication, openFile filename: String) -> Bool {
        // 直接调用主方法处理，避免重复逻辑
        let url = URL(fileURLWithPath: filename)
        self.application(application, open: [url])
        return true
    }
    
    // 处理Apple事件（用于"Open With"功能）
    @objc func handleAppleEvent(_ event: NSAppleEventDescriptor, with replyEvent: NSAppleEventDescriptor) {
        if event.eventClass == kCoreEventClass && event.eventID == kAEOpenDocuments {
            // 获取文件列表
            if let files = event.paramDescriptor(forKeyword: keyDirectObject) {
                if files.descriptorType == typeAEList {
                    // 处理多个文件
                    let count = files.numberOfItems
                    print("Number of files: \(count)")
                    
                    for i in 1...count {
                        if let fileDescriptor = files.atIndex(i),
                           let filePath = fileDescriptor.stringValue {
                            let url = URL(fileURLWithPath: filePath)
                            print("Processing file: \(filePath)")
                            
                            if ImageLoaderService.shared.isImageFile(url) {
                                openImageFile(url)
                                break // 只处理第一个图片文件
                            }
                        }
                    }
                } else if let filePath = files.stringValue {
                    // 处理单个文件
                    print("Single file: \(filePath)")
                    let url = URL(fileURLWithPath: filePath)
                    
                    if ImageLoaderService.shared.isImageFile(url) {
                        openImageFile(url)
                    }
                }
            }
        }
    }
    
    func openBrowserWindow(shouldReloadImages: Bool = true) {
        print("Opening browser window using AppKit, shouldReloadImages: \(shouldReloadImages)")
        
        // 隐藏其他窗口
        hideAllWindows()
        
        if browserWindow == nil {
            let contentView = ImageBrowserView()
            let hostingController = NSHostingController(rootView: contentView)
            
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1024, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            //全透明
            window.titlebarAppearsTransparent = true
            //毛玻璃
            // window.titlebarAppearsTransparent = false
            // window.titleVisibility = .visible
            // window.backgroundColor = NSColor.windowBackgroundColor
            //隐藏标题栏
            // window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.contentViewController = hostingController
            window.center()
            window.makeKeyAndOrderFront(nil)
            
            // 设置窗口代理以监听关闭事件
            window.delegate = self
            
            browserWindow = window
            
            // 初始更新窗口标题
            updateBrowserWindowTitle()
        } else {
            browserWindow?.makeKeyAndOrderFront(nil)
            // 更新窗口标题
            updateBrowserWindowTitle()
            
            // 只有在需要重新加载图片时才发送通知
            if shouldReloadImages, let folderURL = AppState.shared.selectedFolderURL {
                // 发送通知让ImageBrowserView重新加载图片
                NotificationManager.shared.post(name: .reloadImages, userInfo: ["folderURL": folderURL])
            }
        }
    }
    
    func updateBrowserWindowTitle() {
        applyBrowserWindowTitle(imageCount: AppState.shared.images.count)
    }
    
    /// 按图片数量设置列表窗口标题。
    ///
    /// P1-14 修复：抽出为独立方法，供两处复用——
    /// 建窗时的首次设置，以及订阅 `AppState.shared.$images` 后的自动刷新。
    private func applyBrowserWindowTitle(imageCount: Int) {
        guard let window = browserWindow else { return }
        window.title = imageCount > 0 ? "共 \(imageCount) 张图片" : "图片浏览器"
    }
    
    /// 按图片尺寸为详情窗口定尺寸并居中。
    ///
    /// **P1-6 回归修复**：详情窗口从"每次新建"改为"复用单例"之后，
    /// `window.contentViewController = ...` 会让 AppKit 按新内容的最小 fitting size
    /// 收缩窗口；而这会儿图片还没解码完（P0-3 之后解码已异步化），视图处于
    /// "加载中"占位态（`frame(minWidth: 50, minHeight: 50)`），于是窗口被缩到极小。
    /// 原实现每次都新建窗口并 `center()`，恰好掩盖了这个问题。
    ///
    /// 现在由窗口的持有者（AppDelegate）在打开时按 `ImageItem.size` 直接定尺寸，
    /// 不再依赖视图 onAppear 里那套"首次定位"启发式。
    private func sizeDetailWindow(_ window: NSWindow, for imageItem: ImageItem, screenFrame: CGRect) {
        let size = ImageDetailViewModel.windowSize(
            forImageSize: imageItem.size,
            screenVisibleFrame: screenFrame
        )
        let origin = CGPoint(
            x: screenFrame.origin.x + (screenFrame.width - size.width) / 2,
            y: screenFrame.origin.y + (screenFrame.height - size.height) / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
    
    func openDetailWindow(with imageItem: ImageItem) {
        // P1-6 回归修复：必须在 hideAllWindows() **之前**取屏幕。
        // 隐藏全部窗口后就没有 key window 了，`NSScreen.main` 会退回"带菜单栏的主屏"，
        // 多显示器下会把详情窗口摆到错误的屏幕上。
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        
        // 隐藏其他窗口
        hideAllWindows()
        
        // 每次都构造新的内容视图；窗口实例本身复用（理由见下）
        let contentView = ImageDetailView(imageItem: imageItem)
        let hostingController = NSHostingController(rootView: contentView)
        
        // **P1-6 回归修复**：禁止 NSHostingController 反向决定窗口尺寸。
        // 详情窗口复用后，替换 contentViewController 会触发 AppKit 按新内容的最小
        // fitting size 收缩窗口（此时视图还在"加载中"占位态），表现为"窗口非常小"。
        // 窗口尺寸改由下面显式设置，因此这里也不需要它自动撑开。
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = []
        }
        
        // **P1-6 修复：复用同一个详情窗口，不再每次 NSWindow(...) 新建。**
        //
        // 原实现每次打开都新建窗口并覆盖 detailWindow，旧窗口既不 close() 也不置 nil。
        // 实测（AppKit 真实运行）：被 orderOut 的窗口仍被 AppKit 强引用持有，
        // 且一直留在 NSApp.windows 中——丢掉全部强引用后 weak 引用依然存活。
        //
        // 而本应用的详情页退出路径恰好是"隐藏"而非"关闭"：
        // 双击 / 回车 → switchToBrowserView() → orderOut(nil)。
        // 因此窗口累积不是异常路径，而是设计的必然结果。
        //
        // 连带的代价比"多几个 NSWindow"更重：
        //   窗口 → NSHostingController<ImageDetailView> → @StateObject ImageDetailViewModel
        //   → 其私有的 NSCache（上限 20 张 / 2000MB）
        // 每 abandon 一个详情窗口就可能连带留下最多 20 张全尺寸解码图。
        //
        // 复用窗口的同时替换 contentViewController：旧的 NSHostingController 会被释放，
        // 它持有的 ViewModel 与图片缓存随之释放，不再累积。
        if let window = detailWindow {
            window.contentViewController = hostingController
            window.title = "\(imageItem.name)"
            
            // 先同步定好尺寸再显示：避免先闪出一个被内容收缩的小窗口
            sizeDetailWindow(window, for: imageItem, screenFrame: screenFrame)
            window.makeKeyAndOrderFront(nil)
            
            // 再于下一轮 runloop 重新应用一次尺寸：
            // 内容替换触发的自动布局可能在本轮之后再次改动窗口尺寸，
            // 这里确保最终尺寸仍然是按图片算出来的那个。
            DispatchQueue.main.async {
                window.makeKeyAndOrderFront(nil)
                self.sizeDetailWindow(window, for: imageItem, screenFrame: screenFrame)
            }
            return
        }
        
        // 首次打开：创建窗口，并配置只需做一次的外观属性
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 600),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.title = "\(imageItem.name)"
        window.titlebarAppearsTransparent = true
        // 设置标题栏背景色为透明
        window.titlebarSeparatorStyle = .none
        window.contentViewController = hostingController
        
        // P1-6 回归修复：原来这里是 window.center()（固定 1024×600）。
        // 改为直接按图片尺寸定尺寸并居中，与复用路径保持一致。
        sizeDetailWindow(window, for: imageItem, screenFrame: screenFrame)
        
        // 设置窗口层级，确保显示在其他窗口前面
        // window.level = .floating
        
        window.makeKeyAndOrderFront(nil)
        
        // 确保窗口成为键窗口，这对于回车键触发的窗口特别重要
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            self.sizeDetailWindow(window, for: imageItem, screenFrame: screenFrame)
        }
        
        // 启用窗口背景拖拽功能
        window.isMovableByWindowBackground = true
        
        detailWindow = window
    }
    
    func openLaunchWindow() {
        
        // 隐藏其他窗口
        hideAllWindows()
        
        // 如果已经有启动窗口，则显示它
        for window in NSApplication.shared.windows {
            if let contentViewController = window.contentViewController,
               contentViewController is NSHostingController<LaunchView> {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }
    
    private func hideAllWindows() {
        for window in NSApplication.shared.windows {
            window.orderOut(nil)
        }
    }
    
    // MARK: - 直接打开图片文件功能
    
    func openImageFile(_ fileURL: URL) {
        // 检查是否为图片文件
        guard ImageLoaderService.shared.isImageFile(fileURL) else {
            return
        }
        
        // 获取文件所在目录
        let folderURL = fileURL.deletingLastPathComponent()
        
        // P1-9 修复：目录扫描移出主线程。
        //
        // 原实现在这里**同步**调用 `loadImagesFromFolder`——它会递归枚举整个目录、
        // 并发读完全部文件头（`group.wait()` 阻塞至最后一个完成）才返回。
        // 20000 张的目录实测约 0.42 s（热缓存），期间主线程完全无法处理事件，
        // 而且还没到 `openDetailWindow`，所以用户连窗口都看不到。
        //
        // 现在改为后台加载，完成后回主线程定位目标图片并打开详情窗口。
        // 注意：仍然要在列表里取那个"正牌" ImageItem 才能开详情页——
        // 详情页的上一张/下一张导航与 "i/n" 标题都依赖它在 AppState.images 中的
        // 位置，因此不能自己临时 new 一个（那会因 UUID 不同而定位失败）。
        loadImagesInBackground(folderURL) { [weak self] imageItems in
            guard let self = self else { return }
            
            // 从已加载的图片列表中找到对应的图片项（使用URL路径比较）
            guard let imageItem = imageItems.first(where: { $0.url.path == fileURL.path }) else {
                print("Error: Could not find image in loaded list: \(fileURL.path)")
                return
            }
            
            AppState.shared.selectedImageItem = imageItem
            // 同步设置列表页的选中状态
            AppState.shared.browserWindowState.selectedImageID = imageItem.id
            
            // 隐藏其他窗口并打开详情窗口
            self.hideAllWindows()
            self.openDetailWindow(with: imageItem)
            
            // 确保应用成为前台应用
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    /// P1-9 修复：把目录扫描从主线程移到后台队列，完成后回主线程写入 `AppState`。
    ///
    /// - Parameter completion: 在主线程回调，参数为本次加载出的图片列表。
    private func loadImagesInBackground(_ folderURL: URL, completion: @escaping ([ImageItem]) -> Void) {
        // P0-1 线程契约：可复用的旧 ImageItem 快照必须在主线程取好再带进后台。
        let reusableItems = AppState.shared.selectedFolderURL == folderURL ? AppState.shared.images : []
        // 1010需求：排序方式同样在主线程读取后带进后台
        let sortType = AppState.shared.sortType
        
        DispatchQueue.global(qos: .userInitiated).async {
            // 使用共享服务加载图片，保持原有的复用和排序行为
            let imageItems = ImageLoaderService.shared.loadImagesFromFolder(
                folderURL,
                shouldReuseItems: true,
                sortType: sortType,
                reusableItems: reusableItems
            )
            
            DispatchQueue.main.async {
                // P0-1 修复：统一走 AppState 的主线程写入接口，不再直接赋值 images。
                AppState.shared.setImages(imageItems)
                AppState.shared.selectedFolderURL = folderURL
                completion(imageItems)
            }
        }
    }
    
    // MARK: - NSWindowDelegate
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        print("Window close requested: \(sender.title)")
        
        // 检查关闭的是否是浏览器窗口
        if sender == browserWindow {
            // 检查是否有其他可见窗口
            let visibleWindows = NSApplication.shared.windows.filter { $0.isVisible }
            // 如果没有其他可见窗口，退出应用
            if visibleWindows.count <= 1 { // 只包含当前即将关闭的窗口
                NSApplication.shared.terminate(nil)
                return false // 阻止默认关闭行为，因为我们已经处理了退出
            }
        }
        // 默认允许关闭
        return true
    }
    
    // MARK: - 文件菜单功能
    
    func openImageFolder() {
        // 创建文件选择面板，允许选择文件夹和图片文件
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.title = "选择图片文件夹或图片文件"
        panel.prompt = "选择"
        
        // 设置允许的文件类型
        panel.allowedContentTypes = [
            UTType.jpeg,
            UTType.png,
            UTType.gif,
            UTType.bmp,
            UTType.tiff,
            UTType.webP
        ]
        
        // 显示面板并处理结果
        if panel.runModal() == .OK {
            if let url = panel.url {
                #if DEBUG
                print("Selected: \(url.path)")
                #endif
                
                // 检查选择的是文件夹还是图片文件
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        // 选择的是文件夹
                        AppState.shared.selectedFolderURL = url
                        NotificationManager.shared.openBrowserWindow(shouldReloadImages: true)
                    } else {
                        // 选择的是图片文件
                        NotificationManager.shared.openImageFile(url)
                    }
                }
            }
        }
    }
}