import Foundation
import SwiftUI
import CoreImage

/// NSImage扩展：添加锐化功能
extension NSImage {
    /// 共享的CIContext实例，用于GPU加速的图像处理
    /// 重用CIContext可以避免重复初始化开销，提高性能
    private static let sharedCIContext = CIContext(options: [
        .useSoftwareRenderer: false,  // 强制使用GPU加速
        .cacheIntermediates: false,   // 不缓存中间结果，减少内存占用
        .priorityRequestLow: false    // 使用高优先级处理
    ])
    
    /// 应用锐化滤镜（GPU优化版本）
    /// - Parameters:
    ///   - intensity: 锐化强度，默认1.2
    ///   - radius: 锐化半径，默认1.0
    /// - Returns: 锐化后的NSImage，失败时返回nil
    func sharpened(intensity: Double = 1.2, radius: Double = 1.0) -> NSImage? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        let ciImage = CIImage(cgImage: cgImage)
        
        // 创建USM锐化滤镜（Unsharp Mask）
        let filter = CIFilter(name: "CIUnsharpMask")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(NSNumber(value: intensity), forKey: "inputIntensity")
        filter?.setValue(NSNumber(value: radius), forKey: "inputRadius")
        
        guard let outputImage = filter?.outputImage else {
            return nil
        }
        
        // 使用共享的CIContext进行GPU渲染
        guard let outputCGImage = Self.sharedCIContext.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }
        
        // 将CGImage转换为NSImage
        return NSImage(cgImage: outputCGImage, size: self.size)
    }
}