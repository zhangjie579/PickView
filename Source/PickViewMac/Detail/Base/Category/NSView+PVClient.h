//
//  NSView+PVClient.h
//  PickViewMac
//
//  Created by kris cheng on 2026/7/9.
//

#import <Cocoa/Cocoa.h>

@interface NSView (PVClient)

@property(nonatomic, assign, readonly) BOOL isVisible;

@property(nonatomic, copy) NSString *backgroundColorName;

/// 将一个 view 作为自己的 subview 并且放到最底部
- (void)lk_insertSubviewAtBottom:(NSView *)view;

- (void)showDebugBorder;

@end

@interface NSView (PVClientAppearance)

/// 把 NSColor 绑定到 layer.backgroundColor。
///
/// 不要直接写 `view.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor`：
/// 那样只在赋值那一刻把动态色解析成静态 CGColorRef，之后 App 从深色切到浅色（ Preferences
/// 里的 Appearance 选项）layer 不会跟着变。这里记住 NSColor 本体，外观变化时由
/// +pv_refreshAppearanceColorsIn: 重新求值。
///
/// 传入静态色（例如 PVColorMake(...)）也安全，只是每次会重复赋同样的值。
- (void)pv_setLayerBackgroundColor:(NSColor *)color;

/// 同上，绑定到 layer.borderColor。需要先自己设置 layer.borderWidth。
- (void)pv_setLayerBorderColor:(NSColor *)color;

/// 遍历 view 及其所有 subview，重新应用绑定的颜色，并把自定义绘制失效掉。
/// App 外观（深/浅）被切换后由 PVDetailPreferenceManager -applyAppearance 调用。
+ (void)pv_refreshAppearanceColorsIn:(NSView *)view;

@end
