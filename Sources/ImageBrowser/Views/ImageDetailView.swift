import SwiftUI

// 自动播放相关常量
private enum AutoPlayConstants {
    static let totalPlayInterval: TimeInterval = 3.00 // 每张图片显示的总时间（秒）
    static let progressUpdateInterval: TimeInterval = 0.05 // 进度条更新间隔（秒）
    static let animationDelay: TimeInterval = 0.1 // 动画延迟时间（秒）
}

struct ImageDetailView: View {
    // P0-3 修复：移除原先的默认值 `= ImageDetailViewModel()`，
    // 改由下方的 init 通过 StateObject 惰性持有，确保没有"提前构造"的旁路。
    @StateObject private var viewModel: ImageDetailViewModel

    // **问题 3 修复（第 3 步）**：详情页此前**没有观察 `AppState`**——
    // 它只读 `AppState.shared.images` 这个全局单例的属性，而这是一次普通读取，
    // **不会建立 SwiftUI 依赖**。于是 `.onChange(of: AppState.shared.images)`
    // 永远不会因为列表变化而触发（`.onChange` 是在**视图 body 重新求值时**比较新旧值的），
    // 只有 body 因别的原因重绘时才会顺带触发——实际唯一常见的原因就是"切换图片"。
    // 这就是"详情页标题里的数量不切图就不变"的根因。
    // 补上这一行观察后，列表每次变化都会让 body 重绘，`.onChange` 才真正生效。
    @ObservedObject private var appState = AppState.shared

    @State private var scale: CGFloat = 1.0
    @State private var isPlaying = false
    @State private var buttonScale: CGFloat = 1.0
    @State private var buttonOpacity: Double = 0.3
    @State private var autoPlayTimer: Timer?
    @State private var progress: Double = 0.0

    init(imageItem: ImageItem) {
        // P0-3 修复：原实现在这里直接 `let viewModel = ImageDetailViewModel(); viewModel.loadImage(imageItem)`，
        // 而 loadImage 会在调用线程上同步完成「读盘 + 解码 + 缩放 + 锐化 + 预加载前后各 2 张」。
        // 由于 AppDelegate.openDetailWindow 是「先构造 ImageDetailView、后创建 NSWindow」，
        // 这些重活全部发生在窗口存在之前，窗口要等解码结束才出现，打开大图时明显卡顿。
        //
        // 现在 init 只做两件轻量的事：
        //   1. 记下待加载的图片，真正的加载推迟到 onAppear 中异步进行；
        //   2. 把 ViewModel 交给 StateObject 惰性持有——wrappedValue 接收的是 autoclosure，
        //      这里不会立即构造 ImageDetailViewModel。
        _viewModel = StateObject(wrappedValue: ImageDetailViewModel())

        // 标记为首次打开，需要定位窗口
        _isFirstOpen = State(initialValue: true)

        // 待加载图片由 init 传入，在 onAppear 中触发异步加载
        self.initialImageItem = imageItem
    }

    /// 由 init 传入、等待在 `onAppear` 中开始异步加载的图片（P0-3 修复新增）
    private let initialImageItem: ImageItem

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

    /// 本视图所在详情窗口的**权威引用**（P1-14 修复）。
    ///
    /// 原实现用
    /// `NSApp.windows.first(where: { $0.contentViewController is NSHostingController<ImageDetailView> })`
    /// 反查自己的窗口。实测 `NSApp.windows` 中最旧的详情窗口排在最前（当时可见的反而在最后），
    /// 因此从第二个详情窗口起，该反查**必然**命中一个已隐藏的陈旧窗口，导致：
    ///   - 标题被写到看不见的陈旧窗口上（可见窗口的标题永远停留在建窗时的裸文件名）
    ///   - `switchToBrowserView()` 的 `orderOut` 打在错窗口上
    ///
    /// 详情窗口本来就由 `AppDelegate` 持有（`detailWindow`），直接取那个引用即可，
    /// 不需要任何按类型/按层级的猜测。
    private var hostWindow: NSWindow? {
        // 首选：AppDelegate 持有的权威引用
        if let window = (NSApp.delegate as? AppDelegate)?.detailWindow {
            return window
        }
        // 兜底：按类型反查。P1-6 之后详情窗口已复用为单例，候选唯一，
        // 因此不会再出现原先"必然命中最早那个陈旧窗口"的问题。
        return NSApp.windows.first {
            $0.contentViewController is NSHostingController<ImageDetailView>
        }
    }

