import SwiftUI
import AppKit
import Combine

struct ImageBrowserView: View {
    @StateObject private var viewModel = ImageBrowserViewModel()
    @ObservedObject private var browserWindowState = AppState.shared.browserWindowState
    @ObservedObject private var appState = AppState.shared
    
    // 布局计算器实例
    private let layoutCalculator = LayoutCalculatorOpt()
    @State private var hasReceivedGeometry = false
    
    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                loadingView
            } else if let errorMessage = viewModel.errorMessage {
                errorView(message: errorMessage)
            } else if appState.images.isEmpty {
                emptyView
            } else {
                imageGridView
            }
        }
        .navigationTitle(appState.images.isEmpty ? "图片浏览器" : "共 \(appState.images.count) 张图片")
        // P1-14 修复：原先在这里 `.onChange(of: appState.images)` 发 `.updateBrowserWindowTitle`
        // 通知来刷新列表窗口标题。该通道已由 AppDelegate 直接订阅 `AppState.shared.$images`
        // 取代——单一数据源，不会再和删除路径重复触发。
        .frame(minWidth: 1200, minHeight: 700)
        // 1010需求：排序按钮，**只出现在列表页**，位于**左下角**（播放按钮在详情页的右下角，
        // 这里取其镜像位置）。
        //
        // 注意它挂在最外层 VStack 的 overlay 上，因此位于 `ImageGridView` 的
        // `.drawingGroup()` **之外**——否则会被离屏渲染吞掉、点不到。
        .overlay(alignment: .bottomLeading) {
            // 1010需求：排序选择器，只出现在列表页，位于**左下角**（播放按钮在详情页的右下角，
            // 这里取其镜像位置）。三个按钮竖列，无弹层；外观参数见 SortModeSelector。
            SortModeSelector(sortType: $appState.sortType)
                .padding(.leading, 20)
                .padding(.bottom, 20)
        }
        // .edgesIgnoringSafeArea(.top) // 可以将列表向上提一点,但是移动窗口时会激活图片ondrag
        .background(UnifiedKeyboardResponder(
            keyboardContext: KeyboardActionService.createBrowserKeyboardContext(
                appState: appState,
                browserWindowState: browserWindowState,
                showDeleteConfirmation: showDeleteConfirmation
            )
        ))
        .onAppear {
            // 如果已经有选中的文件夹，则加载图片
            if let folderURL = appState.selectedFolderURL {
                viewModel.loadImages(from: folderURL)
            }
        }
        .onChange(of: appState.selectedFolderURL) { newFolderURL in
            // 当选择的文件夹发生变化时，重新加载图片
            if let folderURL = newFolderURL {
                viewModel.loadImages(from: folderURL)
            }
        }
        // P0-2 修复：通知订阅改用 `.onReceive`，不再用 `onAppear` + `@State cancellables`。
        //
        // 原写法的两个问题：
        //   1. **重复订阅**：`setupNotificationListeners()` 每次 `onAppear` 都新建一个
        //      `sink` 并追加进 `cancellables`。本应用频繁用 `hideAllWindows()`
        //      (`orderOut`) / `makeKeyAndOrderFront` 切换窗口，`onAppear` 可能多次触发，
        //      于是同一条 `.reloadImages` 通知会被处理 N 次，造成重复加载。
        //   2. **永不释放**：负责取消订阅的 `onDisappear` 整块被注释掉，订阅随窗口一直存在。
        //
        // `.onReceive` 的订阅生命周期由 SwiftUI 绑定到视图自身：不会累积，
        // 也不需要手动 `store` / `cancel`，因此从结构上消除了这两个问题。
        .onReceive(NotificationManager.shared.publisher(for: .reloadImages)) { notification in
            if let userInfo = notification.userInfo,
               let folderURL = userInfo["folderURL"] as? URL {
                viewModel.loadImages(from: folderURL)
            } else if let folderURL = appState.selectedFolderURL {
                viewModel.loadImages(from: folderURL)
            }
        }
    }
    
    // P0-2 修复：`setupNotificationListeners()` 已删除，
    // `.reloadImages` 的订阅改用体上的 `.onReceive`（见 body），
    // 避免 `onAppear` 每次触发都追加一个永不释放的订阅。
    
    // 显示删除确认对话框
    private func showDeleteConfirmation(for imageItem: ImageItem) {
        ImageActionService.shared.showDeleteConfirmation(for: imageItem) { confirmed in
            if confirmed {
                self.deleteImageItem(imageItem)
            }
        }
    }
    
    // 执行删除图片操作
    private func deleteImageItem(_ imageItem: ImageItem) {
        // P0-4：删除了已无意义的 `from: .browser` 参数——原实现里两种视图类型
        // 走的是完全相同的导航逻辑，只有调用方对 nil 的处理不同。
        ImageActionService.shared.deleteImageItemWithNavigation(imageItem) { success, nextImage, error in
            if let error = error {
                print("删除失败: \(error.localizedDescription)")
            }
            // 删除后的导航逻辑已经在 ImageActionService 中处理
        }
    }
}

