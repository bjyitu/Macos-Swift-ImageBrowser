import SwiftUI

// MARK: - 布局相关类型定义

/// 目录组，包含一组图片
struct DirectoryGroup: Identifiable {
    let id = UUID()
    let name: String
    let images: [ImageItem]
    
    init(name: String, images: [ImageItem]) {
        self.name = name
        self.images = images
    }
}

/// 固定网格布局的行结构
struct FixedGridRow {
    let images: [ImageItem]
    let imageSizes: [CGSize] // 每张图片的个性化尺寸
    let totalWidth: CGFloat
    
    var imageCount: Int { images.count }
    
    // 兼容性属性，返回第一张图片的尺寸（用于向后兼容）
    var imageSize: CGSize {
        return imageSizes.first ?? .zero
    }
}

/// 布局计算器协议
protocol LayoutCalculatorProtocol {
    /// 获取固定网格行
    func getFixedGridRows(for group: DirectoryGroup, availableWidth: CGFloat, hasReceivedGeometry: Bool) -> [FixedGridRow]
    /// 计算有效宽度
    func calculateEffectiveWidth(availableWidth: CGFloat) -> CGFloat
}

/// 优化的布局计算器 - 使用贪心算法实现高性能justified布局
class LayoutCalculatorOpt: LayoutCalculatorProtocol {
    
    // 布局约束常量 - 简化约束范围
    private enum LayoutConstraints {
        static let minRowHeight: CGFloat = 240
        static let maxRowHeight: CGFloat = 320
        static let targetFillRate: CGFloat = 0.99 // 目标填充率95%
        static let acceptableFillRateRange: ClosedRange<CGFloat> = 0.95...1.0 // 可接受的填充率范围
        static let maxImagesPerRow: Int = 10 // 每行最多图片数，减少计算量
    }
    
    // MARK: - 主要布局方法
    
    /// 使用贪心算法创建智能行布局
    func createSmartRows(from images: [ImageItem], availableWidth: CGFloat, thumbnailSize: CGFloat) -> [FixedGridRow] {
        var rows: [FixedGridRow] = []
        let spacing: CGFloat = 10
        
        var imageIndex = 0
        while imageIndex < images.count {
            let remainingImages = Array(images[imageIndex...])
            
            // 使用贪心算法快速找到最优行
            let optimalRow = createGreedyRow(
                images: remainingImages,
                availableWidth: availableWidth,
                targetHeight: thumbnailSize,
                spacing: spacing
            )
            
            if !optimalRow.images.isEmpty {
                rows.append(optimalRow)
                imageIndex += optimalRow.images.count
            } else {
                // 处理单张图片的保底情况
                let fallbackRow = createSingleImageRow(
                    image: images[imageIndex],
                    availableWidth: availableWidth,
                    targetHeight: thumbnailSize,
                    spacing: spacing
                )
                rows.append(fallbackRow)
                imageIndex += 1
            }
        }
        
        return rows
    }
    
    // MARK: - 贪心算法核心
    
    /// 贪心算法：寻找最优行布局
    private func createGreedyRow(images: [ImageItem], availableWidth: CGFloat, targetHeight: CGFloat, spacing: CGFloat) -> FixedGridRow {
        guard !images.isEmpty else { 
            return FixedGridRow(images: [], imageSizes: [], totalWidth: 0) 
        }
        
        var bestRow: FixedGridRow?
        var bestScore: CGFloat = -1
        
        // 贪心策略：尝试不同数量的图片，选择得分最高的方案
        for imageCount in 1...min(images.count, LayoutConstraints.maxImagesPerRow) {
            let testImages = Array(images.prefix(imageCount))
            let candidateRow = createJustifiedRow(images: testImages, availableWidth: availableWidth, targetHeight: targetHeight, spacing: spacing)
            
            let score = calculateRowScore(row: candidateRow, availableWidth: availableWidth)
            
            if score > bestScore {
                bestScore = score
                bestRow = candidateRow
            }
            
            // 如果找到完美填充，提前退出
            if score >= 0.99 {
                break
            }
        }
        
        return bestRow ?? createSingleImageRow(image: images[0], availableWidth: availableWidth, targetHeight: targetHeight, spacing: spacing)
    }
    
