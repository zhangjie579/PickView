//
//  NSView+PVClient.m
//  PickViewMac
//
//  Created by kris cheng on 2026/7/9.
//

#import "PVDetailPrefix.h"
#import "NSView+PVClient.h"

@implementation NSView (PVClient)

- (BOOL)isVisible {
    return !self.hidden && self.alphaValue > 0;
}

- (NSString *)backgroundColorName {
    return [self pv_inspect_getBindObjectForKey:@"lk_backgroundColorName"];
}

- (void)setBackgroundColorName:(NSString *)backgroundColorName {
    [self pv_inspect_bindObject:backgroundColorName forKey:@"lk_backgroundColorName"];
    if (!backgroundColorName) {
        [self pv_setLayerBackgroundColor:nil];
    } else {
        [self pv_setLayerBackgroundColor:[NSColor colorNamed:backgroundColorName]];
    }
}

- (void)showDebugBorder {
    self.layer.borderWidth = 1;
    self.layer.borderColor = [NSColor whiteColor].CGColor;
}

- (void)lk_insertSubviewAtBottom:(NSView *)view {
    if (self.subviews.count) {
        [self addSubview:view positioned:NSWindowBelow relativeTo:self.subviews.firstObject];
    } else {
        [self addSubview:view];
    }
}

@end

static NSString * const PVLayerBackgroundColorKey = @"pv_layerBackgroundColor";
static NSString * const PVLayerBorderColorKey = @"pv_layerBorderColor";

@implementation NSView (PVClientAppearance)

- (void)pv_setLayerBackgroundColor:(NSColor *)color {
    [self pv_inspect_bindObject:color forKey:PVLayerBackgroundColorKey];
    if (!color) {
        self.layer.backgroundColor = nil;
    }
    [self pv_applyBoundLayerColors];
}

- (void)pv_setLayerBorderColor:(NSColor *)color {
    [self pv_inspect_bindObject:color forKey:PVLayerBorderColorKey];
    [self pv_applyBoundLayerColors];
}

- (void)pv_applyBoundLayerColors {
    NSColor *backgroundColor = [self pv_inspect_getBindObjectForKey:PVLayerBackgroundColorKey];
    NSColor *borderColor = [self pv_inspect_getBindObjectForKey:PVLayerBorderColorKey];
    if (!backgroundColor && !borderColor) {
        return;
    }
    /// ⚠️ 关键：动态系统色（NSColor.windowBackgroundColor / colorNamed: 的 Asset 颜色等）
    /// 在「非绘制上下文」里解析时，看的是 NSAppearance.currentAppearance；
    /// 若它从未被显式设置过，AppKit 会回退到**系统外观**（而且首次解析后还会锁存），
    /// 完全无视 NSApp.appearance —— 于是 App 被钉在暗色、系统却是亮色时，
    /// 这些颜色取出来的永远是亮色值，界面就切不过去。
    /// 因此在取值前显式把当前外观设成这个 view 自己的 effectiveAppearance，
    /// 取完再还原。绘制过程中 AppKit 本身就会压栈正确的外观，不受这里影响。
    NSAppearance *saved = NSAppearance.currentAppearance;
    NSAppearance.currentAppearance = self.effectiveAppearance ?: NSApp.effectiveAppearance;
    if (backgroundColor) {
        self.layer.backgroundColor = backgroundColor.CGColor;
    }
    if (borderColor) {
        self.layer.borderColor = borderColor.CGColor;
    }
    NSAppearance.currentAppearance = saved;
}

+ (void)pv_refreshAppearanceColorsIn:(NSView *)view {
    if (!view) {
        return;
    }
    [view pv_applyBoundLayerColors];
    /// PVDetailBaseView 及其子类把深/浅色成对写在 backgroundColors / borderColors 里，
    /// 平时靠 AppKit 的 viewDidChangeEffectiveAppearance 级联触发 updateColors。
    /// 但那次级联是异步的，且对「已经不在窗口里的 view 层级」AppKit 根本不会派发，
    /// 这里主动补一次，保证切换方向（亮→暗 / 暗→亮）都立即生效。
    if ([view respondsToSelector:@selector(updateColors)]) {
        [(id)view updateColors];
    }
    [view setNeedsLayout:YES];
    [view setNeedsDisplay:YES];
    for (NSView *subview in view.subviews) {
        [NSView pv_refreshAppearanceColorsIn:subview];
    }
}

@end
