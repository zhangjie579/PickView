//
//  UIImage+PVInspectDownsample.m
//  PickView
//
//  Created by kris cheng on 2026/11/8.
//

#import "UIImage+PVInspectDownsample.h"

#if TARGET_OS_IPHONE

@implementation UIImage (PVInspectDownsample)

+ (NSData *)pv_downsampledPNGDataForImage:(UIImage *)image
                          maxPixelLength:(CGFloat)maxPixelLength {
    if (!image || !image.CGImage || maxPixelLength <= 0) {
        return image ? UIImagePNGRepresentation(image) : nil;
    }

    CGFloat pixelWidth = image.size.width * image.scale;
    CGFloat pixelHeight = image.size.height * image.scale;
    CGFloat longestPixel = MAX(pixelWidth, pixelHeight);
    if (!(longestPixel > maxPixelLength)) {
        // 未超限：保持原生像素密度，直接编码，避免一次无谓的重绘损失清晰度。
        return UIImagePNGRepresentation(image);
    }

    CGFloat factor = maxPixelLength / longestPixel;
    CGSize targetPixelSize = CGSizeMake(MAX((CGFloat)1, floor(pixelWidth * factor)),
                                        MAX((CGFloat)1, floor(pixelHeight * factor)));

    // 按裸像素绘制，绕开隐式的屏幕 scale 语义。
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat new];
    format.opaque = NO;
    format.scale = 1;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:targetPixelSize format:format];
    UIImage *downsampled = [renderer imageWithActions:
        ^(UIGraphicsImageRendererContext *context) {
            [image drawInRect:CGRectMake(0, 0,
                                         targetPixelSize.width,
                                         targetPixelSize.height)];
        }];
    if (!downsampled.CGImage) {
        return UIImagePNGRepresentation(image);
    }

    // 关键一步：重新标定 scale，让 UIImage.size（逻辑点）保持不变。
    // PNG 编码时 pHYs 元数据会带上这个 scale，Mac 端解码出的 NSImage 逻辑
    // 尺寸因此和 view frame 依然一致。
    CGFloat retaggedScale = image.scale / factor;
    UIImage *retagged = [UIImage imageWithCGImage:downsampled.CGImage
                                            scale:retaggedScale
                                      orientation:image.imageOrientation];
    return UIImagePNGRepresentation(retagged);
}

@end

#endif
