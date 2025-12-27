import Foundation

/// 图片加载服务类，统一处理图片加载逻辑
class ImageLoaderService {
    static let shared = ImageLoaderService()
    
    /// 缓存已排序的图片列表，确保同一文件夹的图片顺序一致
    private var sortedImageCache: [String: [ImageItem]] = [:]
    private let cacheQueue = DispatchQueue(label: "com.imagebrowser.sortedimagecache", qos: .utility)
    
    /// 检查是否为图片文件
    /// - Parameter url: 文件URL
    /// - Returns: 如果是图片文件返回true，否则返回false
    func isImageFile(_ url: URL) -> Bool {
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }
    
    /// 获取文件夹的缓存键
    private func cacheKey(for folderURL: URL) -> String {
        return folderURL.standardizedFileURL.path
    }
    
    /// 从文件夹加载图片（保持原有行为）
    /// - Parameters:
    ///   - folderURL: 文件夹URL
    ///   - shouldReuseItems: 是否复用已存在的ImageItem对象
    ///   - sortType: 排序类型
    /// - Returns: 加载的图片项数组
    func loadImagesFromFolder(
        _ folderURL: URL,
        shouldReuseItems: Bool = true,
        sortType: SortType = .fileName
    ) -> [ImageItem] {
        print("Loading images from folder: \(folderURL.path)")
        
        // 对于随机排序，检查是否有缓存的结果
        if sortType == .random {
            // clearCache(for: folderURL)
            let key = cacheKey(for: folderURL)
            if let cachedItems = getCachedSortedImages(for: key) {
                print("Using cached sorted images for folder: \(folderURL.path)")
                return cachedItems
            }
        }
        
        let fileManager = FileManager.default
        
        // 使用递归枚举器遍历所有子目录
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: resourceKeys)
        
        var contents: [URL] = []
        if let enumerator = enumerator {
            for case let url as URL in enumerator {
                contents.append(url)
            }
        }
        
        var existingImages: [ImageItem] = []
        var existingImageMap: [String: ImageItem] = [:]
        
        if shouldReuseItems {
            // 检查是否是同一目录且已有图片列表
            let isSameDirectory = AppState.shared.selectedFolderURL == folderURL
            existingImages = isSameDirectory ? AppState.shared.images : []
            
            // 创建URL到现有ImageItem的映射，方便快速查找
            for imageItem in existingImages {
                existingImageMap[imageItem.url.path] = imageItem
            }
        }
        
        // 使用 DispatchGroup 实现内部并发创建 ImageItem（10个10个）
        var imageItems: [ImageItem] = []
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        let lock = NSLock()
        let maxConcurrentTasks = 10
        let semaphore = DispatchSemaphore(value: maxConcurrentTasks)
        
        for url in contents {
            guard ImageLoaderService.shared.isImageFile(url) else { continue }
            
            semaphore.wait()
            group.enter()
            
            queue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                
                var item: ImageItem?
                
                if shouldReuseItems, let existingItem = existingImageMap[url.path] {
                    item = existingItem
                } else {
                    item = ImageItem(url: url)
                }
                
                if let item = item {
                    lock.lock()
                    imageItems.append(item)
                    lock.unlock()
                }
            }
        }
        
        group.wait()
        
        // 根据排序类型进行排序
        switch sortType {
        case .fileName:
            imageItems.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .random:
            imageItems = randomizeImageOrder(imageItems)
            // 缓存随机排序的结果
            cacheSortedImages(imageItems, for: folderURL)
        }
        
        print("Loaded \(imageItems.count) images from folder (\(existingImages.count > 0 ? "reused \(imageItems.filter { existingImageMap[$0.url.path] != nil }.count) existing items" : "all new"))")
        
        return imageItems
    }
    

    
    /// 随机化图片顺序
    private func randomizeImageOrder(_ images: [ImageItem]) -> [ImageItem] {
        guard images.count > 1 else { return images }
        
        var shuffled = images
        
        for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
            let j = Int.random(in: 0...i)
            shuffled.swapAt(i, j)
        }
        
        return shuffled
    }
    
    /// 排序类型枚举
    enum SortType {
        case fileName
        case random
    }
    
    /// 缓存随机排序的图片列表
    private func cacheSortedImages(_ images: [ImageItem], for folderURL: URL) {
        let key = cacheKey(for: folderURL)
        cacheQueue.async {
            self.sortedImageCache[key] = images
        }
    }
    
    /// 获取缓存的随机排序图片列表
    private func getCachedSortedImages(for key: String) -> [ImageItem]? {
        var cachedItems: [ImageItem]? = nil
        cacheQueue.sync {
            cachedItems = self.sortedImageCache[key]
        }
        return cachedItems
    }
    
    /// 清除特定文件夹的缓存
    func clearCache(for folderURL: URL) {
        let key = cacheKey(for: folderURL)
        cacheQueue.async {
            self.sortedImageCache.removeValue(forKey: key)
        }
    }
    
    /// 清除所有缓存
    func clearAllCache() {
        cacheQueue.async {
            self.sortedImageCache.removeAll()
        }
    }
}