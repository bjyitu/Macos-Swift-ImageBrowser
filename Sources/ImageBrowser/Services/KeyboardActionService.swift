import SwiftUI
import AppKit

class KeyboardActionService {
    static let shared = KeyboardActionService()
    
    private init() {}
    
    // 处理通用的键盘事件
    func handleKeyEvent(_ event: NSEvent, in context: KeyboardContext) -> Bool {
        guard NSApplication.shared.isActive else { return false }
        
        switch event.keyCode {
        case 36: // 回车键
            context.onEnter?()
        case 51, 117: // Backspace/Delete键
            context.onDelete?()
        case 42: // 反斜杠键
            context.onBackslash?()
        case 123: // 左箭头键
            context.onLeftArrow?()
        case 124: // 右箭头键
            context.onRightArrow?()
        case 49: // 空格键
            context.onSpace?()
        default:
            return false
        }
        
        return true
    }
}

// MARK: - 键盘上下文工厂方法
extension KeyboardActionService {
    // 为浏览器视图创建键盘上下文
    static func createBrowserKeyboardContext(
        appState: AppState,
        browserWindowState: BrowserWindowState,
        showDeleteConfirmation: @escaping (ImageItem) -> Void
    ) -> KeyboardContext {
        return KeyboardContext(
            onEnter: {
                // 回车键：切换到详情页
                if let selectedID = browserWindowState.selectedImageID,
                   let selectedImage = appState.images.first(where: { $0.id == selectedID }) {
                    NotificationManager.shared.openDetailWindow(with: selectedImage)
                }
            },
            onDelete: {
                // Backspace/Delete键：删除当前图片到回收站
                if let selectedID = browserWindowState.selectedImageID,
                   let selectedImage = appState.images.first(where: { $0.id == selectedID }) {
                    showDeleteConfirmation(selectedImage)
                }
            },
            onBackslash: {
                // 反斜杠键：打开图片所在目录
                if let selectedID = browserWindowState.selectedImageID,
                   let selectedImage = appState.images.first(where: { $0.id == selectedID }) {
                    ImageActionService.shared.openImageDirectory(for: selectedImage)
                }
            },
            onLeftArrow: {
                // 左箭头键：选择上一张图片
                ImageActionService.shared.navigateToPreviousImageInBrowser()
            },
            onRightArrow: {
                // 右箭头键：选择下一张图片
                ImageActionService.shared.navigateToNextImageInBrowser()
            },
            onSpace: nil // 浏览器视图不处理空格键
        )
    }
    
    // 为详情视图创建键盘上下文
    static func createDetailKeyboardContext(
        switchToBrowserView: @escaping () -> Void,
        deleteCurrentImage: @escaping () -> Void,
        openImageDirectory: @escaping () -> Void,
        showPreviousImage: @escaping () -> Void,
        showNextImage: @escaping () -> Void,
        togglePlayPause: @escaping () -> Void
    ) -> KeyboardContext {
        return KeyboardContext(
            onEnter: { switchToBrowserView() },
            onDelete: { deleteCurrentImage() },
            onBackslash: { openImageDirectory() },
            onLeftArrow: { showPreviousImage() },
            onRightArrow: { showNextImage() },
            onSpace: { togglePlayPause() }
        )
    }
}

// 键盘事件上下文
struct KeyboardContext {
    let onEnter: (() -> Void)?
    let onDelete: (() -> Void)?
    let onBackslash: (() -> Void)?
    let onLeftArrow: (() -> Void)?
    let onRightArrow: (() -> Void)?
    let onSpace: (() -> Void)?
    
    init(
        onEnter: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onBackslash: (() -> Void)? = nil,
        onLeftArrow: (() -> Void)? = nil,
        onRightArrow: (() -> Void)? = nil,
        onSpace: (() -> Void)? = nil
    ) {
        self.onEnter = onEnter
        self.onDelete = onDelete
        self.onBackslash = onBackslash
        self.onLeftArrow = onLeftArrow
        self.onRightArrow = onRightArrow
        self.onSpace = onSpace
    }
}

// 统一的键盘响应视图
struct UnifiedKeyboardResponder: NSViewRepresentable {
    let keyboardContext: KeyboardContext
    
    func makeNSView(context: Context) -> NSView {
        let view = UnifiedKeyboardView()
        view.setupContext(keyboardContext)
        
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

// 统一的键盘视图类
class UnifiedKeyboardView: NSView {
    private var keyboardContext: KeyboardContext?
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    func setupContext(_ context: KeyboardContext) {
        self.keyboardContext = context
    }
    
    override func keyDown(with event: NSEvent) {
        guard let context = keyboardContext else {
            super.keyDown(with: event)
            return
        }
        
        // 使用 KeyboardActionService 处理键盘事件
        let handled = KeyboardActionService.shared.handleKeyEvent(event, in: context)
        
        if !handled {
            super.keyDown(with: event)
        }
    }
}