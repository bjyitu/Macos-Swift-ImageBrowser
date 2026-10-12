import Foundation
import SwiftUI
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

class ImageDetailViewModel: ObservableObject {
    @Published var imageItem: ImageItem?
    @Published var fullImage: NSImage?

    // 锐化参数,之前是3,0.5
    // private let sharpenIntensity: Double = 2.5
    // private let sharpenRadius: Double = 0.5
    // 为了去除黑白漫画缩放后的高频网纹做以下参数
    private let sharpenIntensity: Double = 1.5
    private let sharpenRadius: Double = 1

    // 图片缓存系统
    let imageCache = NSCache<NSString, NSImage>()
    private let cacheQueue = DispatchQueue(label: "com.imagebrowser.detail.cache", qos: .utility)

    // MARK: - 解码队列（P0-3 修复新增）

    /// 主图解码专用队列（并发）。
    /// 把「读盘 + 解码 + CILanczos 缩放 + 去噪/锐化」从主线程挪到这里执行。
    private let decodeQueue = DispatchQueue(
        label: "com.imagebrowser.detail.decode",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// 相邻图片预加载专用队列（串行）。
    /// 与 `decodeQueue` 分开，是为了保证预加载不会拖慢用户当前正在看的那张图的解码；
    /// 串行化则避免快速翻页时堆积大量并发解码。
    private let preloadQueue = DispatchQueue(label: "com.imagebrowser.detail.preload", qos: .utility)

    // 预加载参数
    private let preloadCount = 2 // 预加载前后各2张图片

    /// 是否正在后台解码当前图片（P0-3 修复新增）。
    /// 用于让视图区分「加载中」与「确实加载失败」——解码异步化之后，
    /// 若仍沿用 `fullImage == nil` 作为唯一判据，每次切图都会先闪一下"图片未找到"。
    @Published var isLoadingImage = false

    init() {
        // 初始化处理队列
        setupImageCache()
    }

    // 设置图片缓存
    private func setupImageCache() {
        // 设置缓存限制
        imageCache.countLimit = 20 // 最多缓存20张图片
        imageCache.totalCostLimit = 2000 * 1024 * 1024 // 2000MB内存限制

        // 设置缓存清理策略
        imageCache.evictsObjectsWithDiscardedContent = true
    }


    /// 加载并显示指定图片。
    ///
    /// **P0-3 修复**：原实现在调用线程（主线程）上同步完成
    /// `Data(contentsOf:)` 全量读盘 + CILanczos 缩放 + 去噪/锐化 + 相邻预加载。
    /// 而它是由 `ImageDetailView.init` 调用的，`AppDelegate.openDetailWindow` 又是
    /// **先**构造 `ImageDetailView`、**后**创建 `NSWindow`，因此这些重活会在窗口
    /// 存在之前全部跑完——打开大图时表现为窗口迟迟不出现、界面卡死。
    ///
    /// 现在改为三段式：
    /// 1. **主线程**：切换 `imageItem`、试探缓存，命中则立即显示并返回；
    /// 2. **后台**（`decodeQueue`）：读盘 + 解码 + 缩放 + 锐化，完成后写入缓存；
    /// 3. **主线程**：回写 `fullImage` / `isLoadingImage`，若期间已切走则丢弃结果。
    ///
    /// - Parameters:
    ///   - imageItem: 目标图片
    ///   - shouldAdjustWindow: 是否需要按图片尺寸计算窗口大小。
    ///     该计算只依赖 `ImageItem.size`（建索引时已读好的文件头信息），代价可忽略，
    ///     因此保留在调用线程同步完成，使 `onAppear` 中的窗口调整逻辑无需等待解码。
    func loadImage(_ imageItem: ImageItem, shouldAdjustWindow: Bool = true) {
        // 更新当前图片项（主线程，UI 立即切到加载态）
        self.imageItem = imageItem

        // 首先尝试从缓存获取图片
        let cacheKey = imageItem.url.absoluteString as NSString
        if let cachedImage = imageCache.object(forKey: cacheKey) {
            // 缓存命中：立即更新UI，无需异步延迟
            self.fullImage = cachedImage
            self.isLoadingImage = false
            // 预加载相邻图片（已改为后台执行）
            schedulePreload(around: imageItem)
            return
        }

        // P0-3 修复：预加载需要在后台按屏幕尺寸计算窗口大小，而 `NSScreen.main`
        // 是只能在主线程访问的 AppKit API，因此在主线程把屏幕可视区域一次性取好，
        // 随解码 / 预加载任务一起带到后台，后台不再触碰 AppKit。
        let screenVisibleFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)

        // 缓存未命中：先算好窗口大小（纯计算），随后把重活整体丢到后台队列
        let windowSize = shouldAdjustWindow
            ? Self.windowSize(forImageSize: imageItem.size, screenVisibleFrame: screenVisibleFrame)
            : nil

        // 标记进入加载态；此时刻意不清空 fullImage，
        // 让上一张图继续显示直到新图解码完成，避免切图时闪白。
        self.isLoadingImage = true

        // P0-1 线程契约：预加载所需的图片列表必须在主线程取快照，
        // 再随解码任务一起带到后台，后台线程绝不直接读取 AppState。
        let imageListSnapshot = AppState.shared.images

        // P0-3 修复：解码重活整体移到后台队列，主线程立即返回。
        decodeQueue.async { [weak self] in
            guard let self = self else { return }

            let decodedImage: NSImage?
            do {
                let imageData = try self.loadImageDataSynchronously(from: imageItem.url)
                decodedImage = self.createOptimizedImage(from: imageData, targetSize: windowSize)
            } catch {
                decodedImage = nil
            }

            if let decodedImage = decodedImage {
                // NSCache 自身线程安全，可在后台直接写入
                let imageSize = decodedImage.size.width * decodedImage.size.height * 4 // 估算像素内存占用
                self.imageCache.setObject(decodedImage, forKey: cacheKey, cost: Int(imageSize))
            }

            // 回主线程更新 @Published 状态；若期间用户已切换到别的图片，丢弃本次结果
            DispatchQueue.main.async {
                guard self.imageItem?.url == imageItem.url else { return }
                self.fullImage = decodedImage
                self.isLoadingImage = false
            }

            // 无论解码成功与否，都在后台把相邻图片补进缓存（不再占用主线程）
            self.dispatchPreload(around: imageItem, in: imageListSnapshot, screenVisibleFrame: screenVisibleFrame)
        }
    }

