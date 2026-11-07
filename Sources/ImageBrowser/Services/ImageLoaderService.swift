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
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }
    
    /// 判断是否为目录。不存在的路径返回 false。
    func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
    
    /// 获取文件夹的缓存键。
    ///
    /// 前缀也进 key：同一个目录在不同来源集合里可能拿到不同的虚拟根 label
    ///（例如同名目录被消歧成 `A (2)`），缓存不能把旧前缀的 item 直接返回。
    private func cacheKey(for folderURL: URL, prefix: [String] = []) -> String {
        let base = folderURL.standardizedFileURL.path
        guard !prefix.isEmpty else { return base }
        return base + "|" + prefix.joined(separator: "/")
    }
    
    /// 从文件夹加载图片（保持原有行为）
    /// - Parameters:
    ///   - folderURL: 文件夹URL
    ///   - shouldReuseItems: 是否复用已存在的ImageItem对象
    ///   - sortType: 排序类型
    ///   - reusableItems: 可复用的已有 ImageItem 列表（P0-1 修复新增）。
    ///     **该列表必须由调用方在主线程从 `AppState.shared.images` 取出后传入。**
    ///     本方法运行在后台线程，绝不能跨线程直接读取 `AppState`：
    ///     修复前这里直接读 `AppState.shared.openURLs` 与
    ///     `AppState.shared.images`，而主线程同时在 `append`/`removeAll`，
    ///     属于典型的数据竞争，且 `group.wait()` 期间列表随时可能变短，
    ///     可能引发数组越界。改成"主线程取快照、后台只读参数"后彻底消除该竞争。
    ///   - relativePrefix: 虚拟根下一级前缀（多来源合并时用，单目录传空即可）
    ///   - prefixDates: 与 `relativePrefix` 一一对应的目录时间
    /// - Returns: 加载的图片项数组
    func loadImagesFromFolder(
        _ folderURL: URL,
        shouldReuseItems: Bool = true,
        sortType: ImageSortType = .name,
        reusableItems: [ImageItem] = [],
        relativePrefix: [String] = [],
        prefixDates: [Date] = []
    ) -> [ImageItem] {
        print("Loading images from folder: \(folderURL.path)")
        
        // 对于随机排序，检查是否有缓存的结果
        if sortType == .random {
            // clearCache(for: folderURL)
            let key = cacheKey(for: folderURL, prefix: relativePrefix)
            
            // 检查文件夹内容是否发生变化
            if let cachedItems = getCachedSortedImages(for: key),
               !hasFolderContentChanged(folderURL, cachedItems: cachedItems) {
                print("Using cached sorted images for folder: \(folderURL.path)")
                return cachedItems
            } else if let cachedItems = getCachedSortedImages(for: key) {
                // 内容已变化，执行增量更新
                print("Performing incremental update for folder: \(folderURL.path)")
                let updatedItems = performIncrementalUpdate(
                    for: folderURL,
                    cachedItems: cachedItems,
                    sortType: sortType,
                    relativePrefix: relativePrefix,
                    prefixDates: prefixDates
                )
                cacheSortedImages(updatedItems, for: folderURL, prefix: relativePrefix)
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
            // P0-1 修复：原实现在此读取 AppState.shared.openURLs 与
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
                    item = ImageItem(
                        url: url,
                        rootURL: folderURL,
                        directoryAddedDates: directoryAddedDates,
                        relativePrefix: relativePrefix,
                        prefixDates: prefixDates
                    )
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
            cacheSortedImages(imageItems, for: folderURL, prefix: relativePrefix)
        }
        
        print("Loaded \(imageItems.count) images from folder (\(existingImages.count > 0 ? "reused \(imageItems.filter { existingImageMap[$0.url.path] != nil }.count) existing items" : "all new"))")
        
        return imageItems
    }
    
    /// 一次打开多个来源：目录递归展开，单独的文件只取自身。
    ///
    /// 规则：
    /// - 目录内的图片带 `[目录名]` 前缀，作为虚拟根下的一块；
    /// - 单独选中的文件直接挂在虚拟根下（`relativeDirectory = []`）；
    /// - 目录先于文件处理：文件若同时落在某个已选目录里，保留目录里的那份，避免重复；
    /// - 外层目录先于内层：被包含的目录不再重复扫描；
    /// - 合并后按 `url.path` 去重，再统一排序。
    func loadImages(
        from urls: [URL],
        shouldReuseItems: Bool = true,
        sortType: ImageSortType = .name,
        reusableItems: [ImageItem] = []
    ) -> [ImageItem] {
        var directories: [URL] = []
        var files: [URL] = []
        var seenInputs = Set<String>()
        
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seenInputs.insert(path).inserted else { continue }
            
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                directories.append(url)
            } else if isImageFile(url) {
                files.append(url)
            }
        }
        
        // 目录按路径排序：`/A` 必然排在 `/A/B` 前，保证"外层先处理"。
        directories.sort { $0.path < $1.path }
        files.sort { $0.path < $1.path }
        
        let labels = Self.uniqueDirectoryLabels(for: directories)
        
        var reusableMap: [String: ImageItem] = [:]
        if shouldReuseItems {
            for item in reusableItems {
                reusableMap[item.url.path] = item
            }
        }
        
        var result: [ImageItem] = []
        var seenItems = Set<String>()
        var processedDirectories: [String] = []
        var loadedSourceCount = 0
        
        func appendIfNew(_ item: ImageItem) {
            if seenItems.insert(item.url.path).inserted {
                result.append(item)
            }
        }
        
        for directory in directories {
            let directoryPath = directory.standardizedFileURL.path
            // 已经被外层目录覆盖，跳过重复扫描
            if processedDirectories.contains(where: { directoryPath.hasPrefix($0 + "/") }) {
                continue
            }
            processedDirectories.append(directoryPath)
            
            let label = labels[directoryPath] ?? directory.lastPathComponent
            let items = loadImagesFromFolder(
                directory,
                shouldReuseItems: shouldReuseItems,
                sortType: sortType,
                reusableItems: reusableItems,
                relativePrefix: [label],
                prefixDates: [.distantPast]
            )
            for item in items {
                appendIfNew(item)
            }
            loadedSourceCount += 1
        }
        
        for file in files {
            let filePath = file.standardizedFileURL.path
            // 落在已选目录里的文件已经由目录带进来
            if processedDirectories.contains(where: { filePath.hasPrefix($0 + "/") }) {
                continue
            }
            
            let item: ImageItem
            if shouldReuseItems, let existing = reusableMap[file.path] {
                item = existing
            } else {
                item = ImageItem(url: file)
            }
            appendIfNew(item)
            loadedSourceCount += 1
        }
        
        // 单来源时不要重排：`loadImagesFromFolder` 已经排好，随机排序还依赖它按目录
        // 缓存的结果来保证"再次打开同一目录顺序稳定"。多来源才需要按虚拟根前缀统一排序。
        let sorted = loadedSourceCount <= 1 ? result : ImageSorter.sort(result, by: sortType)
        print("Loaded \(sorted.count) images from \(directories.count) folder(s) + \(files.count) file(s)")
        return sorted
    }
    
    /// 为虚拟根下的目录生成唯一 label。同名目录追加 ` (2)`、` (3)`…
    ///
    /// 正常从同一个目录多选时不会重名（文件系统保证），这里只是跨目录拖拽
    /// （Finder 搜索/列表展开）时的兜底，避免两个目录的内容在排序里并成一块。
    private static func uniqueDirectoryLabels(for directories: [URL]) -> [String: String] {
        var counts: [String: Int] = [:]
        var labels: [String: String] = [:]
        
        for directory in directories {
            let path = directory.standardizedFileURL.path
            let base = directory.lastPathComponent.isEmpty ? path : directory.lastPathComponent
            let count = (counts[base] ?? 0) + 1
            counts[base] = count
            labels[path] = count == 1 ? base : "\(base) (\(count))"
        }
        return labels
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
    private func cacheSortedImages(_ images: [ImageItem], for folderURL: URL, prefix: [String] = []) {
        let key = cacheKey(for: folderURL, prefix: prefix)
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
    private func performIncrementalUpdate(
        for folderURL: URL,
        cachedItems: [ImageItem],
        sortType: ImageSortType,
        relativePrefix: [String],
        prefixDates: [Date]
    ) -> [ImageItem] {
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
                        let newItem = ImageItem(
                            url: fileURL,
                            rootURL: folderURL,
                            directoryAddedDates: directoryAddedDates,
                            relativePrefix: relativePrefix,
                            prefixDates: prefixDates
                        )
                        newItems.append(newItem)
                        updatedItems.append(newItem)
                    }
                }
            }
        } catch {
            print("Error performing incremental update: \(error)")
            // 出错时回退到完全重新加载
            return loadImagesFromFolder(
                folderURL,
                shouldReuseItems: false,
                sortType: sortType,
                relativePrefix: relativePrefix,
                prefixDates: prefixDates
            )
        }
        
        // 根据排序类型排序（1010需求：统一走 ImageSorter）
        return ImageSorter.sort(updatedItems, by: sortType)
    }
}