    // 切换到列表页
    private func switchToBrowserView() {
        // 停止自动播放和进度计时器
        if isPlaying {
            togglePlayPause()
        }

        // 隐藏当前窗口
        // P1-14 修复：改为直接使用 AppDelegate 持有的详情窗口引用
        hostWindow?.orderOut(nil)

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
        // P0-4：删除了已无意义的 `from: .detail` 参数——原实现里两种视图类型
        // 走的是完全相同的导航逻辑，差异只在下面这段对 nextImage 为 nil 的处理。
        ImageActionService.shared.deleteImageItemWithNavigation(imageItem) { success, nextImage, error in
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

        if let index = appState.images.firstIndex(of: imageItem) {
            let currentIndex = index + 1
            // 第 1 步优化：装填期间分母显示"总量（已载入 N）"，装填结束后只显示总量。
            // 口径与列表页共用 `AppState` 的同一组属性，避免两处各写一遍导致不一致。
            title = "\(currentIndex)/\(appState.displayTotalCount)\(appState.loadingCountSuffix) \(imageItem.name)"
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
            // P1-14 修复：直接写 AppDelegate 持有的详情窗口，不再按类型反查
            // （反查会命中最早的陈旧窗口，见 hostWindow 的说明）
            self.hostWindow?.title = self.windowTitle
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
            } else if viewModel.isLoadingImage {
                // P0-3 修复：解码已异步化，"fullImage == nil" 不再等同于加载失败。
                // 必须单独区分「加载中」与「确实加载失败」，否则异步化之后
                // 每次切图/首次打开都会先闪一下误导性的"图片未找到"。
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // P0-3 修复：图片加载由 init 移到这里触发，此时解码已异步化，不会阻塞窗口显示。
            // 加 nil 判断是为了保证只加载一次——onAppear 可能因窗口重新显示等原因再次触发，
            // 而重复加载会白白丢弃用户当前的浏览位置。
            if viewModel.imageItem == nil {
                viewModel.loadImage(initialImageItem)
            }

            // 初始设置窗口标题
            // 注意顺序：必须在上面的 loadImage 之后，因为窗口标题依赖 viewModel.imageItem，
            // 而 imageItem 是在 loadImage 中同步赋值的。
            updateWindowTitle()

            // 首次定位窗口。
            //
            // 注意：详情窗口的尺寸现在主要由 `AppDelegate.openDetailWindow` 在打开时
            // 显式设定（P1-6 回归修复），这里只作为兜底再应用一次。
            // 保留它的价值在于：此刻窗口已经可见/成为 key，`NSScreen.main` 必然是该窗口
            // 所在的屏幕，可用来自我校正；两处用的是同一个尺寸计算函数，结果一致、不会打架。
            if isFirstOpen {
                // P1-14 修复：不再用「keyWindow → 类型反查 → mainWindow」三重猜测定位窗口，
                // 直接使用 AppDelegate 持有的详情窗口引用（hostWindow 内置兜底）。
                if let window = hostWindow {
                    // 延迟一点时间确保窗口完全初始化
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                        self.adjustWindowSizeForImage(window: window)
                    }
                }

                isFirstOpen = false // 标记为已定位
            }
        }
        .onChange(of: appState.images) { _ in
            // 图片列表变化（分批装填推进 / 删除 / 重排）→ 刷新标题。
            // **问题 3 修复**：原先这里写的是 `AppState.shared.images`，而本视图没有观察
            // `AppState`，导致这个闭包几乎永不触发。现在本视图已 `@ObservedObject appState`，
            // body 会随列表变化重绘，`.onChange` 才真正生效。
            updateWindowTitle()
        }
        .onChange(of: appState.isBatchFilling) { _ in
            // 装填"结束"这一刻不伴随 `images` 变化，必须单独订阅，
            // 否则标题里的"（已载入 N）"会一直留着。
            updateWindowTitle()
        }
        .onChange(of: appState.loadTotalCount) { _ in
            // 总量确定的那一刻（列表还是空的）也要刷一次标题。
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