    // 公共方法：切换到指定图片并管理缓存
    func switchToImage(_ imageItem: ImageItem, shouldAdjustWindow: Bool = false) {
        // 清理超出范围的缓存
        cleanupCache(for: imageItem)

        // 加载新图片
        loadImage(imageItem, shouldAdjustWindow: shouldAdjustWindow)
    }



    // 预加载相邻图片（P0-3：由主线程同步执行改为投递到 preloadQueue 后台队列）

    /// 在主线程取好图片列表与屏幕尺寸快照后，把预加载任务投递到后台队列。
    /// **必须在主线程调用**（P0-1 约定：`AppState` 只在主线程访问；
    /// 且 `NSScreen.main` 是主线程专属的 AppKit API）。
    private func schedulePreload(around currentItem: ImageItem) {
        let imageListSnapshot = AppState.shared.images
        let screenVisibleFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        dispatchPreload(around: currentItem, in: imageListSnapshot, screenVisibleFrame: screenVisibleFrame)
    }

    /// 把预加载投递到串行后台队列。列表与屏幕尺寸快照均由主线程取好，
    /// 后台只消费纯数据，不再触碰 `AppState` / AppKit。
    private func dispatchPreload(
        around currentItem: ImageItem,
        in imageListSnapshot: [ImageItem],
        screenVisibleFrame: CGRect
    ) {
        preloadQueue.async { [weak self] in
            self?.preloadAdjacentImages(
                around: currentItem,
                in: imageListSnapshot,
                screenVisibleFrame: screenVisibleFrame
            )
        }
    }

