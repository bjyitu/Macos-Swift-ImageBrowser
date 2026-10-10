import Foundation
import SwiftUI
import ImageIO
import AppKit
import Combine

class ImageBrowserViewModel: ObservableObject {
    // 直接使用共享的图片数组，不再维护本地副本
    // P0-1 修复：这里只是对 AppState.shared.images 的**只读**转发，供 SwiftUI 在
    // 主线程渲染使用；所有写入一律走 AppState 的主线程写入接口（见下）。
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
    
    init() {
        // 1010需求：排序方式变更时，只对内存中的列表重排，不重新扫描目录。
        // `dropFirst()` 用于跳过订阅瞬间立即发出的当前值（那是初始状态，不需要重排）。
        AppState.shared.$sortType
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sortType in
                self?.resort(by: sortType)
            }
            .store(in: &cancellables)
    }
    
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
        // P0-1 修复：本方法由 SwiftUI 的 onAppear / onChange / 通知回调在主线程调用，
        // 改为通过 AppState 的主线程写入接口操作，不再直接给 images 赋值。
        AppState.shared.setImages([])
        
        // 1010需求：排序方式在主线程读取后带进后台（P0-1 约定 AppState 只在主线程访问）
        let requestedSortType = AppState.shared.sortType
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 使用共享服务加载图片
            // P0-1 修复：本闭包运行在后台队列，因此这里**不复用**旧 ImageItem
            //（shouldReuseItems: false），也不向加载服务传递任何 AppState 快照，
            // 确保整个加载过程完全不触碰 AppState.images / selectedFolderURL。
            let imageItems = ImageLoaderService.shared.loadImagesFromFolder(
                folderURL,
                shouldReuseItems: false,
                sortType: requestedSortType
            )
            
            DispatchQueue.main.async {
                // 1010需求：以**当前**排序方式为准——加载期间用户可能已经切换过排序。
                // 若与加载时用的是同一种，就无需再排一次（20000 张重排约 40 ms）。
                let currentSortType = AppState.shared.sortType
                self.allImageItems = currentSortType == requestedSortType
                    ? imageItems
                    : ImageSorter.sort(imageItems, by: currentSortType)
                self.isLoading = false
                
                // 开始分批加载
                self.startBatchLoading()
            }
        }
    }
    
    /// 仅改变排序方式：对已加载的完整列表在内存里重排，**不重新扫描磁盘**（1010需求）。
    ///
    /// 缩略图已挂在各个 `ImageItem.thumbnailData` 上，因此重排后不会重新解码，
    /// 画面能很快补齐。
    private func resort(by sortType: ImageSortType) {
        // 还没有加载完成时无需处理：
        // `loadImages` 的完成回调会以"当时的 AppState.sortType"为准重新排好。
        guard !allImageItems.isEmpty else { return }
        
        allImageItems = ImageSorter.sort(allImageItems, by: sortType)
        
        // 取消进行中的分批任务，从头重排展示
        thumbnailLoadingTasks.values.forEach { $0.cancel() }
        thumbnailLoadingTasks.removeAll()
        batchLoadingTask?.cancel()
        
        // 先把第一批**同步**装上，再交给分批任务继续。
        // 否则 setImages([]) 之后会先渲染一帧"没有找到图片"的空态，看起来像闪了一下。
        // 这一批的缩略图早已挂在各 ImageItem 上，不需要重新解码。
        let firstBatchEnd = min(batchSize, allImageItems.count)
        AppState.shared.setImages(Array(allImageItems[0..<firstBatchEnd]))
        currentBatchIndex = firstBatchEnd
        isBatchLoading = false
        startBatchLoading()
    }
    
    private func startBatchLoading() {
        guard !isBatchLoading else { return }
        
        isBatchLoading = true
        batchGeneration += 1
        let generation = batchGeneration
        batchLoadingTask = Task {
            await loadImagesInBatches(generation: generation)
        }
    }
    
    /// 分批装载的「代号」。
    ///
    /// **为什么需要它**：`Task.cancel()` 是**协作式**的——旧任务如果正卡在
    /// `loadThumbnailsAsync` 里，取消不会立刻生效；而循环末尾的
    /// `try? await Task.sleep(...)` 又会把 `CancellationError` 吞掉、继续下一轮。
    /// 于是切换排序（或重新加载）时，旧任务会与新的分批任务**并发**运行：
    /// 两者共用 `currentBatchIndex`，又都往 `AppState.images` 里 append，
    /// 结果列表出现**重复图片**——正是 SwiftUI 报的
    /// "the ID ... occurs multiple times within the collection"。
    ///
    /// 现在每次重新分批都自增代号，旧任务在读写任何共享状态前先核对代号，
    /// 过期就立刻退出、不再写入。
    private var batchGeneration = 0
    
    private func loadImagesInBatches(generation: Int) async {
        while true {
            // 所有可变状态（currentBatchIndex / allImageItems / batchGeneration）
            // 都收在主线程读写，避免与 resort / loadImages 竞争。
            let batchItems: [ImageItem]? = await MainActor.run {
                guard generation == self.batchGeneration else { return nil }
                guard self.currentBatchIndex < self.allImageItems.count else { return nil }
                
                let startIndex = self.currentBatchIndex
                let endIndex = min(startIndex + self.batchSize, self.allImageItems.count)
                let items = Array(self.allImageItems[startIndex..<endIndex])
                self.currentBatchIndex = endIndex
                return items
            }
            
            // 取不到批次 = 已过期或已装载完，直接退出，不写任何共享状态
            guard let batchItems = batchItems, !batchItems.isEmpty else { break }
            
            // 更新当前显示的图片列表
            // P0-1 修复：分批加载在 Task 中推进，必须切回主线程后再写入，
            // 避免与后台加载 / 删除回调竞争同一个数组。
            // 代号核对是第二道防线：即便状态读取之后才被顶替，也不会重复写入。
            await MainActor.run {
                guard generation == self.batchGeneration else { return }
                AppState.shared.appendImages(batchItems)
            }
            
            // 异步加载当前批次的缩略图
            await loadThumbnailsAsync(for: batchItems)
            
            // 短暂延迟，避免过于密集的UI更新
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        
        await MainActor.run {
            // 只有仍然是"当代"的任务才能清标记：
            // 若已被新任务顶替，清了会把新任务的标记误清掉。
            guard generation == self.batchGeneration else { return }
            self.isBatchLoading = false
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
}
