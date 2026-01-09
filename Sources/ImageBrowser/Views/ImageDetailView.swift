import SwiftUI

// 自动播放相关常量
private enum AutoPlayConstants {
    static let totalPlayInterval: TimeInterval = 3.00 // 每张图片显示的总时间（秒）
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
        ImageActionService.shared.navigateToPreviousImageInDetail(
            viewModel: viewModel,
            stopPlayback: stopPlayback,
            isPlaying: isPlaying,
            togglePlayPause: togglePlayPause,
            updateWindowTitle: updateWindowTitle
        )
    }
    
    // 切换到下一张图片
    private func showNextImage(stopPlayback: Bool = true) {
        ImageActionService.shared.navigateToNextImageInDetail(
            viewModel: viewModel,
            stopPlayback: stopPlayback,
            isPlaying: isPlaying,
            togglePlayPause: togglePlayPause,
            updateWindowTitle: updateWindowTitle,
            resetProgress: {
                // 如果是自动播放模式，立即重置进度，避免闪现
                if !stopPlayback {
                    self.progress = 0.0
                }
            }
        )
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
        progress = 0.00
        
        // 使用一个计时器同时处理进度更新和图片切换
        autoPlayTimer = Timer.scheduledTimer(withTimeInterval: AutoPlayConstants.progressUpdateInterval, repeats: true) { _ in
            // 更新进度
            self.progress += AutoPlayConstants.progressUpdateInterval / AutoPlayConstants.totalPlayInterval // 每progressUpdateInterval秒增加totalPlayInterval的1/5
            
            // 检查是否达到总播放间隔
            if self.progress >= 0.98 {
                // 重置进度
                self.progress = 0.00
                
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
        NotificationManager.shared.post(
            name: .openBrowserWindow,
            userInfo: ["shouldReloadImages": false]
        )
    }
    
    // 删除当前图片
    private func deleteCurrentImage() {
        guard let imageItem = viewModel.imageItem else { return }
        
        ImageActionService.shared.showDeleteConfirmation(for: imageItem) { confirmed in
            if confirmed {
                self.deleteImageItem(imageItem)
            }
        }
    }
    
    // 执行删除图片操作
    private func deleteImageItem(_ imageItem: ImageItem) {
        ImageActionService.shared.deleteImageItemWithNavigation(imageItem, from: .detail) { success, nextImage, error in
            if success {
                DispatchQueue.main.async {
                    // 清理被删除图片的缓存
                    let cacheKey = imageItem.url.absoluteString as NSString
                    self.viewModel.imageCache.removeObject(forKey: cacheKey)
                    
                    if let nextImage = nextImage {
                        // 切换到下一张或上一张图片
                        self.viewModel.switchToImage(nextImage, shouldAdjustWindow: false)
                    } else {
                        // 如果没有图片了，关闭详情窗口并显示列表窗口
                        self.switchToBrowserView()
                    }
                    
                    // 更新窗口标题
                    self.updateWindowTitle()
                }
            } else if let error = error {
                print("删除失败: \(error.localizedDescription)")
            }
        }
    }
    
    // 打开图片所在目录
    private func openImageDirectory() {
        guard let imageItem = viewModel.imageItem else { return }
        
        ImageActionService.shared.openImageDirectory(for: imageItem)
    }
    
    private var windowTitle: String {
        guard let imageItem = viewModel.imageItem else { return "" }
        
        let maxTitleLength = 50
        var title = ""
        
        if let index = AppState.shared.images.firstIndex(of: imageItem) {
            let currentIndex = index + 1
            let totalCount = AppState.shared.images.count
            title = "\(currentIndex)/\(totalCount) \(imageItem.name)"
        } else {
            title = imageItem.name
        }
        
        // 统一处理长度限制
        if title.count > maxTitleLength {
            return String(title.prefix(maxTitleLength - 3)) + "..."
        }
        return title
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
                    .contrast(1.1)
                    .brightness(0.03)
                    .aspectRatio(contentMode: .fit)
                    .clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .edgesIgnoringSafeArea(.all)
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .foregroundColor(.gray)
                    Text("图片未找到")
                        .font(.system(size: 16))
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(0)
        .scaleEffect(scale)
        .onChange(of: viewModel.imageItem) { _ in
            scale = 1.01
            DispatchQueue.main.asyncAfter(deadline: .now() + AutoPlayConstants.animationDelay) {
                withAnimation(.easeOut(duration: 0.2)) {
                    scale = 1
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
        .onReceive(NotificationManager.shared.publisher(for: .scrollWheel)) { notification in
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
            UnifiedKeyboardResponder(
                keyboardContext: KeyboardActionService.createDetailKeyboardContext(
                    switchToBrowserView: switchToBrowserView,
                    deleteCurrentImage: deleteCurrentImage,
                    openImageDirectory: openImageDirectory,
                    showPreviousImage: { showPreviousImage() },
                    showNextImage: { showNextImage() },
                    togglePlayPause: togglePlayPause
                )
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
            // Circle()
            //     .stroke(Color.black.opacity(0.2), lineWidth: 2)
            //     .frame(width: 50, height: 50)
            
            // 进度圆圈
            Circle()
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.white.opacity(0.0), .white.opacity(1.0)]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    ),
                    style: StrokeStyle(
                        lineWidth: 2,
                        lineCap: .round
                    )
                )
                .frame(width: 50, height: 50)
                // .trim(from: 0.05, to: isPlaying ? progress : 0)
                // .rotationEffect(.degrees(-90))//从默认的3点钟方向转到12点钟方向
                .opacity(isPlaying ? 1.0 : 0.0)
                .rotationEffect(.degrees(isPlaying ? -90 + (progress * 360) : -90))
            
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