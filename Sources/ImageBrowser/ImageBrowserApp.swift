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
        print("Application activation policy set to .regular")
    }
    
    var body: some Scene {
        // 启动窗口
        WindowGroup {
            LaunchView()
                .onAppear {
                    onAppear()
                }
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
    
    // 监听通知
    func onAppear() {
        print("Setting up notification listeners in ImageBrowserApp")
        
        // 监听打开文件夹选择对话框的通知
        NotificationManager.shared.publisher(for: .openImageFolder)
            .sink { _ in
                print("Received openImageFolder notification")
                appDelegate.openImageFolder()
            }
            .store(in: &cancellables)
        
        NotificationManager.shared.publisher(for: .openBrowserWindow)
            .sink { notification in
                // 默认情况下需要重新加载图片，除非明确指定不需要
                let shouldReloadImages = (notification.userInfo?["shouldReloadImages"] as? Bool) ?? true
                appDelegate.openBrowserWindow(shouldReloadImages: shouldReloadImages)
            }
            .store(in: &cancellables)
        
        // 监听打开详情窗口的通知
        NotificationManager.shared.publisher(for: .openDetailWindow)
            .sink { notification in
                print("Received openDetailWindow notification")
                if let userInfo = notification.userInfo,
                   let imageItem = userInfo["imageItem"] as? ImageItem {
                    print("Setting selectedImageItem to: \(imageItem.name)")
                    AppState.shared.selectedImageItem = imageItem
                    print("Opening detail window for image: \(imageItem.name)")
                    
                    // 打开详情窗口
                    appDelegate.openDetailWindow(with: imageItem)
                } else {
                    print("Failed to extract imageItem from notification")
                }
            }
            .store(in: &cancellables)
        
        // 监听直接打开图片文件的通知
        NotificationManager.shared.publisher(for: .openImageFile)
            .sink { notification in
                print("Received openImageFile notification")
                if let userInfo = notification.userInfo,
                   let fileURL = userInfo["fileURL"] as? URL {
                    print("Opening image file: \(fileURL.path)")
                    appDelegate.openImageFile(fileURL)
                } else {
                    print("Failed to extract fileURL from notification")
                }
            }
            .store(in: &cancellables)
        
        // 监听显示启动窗口的通知
        NotificationManager.shared.publisher(for: .showLaunchWindow)
            .sink { _ in
                print("Opening launch window")
                appDelegate.openLaunchWindow()
            }
            .store(in: &cancellables)
        
        // 监听更新浏览器窗口标题的通知
        NotificationManager.shared.publisher(for: .updateBrowserWindowTitle)
            .sink { _ in
                print("Updating browser window title")
                appDelegate.updateBrowserWindowTitle()
            }
            .store(in: &cancellables)
        
        print("Notification listeners setup complete")
    }
    
    @State private var cancellables = Set<AnyCancellable>()
}

// AppDelegate 用于处理 macOS 12 的窗口管理
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var browserWindow: NSWindow?
    var detailWindow: NSWindow?
    
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
            print("Found file URL in AppleEvent: \(fileURL.path)")
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
                print("Processing command line argument: \(arg)")
                
                if ImageLoaderService.shared.isImageFile(fileURL) {
                    print("Opening image file from command line: \(fileURL.path)")
                    openImageFile(fileURL)
                    return
                }
            }
        }
        
        // 延迟显示启动窗口，给application(_:open:)方法处理时间
        // 如果应用是通过Open With启动的，application(_:open:)会在稍后被调用
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            // 检查是否有窗口已经显示
            let visibleWindows = NSApplication.shared.windows.filter { $0.isVisible }
            if visibleWindows.isEmpty {
                print("No windows visible after launch delay, showing launch window")
                self.openLaunchWindow()
            } else {
                print("Windows already visible, skipping launch window")
            }
        }
    }
    
    // 处理从Finder或其他应用打开图片文件
    func application(_ application: NSApplication, open urls: [URL]) {
        print("=== Application open URLs called ===")
        print("URLs: \(urls)")
        
        // 确保应用成为前台应用
        NSApp.activate(ignoringOtherApps: true)
        
        // 延迟处理，确保应用已经完全启动（采用PVApp的延迟策略）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.handleFileOpen(urls)
        }
    }
    
    // 统一的文件打开处理方法（借鉴PVApp的架构）
    private func handleFileOpen(_ urls: [URL]) {
        for url in urls {
            print("Processing URL: \(url.path)")
            
            // 检查文件类型
            let fileType = getFileType(url)
            
            switch fileType {
            case .file:
                if ImageLoaderService.shared.isImageFile(url) {
                    print("filetype: image, Opening image file: \(url.path)")
                    self.openImageFileWithRetry(url, attempt: 0)
                    return
                }
            case .directory:
                print("filetype: folder, Opening folder: \(url.path)")
                self.loadImagesFromFolder(url)
                self.openBrowserWindow(shouldReloadImages: false)
                return
            case .unknown:
                print("Unknown file type: \(url.path)")
            }
        }
    }
    
    // 带重试机制的图片文件打开方法
    private func openImageFileWithRetry(_ fileURL: URL, attempt: Int) {
        let maxRetryAttempts = 3
        guard attempt < maxRetryAttempts else {
            print("Max retry attempts reached for file: \(fileURL.path)")
            return
        }
        
        let delay = calculateDelay(for: attempt)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // 获取文件所在目录
            let folderURL = fileURL.deletingLastPathComponent()
            
            // 加载目录中的所有图片
            self.loadImagesFromFolder(folderURL)
            
            // 从已加载的图片列表中找到对应的图片项
            if let imageItem = AppState.shared.images.first(where: { $0.url.path == fileURL.path }) {
                AppState.shared.selectedImageItem = imageItem
                AppState.shared.browserWindowState.selectedImageID = imageItem.id
                
                // 隐藏其他窗口并打开详情窗口
                self.hideAllWindows()
                self.openDetailWindow(with: imageItem)
                
                // 确保应用成为前台应用
                NSApp.activate(ignoringOtherApps: true)
                print("Successfully opened image file: \(fileURL.path)")
            } else {
                print("Retry attempt \(attempt + 1) for file: \(fileURL.path)")
                self.openImageFileWithRetry(fileURL, attempt: attempt + 1)
            }
        }
    }
    
    // 文件类型判断（借鉴PVApp的方法）
    private func getFileType(_ url: URL) -> FileType {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .unknown
        }
        
        return isDirectory.boolValue ? .directory : .file
    }
    
    // 延迟计算（借鉴PVApp的策略）
    private func calculateDelay(for attempt: Int) -> Double {
        switch attempt {
        case 0:
            return 0.01 // 立即重试
        case 1:
            return 0.02  // 短暂延迟
        case 2:
            return 0.03 // 更长延迟
        default:
            return 0
        }
    }
    
    // 文件类型枚举
    private enum FileType {
        case file
        case directory
        case unknown
    }
    
    // 处理单个文件打开（备用方法）
    func application(_ application: NSApplication, openFile filename: String) -> Bool {
        print("=== Application openFile called ===")
        print("File path: \(filename)")
        
        let url = URL(fileURLWithPath: filename)
        
        // 确保应用成为前台应用
        NSApp.activate(ignoringOtherApps: true)
        
        // 使用统一的文件处理方法
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.handleFileOpen([url])
        }
        
        return true
    }
    
    // 处理Apple事件（用于"Open With"功能）
    @objc func handleAppleEvent(_ event: NSAppleEventDescriptor, with replyEvent: NSAppleEventDescriptor) {
        print("=== Handle Apple Event called ===")
        print("Event class: \(event.eventClass), event ID: \(event.eventID)")
        
        if event.eventClass == kCoreEventClass && event.eventID == kAEOpenDocuments {
            print("Open Documents event received")
            
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
    
    func openBrowserWindow(shouldReloadImages: Bool = false) {
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
        guard let window = browserWindow else { return }
        
        // 获取图片数量
        let imageCount = AppState.shared.images.count
        let title = imageCount > 0 ? "共 \(imageCount) 张图片" : "图片浏览器"
        
        window.title = title
    }
    
    func openDetailWindow(with imageItem: ImageItem) {
        // 隐藏其他窗口
        hideAllWindows()
        
        // 创建新的详情窗口
        let contentView = ImageDetailView(imageItem: imageItem)
        let hostingController = NSHostingController(rootView: contentView)
        
        // 使用固定尺寸，让ImageDetailView的缩放逻辑负责调整窗口大小
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 600),
            styleMask: [.titled,.fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.title = "\(imageItem.name)"
        window.titlebarAppearsTransparent = true
        // 设置标题栏背景色为透明
        window.titlebarSeparatorStyle = .none
        window.contentViewController = hostingController
        window.center()
        
        // 设置窗口层级，确保显示在其他窗口前面
        // window.level = .floating
        
        window.makeKeyAndOrderFront(nil)
        
        // 确保窗口成为键窗口，这对于回车键触发的窗口特别重要
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
        }
        
        // 启用窗口背景拖拽功能
        window.isMovableByWindowBackground = true
        
        detailWindow = window
    }
    
    func openLaunchWindow() {
        print("Opening launch window using AppKit")
        
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
            print("File is not an image: \(fileURL.path)")
            return
        }
        
        // 获取文件所在目录
        let folderURL = fileURL.deletingLastPathComponent()
        
        // 加载目录中的所有图片
        loadImagesFromFolder(folderURL)
        
        // 从已加载的图片列表中找到对应的图片项（使用URL路径比较）
        guard let imageItem = AppState.shared.images.first(where: { $0.url.path == fileURL.path }) else {
            print("Error: Could not find image in loaded list: \(fileURL.path)")
            print("Available images:")
            for img in AppState.shared.images {
                print("  - \(img.url.path)")
            }
            return
        }
        
        AppState.shared.selectedImageItem = imageItem
        // 同步设置列表页的选中状态
        AppState.shared.browserWindowState.selectedImageID = imageItem.id
        
        // 隐藏其他窗口并打开详情窗口
        hideAllWindows()
        openDetailWindow(with: imageItem)
        
        // 确保应用成为前台应用
        NSApp.activate(ignoringOtherApps: true)
    }
    

    
    private func loadImagesFromFolder(_ folderURL: URL) {
        // 使用共享服务加载图片，保持原有的复用和排序行为
        let imageItems = ImageLoaderService.shared.loadImagesFromFolder(folderURL, shouldReuseItems: true, sortType: .random)
        
        // 更新AppState中的图片列表
        AppState.shared.images = imageItems
        AppState.shared.selectedFolderURL = folderURL
    }
    
    // MARK: - NSWindowDelegate
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        print("Window close requested: \(sender.title)")
        
        // 检查关闭的是否是浏览器窗口
        if sender == browserWindow {
            print("Browser window is closing")
            
            // 检查是否有其他可见窗口
            let visibleWindows = NSApplication.shared.windows.filter { $0.isVisible }
            print("Visible windows count: \(visibleWindows.count)")
            
            // 如果没有其他可见窗口，退出应用
            if visibleWindows.count <= 1 { // 只包含当前即将关闭的窗口
                print("No other visible windows, exiting application")
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
                        NotificationManager.shared.openBrowserWindow()
                    } else {
                        // 选择的是图片文件
                        NotificationManager.shared.openImageFile(url)
                    }
                }
            }
        }
    }
}