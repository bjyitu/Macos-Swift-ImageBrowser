import SwiftUI
import UniformTypeIdentifiers

struct LaunchView: View {
    @State private var isHovering = false
    @State private var isDropTarget = false
    
    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 5) {
                Image(systemName: "photo.fill.on.rectangle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(isHovering || isDropTarget ? .blue : .gray)
                    .padding(.bottom, 10)
                Text("点击加载图片或目录")
                    .font(.title2)
                    .foregroundColor(.secondary)
                    .opacity(0.7)
                Text("或拖拽图片文件到此窗口")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .opacity(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                // 发送打开文件夹选择对话框的通知
                NotificationCenter.default.post(name: .openImageFolder, object: nil)
            }
            .onHover { hovering in
                isHovering = hovering
            }
            .padding()
            .background(isDropTarget ? Color.blue.opacity(0.1) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isDropTarget ? Color.blue : Color.clear, lineWidth: 2)
            )
            // 添加拖拽支持
            .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers -> Bool in
                handleDrop(providers: providers)
            }
        }
        .frame(minWidth: 600, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // 空的按钮，保持布局一致性
                EmptyView()
            }
        }
    }
    
    // 处理拖拽文件
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        // 加载文件URL
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
            if let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                
                DispatchQueue.main.async {
                    // 检查是否为图片文件
                    if isImageFile(url) {
                        AppState.shared.openImageFile(url)
                    } else {
                        // 如果不是图片文件，检查是否为文件夹
                        var isDirectory: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue {
                            AppState.shared.selectedFolderURL = url
                            AppState.shared.openBrowserWindow()
                        }
                    }
                }
            }
        }
        
        return true
    }
    
    // 检查是否为图片文件
    private func isImageFile(_ url: URL) -> Bool {
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }
}

struct LaunchView_Previews: PreviewProvider {
    static var previews: some View {
        LaunchView()
    }
}