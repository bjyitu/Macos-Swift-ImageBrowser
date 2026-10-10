import Foundation
import SwiftUI

class ImageItem: Identifiable, ObservableObject, Equatable {
    let id = UUID()
    let url: URL
    let name: String
    @Published var thumbnailData: Data? // 使用Data存储缩略图数据
    var size: CGSize // 添加图片尺寸属性
    @Published var thumbnailSize: CGSize? // 添加缩略图尺寸属性
    
    // MARK: - 排序所需的元数据（1010需求）
    
    /// 「添加时间」：该文件**加入其所在目录**的时间。
    ///
    /// 优先取 `URLResourceKey.addedToDirectoryDate`——它的语义正是"加入此目录的时间"，
    /// 且实测在修改文件时间后仍保持真实值（与 creationDate / contentModificationDate
    /// 可区分）。该键在部分网络卷 / 非 APFS 卷上可能缺失，因此按
    /// `addedToDirectoryDate → creationDate → contentModificationDate` 逐级兜底。
    let addedAt: Date
    
    /// 相对**加载根目录**的路径分量，用于实现"目录优先"排序。
    ///
    /// 例：根目录为 `/photos`，则 `/photos/2023/a.jpg` → `["2023"]`；
    /// `/photos/a.jpg` → `[]`（根目录下的图片）。
    ///
    /// 之所以在创建时就算好并缓存，是为了让排序变成纯内存比较（不依赖根目录、
    /// 不碰磁盘），从而支持"切换排序不重新扫盘"。
    let relativeDirectory: [String]
    
    /// 每一层祖先目录**自身**的「添加时间」，与 `relativeDirectory` 一一对应。
    ///
    /// 例：`/photos/2023/summer/a.jpg` → `[<2023 的加入时间>, <summer 的加入时间>]`。
    ///
    /// 用途：让"按添加时间"排序时**目录块本身也按时间排序**，而不是永远按名称排。
    /// 目录的时间由加载器一次性收集（按路径查表），避免每张图片重复 stat。
    let directoryAddedDates: [Date]
    
    // 计算属性：从Data创建NSImage（仅在需要时创建）
    var thumbnail: NSImage? {
        guard let data = thumbnailData else { return nil }
        return NSImage(data: data)
    }
    
    /// - Parameters:
    ///   - url: 图片文件 URL
    ///   - rootURL: 本次加载的根目录。用于计算 `relativeDirectory`；
    ///     传 nil 时视为"无目录结构"（如 SwiftUI Preview）。
    ///   - directoryAddedDates: 目录绝对路径 → 该目录自身的加入时间。
    ///     由 `ImageLoaderService` 在加载时统一收集后传入。
    init(url: URL, rootURL: URL? = nil, directoryAddedDates: [String: Date] = [:]) {
        self.url = url
        self.name = url.lastPathComponent
        self.thumbnailData = nil
        self.size = CGSize(width: 1.0, height: 1.0) // 默认尺寸，避免除零错误
        self.thumbnailSize = nil // 默认缩略图尺寸为空
        self.addedAt = Self.addedDate(of: url)
        
        let relative = Self.relativeDirectory(of: url, from: rootURL)
        self.relativeDirectory = relative
        self.directoryAddedDates = Self.resolveDirectoryDates(
            relativeDirectory: relative,
            rootURL: rootURL,
            lookup: directoryAddedDates
        )
        
        // 尝试从图片文件获取实际尺寸
        if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
           let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
           let width = imageProperties[kCGImagePropertyPixelWidth as String] as? CGFloat,
           let height = imageProperties[kCGImagePropertyPixelHeight as String] as? CGFloat {
            self.size = CGSize(width: width, height: height)
        }
    }
    
    // MARK: - 元数据读取
    
    /// 读取某个文件 / 目录"加入其所在目录的时间"，并做兜底。
    ///
    /// 同时供图片（`addedAt`）与目录（`directoryAddedDates`）使用——目录自身的
    /// `addedToDirectoryDate` 语义与文件完全一致（"该目录加入其父目录的时间"）。
    static func addedDate(of url: URL) -> Date {
        let keys: Set<URLResourceKey> = [
            .addedToDirectoryDateKey,
            .creationDateKey,
            .contentModificationDateKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return .distantPast
        }
        return values.addedToDirectoryDate
            ?? values.creationDate
            ?? values.contentModificationDate
            ?? .distantPast
    }
    
    /// 计算相对根目录的路径分量（不含文件名本身）。
    private static func relativeDirectory(of url: URL, from rootURL: URL?) -> [String] {
        guard let rootURL = rootURL else { return [] }
        
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let fullComponents = url.standardizedFileURL.pathComponents
        
        // 必须确实位于根目录之下，否则退化为"无目录结构"，避免算出错误的层级
        guard fullComponents.count > rootComponents.count,
              Array(fullComponents.prefix(rootComponents.count)) == rootComponents else {
            return []
        }
        
        // 去掉根前缀，再去掉文件名本身
        return Array(fullComponents.dropFirst(rootComponents.count).dropLast())
    }
    
    /// 逐级拼出祖先目录路径，并从查表取出各自的加入时间。
    /// 查不到时用 `.distantPast`，由比较器回退到名称比较，保证排序仍然确定。
    private static func resolveDirectoryDates(
        relativeDirectory: [String],
        rootURL: URL?,
        lookup: [String: Date]
    ) -> [Date] {
        guard let rootURL = rootURL, !relativeDirectory.isEmpty else { return [] }
        
        var directoryURL = rootURL.standardizedFileURL
        var dates: [Date] = []
        dates.reserveCapacity(relativeDirectory.count)
        
        for component in relativeDirectory {
            directoryURL.appendPathComponent(component)
            dates.append(lookup[directoryURL.standardizedFileURL.path] ?? .distantPast)
        }
        return dates
    }
    
    static func == (lhs: ImageItem, rhs: ImageItem) -> Bool {
        return lhs.id == rhs.id
    }
}
