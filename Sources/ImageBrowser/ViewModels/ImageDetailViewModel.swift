import Foundation
import SwiftUI
import CoreGraphics

class ImageDetailViewModel: ObservableObject {
    @Published var imageItem: ImageItem?
    @Published var fullImage: NSImage?
    
    // 锐化参数
    private let sharpenIntensity: Double = 1.5
    private let sharpenRadius: Double = 0.5
    
    // 后台处理队列
    private let processingQueue = DispatchQueue(label: "com.imagebrowser.detail.processing", qos: .userInitiated)
    
    // 图片缓存系统
    private let imageCache = NSCache<NSString, NSImage>()
    private let cacheQueue = DispatchQueue(label: "com.imagebrowser.detail.cache", qos: .utility)
    
    // 预加载参数
    private let preloadCount = 10 // 预加载前后各20张图片
    
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
            DispatchQueue.main.async {
                self.fullImage = cachedImage
                
                // 只在明确要求时调整窗口大小
                if shouldAdjustWindow {
                    // 通知View调整窗口大小
                    let windowSize = self.calculateWindowSizeForImage(originalSize: cachedImage.size)
                    NotificationCenter.default.post(
                        name: .adjustWindowSize,
                        object: nil,
                        userInfo: [
                            "windowSize": windowSize,
                            "imageItem": imageItem
                        ]
                    )
                }
            }
            
            // 预加载相邻图片
            preloadAdjacentImages(for: imageItem)
            return
        }
        
        // 在后台队列执行图片处理
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                // 第一步：加载图片数据并获取原始尺寸
                let imageData = try self.loadImageDataSynchronously(from: imageItem.url)
                guard let originalSize = self.getOriginalImageSize(from: imageData) else {
                    throw NSError(domain: "ImageLoader", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法获取图片尺寸"])
                }
                
                // 第二步：根据图片尺寸计算合适的窗口大小
                let windowSize = self.calculateWindowSizeForImage(originalSize: originalSize)
                
                // 第三步：创建优化图片
                if let finalImage = self.createOptimizedImage(from: imageData, targetSize: windowSize) {
                    // 将图片存入缓存
                    let imageSize = finalImage.size.width * finalImage.size.height * 4 // 估算像素内存占用
                    self.imageCache.setObject(finalImage, forKey: cacheKey, cost: Int(imageSize))
                    
                    // 在主线程更新UI
                    DispatchQueue.main.async {
                        self.fullImage = finalImage
                        
                        // 只在明确要求时调整窗口大小
                        if shouldAdjustWindow {
                            // 通知View调整窗口大小
                            NotificationCenter.default.post(
                                name: .adjustWindowSize,
                                object: nil,
                                userInfo: [
                                    "windowSize": windowSize,
                                    "imageItem": imageItem
                                ]
                            )
                        }
                    }
                    
                    // 预加载相邻图片
                    self.preloadAdjacentImages(for: imageItem)
                } else {
                    DispatchQueue.main.async {
                        self.fullImage = nil
                    }
                }
                
            } catch {
                DispatchQueue.main.async {
                    self.fullImage = nil
                }
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
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 获取当前图片在列表中的索引
            guard let currentIndex = AppState.shared.images.firstIndex(of: currentItem) else {
                return
            }
            
            // 计算预加载范围
            let startIndex = max(0, currentIndex - self.preloadCount)
            let endIndex = min(AppState.shared.images.count - 1, currentIndex + self.preloadCount)
            
            // 预加载范围内的图片
            for i in startIndex...endIndex {
                // 跳过当前图片
                if i == currentIndex { continue }
                
                let imageItem = AppState.shared.images[i]
                let cacheKey = imageItem.url.absoluteString as NSString
                
                // 检查是否已缓存
                if self.imageCache.object(forKey: cacheKey) == nil {
                    // 异步加载并缓存图片
                    self.processingQueue.async {
                        do {
                            let imageData = try self.loadImageDataSynchronously(from: imageItem.url)
                            guard let originalSize = self.getOriginalImageSize(from: imageData) else { return }
                            
                            let windowSize = self.calculateWindowSizeForImage(originalSize: originalSize)
                            if let optimizedImage = self.createOptimizedImage(from: imageData, targetSize: windowSize) {
                                // 存入缓存
                                let imageSize = optimizedImage.size.width * optimizedImage.size.height * 4
                                self.imageCache.setObject(optimizedImage, forKey: cacheKey, cost: Int(imageSize))
                            }
                        } catch {
                            // 预加载失败，忽略错误
                            print("预加载图片失败: \(imageItem.url.lastPathComponent)")
                        }
                    }
                }
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
        // 使用NSImage初始化
        guard let nsImage = NSImage(data: data) else {
            return nil
        }
        
        // 获取原始尺寸
        let originalSize = nsImage.size
        let width = Int(originalSize.width)
        let height = Int(originalSize.height)
        
        // 使用提供的targetSize，如果没有则使用默认大小
        let windowSize = targetSize ?? CGSize(width: 1024, height: 768)
        let maxWindowDimension = max(windowSize.width, windowSize.height)
        
        // 根据窗口大小计算缩放后的尺寸
        let imageMaxDimension = max(CGFloat(width), CGFloat(height))
        let scale = maxWindowDimension / imageMaxDimension
        
        // 如果图片小于目标尺寸，不需要缩放
        if scale >= 1.0 {
            return nsImage.sharpened(intensity: self.sharpenIntensity, radius: self.sharpenRadius) ?? nsImage
        }
        
        // 计算缩放后的尺寸
        let scaledWidth = Int(CGFloat(width) * scale)
        let scaledHeight = Int(CGFloat(height) * scale)
        let scaledSize = NSSize(width: scaledWidth, height: scaledHeight)
        
        // 创建缩放后的图像
        guard let resizedImage = resizeImage(nsImage, to: scaledSize) else {
            return nsImage
        }
        
        // 应用锐化滤镜
        return resizedImage.sharpened(intensity: self.sharpenIntensity, radius: self.sharpenRadius) ?? resizedImage
    }
    
    // 辅助方法：调整图像尺寸
    private func resizeImage(_ image: NSImage, to size: NSSize) -> NSImage? {
        let newImage = NSImage(size: size)
        
        newImage.lockFocus()
        let context = NSGraphicsContext.current?.cgContext
        
        // 设置高质量插值
        context?.interpolationQuality = .high
        
        // 绘制图像
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        
        newImage.unlockFocus()
        
        return newImage.size.width > 0 && newImage.size.height > 0 ? newImage : nil
    }
    
    // 公开方法：获取原始图片尺寸（供View调用）
    func getOriginalImageSize(from data: Data) -> CGSize? {
        guard let nsImage = NSImage(data: data) else {
            return nil
        }
        
        return nsImage.size
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
        
        // 直接加载图片数据获取原始尺寸
        do {
            let imageData = try Data(contentsOf: imageItem.url)
            
            // 获取原始图片尺寸
            guard let originalSize = getOriginalImageSize(from: imageData) else { return }
            
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
            
        } catch {
            print("无法获取原始图片尺寸: \(error)")
        }
    }

}