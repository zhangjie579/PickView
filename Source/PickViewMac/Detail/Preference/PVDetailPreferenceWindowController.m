//
//  PVDetailPreferenceWindowController.m
//  PickViewMac
//
//  Created by kris cheng on 2026/7/9.
//

#import "PVDetailPrefix.h"
#import "PVDetailPreferenceWindowController.h"
#import "PVDetailPreferenceViewController.h"
#import "PVDetailWindow.h"

@implementation PVDetailPreferenceWindowController

- (instancetype)init {
    // 高度需要容纳第二个开关（Bloc 过滤），它的说明文字会换行
    PVDetailWindow *window = [[PVDetailWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 460) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:YES];
    window.movableByWindowBackground = YES;
    window.title = NSLocalizedString(@"Preferences", nil);
    [window center];
    
    if (self = [self initWithWindow:window]) {
        PVDetailPreferenceViewController *vc = [PVDetailPreferenceViewController new];
        window.contentView = vc.view;
        self.contentViewController = vc;
    }
    return self;
}

@end
