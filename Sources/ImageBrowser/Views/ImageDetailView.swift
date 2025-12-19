import SwiftUI

// 自动播放相关常量
private enum AutoPlayConstants {
    static let totalPlayInterval: TimeInterval = 3.0 // 每张图片显示的总时间（秒）
    static let progressUpdateInterval: TimeInterval = 0.05 // 进度条更新间隔（秒）
    static let animationDelay: TimeInterval = 0.1 // 动画延迟时间（秒）
}

struct ImageDetailView: View {
    @StateObject private var viewModel = ImageDetailViewModel()
    @State private var scale: CGFloat = 1.0
    @State private var isPlaying = false
    @State private var buttonScale: CGFloat = 1.0
    @State private var buttonOpacity: Double = 0.3
    @State private var autoPlayTimer: Timer?
    @State private var progress: Double = 0.0
    
    init(imageItem: ImageItem) {
        // 创建ViewModel并加载图片
        let viewModel = ImageDetailViewModel()
        viewModel.loadImage(imageItem)
        _viewModel = StateObject(wrappedValue: viewModel)
        
        // 标记为首次打开，需要定位窗口
        _isFirstOpen = State(initialValue: true)
    }
    
    @State private var isFirstOpen: Bool
    
    // 切换到上一张图片
    private func showPreviousImage(stopPlayback: Bool = true) {
        // 如果正在播放且需要停止，停止自动播放
        if stopPlayback && isPlaying {
            togglePlayPause()
        }
        
        guard let currentImageItem = viewModel.imageItem,
              let currentIndex = AppState.shared.images.firstIndex(of: currentImageItem),
              !AppState.shared.images.isEmpty else { return }
        
        // 取消循环浏览：如果是第一张图片，则不进行切换
        if currentIndex == 0 {
            print("已经是第一张图片，无法继续向前浏览")
            return
        }
        
        let previousIndex = currentIndex - 1
        let previousImage = AppState.shared.images[previousIndex]
        
        // 优化：先更新列表页选中状态，再切换图片
        AppState.shared.browserWindowState.selectedImageID = previousImage.id
        
        // 使用新的切换方法，自动管理缓存
        viewModel.switchToImage(previousImage, shouldAdjustWindow: false)
        
        // 异步更新窗口标题，避免阻塞切换
        DispatchQueue.main.async {
            self.updateWindowTitle()
        }
    }
    
    // 切换到下一张图片
    private func showNextImage(stopPlayback: Bool = true) {
        // 如果正在播放且需要停止，停止自动播放
        if stopPlayback && isPlaying {
            togglePlayPause()
        }
        
        guard let currentImageItem = viewModel.imageItem,
              let currentIndex = AppState.shared.images.firstIndex(of: currentImageItem),
              !AppState.shared.images.isEmpty else { return }
        
        // 循环浏览：如果是最后一张图片，则跳转到第一张
        let nextIndex: Int
        if currentIndex == AppState.shared.images.count - 1 {
            nextIndex = 0
            print("到底了 = \(currentIndex)")
        } else {
            nextIndex = currentIndex + 1
        }
        
        let nextImage = AppState.shared.images[nextIndex]
        
        // 优化：先更新列表页选中状态，再切换图片
        AppState.shared.browserWindowState.selectedImageID = nextImage.id
        
        // 使用新的切换方法，自动管理缓存
        viewModel.switchToImage(nextImage, shouldAdjustWindow: false)
        
        // 异步更新窗口标题，避免阻塞切换
        DispatchQueue.main.async {
            self.updateWindowTitle()
        }
    }
    
    // 切换播放/暂停状态
    private func togglePlayPause() {
        isPlaying.toggle()
        
        if isPlaying {
            // 开始自动播放（包含进度更新）
            startAutoPlay()
        } else {
            // 停止自动播放
            stopAutoPlay()
        }
    }
    