struct ImageItemView: View, Equatable {
    @ObservedObject var imageItem: ImageItem
    let size: CGSize
    let isSelected: Bool 
    private let onSelectionChange: (Bool) -> Void
    private let onDoubleTap: () -> Void
    
    // 实现 Equatable 协议，只比较关键属性
    static func == (lhs: ImageItemView, rhs: ImageItemView) -> Bool {
        lhs.imageItem.id == rhs.imageItem.id && 
        lhs.isSelected == rhs.isSelected &&
        lhs.size == rhs.size
    }
    
    init(imageItem: ImageItem, size: CGSize, isSelected: Bool, onSelectionChange: @escaping (Bool) -> Void, onDoubleTap: @escaping () -> Void) {
        self.imageItem = imageItem
        self.size = size
        self.isSelected = isSelected
        self.onSelectionChange = onSelectionChange
        self.onDoubleTap = onDoubleTap
    }
    
    var body: some View {
        Group {
            if let thumbnail = imageItem.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                    )
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .cornerRadius(4)
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .inset(by: 2)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 4)
        )
        .simultaneousGesture(
            TapGesture(count: 1)
                .onEnded { _ in
                    if !isSelected {
                        onSelectionChange(true)
                    }
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { _ in
                    onDoubleTap()
                }
        )
        .onDrag {
            // 拖拽功能：提供文件URL
            NSItemProvider(item: imageItem.url as NSURL, typeIdentifier: "public.file-url")
        }
    }
}

// MARK: - 提取的视图方法
private extension ImageBrowserView {
    
    var loadingView: some View {
        ProgressView("加载中...")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    func errorView(message: String) -> some View {
        VStack {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    var emptyView: some View {
        Text("没有找到图片")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    var imageGridView: some View {
        ImageGridView(
            appState: appState,
            browserWindowState: browserWindowState,
            layoutCalculator: layoutCalculator,
            hasReceivedGeometry: $hasReceivedGeometry
        )
    }
}

// MARK: - ImageGridView 独立组件
struct ImageGridView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var browserWindowState: BrowserWindowState
    let layoutCalculator: LayoutCalculatorOpt
    @Binding var hasReceivedGeometry: Bool
    
    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    // 添加顶部锚点
                    Color.clear
                        .frame(height: 1)
                        .id("TOP_ANCHOR")
                    
                    imageGridContent(geometry: geometry)
                        .padding(.horizontal, 10)
                        .padding(.vertical, -10)//将列表整体向上移动10像素
                }
                .onAppear {
                    hasReceivedGeometry = true
                }
                .onChange(of: geometry.size) { _ in
                    hasReceivedGeometry = true
                }
                // 监听返回顶部的事件
                .onReceive(NotificationManager.shared.publisher(for: .scrollToTop)) { _ in
                    // 延迟一小段时间确保UI已更新，然后滚动到顶部
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        print("滚动到顶部通知")
                        proxy.scrollTo("TOP_ANCHOR", anchor: .top)
                    }   
                }
            }
            .onChange(of: browserWindowState.selectedImageID) { selectedID in
                if let selectedID = selectedID {
                    // 不再发送全局通知，直接使用 SwiftUI 的状态管理
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        // withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo(selectedID, anchor: UnitPoint.center)
                        // }
                    }
                }
            }
        }
    }
    
    private func imageGridContent(geometry: GeometryProxy) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            // 将所有图片作为一个目录组处理
            let directoryGroup = DirectoryGroup(name: "Images", images: appState.images)
            let rows = layoutCalculator.getFixedGridRows(
                for: directoryGroup,
                availableWidth: geometry.size.width,
                hasReceivedGeometry: hasReceivedGeometry
            )
            
            ForEach(rows, id: \.images.first?.id) { row in
                imageRow(row: row)
            }
        }
        .drawingGroup()
    }
    
    private func imageRow(row: FixedGridRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(row.images.enumerated()), id: \.element.id) { index, imageItem in
                imageItemView(row: row, index: index, imageItem: imageItem)
            }
            
            Spacer(minLength: 0)
        }
    }
    
    private func imageItemView(row: FixedGridRow, index: Int, imageItem: ImageItem) -> some View {
        ImageItemView(
            imageItem: imageItem,
            size: row.imageSizes[index],
            isSelected: browserWindowState.selectedImageID == imageItem.id,
            onSelectionChange: { isSelected in
                if isSelected {
                    browserWindowState.selectedImageID = imageItem.id
                }
            },
            onDoubleTap: {
                NotificationManager.shared.openDetailWindow(with: imageItem)
            }
        )
        .id(imageItem.id)
    }
}

struct ImageBrowserView_Previews: PreviewProvider {
    static var previews: some View {
        ImageBrowserView()
    }
}