    /// 预加载当前图片前后的相邻图片。
    ///
    /// **P0-3 修复**：本方法现在只在 `preloadQueue` 后台队列上执行，
    /// 因此图片列表与屏幕尺寸都必须以参数形式传入（由主线程取好的快照），
    /// 方法内部不再访问 `AppState`（P0-1 的线程契约）与 `NSScreen`。
    private func preloadAdjacentImages(
        around currentItem: ImageItem,
        in imageList: [ImageItem],
        screenVisibleFrame: CGRect
    ) {
        // 获取当前图片在列表中的索引
        guard let currentIndex = imageList.firstIndex(of: currentItem) else {
            return
        }

        // 计算预加载范围
        let startIndex = max(0, currentIndex - self.preloadCount)
        let endIndex = min(imageList.count - 1, currentIndex + self.preloadCount)

        // 批量预加载图片
        let preloadItems = (startIndex...endIndex)
            .filter { $0 != currentIndex }
            .map { imageList[$0] }
            .filter { self.imageCache.object(forKey: $0.url.absoluteString as NSString) == nil }

        // 在后台队列串行预加载，避免占用主线程
        for imageItem in preloadItems {
            do {
                // 直接使用imageItem中的尺寸信息
                let originalSize = imageItem.size
                // 用主线程传下来的屏幕尺寸做纯计算，避免后台访问 NSScreen.main
                let windowSize = Self.windowSize(
                    forImageSize: originalSize,
                    screenVisibleFrame: screenVisibleFrame
                )

                // 使用优化的数据加载和图片处理
                let imageData = try self.loadImageDataSynchronously(from: imageItem.url)
                if let optimizedImage = self.createOptimizedImage(from: imageData, targetSize: windowSize) {
                    // 存入缓存
                    let imageSize = optimizedImage.size.width * optimizedImage.size.height * 4
                    let cacheKey = imageItem.url.absoluteString as NSString
                    self.imageCache.setObject(optimizedImage, forKey: cacheKey, cost: Int(imageSize))
                }
            } catch {
                // 预加载失败，忽略错误
                print("预加载图片失败: \(imageItem.url.lastPathComponent)")
            }
        }
    }

    // 清理超出范围的缓存
    private func cleanupCache(for currentItem: ImageItem) {
        // P0-1 修复：原实现把对 AppState.shared.images 的读取放在 cacheQueue
        // 后台队列里执行，与主线程的 append/removeAll 构成数据竞争。
        // 现在改为在调用线程（主线程）先取出不可变快照，后台队列只消费快照。
        let imageList = AppState.shared.images

        // 获取当前图片在列表中的索引
        guard let currentIndex = imageList.firstIndex(of: currentItem) else {
            return
        }

        // 计算应保留的缓存范围
        let keepStartIndex = max(0, currentIndex - self.preloadCount - 1) // 多保留一张，避免频繁清理
        let keepEndIndex = min(imageList.count - 1, currentIndex + self.preloadCount + 1)

        // 获取应保留的图片URL集合
        var keepUrls = Set<String>()
        for i in keepStartIndex...keepEndIndex {
            keepUrls.insert(imageList[i].url.absoluteString)
        }

        cacheQueue.async {
            // 这里无法直接遍历NSCache的所有键，所以采用另一种策略：
            // 当缓存超过限制时，NSCache会自动清理最久未使用的项
            // 我们已经设置了合理的countLimit和totalCostLimit
            // keepUrls 仅用于记录"本应保留"的范围，实际淘汰交由 NSCache 自主完成
            _ = keepUrls
        }
    }
    private func loadImageDataSynchronously(from url: URL) throws -> Data {
        do {
            // 直接读取图片文件数据
            return try Data(contentsOf: url)
        } catch {
            throw NSError(domain: "ImageLoader", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法加载图片数据: \(error.localizedDescription)"])
        }
    }

    // 从Data创建优化图片的辅助方法
    private func createOptimizedImage(from data: Data, targetSize: CGSize? = nil) -> NSImage? {
        // 使用CGImageSource直接处理数据，避免多次创建NSImage
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            // 如果CGImageSource失败，直接打印错误日志
            print("CGImageSource处理失败，无法创建优化图片")
            return nil
        }

        // 获取原始尺寸信息
        let originalWidth = CGFloat(image.width)
        let originalHeight = CGFloat(image.height)
        // let originalSize = CGSize(width: originalWidth, height: originalHeight)

        // 使用提供的targetSize，如果没有则使用默认大小
        let windowSize = targetSize ?? CGSize(width: 768, height: 768)
        let maxWindowDimension = max(windowSize.width, windowSize.height)

        // 根据窗口大小计算缩放后的尺寸
        let imageMaxDimension = max(originalWidth, originalHeight)
        let scale = maxWindowDimension / imageMaxDimension

        // 如果图片小于目标尺寸，不需要缩放
        // if scale >= 1.0 {
        //     let nsImage = NSImage(cgImage: image, size: originalSize)
        //     return nsImage.sharpened(intensity: self.sharpenIntensity, radius: self.sharpenRadius) ?? nsImage
        // }

        // 计算缩放后的尺寸
        let scaledWidth = Int(originalWidth * scale)
        let scaledHeight = Int(originalHeight * scale)
        let scaledSize = NSSize(width: scaledWidth, height: scaledHeight)

        // 直接使用CGImage进行缩放，避免中间NSImage转换
        guard let resizedImage = resizeCGImage(image, to: scaledSize) else {
            // 缩放失败，直接打印错误日志
            print("CGImage缩放失败，无法创建优化图片")
            return nil
        }

        // 转换为NSImage并应用锐化（使用优化后的GPU加速方法）
        let finalNSImage = NSImage(cgImage: resizedImage, size: scaledSize)
        return finalNSImage.sharpened(intensity: self.sharpenIntensity, radius: self.sharpenRadius) ?? finalNSImage
    }