    // 开始自动播放
    private func startAutoPlay() {
        // 重置进度
        progress = 0.0
        
        // 使用一个计时器同时处理进度更新和图片切换
        autoPlayTimer = Timer.scheduledTimer(withTimeInterval: AutoPlayConstants.progressUpdateInterval, repeats: true) { _ in
            // 更新进度
            self.progress += AutoPlayConstants.progressUpdateInterval / AutoPlayConstants.totalPlayInterval // 每progressUpdateInterval秒增加totalPlayInterval的1/5
            
            // 检查是否达到总播放间隔
        if self.progress >= 1.0 {
            // 重置进度
            self.progress = 0.0
            
            // 切换到下一张图片，不停止自动播放
            self.showNextImage(stopPlayback: false)
        }
        }
    }
    
    // 停止自动播放
    private func stopAutoPlay() {
        autoPlayTimer?.invalidate()
        autoPlayTimer = nil
        progress = 0.0 // 重置进度
    }
    
    // 切换到列表页
    private func switchToBrowserView() {
        // 停止自动播放和进度计时器
        if isPlaying {
            togglePlayPause()
        }
        
        // 隐藏当前窗口
        if let window = NSApp.windows.first(where: { $0.contentViewController is NSHostingController<ImageDetailView> }) {
            window.orderOut(nil)
        }
        
        // 显示列表窗口但不重新加载图片
        NotificationCenter.default.post(
            name: .openBrowserWindow,
            object: nil,
            userInfo: ["shouldReloadImages": false]
        )
    }
    
