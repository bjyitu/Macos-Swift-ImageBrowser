import SwiftUI
import AppKit

struct ImageBrowserView: View {
    @StateObject private var viewModel = ImageBrowserViewModel()
    @ObservedObject private var browserWindowState = AppState.shared.browserWindowState
    @ObservedObject private var appState = AppState.shared
    
    // 布局计算器实例
    private let layoutCalculator = LayoutCalculatorOpt()
    @State private var hasReceivedGeometry = false
    
    // 用于存储通知观察者
    @State private var notificationObserver: NSObjectProtocol?
    
    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = viewModel.errorMessage {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.images.isEmpty {
                Text("没有找到图片")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    GeometryReader { geometry in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                // 将所有图片作为一个目录组处理
                                let directoryGroup = DirectoryGroup(name: "Images", images: appState.images)
                                let rows = layoutCalculator.getFixedGridRows(
                                    for: directoryGroup,
                                    availableWidth: geometry.size.width,
                                    hasReceivedGeometry: hasReceivedGeometry
                                )
                                
                                ForEach(rows, id: \.images.first?.id) { row in
                                    HStack(alignment: .top, spacing: 10) {
                                        ForEach(Array(row.images.enumerated()), id: \.element.id) { index, imageItem in
                                            ImageItemView(
                                                imageItem: imageItem,
                                                size: row.imageSizes[index],
                                                isSelected: browserWindowState.selectedImageID == imageItem.id,
                                                onSelectionChange: { isSelected in
                                                    if isSelected {
                                                        browserWindowState.selectedImageID = imageItem.id
                                                        // 发送通知，只通知选中状态变化
                                                        NotificationCenter.default.post(name: .imageSelectionChanged, object: imageItem.id)
                                                    }
                                                },
                                                onDoubleTap: {
                                                    AppState.shared.showDetailWindow(with: imageItem)
                                                }
                                            )
                                            .id(imageItem.id)
                                        }
                                        
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                            .drawingGroup()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                        }
                        .onAppear {
                            hasReceivedGeometry = true
                        }
                        .onChange(of: geometry.size) { _ in
                            hasReceivedGeometry = true
                        }
                    }
                    .onAppear {
                        // if let selectedID = browserWindowState.selectedImageID {
                        //     DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        //         withAnimation(.easeOut(duration: 0.2)) {
                        //             proxy.scrollTo(selectedID, anchor: UnitPoint.center)
                        //         }
                        //     }
                        // }
                    }
                    .onChange(of: browserWindowState.selectedImageID) { selectedID in
                        if let selectedID = selectedID {
                            // 发送通知，通知所有ImageItemView更新选中状态
                            NotificationCenter.default.post(name: .imageSelectionChanged, object: selectedID)
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(selectedID, anchor: UnitPoint.center)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(viewModel.images.isEmpty ? "图片浏览器" : "共 \(viewModel.images.count) 张图片")
        .onChange(of: viewModel.images) { _ in
            // 当图片数量变化时，标题会自动更新
            // 发送通知更新窗口标题
            NotificationCenter.default.post(name: .updateBrowserWindowTitle, object: nil)
        }
        .frame(minWidth: 1200, minHeight: 700)
        .edgesIgnoringSafeArea(.top)
        .background(KeyboardHandler(
            onEnter: {
                // 回车键：切换到详情页
                if let selectedID = browserWindowState.selectedImageID,
                   let selectedImage = appState.images.first(where: { $0.id == selectedID }) {
                    AppState.shared.showDetailWindow(with: selectedImage)
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
        .onDisappear {
            // 清理通知监听器
            if let observer = notificationObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
    
    private func setupNotificationListeners() {
        // 使用传统方式监听重新加载图片的通知
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .reloadImages,
            object: nil,
            queue: .main
        ) { notification in
            if let userInfo = notification.userInfo,
               let folderURL = userInfo["folderURL"] as? URL {
                self.viewModel.loadImages(from: folderURL)
            } else if let folderURL = self.appState.selectedFolderURL {
                self.viewModel.loadImages(from: folderURL)
            }
        }
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
                    NotificationCenter.default.post(name: .updateBrowserWindowTitle, object: nil)
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
    
    func makeNSView(context: Context) -> NSView {
        let view = BrowserKeyboardView()
        view.setupActions(
            onEnter: onEnter,
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

class BrowserKeyboardView: NSView {
    var onEnter: (() -> Void)?
    var onDelete: (() -> Void)?
    var onBackslash: (() -> Void)?
    
    func setupActions(
        onEnter: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onBackslash: @escaping () -> Void
    ) {
        self.onEnter = onEnter
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
        case 36: // 回车键
            onEnter?()
        case 51: // Backspace键
            onDelete?()
        case 117: // Delete键
            onDelete?()
        case 42: // 反斜杠键
            onBackslash?()
        default:
            // 其他按键不处理
            super.keyDown(with: event)
        }
    }
}

struct ImageItemView: View {
    @ObservedObject var imageItem: ImageItem
    let size: CGSize
    @State private var isSelected: Bool = false
    private let onSelectionChange: (Bool) -> Void
    private let onDoubleTap: () -> Void
    
    init(imageItem: ImageItem, size: CGSize, isSelected: Bool, onSelectionChange: @escaping (Bool) -> Void, onDoubleTap: @escaping () -> Void) {
        self.imageItem = imageItem
        self.size = size
        self._isSelected = State(initialValue: isSelected)
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
        .cornerRadius(8)
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .inset(by: 2)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 4)
        )
        .simultaneousGesture(
            TapGesture(count: 1)
                .onEnded { _ in
                    if !isSelected {
                        isSelected = true
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
        .onReceive(NotificationCenter.default.publisher(for: .imageSelectionChanged)) { notification in
            if let selectedID = notification.object as? UUID {
                let shouldBeSelected = (selectedID == imageItem.id)
                if isSelected != shouldBeSelected {
                    isSelected = shouldBeSelected
                }
            }
        }
    }
}

struct ImageBrowserView_Previews: PreviewProvider {
    static var previews: some View {
        ImageBrowserView()
    }
}