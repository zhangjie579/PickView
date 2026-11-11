//
//  UIImage+PVInspectDownsample.h
//  PickView
//
//  Created by kris cheng on 2026/11/8.
//

#import "PVInspectionDefines.h"

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>

@interface UIImage (PVInspectDownsample)

/// 把截图编码成 PNG，编码前按 `maxPixelLength`（最长像素边）统一降采样。
///
/// 与直接把采集 scale 写小不同，这里的降采样发生在所有像素↔逻辑点换算完成
/// 之后：输出图像的 `UIImage.size`（逻辑点）始终与原图保持一致，只是
/// `image.scale` 相应变大、像素密度变小，因此采集链路和 Mac 端的布局逻辑
/// 完全不受影响。
///
/// @param image 原始截图（通常为原生 scale 采集的 UIImage）
/// @param maxPixelLength 允许的最长像素边；原图未超限时原样编码，不做重绘
+ (NSData *)pv_downsampledPNGDataForImage:(UIImage *)image
                          maxPixelLength:(CGFloat)maxPixelLength;

@end
#endif