    // 直接缩放CGImage的方法,之前使用CGContext,缩放质量要差一些,.bak文件可以直接节省这个方法,质量稍差
    private func resizeCGImage(_ cgImage: CGImage, to size: NSSize) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)

        // 计算缩放比例
        let scaleX = size.width / CGFloat(cgImage.width)
        let scaleY = size.height / CGFloat(cgImage.height)
        let scale = min(scaleX, scaleY)

        // 预模糊：仅在下采样（scale < 1）时启用
        //   - scale >= 1 时 1/(s*s) - 1 <= 0，开方得到 NaN，会把 CIGaussianBlur 搞崩；
        //   - 且放大本来不会产生混叠，无需预模糊。
        let inputImage: CIImage
        if scale < 1.0 {
            // 更严格的抗混叠 sigma：sigma = 0.35 * sqrt(1/s² - 1)
            // 系数 0.35 是"彩图清晰度 vs 漫画网纹"的折中：
            //   - 彩图仍偏糊 → 降到 0.30
            //   - 漫画偶发网纹 → 升到 0.40
            let sigma = 0.35 * sqrt(1.0 / (scale * scale) - 1.0)

            let preBlur = CIFilter.gaussianBlur()
            preBlur.inputImage = ciImage
            preBlur.radius = Float(sigma)   // CIGaussianBlur 的 radius 与 sigma 含义接近

            // 必须裁回原 extent：CIGaussianBlur 是无界卷积，不裁会让后续
            // Lanczos 缩放出现偏移或边缘透明。失败时兜底用原图，避免整张图挂掉。
            inputImage = preBlur.outputImage?.cropped(to: ciImage.extent) ?? ciImage
        } else {
            // scale == 1（原尺寸）或放大：直接使用原图
            inputImage = ciImage
        }

        // 使用Lanczos高质量缩放滤镜
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(inputImage, forKey: kCIInputImageKey)
        filter.setValue(scaleX, forKey: "inputScale")
        filter.setValue(scaleY / scaleX, forKey: "inputAspectRatio")

        guard let outputImage = filter.outputImage else { return nil }

        // 使用GPU渲染上下文，提高4K图片处理性能
        let context = CIContext(options: [
            .useSoftwareRenderer: false,  // 使用GPU加速
            .cacheIntermediates: false    // 避免缓存中间结果，减少内存占用
        ])

        return context.createCGImage(outputImage, from: outputImage.extent)
    }

    // 根据图片原始尺寸计算合适的窗口大小
    //
    // **P0-3 修复**：本方法内部访问 `NSScreen.main`（AppKit UI API，只能在主线程调用）。
    // 由于预加载已经移到后台队列，这里把实际计算拆成纯函数
    // `windowSize(forImageSize:screenVisibleFrame:)`，由调用方在主线程先把屏幕尺寸
    // 取好再传进来，避免后台线程触碰 AppKit。
    func calculateWindowSizeForImage(originalSize: CGSize) -> CGSize {
        // 获取屏幕尺寸（主线程）
        guard let screen = NSScreen.main else { return CGSize(width: 1024, height: 768) }
        return Self.windowSize(forImageSize: originalSize, screenVisibleFrame: screen.visibleFrame)
    }

    /// 纯计算：按图片尺寸与屏幕可视区域算出窗口大小。
    /// 不访问任何 AppKit 全局状态，因此可在后台线程安全调用。
    ///
    /// P1-6 回归修复：改为 `static`，使窗口的持有者 `AppDelegate` 也能直接调用它
    /// 在打开时确定窗口尺寸，而不必依赖视图生命周期里的"首次定位"启发式。
    static func windowSize(forImageSize originalSize: CGSize, screenVisibleFrame: CGRect) -> CGSize {
        let screenWidth = screenVisibleFrame.size.width
        let screenHeight = screenVisibleFrame.size.height

        // 计算适合屏幕的最大窗口尺寸，保持图片宽高比
        let maxWindowWidth = screenWidth * 0.95
        let maxWindowHeight = screenHeight * 0.95

        let originalWidth = originalSize.width
        let originalHeight = originalSize.height
        let imageAspectRatio = originalWidth / originalHeight

        // 根据图片宽高比计算窗口尺寸
        var windowWidth: CGFloat
        var windowHeight: CGFloat

        if imageAspectRatio > 1 {
            // 横向图片
            windowWidth = maxWindowWidth
            windowHeight = windowWidth / imageAspectRatio

            // 如果高度超出限制，则以高度为基准重新计算
            if windowHeight > maxWindowHeight {
                windowHeight = maxWindowHeight
                windowWidth = windowHeight * imageAspectRatio
            }
        } else {
            // 竖向图片或正方形图片
            windowHeight = maxWindowHeight
            windowWidth = windowHeight * imageAspectRatio

            // 如果宽度超出限制，则以宽度为基准重新计算
            if windowWidth > maxWindowWidth {
                windowWidth = maxWindowWidth
                windowHeight = windowWidth / imageAspectRatio
            }
        }

        return CGSize(width: windowWidth, height: windowHeight)
    }

    // 根据图片原始尺寸调整窗口大小
    func adjustWindowSizeForImage(window: NSWindow, imageItem: ImageItem) {
        // 获取屏幕尺寸
        guard let screen = NSScreen.main else { return }
        let screenWidth = screen.visibleFrame.size.width
        let screenHeight = screen.visibleFrame.size.height

        // 直接使用imageItem中的尺寸信息
        let originalSize = imageItem.size

        // 使用新的计算方法
        let windowSize = calculateWindowSizeForImage(originalSize: originalSize)

        // 计算居中位置
        let centerX = screen.visibleFrame.origin.x + (screenWidth - windowSize.width) / 2
        let centerY = screen.visibleFrame.origin.y + (screenHeight - windowSize.height) / 2

        // 设置窗口位置和大小
        let newFrame = NSRect(
            x: centerX,
            y: centerY,
            width: windowSize.width,
            height: windowSize.height
        )

        window.setFrame(newFrame, display: true, animate: true)
    }

}

