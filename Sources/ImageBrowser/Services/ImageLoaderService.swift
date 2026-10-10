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
    ///   - reusableItems: 可复用的已有 ImageItem 列表（P0-1 修复新增）。
    ///     **该列表必须由调用方在主线程从 `AppState.shared.images` 取出后传入。**
    ///     本方法运行在后台线程，绝不能跨线程直接读取 `AppState`：
    ///     修复前这里直接读 `AppState.shared.selectedFolderURL` 与
    ///     `AppState.shared.images`，而主线程同时在 `append`/`removeAll`，
    ///     属于典型的数据竞争，且 `group.wait()` 期间列表随时可能变短，
    ///     可能引发数组越界。改成"主线程取快照、后台只读参数"后彻底消除该竞争。
    /// - Returns: 加载的图片项数组
    func loadImagesFromFolder(
        _ folderURL: URL,
        shouldReuseItems: Bool = true,
        sortType: ImageSortType = .name,
        reusableItems: [ImageItem] = []
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
        
        // 1010需求：一次性收集所有子目录自身的"加入时间"（目录绝对路径 → 时间）。
        // 这样"按添加时间"排序时目录块也能按时间排，而不是永远按名称。
        // 查表在 ImageItem 构造时按路径使用，避免每张图片重复 stat 同一批目录。
        let directoryAddedDates = collectDirectoryAddedDates(from: contents)
        
        var existingImages: [ImageItem] = []
        var existingImageMap: [String: ImageItem] = [:]
        
        if shouldReuseItems {
            // P0-1 修复：原实现在此读取 AppState.shared.selectedFolderURL 与
            // AppState.shared.images。本方法运行在后台线程，而主线程可能正在
            // 对这些属性做整体赋值 / append / removeAll，构成数据竞争。
            // 现在"是否同一目录"的判断与快照的提取都上移到主线程调用方完成，
            // 这里只使用传入的不可变快照 reusableItems。
            existingImages = reusableItems
            
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
                    // 1010需求：带上根目录与目录时间表，让 ImageItem 算好
                    // relativeDirectory / directoryAddedDates（目录优先排序要用）
                    item = ImageItem(url: url, rootURL: folderURL, directoryAddedDates: directoryAddedDates)
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
        // 1010需求：排序逻辑已抽到 `ImageSorter`（纯函数），既能在这里用，
        // 也能让"切换排序方式"在不重新扫盘的情况下对内存中的列表复用同一套规则。
        imageItems = ImageSorter.sort(imageItems, by: sortType)
        if sortType == .random {
            // 缓存随机排序的结果，保证同一目录再次打开时随机顺序稳定
            cacheSortedImages(imageItems, for: folderURL)
        }
        
        print("Loaded \(imageItems.count) images from folder (\(existingImages.count > 0 ? "reused \(imageItems.filter { existingImageMap[$0.url.path] != nil }.count) existing items" : "all new"))")
        
        return imageItems
    }
    

    
    /// 收集目录自身的"加入其父目录的时间"（1010需求）。
    ///
    /// 目录数量通常远小于图片数量，因此一次性采样并建表（绝对路径 → 时间），
    /// 供所有 `ImageItem` 按路径查用，避免每张图片重复 stat 同一批目录。
    private func collectDirectoryAddedDates(from contents: [URL]) -> [String: Date] {
        var result: [String: Date] = [:]
        for url in contents {
            // 枚举时已预取 .isDirectoryKey，这里的判断很轻
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            result[url.standardizedFileURL.path] = ImageItem.addedDate(of: url)
        }
        return result
    }
    
    /// 随机化图片顺序
    // 1010需求：`randomizeImageOrder` 与嵌套的 `SortType` 枚举已移除——
    // 洗牌与三种排序统一由 `ImageSorter` 提供，避免两处实现各自演化。
    
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
    private func performIncrementalUpdate(for folderURL: URL, cachedItems: [ImageItem], sortType: ImageSortType) -> [ImageItem] {
        let fileManager = FileManager.default
        
        // 创建已缓存图片的路径到ImageItem的映射
        var cachedItemsMap: [String: ImageItem] = [:]
        for item in cachedItems {
            cachedItemsMap[item.url.path] = item
        }
        
        // 获取当前文件夹中的所有图片文件
        var newItems: [ImageItem] = []
        var updatedItems: [ImageItem] = []
        
        // 1010需求：目录时间表。这条路径没有像主路径那样先收集 contents，
        // 因此单独走一遍枚举取目录（此路径仅在随机排序的缓存失效时触发，代价可接受）。
        var directoryAddedDates: [String: Date] = [:]
        if let directoryEnumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            while let url = directoryEnumerator.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                directoryAddedDates[url.standardizedFileURL.path] = ImageItem.addedDate(of: url)
            }
        }
        
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
                        // 1010需求：带上根目录与目录时间表
                        let newItem = ImageItem(url: fileURL, rootURL: folderURL, directoryAddedDates: directoryAddedDates)
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
        
        // 根据排序类型排序（1010需求：统一走 ImageSorter）
        return ImageSorter.sort(updatedItems, by: sortType)
    }
}