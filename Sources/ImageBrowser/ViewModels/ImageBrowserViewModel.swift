import Foundation
import SwiftUI
import ImageIO
import AppKit
import Combine

class ImageBrowserViewModel: ObservableObject {
    // 直接使用共享的图片数组，不再维护本地副本
    var images: [ImageItem] { AppState.shared.images }
    
    @Published var selectedFolderURL: URL?
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private var thumbnailLoadingTasks: [UUID: Task<Void, Never>] = [:]
    var cancellables = Set<AnyCancellable>()
    
    // 分批加载相关属性
    private var allImageItems: [ImageItem] = []
    private var batchSize = 200 // 每批加载200张图片
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
        AppState.shared.images = []
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 使用共享服务加载图片，使用随机排序以保持一致性
            let imageItems = ImageLoaderService.shared.loadImagesFromFolder(folderURL, shouldReuseItems: false, sortType: .random)
            
            DispatchQueue.main.async {
                // 应用随机排序（服务中已完成）
                self.allImageItems = imageItems
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
                AppState.shared.images.append(contentsOf: batchItems)
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
            // 获取图片原始尺寸以计算最佳缩图尺寸
            // let originalSize = try await getImageSize(from: imageItem.url)
            let originalSize = imageItem.size
            
            // 根据图片宽高比和布局需求动态计算缩图尺寸
            let maxPixelSize = calculateOptimalThumbnailSize(originalSize: originalSize)
            
            // 使用ImageIO框架高效生成缩略图数据
            let thumbnailData = try await generateThumbnailData(from: imageItem.url, maxPixelSize: maxPixelSize)
            
            // 在主线程更新缩略图数据
            await MainActor.run {
                imageItem.thumbnailData = thumbnailData
                imageItem.thumbnailSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            }
        } catch {
            // 如果生成缩略图失败，使用默认尺寸
            do {
                let thumbnailData = try await generateThumbnailData(from: imageItem.url, maxPixelSize: 300)
                await MainActor.run {
                    imageItem.thumbnailData = thumbnailData
                    imageItem.thumbnailSize = CGSize(width: 300, height: 300)
                }
            } catch {
                // 如果生成缩略图失败，不设置任何数据，由View处理占位符显示
                print("缩略图加载失败: \(imageItem.name)")
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
    
    /// 获取图片原始尺寸
    private func getImageSize(from url: URL) async throws -> CGSize {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(throwing: NSError(domain: "ImageBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建图片源"]))
                    return
                }
                
                guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
                    continuation.resume(throwing: NSError(domain: "ImageBrowser", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法获取图片属性"]))
                    return
                }
                
                if let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                   let height = properties[kCGImagePropertyPixelHeight] as? CGFloat {
                    continuation.resume(returning: CGSize(width: width, height: height))
                } else {
                    continuation.resume(throwing: NSError(domain: "ImageBrowser", code: 5, userInfo: [NSLocalizedDescriptionKey: "无法获取图片尺寸"]))
                }
            }
        }
    }
    
    /// 根据图片宽高比和布局需求计算最佳缩图尺寸
    private func calculateOptimalThumbnailSize(originalSize: CGSize) -> CGFloat {
        let aspectRatio = originalSize.width / originalSize.height
        
        // 布局算法约束高度在240-320px范围
        // 根据宽高比动态调整缩图尺寸，减少缩放比例
        if aspectRatio > 1.5 { // 横向图片（宽高比大于1.5）
            // 横向图片：优先保证宽度，减少高度缩放
            return 480 // 适合布局高度240px (480×240)
        } else if aspectRatio < 0.67 { // 纵向图片（宽高比小于0.67）
            // 纵向图片：优先保证高度，减少宽度缩放
            return 320 // 适合布局宽度约214px (214×320)
        } else { // 接近方形的图片
            // 方形图片：使用中等尺寸
            return 350 // 适合布局尺寸约280-320px
        }
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