import Foundation
import SwiftUI
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

class ImageDetailViewModel: ObservableObject {
    @Published var imageItem: ImageItem?
    @Published var fullImage: NSImage?
    
    // 锐化参数
    private let sharpenIntensity: Double = 10
    private let sharpenRadius: Double = 0.3
    
    // 图片缓存系统
    let imageCache = NSCache<NSString, NSImage>()
    private let cacheQueue = DispatchQueue(label: "com.imagebrowser.detail.cache", qos: .utility)
    
    // 预加载参数
    private let preloadCount = 2 // 预加载前后各2张图片
    
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
    
    
    func loadImage(_ imageItem: ImageItem, shouldAdjustWindow: Bool = true) {
        // 更新当前图片项
        self.imageItem = imageItem
        
        // 首先尝试从缓存获取图片
        let cacheKey = imageItem.url.absoluteString as NSString
        if let cachedImage = imageCache.object(forKey: cacheKey) {
            // 缓存命中：立即更新UI，无需异步延迟
            self.fullImage = cachedImage
            // 预加载相邻图片
            preloadAdjacentImages(for: imageItem)
            return
        }
        
        // 缓存未命中：立即开始同步处理图片，优先保证用户滚动体验
        do {
            // 第一步：直接使用imageItem中的尺寸信息
            let originalSize = imageItem.size
            
            // 第二步：只有在需要调整窗口时才计算窗口大小
            let windowSize = shouldAdjustWindow ? self.calculateWindowSizeForImage(originalSize: originalSize) : nil
            
            // 第三步：一次性加载数据并创建优化图片
            let imageData = try self.loadImageDataSynchronously(from: imageItem.url)
            if let finalImage = self.createOptimizedImage(from: imageData, targetSize: windowSize) {
                // 将图片存入缓存
                let imageSize = finalImage.size.width * finalImage.size.height * 4 // 估算像素内存占用
                self.imageCache.setObject(finalImage, forKey: cacheKey, cost: Int(imageSize))
                
                // 立即更新UI，无需异步
                if self.imageItem?.url == imageItem.url {
                    self.fullImage = finalImage
                }
                
                // 预加载相邻图片
                self.preloadAdjacentImages(for: imageItem)
            } else {
                if self.imageItem?.url == imageItem.url {
                    self.fullImage = nil
                }
            }
            
        } catch {
            if self.imageItem?.url == imageItem.url {
                self.fullImage = nil
            }
        }
    }
    
    // 公共方法：切换到指定图片并管理缓存
    func switchToImage(_ imageItem: ImageItem, shouldAdjustWindow: Bool = false) {
        // 清理超出范围的缓存
        cleanupCache(for: imageItem)
        
        // 加载新图片
        loadImage(imageItem, shouldAdjustWindow: shouldAdjustWindow)
    }
    

    
    // 预加载相邻图片
    private func preloadAdjacentImages(for currentItem: ImageItem) {
        // 获取当前图片在列表中的索引
        guard let currentIndex = AppState.shared.images.firstIndex(of: currentItem) else {
            return
        }
        
        // 计算预加载范围
        let startIndex = max(0, currentIndex - self.preloadCount)
        let endIndex = min(AppState.shared.images.count - 1, currentIndex + self.preloadCount)
        
        // 批量预加载图片
        let preloadItems = (startIndex...endIndex)
            .filter { $0 != currentIndex }
            .map { AppState.shared.images[$0] }
            .filter { self.imageCache.object(forKey: $0.url.absoluteString as NSString) == nil }
        
        // 同步预加载，优先保证当前图片的响应速度
        for imageItem in preloadItems {
            do {
                // 直接使用imageItem中的尺寸信息
                let originalSize = imageItem.size
                let windowSize = self.calculateWindowSizeForImage(originalSize: originalSize)
                
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
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 获取当前图片在列表中的索引
            guard let currentIndex = AppState.shared.images.firstIndex(of: currentItem) else {
                return
            }
            
            // 计算应保留的缓存范围
            let keepStartIndex = max(0, currentIndex - self.preloadCount - 1) // 多保留一张，避免频繁清理
            let keepEndIndex = min(AppState.shared.images.count - 1, currentIndex + self.preloadCount + 1)
            
            // 获取应保留的图片URL集合
            var keepUrls = Set<String>()
            for i in keepStartIndex...keepEndIndex {
                keepUrls.insert(AppState.shared.images[i].url.absoluteString)
            }
            
            // 这里无法直接遍历NSCache的所有键，所以采用另一种策略：
            // 当缓存超过限制时，NSCache会自动清理最久未使用的项
            // 我们已经设置了合理的countLimit和totalCostLimit
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
        
        // 使用Lanczos高质量缩放滤镜
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
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
    func calculateWindowSizeForImage(originalSize: CGSize) -> CGSize {
        // 获取屏幕尺寸
        guard let screen = NSScreen.main else { return CGSize(width: 1024, height: 768) }
        let screenWidth = screen.visibleFrame.size.width
        let screenHeight = screen.visibleFrame.size.height
        
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
        
        // 使用现代API创建滤镜
        // let sharpenFilter = CIFilter.unsharpMask()
        // sharpenFilter.inputImage = ciImage
        // sharpenFilter.intensity = Float(intensity)
        // sharpenFilter.radius = Float(radius)

        let sharpenFilter = CIFilter.noiseReduction()
        sharpenFilter.inputImage = ciImage
        sharpenFilter.noiseLevel = 0.015 //最大0.1,0.01至0.02
        sharpenFilter.sharpness = 0.8 //最大2,0.2-1之间

        
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