    // 删除当前图片
    private func deleteCurrentImage() {
        guard let imageItem = viewModel.imageItem else { return }
        
        // 显示确认删除弹窗
        let alert = NSAlert()
        alert.messageText = "确认删除"
        alert.informativeText = "确定要将图片 \"\(imageItem.name)\" 移动到回收站吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        
        // 显示弹窗并处理用户选择
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    // 用户确认删除
                    self.deleteImageItem(imageItem)
                }
            }
        }
    }
    
    // 执行删除图片操作
    private func deleteImageItem(_ imageItem: ImageItem) {
        // 将文件移动到回收站
        NSWorkspace.shared.recycle([imageItem.url]) { urls, error in
            if let error = error {
                // 删除失败，显示错误信息
                DispatchQueue.main.async {
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "删除失败"
                    errorAlert.informativeText = "无法删除图片：\(error.localizedDescription)"
                    errorAlert.alertStyle = .critical
                    errorAlert.addButton(withTitle: "确定")
                    errorAlert.runModal()
                }
            } else {
                // 删除成功，更新UI
                DispatchQueue.main.async {
                    // 先获取被删除图片的索引，然后再从列表中移除
                    let deletedIndex = AppState.shared.images.firstIndex(of: imageItem)
                    
                    // 从应用状态中移除图片
                    AppState.shared.images.removeAll { $0.id == imageItem.id }
                    
                    // 清理被删除图片的缓存
                    let cacheKey = imageItem.url.absoluteString as NSString
                    self.viewModel.imageCache.removeObject(forKey: cacheKey)
                    
                    // 如果删除后还有图片，显示下一张或上一张
                    if !AppState.shared.images.isEmpty {
                        // 使用之前获取的索引来决定显示哪张图片
                        if let index = deletedIndex {
                            if index < AppState.shared.images.count {
                                // 显示下一张（原来位置的图片）
                                let nextImage = AppState.shared.images[index]
                                self.viewModel.switchToImage(nextImage, shouldAdjustWindow: false)
                            } else {
                                // 如果删除的是最后一张，显示上一张
                                let previousImage = AppState.shared.images[index - 1]
                                self.viewModel.switchToImage(previousImage, shouldAdjustWindow: false)
                            }
                        } else {
                            // 如果无法获取索引，显示第一张图片
                            if let firstImage = AppState.shared.images.first {
                                self.viewModel.switchToImage(firstImage, shouldAdjustWindow: false)
                            }
                        }
                    } else {
                        // 如果没有图片了，关闭详情窗口并显示列表窗口
                        self.switchToBrowserView()
                    }
                    
                    // 更新窗口标题
                    self.updateWindowTitle()
                }
            }
        }
    }
    
    // 打开图片所在目录
    private func openImageDirectory() {
        guard let imageItem = viewModel.imageItem else { return }
        
        // 使用NSWorkspace打开文件所在的目录并选中文件
        NSWorkspace.shared.selectFile(imageItem.url.path, inFileViewerRootedAtPath: "")
    }
    
    private var windowTitle: String {
        guard let imageItem = viewModel.imageItem else { return "" }
        
        if let index = AppState.shared.images.firstIndex(of: imageItem) {
            let currentIndex = index + 1
            let totalCount = AppState.shared.images.count
            return "\(currentIndex)/\(totalCount) \(imageItem.name)"
        } else {
            return imageItem.name
        }
    }
    
    private func updateWindowTitle() {
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.contentViewController is NSHostingController<ImageDetailView> }) {
                window.title = windowTitle
            }
        }
    }
    
    // 简化后的窗口调整方法，调用ViewModel的逻辑
    private func adjustWindowSizeForImage(window: NSWindow) {
        guard let imageItem = viewModel.imageItem else { return }
        
        // 调用ViewModel的窗口调整逻辑
        viewModel.adjustWindowSizeForImage(window: window, imageItem: imageItem)
    }
    
    var body: some View {
        Group {
            if let image = viewModel.fullImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .contrast(1.2)
                    .brightness(0.02)
                    .aspectRatio(contentMode: .fit)
                    .clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .edgesIgnoringSafeArea(.all)
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .foregroundColor(.gray)
                    Text(" ")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(0)
        .scaleEffect(scale)
        .onChange(of: viewModel.imageItem) { _ in
            scale = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + AutoPlayConstants.animationDelay) {
                withAnimation(.easeOut(duration: 0.2)) {
                    scale = 1.005
                }
            }
        }
        .onAppear {
            // 初始设置窗口标题
            updateWindowTitle()
            
            // 只在首次打开时调整窗口大小和位置
            if isFirstOpen {
                // 使用多种方式尝试获取窗口
                var targetWindow: NSWindow?
                
                // 方法1: 尝试使用keyWindow
                if let keyWindow = NSApp.keyWindow {
                    targetWindow = keyWindow
                }
                // 方法2: 查找最新创建的包含ImageDetailView的窗口
                else if let window = NSApp.windows.last(where: { $0.contentViewController is NSHostingController<ImageDetailView> }) {
                    targetWindow = window
                }
                // 方法3: 查找主窗口
                else if let mainWindow = NSApp.mainWindow {
                    targetWindow = mainWindow
                }
                
                if let window = targetWindow {
                    // 延迟一点时间确保窗口完全初始化
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                        self.adjustWindowSizeForImage(window: window)
                    }
                }
                
                isFirstOpen = false // 标记为已定位
            }
        }
        .onChange(of: AppState.shared.images) { _ in
            // 当图片列表加载完成后，更新窗口标题
            print("Images list changed, count: \(AppState.shared.images.count)")
            updateWindowTitle()
        }
        .frame(minWidth: 50, minHeight: 50)
        .edgesIgnoringSafeArea([.top, .leading, .trailing])
        .onTapGesture(count: 2) {
            // 双击隐藏单页窗口并显示列表窗口
            print("Double-tap detected on detail view, hiding detail window and opening browser window")
            
            // 调用switchToBrowserView方法，确保停止自动播放
            switchToBrowserView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrollWheel)) { notification in
            // 处理鼠标滚轮事件
            if let event = notification.object as? NSEvent {
                // 如果正在播放，滚轮操作暂停播放
                if isPlaying {
                    togglePlayPause()
                }
                
                if event.deltaY > 0 {
                    // 向上滚动，显示上一张图片
                    showPreviousImage()
                } else if event.deltaY < 0 {
                    // 向下滚动，显示下一张图片
                    showNextImage()
                }
            }
        }
        .overlay(
            // 播放/暂停按钮
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    PlayPauseButton(
                        isPlaying: isPlaying,
                        buttonScale: buttonScale,
                        buttonOpacity: buttonOpacity,
                        progress: progress,
                        onToggle: togglePlayPause,
                        onHover: { isHovering in
                            buttonOpacity = isHovering ? 0.9 : 0.3
                        },
                        onPress: {
                            buttonScale = 0.9
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                withAnimation(.linear(duration: 0.1)) {
                                    buttonScale = 1.0
                                }
                            }
                        }
                    )
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                }
            }
        )
        .onDisappear {
            // 视图消失时停止自动播放
            stopAutoPlay()
        }
        .background(
            KeyboardResponder(
                onSpace: { togglePlayPause() },
                onLeftArrow: { showPreviousImage() }, // 使用默认参数，停止自动播放
                onRightArrow: { showNextImage() }, // 使用默认参数，停止自动播放
                onReturn: { switchToBrowserView() },
                onDelete: { deleteCurrentImage() },
                onBackslash: { openImageDirectory() }
            )
        )
    }
}

