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
    
    // 用于存储通知观察者
    @State private var notificationObserver: NSObjectProtocol?
    @State private var cancellables = Set<AnyCancellable>()
    @State private var scrollToTopAction: (() -> Void)?
    
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
        .onChange(of: appState.images) { _ in
            // 当图片数量变化时，标题会自动更新
            // 发送通知更新窗口标题
            NotificationManager.shared.post(name: .updateBrowserWindowTitle)
        }
        .frame(minWidth: 1200, minHeight: 700)
        // .edgesIgnoringSafeArea(.top) // 可以将列表向上提一点,但是移动窗口时会激活图片ondrag
        .background(KeyboardHandler(
            onEnter: {
                // 回车键：切换到详情页
                if let selectedID = browserWindowState.selectedImageID,
                   let selectedImage = appState.images.first(where: { $0.id == selectedID }) {
                    NotificationManager.shared.showDetailWindow(with: selectedImage)
                }
            },
            onDelete: {
                // Backspace/Delete键：删除当前图片到回收站
                if let selectedID = browserWindowState.selectedImageID,
                   let selectedImage = appState.images.first(where: { $0.id == selectedID }) {
                    showDeleteConfirmation(for: selectedImage)
                }
            },
            onBackslash: {
                // 反斜杠键：打开图片所在目录
                if let selectedID = browserWindowState.selectedImageID,
                   let selectedImage = appState.images.first(where: { $0.id == selectedID }) {
                    NSWorkspace.shared.selectFile(selectedImage.url.path, inFileViewerRootedAtPath: "")
                }
            },
            onLeftArrow: {
                // 左箭头键：选择上一张图片
                guard !appState.images.isEmpty else { return }
                
                if let selectedID = browserWindowState.selectedImageID,
                   let currentIndex = appState.images.firstIndex(where: { $0.id == selectedID }) {
                    // 不再循环，如果已经是第一张图片则不处理
                    if currentIndex > 0 {
                        let previousIndex = currentIndex - 1
                        let previousImage = appState.images[previousIndex]
                        browserWindowState.selectedImageID = previousImage.id
                    }
                } else if let firstImage = appState.images.first {
                    // 如果没有选中的图片，选择第一张图片
                    browserWindowState.selectedImageID = firstImage.id
                }
            },
            onRightArrow: {
                // 右箭头键：选择下一张图片
                guard !appState.images.isEmpty else { return }
                
                if let selectedID = browserWindowState.selectedImageID,
                   let currentIndex = appState.images.firstIndex(where: { $0.id == selectedID }) {
                    // 不再循环，如果已经是最后一张图片则不处理
                    if currentIndex < appState.images.count - 1 {
                        let nextIndex = currentIndex + 1
                        let nextImage = appState.images[nextIndex]
                        browserWindowState.selectedImageID = nextImage.id
                    }
                } else if let firstImage = appState.images.first {
                    // 如果没有选中的图片，选择第一张图片
                    browserWindowState.selectedImageID = firstImage.id
                }
            }
        ))
        .onAppear {
            // 设置通知监听器
            setupNotificationListeners()
            
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
        // .onDisappear {
        //     // 清理通知监听器
        //     if let observer = notificationObserver {
        //         NotificationCenter.default.removeObserver(observer)
        //     }
        // }
    }
    
    private func setupNotificationListeners() {
        // 使用NotificationManager监听重新加载图片的通知
        NotificationManager.shared.publisher(for: .reloadImages)
            .sink { notification in
                if let userInfo = notification.userInfo,
                   let folderURL = userInfo["folderURL"] as? URL {
                    self.viewModel.loadImages(from: folderURL)
                } else if let folderURL = self.appState.selectedFolderURL {
                    self.viewModel.loadImages(from: folderURL)
                }
            }
            .store(in: &cancellables)
        
        // 监听打开浏览器窗口的通知，确保滚动到选中的图片
        NotificationManager.shared.publisher(for: .openBrowserWindow)
            .sink { _ in
                // 延迟一小段时间确保UI已更新，然后滚动到选中的图片
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    if let selectedID = self.browserWindowState.selectedImageID {
                        NotificationManager.shared.post(name: .imageSelectionChanged, userInfo: ["imageID": selectedID])
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    // 显示删除确认对话框
    private func showDeleteConfirmation(for imageItem: ImageItem) {
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
                    // 从应用状态中移除图片
                    AppState.shared.images.removeAll { $0.id == imageItem.id }
                    
                    // 如果删除的是当前选中的图片，清除选中状态
                    if self.browserWindowState.selectedImageID == imageItem.id {
                        self.browserWindowState.selectedImageID = nil
                    }
                    
                    // 发送通知更新窗口标题
                    NotificationManager.shared.post(name: .updateBrowserWindowTitle)
                }
            }
        }
    }
}

// 键盘处理器
struct KeyboardHandler: NSViewRepresentable {
    let onEnter: () -> Void
    let onDelete: () -> Void
    let onBackslash: () -> Void
    let onLeftArrow: () -> Void
    let onRightArrow: () -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = BrowserKeyboardView()
        view.setupActions(
            onEnter: onEnter,
            onDelete: onDelete,
            onBackslash: onBackslash,
            onLeftArrow: onLeftArrow,
            onRightArrow: onRightArrow
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

class BrowserKeyboardView: NSView {
    var onEnter: (() -> Void)?
    var onDelete: (() -> Void)?
    var onBackslash: (() -> Void)?
    var onLeftArrow: (() -> Void)?
    var onRightArrow: (() -> Void)?
    
    func setupActions(
        onEnter: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onBackslash: @escaping () -> Void,
        onLeftArrow: @escaping () -> Void,
        onRightArrow: @escaping () -> Void
    ) {
        self.onEnter = onEnter
        self.onDelete = onDelete
        self.onBackslash = onBackslash
        self.onLeftArrow = onLeftArrow
        self.onRightArrow = onRightArrow
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
        case 36: // 回车键
            onEnter?()
        case 51: // Backspace键
            onDelete?()
        case 117: // Delete键
            onDelete?()
        case 42: // 反斜杠键
            onBackslash?()
        case 123: // 左箭头键
            onLeftArrow?()
        case 124: // 右箭头键
            onRightArrow?()
        default:
            // 其他按键不处理
            super.keyDown(with: event)
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
                    proxy.scrollTo("TOP_ANCHOR", anchor: .top)
                }
            }
            .onChange(of: browserWindowState.selectedImageID) { selectedID in
                if let selectedID = selectedID {
                    // 不再发送全局通知，直接使用 SwiftUI 的状态管理
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
                NotificationManager.shared.showDetailWindow(with: imageItem)
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