// NSImage锐化扩展（仅在ImageDetailViewModel中使用）
private extension NSImage {
    /// 共享的CIContext实例，用于GPU加速的图像处理
    /// 重用CIContext可以避免重复初始化开销，提高性能
    private static let sharedCIContext = CIContext(options: [
        .useSoftwareRenderer: false,  // 强制使用GPU加速
        .cacheIntermediates: false,   // 不缓存中间结果，减少内存占用
        .priorityRequestLow: false    // 使用高优先级处理
    ])

    /// 应用锐化滤镜（优化版本）
    /// - Parameters:
    ///   - intensity: 锐化强度，默认1.2
    ///   - radius: 锐化半径，默认1.0
    /// - Returns: 锐化后的NSImage，失败时返回nil
    func sharpened(intensity: Double = 1.2, radius: Double = 1.0) -> NSImage? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let ciImage = CIImage(cgImage: cgImage)

// 添加预模糊之后,这段先清理
//         let noiseFilter = CIFilter.noiseReduction()
//         noiseFilter.inputImage = ciImage
//         noiseFilter.noiseLevel = 0.015 //最大0.1,0.01至0.02
//         noiseFilter.sharpness = 0 //最大1,0.2-1之间,0.8,之前是0
//
//         guard let noiseImage = noiseFilter.outputImage else {
//             return nil
//         }

        // 使用现代API创建滤镜
        let sharpenFilter = CIFilter.unsharpMask()
        sharpenFilter.inputImage = ciImage
        sharpenFilter.intensity = Float(intensity)
        sharpenFilter.radius = Float(radius)

        guard let outputImage = sharpenFilter.outputImage else {
            return nil
        }

        // 保留GPU优化：使用共享CIContext进行渲染
        guard let outputCGImage = Self.sharedCIContext.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }

        // 将CGImage转换为NSImage
        return NSImage(cgImage: outputCGImage, size: self.size)
    }
}