struct PlayPauseButton: View {
    let isPlaying: Bool
    let buttonScale: CGFloat
    let buttonOpacity: Double
    let progress: Double
    let onToggle: () -> Void
    let onHover: (Bool) -> Void
    let onPress: () -> Void
    
    var body: some View {
        ZStack {
            // 背景圆圈进度条
            Circle()
                .stroke(Color.black.opacity(0.3), lineWidth: 2)
                .frame(width: 50, height: 50)
            
            // 进度圆圈
            Circle()
                .trim(from: 0, to: isPlaying ? progress : 0)
                .stroke(
                    Color.white,
                    style: StrokeStyle(
                        lineWidth: 2,
                        lineCap: .round
                    )
                )
                .frame(width: 50, height: 50)
                .rotationEffect(.degrees(-90))//从默认的3点钟方向转到12点钟方向
                .animation(isPlaying ? .linear(duration: AutoPlayConstants.progressUpdateInterval) : .none, value: progress)
            
            Button(action: {
                onPress()
                onToggle()
            }) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30))
                    .frame(width: 50, height: 50)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.3))
                    )
            }
        }
        .scaleEffect(buttonScale)
        .opacity(buttonOpacity)
        .onHover { isHovering in
            onHover(isHovering)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ImageDetailView_Previews: PreviewProvider {
    static var previews: some View {
        ImageDetailView(imageItem: ImageItem(url: URL(fileURLWithPath: "/tmp/sample.jpg")))
    }
}

// 键盘事件响应器
struct KeyboardResponder: NSViewRepresentable {
    let onSpace: () -> Void
    let onLeftArrow: () -> Void
    let onRightArrow: () -> Void
    let onReturn: () -> Void
    let onDelete: () -> Void
    let onBackslash: () -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = KeyboardView()
        view.setupActions(
            onSpace: onSpace,
            onLeftArrow: onLeftArrow,
            onRightArrow: onRightArrow,
            onReturn: onReturn,
            onDelete: onDelete,
            onBackslash: onBackslash
        )
        
        // 使视图成为第一响应者
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // 不需要更新
    }
}

class KeyboardView: NSView {
    var onSpace: (() -> Void)?
    var onLeftArrow: (() -> Void)?
    var onRightArrow: (() -> Void)?
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?
    var onBackslash: (() -> Void)?
    
    func setupActions(
        onSpace: @escaping () -> Void,
        onLeftArrow: @escaping () -> Void,
        onRightArrow: @escaping () -> Void,
        onReturn: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onBackslash: @escaping () -> Void
    ) {
        self.onSpace = onSpace
        self.onLeftArrow = onLeftArrow
        self.onRightArrow = onRightArrow
        self.onReturn = onReturn
        self.onDelete = onDelete
        self.onBackslash = onBackslash
    }
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override func keyDown(with event: NSEvent) {
        // 检查应用是否在前台，如果不是则忽略键盘事件
        guard NSApplication.shared.isActive else {
            super.keyDown(with: event)
            return
        }
        
        switch event.keyCode {
        case 49: // 空格键
            onSpace?()
        case 123: // 左箭头键
            onLeftArrow?()
        case 124: // 右箭头键
            onRightArrow?()
        case 36: // 回车键
            onReturn?()
        case 51: // Delete键
            onDelete?()
        case 117: // Delete键（向前删除）
            onDelete?()
        case 42: // 反斜杠键
            onBackslash?()
        default:
            // 其他按键不处理
            super.keyDown(with: event)
        }
    }
}
