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
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .opacity(0.7)
                Text("或拖拽图片 / 文件夹到此窗口（可多选）")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .opacity(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                // 发送打开文件夹选择对话框的通知
                NotificationManager.shared.post(name: .openImageFolder)
            }
            .onHover { hovering in
                isHovering = hovering
            }
            .padding()
            .background(isDropTarget ? Color.blue.opacity(0.1) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isDropTarget ? Color.blue : Color.clear, lineWidth: 2)
            )
            // 添加拖拽支持
            .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers -> Bool in
                handleDrop(providers: providers)
            }
        }
        .frame(minWidth: 200, minHeight: 200)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // 空的按钮，保持布局一致性
                EmptyView()
            }
        }
    }
    
    // 处理拖拽文件（支持一次拖入多个）
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                } else if let fileURL = item as? URL {
                    url = fileURL
                } else {
                    url = nil
                }
                
                guard let url = url else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }
        
        // 等所有 provider 都解析完，再统一走与面板/Finder 相同的分派
        group.notify(queue: .main) {
            let picked = urls.filter { url in
                ImageLoaderService.shared.isImageFile(url) || ImageLoaderService.shared.isDirectory(url)
            }
            guard !picked.isEmpty else { return }
            
            if picked.count == 1, ImageLoaderService.shared.isImageFile(picked[0]) {
                NotificationManager.shared.openImageFile(picked[0])
                return
            }
            
            let selectionChanged = Set(AppState.shared.openURLs) != Set(picked)
            AppState.shared.openURLs = picked
            NotificationManager.shared.openBrowserWindow(shouldReloadImages: !selectionChanged)
        }
        
        return true
    }
    

}

struct LaunchView_Previews: PreviewProvider {
    static var previews: some View {
        LaunchView()
    }
}