    /// 计算行布局得分 - 贪心策略的核心
    private func calculateRowScore(row: FixedGridRow, availableWidth: CGFloat) -> CGFloat {
        let fillRate = row.totalWidth / availableWidth
        
        // 如果超出可用宽度，得分为负
        if fillRate > 1.0 {
            return -1
        }
        
        // 优先选择接近目标填充率的方案
        let targetDiff = abs(fillRate - LayoutConstraints.targetFillRate)
        let score = 1.0 - targetDiff
        
        return max(0, score)
    }
    
    // MARK: - 基础布局计算
    
    /// 创建justified行布局（基础算法）
    private func createJustifiedRow(images: [ImageItem], availableWidth: CGFloat, targetHeight: CGFloat, spacing: CGFloat) -> FixedGridRow {
        guard !images.isEmpty else {
            return FixedGridRow(images: [], imageSizes: [], totalWidth: 0)
        }
        
        let aspectRatios = images.map { $0.size.width / $0.size.height }
        let totalAspectRatio = aspectRatios.reduce(0, +)
        
        let availableWidthForImages = availableWidth - spacing * CGFloat(images.count - 1)
        let idealHeight = availableWidthForImages / totalAspectRatio
        
        // 约束高度在合理范围内
        let finalHeight = max(LayoutConstraints.minRowHeight, min(LayoutConstraints.maxRowHeight, idealHeight))
        
        let imageSizes = aspectRatios.map { aspectRatio in
            CGSize(width: finalHeight * aspectRatio, height: finalHeight)
        }
        
        let totalWidth = imageSizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(images.count - 1)
        
        // 如果超出宽度，按比例缩放
        if totalWidth > availableWidth {
            let scale = availableWidth / totalWidth
            let scaledHeight = finalHeight * scale
            
            // 确保缩放后的高度仍在合理范围内
            if scaledHeight >= LayoutConstraints.minRowHeight {
                let scaledSizes = imageSizes.map { size in
                    CGSize(width: size.width * scale, height: scaledHeight)
                }
                return FixedGridRow(
                    images: images,
                    imageSizes: scaledSizes,
                    totalWidth: availableWidth
                )
            }
        }
        
        return FixedGridRow(
            images: images,
            imageSizes: imageSizes,
            totalWidth: totalWidth
        )
    }
    
    /// 处理单张图片的特殊情况
    private func createSingleImageRow(image: ImageItem, availableWidth: CGFloat, targetHeight: CGFloat, spacing: CGFloat) -> FixedGridRow {
        let aspectRatio = image.size.width / image.size.height
        let imageWidth = targetHeight * aspectRatio
        
        // 如果单张图片太宽，适当调整高度
        let finalHeight: CGFloat
        if imageWidth > availableWidth {
            finalHeight = availableWidth / aspectRatio
        } else {
            finalHeight = targetHeight
        }
        
        let finalWidth = finalHeight * aspectRatio
        let imageSize = CGSize(width: finalWidth, height: finalHeight)
        
        return FixedGridRow(
            images: [image],
            imageSizes: [imageSize],
            totalWidth: finalWidth
        )
    }
    
    // MARK: - LayoutCalculatorProtocol 实现
    
    func getFixedGridRows(for group: DirectoryGroup, availableWidth: CGFloat, hasReceivedGeometry: Bool) -> [FixedGridRow] {
        guard hasReceivedGeometry else { return [] }
        
        let effectiveWidth = calculateEffectiveWidth(availableWidth: availableWidth)
        let rows = createSmartRows(from: group.images, availableWidth: effectiveWidth, thumbnailSize: 200)
        
        return rows
    }
    
    /// 计算有效宽度（扣除左右边距）
    func calculateEffectiveWidth(availableWidth: CGFloat) -> CGFloat {
        return availableWidth - 20 // 减去左右各10的边距
    }
    

}