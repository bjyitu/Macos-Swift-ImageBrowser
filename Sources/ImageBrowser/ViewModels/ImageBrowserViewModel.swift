import Foundation
import SwiftUI
import ImageIO

class ImageBrowserViewModel: ObservableObject {
    @Published var images: [ImageItem] = []
    @Published var selectedFolderURL: URL?
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private var thumbnailLoadingTasks: [UUID: Task<Void, Never>] = [:]
    
    // 分批加载相关属性
    private var allImageItems: [ImageItem] = []
    private var batchSize = 100 // 每批加载100张图片
    private var currentBatchIndex = 0
    private var isBatchLoading = false
    private var batchLoadingTask: Task<Void, Never>?
    
    func loadImages(from folderURL: URL) {
        isLoading = true
        errorMessage = nil
        selectedFolderURL = folderURL
        
        // 取消所有正在进行的任务
        thumbnailLoadingTasks.values.forEach { $0.cancel() }
        thumbnailLoadingTasks.removeAll()
        batchLoadingTask?.cancel()
        
        // 重置分批加载状态
        allImageItems = []
        currentBatchIndex = 0
        isBatchLoading = false
        
        // 先清空当前图片列表，确保UI立即更新
        self.images = []
        AppState.shared.images = []
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var imageItems: [ImageItem] = []
            
            // 获取文件夹中的所有文件
            let fileManager = FileManager.default
            let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
            
            if let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: resourceKeys) {
                for case let url as URL in enumerator {
                    // 检查是否为图片文件
                    if self.isImageFile(url) {
                        let imageItem = ImageItem(url: url)
                        imageItems.append(imageItem)
                    }
                }
            }
            
            DispatchQueue.main.async {
                // 应用随机排序
                self.allImageItems = self.randomizeImageOrder(imageItems)
                self.isLoading = false
                
                // 开始分批加载
                self.startBatchLoading()
            }
        }
    }
    
    private func startBatchLoading() {
        guard !isBatchLoading else { return }
        
        isBatchLoading = true
        batchLoadingTask = Task {
            await loadImagesInBatches()
        }
    }
    
    private func loadImagesInBatches() async {
        while currentBatchIndex < allImageItems.count {
            let startIndex = currentBatchIndex
            let endIndex = min(currentBatchIndex + batchSize, allImageItems.count)
            let batchItems = Array(allImageItems[startIndex..<endIndex])
            
            // 更新当前显示的图片列表
            await MainActor.run {
                self.images.append(contentsOf: batchItems)
                AppState.shared.images = self.images
            }
            
            // 异步加载当前批次的缩略图
            await loadThumbnailsAsync(for: batchItems)
            
            // 更新批次索引
            currentBatchIndex = endIndex
            
            // 短暂延迟，避免过于密集的UI更新
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        
        await MainActor.run {
            isBatchLoading = false
        }
    }
    
    private func loadThumbnailsAsync(for imageItems: [ImageItem]) async {
        // 简化：直接并发加载缩略图，限制并发数量
        await withTaskGroup(of: Void.self) { group in
            var activeTasks = 0
            let maxConcurrentTasks = 10
            
            for imageItem in imageItems {
                // 限制并发任务数量，避免内存爆炸
                while activeTasks >= maxConcurrentTasks {
                    await group.next()
                    activeTasks -= 1
                }
                
                activeTasks += 1
                group.addTask {
                    await self.loadThumbnail(for: imageItem)
                }
            }
        }
    }
    
    private func loadThumbnail(for imageItem: ImageItem) async {
        // 检查是否已经有缩略图数据
        if imageItem.thumbnailData != nil { return }
        
        do {
            // 使用ImageIO框架高效生成缩略图数据
            let thumbnailData = try await generateThumbnailData(from: imageItem.url, maxPixelSize: 300)
            
            // 在主线程更新缩略图数据
            await MainActor.run {
                imageItem.thumbnailData = thumbnailData
            }
        } catch {
            // 如果生成缩略图失败，设置一个占位图数据
            await MainActor.run {
                if let placeholderData = createPlaceholderImageData() {
                    imageItem.thumbnailData = placeholderData
                }
            }
        }
    }
    
    /// 使用ImageIO框架高效生成缩略图数据
    private func generateThumbnailData(from url: URL, maxPixelSize: CGFloat) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(throwing: NSError(domain: "ImageBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建图片源"]))
                    return
                }
                
                // 简化选项：只使用必要的参数
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ]
                
                if let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                    let bitmapRep = NSBitmapImageRep(cgImage: cgThumbnail)
                    if let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: NSError(domain: "ImageBrowser", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法转换缩略图为数据"]))
                    }
                } else {
                    continuation.resume(throwing: NSError(domain: "ImageBrowser", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法生成缩略图"]))
                }
            }
        }
    }
    
    /// 创建占位图数据
    private func createPlaceholderImageData() -> Data? {
        let size = NSSize(width: 200, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.gray.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        
        // 将NSImage转换为JPEG数据
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
    
    /// 创建占位图（兼容性方法）
    private func createPlaceholderImage() -> NSImage {
        let size = NSSize(width: 200, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.gray.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
    
    private func isImageFile(_ url: URL) -> Bool {
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }
    
    private func randomizeImageOrder(_ images: [ImageItem]) -> [ImageItem] {
        guard images.count > 1 else { return images }
        
        var shuffled = images
        
        for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
            let j = Int.random(in: 0...i)
            shuffled.swapAt(i, j)
        }
        
        return shuffled
    }
    
    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择文件夹"
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                loadImages(from: url)
            }
        }
    }
}