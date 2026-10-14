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
    
    // 说明：缩略图任务**不做取消跟踪**。
    //
    // `loadThumbnail` 内部没有任何取消检查，而 ImageIO 的缩略图生成一旦开始也无法
    // 中途打断——"取消"只会让任务白跑一半，并不会真正省下工作。
    // 旧代码里那个 `thumbnailLoadingTasks` 字典从来没有任何地方写入过
    //（只被 `cancel()` + `removeAll()`），是一处死代码，已随本次修复移除。
    // 切目录时旧目录的缩略图任务会自然跑完，不影响正确性。
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

        // 「重复打开同一目录」时复用已有的 `ImageItem`（第 4 步优化）。
        //
        // 为什么要在**这里**判断：`selectedFolderURL` 马上就会被覆盖，所以"是否同一目录"
        // 必须在覆盖之前取。
        //
        // 为什么快照要在**主线程**取：P0-1 的线程契约要求 `AppState.images` 只在主线程读写。
        // 本方法由 SwiftUI 的 onAppear / onChange / 通知回调在主线程调用，因此这里取快照是安全的；
        // 快照随后作为一个**不可变数组**被带进后台，后台全程不触碰 `AppState`。
        //
        // 收益（在 19254 张 / 185 子目录的真实目录上实测）：
        //   · 跳过全部已有文件的重新读头：646.8 ms → ≈0
        //   · 整条重开路径约 789 ms → 约 142 ms
        //   · 顺带保住已生成的缩略图——`ImageItem` 对象被复用，`thumbnailData` 还在，
        //     网格不必重新解码上万张缩略图
        let isSameFolder = (selectedFolderURL == folderURL)
        let reusableItems = isSameFolder ? AppState.shared.images : []

        selectedFolderURL = folderURL
        
        // 取消正在进行的分批任务（缩略图任务不跟踪、也不取消，理由见属性声明处）
        batchLoadingTask?.cancel()
        
        // 重置分批加载状态
        allImageItems = []
        currentBatchIndex = 0
        isBatchLoading = false
        
        // 新一轮加载：清空标题栏的载入进度（此时总量尚未确定）
        AppState.shared.resetLoadProgress()
        
        // 先清空当前图片列表，确保UI立即更新
        // P0-1 修复：本方法由 SwiftUI 的 onAppear / onChange / 通知回调在主线程调用，
        // 改为通过 AppState 的主线程写入接口操作，不再直接给 images 赋值。
        AppState.shared.setImages([])
        
        // 1010需求：排序方式在主线程读取后带进后台（P0-1 约定 AppState 只在主线程访问）
        let requestedSortType = AppState.shared.sortType
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 使用共享服务加载图片
            //
            // P0-1 修复的原始说明（已随第 4 步更新）：本闭包运行在后台队列，因此当时
            // **不复用**旧 ImageItem（`shouldReuseItems: false`），以确保整个加载过程
            // 完全不触碰 `AppState.images` / `selectedFolderURL`。
            //
            // 第 4 步优化：线程安全不再靠"不复用"来保证，而是靠"**可复用列表已由主线程
            // 取成不可变快照传进来**"——`reusableItems` 是一个不带任何共享可变状态的数组，
            // 后台只读它、不回写，因此依然不触碰 `AppState`。
            //
            // 改这一点的原因是实测发现"不复用"的代价极高：它会让每个已有文件都重新走一遍
            // `ImageItem.init`（读文件头）。在 19254 张的真实目录上是 646.8 ms，
            // 而整条路径里唯一必要的大头成本就来自这里。
            //
            // 注意：`reusableItems` 为空数组时（不同目录）行为与 `false` 完全等价——
            // 服务内部按 URL 查表的字典为空，所有项都会新建。
            let imageItems = ImageLoaderService.shared.loadImagesFromFolder(
                folderURL,
                shouldReuseItems: true,
                sortType: requestedSortType,
                reusableItems: reusableItems
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
        presentItems(ImageSorter.sort(allImageItems, by: sortType))
    }
    
    /// 重新载入当前目录，用于拾取目录内**新增 / 删除**的图片（`r` 快捷键）。
    ///
    /// 与 `loadImages` 的关键区别：**全程不清空当前列表**。
    /// - 扫描期间旧列表继续显示，不会闪一帧空态；
    /// - 滚动位置与选中态保持不变（扫完后若某张图仍在，其 `ImageItem` 因复用而保持同一个 `id`）；
    /// - 复用已有 `ImageItem`，未变动的文件不重读文件头、已生成的缩略图也保留。
    ///
    /// 之所以不复用 `loadImages`：它开头就会 `setImages([])`，那是为"切换目录"准备的
    /// 语义；原地刷新时那样做会白白闪一下，并丢掉当前浏览位置。
    func refresh() {
        guard let folderURL = selectedFolderURL else { return }
        // 只挡"另一次扫描"，不挡"分批装填"。
        // 大目录的装填（含全部缩略图）可能持续很久，若把它也算作忙碌，
        // `r` 会在这段时间里完全失效；而重入装填本身是安全的——
        // `presentItems` 会取消旧的分批任务，代号核对会拦住过期任务写入。
        guard !isLoading else { return }
        
        // P0-1 线程契约：快照与排序方式都在主线程取好后带进后台
        let reusableItems = AppState.shared.images
        let requestedSortType = AppState.shared.sortType
        
        isLoading = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let imageItems = ImageLoaderService.shared.loadImagesFromFolder(
                folderURL,
                shouldReuseItems: true,
                sortType: requestedSortType,
                reusableItems: reusableItems
            )
            
            DispatchQueue.main.async {
                self.isLoading = false
                // 与 loadImages 的收尾同口径：以**当前**排序方式为准
                let currentSortType = AppState.shared.sortType
                let items = currentSortType == requestedSortType
                    ? imageItems
                    : ImageSorter.sort(imageItems, by: currentSortType)
                self.presentItems(items)
            }
        }
    }
    
    /// 用一份**完整列表**刷新展示：替换第一批，其余交给分批任务补全。
    ///
    /// 为什么不直接 `setImages(完整列表)`：大目录一次性上屏会在单帧里重建上万个视图；
    /// 分批推进则保持与首次加载相同的节奏。
    ///
    /// ⚠️ 关键：第一批是**直接上屏**的，绕过了分批循环（循环从 `currentBatchIndex` 开始，
    /// 正好跳过这一段），而它的缩略图还没生成过。必须把它作为 `preloadedBatch`
    /// 交给分批任务补做，否则这些格子会一直停在灰色占位符（问题 36）。
    private func presentItems(_ items: [ImageItem]) {
        allImageItems = items
        
        // 取消进行中的分批任务，从头重新展示（缩略图任务不跟踪、也不取消）
        batchLoadingTask?.cancel()
        
        let firstBatchEnd = min(batchSize, items.count)
        let firstBatch = Array(items[0..<firstBatchEnd])
        AppState.shared.setImages(firstBatch)
        currentBatchIndex = firstBatchEnd
        isBatchLoading = false
        startBatchLoading(preloadedBatch: firstBatch)
    }
    
    /// 启动分批装载。
    ///
    /// - Parameter preloadedBatch: 已经由调用方直接上屏、但**尚未生成缩略图**的那一批。
    ///   `resort` 会用到它：为了让排序切换不闪空态，第一批是直接 `setImages` 上去的，
    ///   绕过了分批循环（循环从 `currentBatchIndex` 开始，正好跳过这一段），
    ///   因此需要在这里把它的缩略图补上。传空数组表示"无需补做"（`loadImages` 的情形）。
    private func startBatchLoading(preloadedBatch: [ImageItem] = []) {
        guard !isBatchLoading else { return }
        
        isBatchLoading = true
        batchGeneration += 1
        let generation = batchGeneration
        
        // 标题栏：总量已确定（= 完整列表长度），开始逐批推进。
        // 这里写的是 `allImageItems.count` 而不是 `AppState.images.count`——
        // 后者此时只装了前几批，正是要避免把它当成"总量"显示出来。
        AppState.shared.beginBatchFilling(total: allImageItems.count)
        
        batchLoadingTask = Task {
            await loadImagesInBatches(generation: generation, preloadedBatch: preloadedBatch)
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
    
    private func loadImagesInBatches(generation: Int, preloadedBatch: [ImageItem]) async {
        // 先补做"已直接上屏那一批"的缩略图。
        // 下面的循环从 currentBatchIndex（= 这一批之后）开始，覆盖不到它；
        // 不补的话，切换排序后新进入前 N 名的图片会永远是占位符。
        // `loadThumbnail` 开头对已有 `thumbnailData` 的项会直接返回，因此重复调用是幂等的——
        // 已经生成过的那部分不会重复解码，只有缺的会被补上。
        if !preloadedBatch.isEmpty {
            await loadThumbnailsAsync(for: preloadedBatch)
        }
        
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
            // 标题栏：装填结束，退回只显示总量
            AppState.shared.endBatchFilling()
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
