import Foundation
import SwiftUI
import CoreImage

/// NSImage扩展：添加锐化功能
extension NSImage {
    /// 应用锐化滤镜
    func sharpened(intensity: Double = 1, radius: Double = 1) -> NSImage? {
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
        
        // 将CIImage转换回NSImage
        let rep = NSCIImageRep(ciImage: outputImage)
        let sharpenedImage = NSImage(size: rep.size)
        sharpenedImage.addRepresentation(rep)
        
        return sharpenedImage
    }
}