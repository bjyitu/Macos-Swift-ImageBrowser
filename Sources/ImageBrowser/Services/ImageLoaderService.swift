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
            
            // 检查文件夹内容是否发生变化
            if let cachedItems = getCachedSortedImages(for: key),
               !hasFolderContentChanged(folderURL, cachedItems: cachedItems) {
                print("Using cached sorted images for folder: \(folderURL.path)")
                return cachedItems
            } else if let cachedItems = getCachedSortedImages(for: key) {
                // 内容已变化，执行增量更新
                print("Performing incremental update for folder: \(folderURL.path)")
                let updatedItems = performIncrementalUpdate(for: folderURL, cachedItems: cachedItems, sortType: sortType)
                cacheSortedImages(updatedItems, for: folderURL)
                return updatedItems
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
        let maxConcurrentTasks = 200
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
    
    /// 检查文件夹内容是否发生变化
    /// - Parameters:
    ///   - folderURL: 文件夹URL
    ///   - cachedItems: 缓存的图片项数组
    /// - Returns: 如果内容已变化返回true，否则返回false
    private func hasFolderContentChanged(_ folderURL: URL, cachedItems: [ImageItem]) -> Bool {
        let fileManager = FileManager.default
        
        // 获取当前文件夹中的所有图片文件
        var currentImagePaths: Set<String> = []
        
        do {
            let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
            let enumerator = fileManager.enumerator(at: folderURL,
                                                  includingPropertiesForKeys: resourceKeys,
                                                  options: [.skipsHiddenFiles])
            
            while let fileURL = enumerator?.nextObject() as? URL {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                
                // 只处理图片文件，跳过目录
                if let isDirectory = resourceValues.isDirectory, !isDirectory,
                   isImageFile(fileURL) {
                    currentImagePaths.insert(fileURL.path)
                }
            }
        } catch {
            print("Error enumerating files for change detection: \(error)")
            return true // 出错时认为内容已变化
        }
        
        // 获取缓存中的图片路径
        let cachedImagePaths = Set(cachedItems.map { $0.url.path })
        
        // 比较两个集合是否相同
        return currentImagePaths != cachedImagePaths
    }
    
    /// 执行增量更新
    /// - Parameters:
    ///   - folderURL: 文件夹URL
    ///   - cachedItems: 缓存的图片项数组
    ///   - sortType: 排序类型
    /// - Returns: 更新后的图片项数组
    private func performIncrementalUpdate(for folderURL: URL, cachedItems: [ImageItem], sortType: SortType) -> [ImageItem] {
        let fileManager = FileManager.default
        
        // 创建已缓存图片的路径到ImageItem的映射
        var cachedItemsMap: [String: ImageItem] = [:]
        for item in cachedItems {
            cachedItemsMap[item.url.path] = item
        }
        
        // 获取当前文件夹中的所有图片文件
        var newItems: [ImageItem] = []
        var updatedItems: [ImageItem] = []
        
        do {
            let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
            let enumerator = fileManager.enumerator(at: folderURL,
                                                  includingPropertiesForKeys: resourceKeys,
                                                  options: [.skipsHiddenFiles])
            
            while let fileURL = enumerator?.nextObject() as? URL {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                
                // 只处理图片文件，跳过目录
                if let isDirectory = resourceValues.isDirectory, !isDirectory,
                   isImageFile(fileURL) {
                    
                    if let cachedItem = cachedItemsMap[fileURL.path] {
                        // 文件已存在，保留缓存的ImageItem
                        updatedItems.append(cachedItem)
                    } else {
                        // 新文件，创建新的ImageItem
                        let newItem = ImageItem(url: fileURL)
                        newItems.append(newItem)
                        updatedItems.append(newItem)
                    }
                }
            }
        } catch {
            print("Error performing incremental update: \(error)")
            // 出错时回退到完全重新加载
            return loadImagesFromFolder(folderURL, shouldReuseItems: false, sortType: sortType)
        }
        
        // 根据排序类型排序
        switch sortType {
        case .fileName:
            return updatedItems.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        case .random:
            return updatedItems.shuffled()
        }
    }
}