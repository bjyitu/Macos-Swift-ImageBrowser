import Foundation
import SwiftUI

class ImageItem: Identifiable, ObservableObject, Equatable {
    let id = UUID()
    let url: URL
    let name: String
    @Published var thumbnailData: Data? // 使用Data存储缩略图数据
    var size: CGSize // 添加图片尺寸属性
    @Published var thumbnailSize: CGSize? // 添加缩略图尺寸属性
    
    // 计算属性：从Data创建NSImage（仅在需要时创建）
    var thumbnail: NSImage? {
        guard let data = thumbnailData else { return nil }
        return NSImage(data: data)
    }
    
    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        self.thumbnailData = nil
        self.size = CGSize(width: 1.0, height: 1.0) // 默认尺寸，避免除零错误
        self.thumbnailSize = nil // 默认缩略图尺寸为空
        
        // 尝试从图片文件获取实际尺寸
        if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
           let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
           let width = imageProperties[kCGImagePropertyPixelWidth as String] as? CGFloat,
           let height = imageProperties[kCGImagePropertyPixelHeight as String] as? CGFloat {
            self.size = CGSize(width: width, height: height)
        }
    }
    
    static func == (lhs: ImageItem, rhs: ImageItem) -> Bool {
        return lhs.id == rhs.id
    }
}