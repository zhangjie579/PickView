//
//  AppDelegate.m
//  PickViewMac
//
//  Created by kris cheng on 2026/7/5.
//

#import "AppDelegate.h"

#import "PVClientWindowController.h"

@interface AppDelegate ()

@property (nonatomic, strong) PVClientWindowController *clientWindowController;

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self pv_installEditMenu];
    self.clientWindowController = [[PVClientWindowController alloc] init];
    [self.clientWindowController start];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.clientWindowController stop];
}

#pragma mark - Edit Menu

/// macOS 上剪切 / 拷贝 / 粘贴 / 全选 / 撤销这些快捷键，并不是由 NSTextField 自己处理的，
/// 而是依赖主菜单里 Edit 子菜单的 NSMenuItem.keyEquivalent 做派发：
/// NSApplication 收到 ⌘+key 时先做 key equivalent 匹配，命中后把对应 action 发给 responder chain。
///
/// 本 App 没有 MainMenu nib（Info.plist 无 NSMainNibFile，Resources 构建阶段为空），
/// AppKit 只会代为生成一个不含 Edit 的空壳菜单栏，于是 ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z
/// 在 AppKit 里找不到任何 keyEquivalent 载体 —— 所有输入框里这些键都会失灵（不是被谁抢走）。
///
/// 因此在启动时用代码把 Edit 菜单补进 NSApp.mainMenu 即可恢复。
- (void)pv_installEditMenu {
    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu) {
        mainMenu = [[NSMenu alloc] initWithTitle:@""];
        [NSApp setMainMenu:mainMenu];
    }
    if ([mainMenu itemWithTitle:NSLocalizedString(@"Edit", nil)]) {
        return;
    }

    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Edit", nil)
                                                          action:NULL
                                                   keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Edit", nil)];
    editMenuItem.submenu = editMenu;

    // ⚠️ target 必须保持为 nil：这样 action 会沿 responder chain 派发到当前的 first responder
    // （输入框的 field editor、NSTextView、表格等），同一个菜单项才能在所有输入框里生效。
    // ⚠️ autoenablesItems 保持默认的 YES：AppKit 会依据 responder chain 上能否响应 action
    // 自动置灰菜单项（例如剪贴板为空时「粘贴」变灰）。
    [editMenu addItem:[self pv_editItemWithTitle:NSLocalizedString(@"Undo", nil)
                                          action:@selector(undo:)
                                   keyEquivalent:@"z"
                                    modifierMask:NSEventModifierFlagCommand]];
    [editMenu addItem:[self pv_editItemWithTitle:NSLocalizedString(@"Redo", nil)
                                          action:@selector(redo:)
                                   keyEquivalent:@"z"
                                    modifierMask:NSEventModifierFlagCommand | NSEventModifierFlagShift]];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItem:[self pv_editItemWithTitle:NSLocalizedString(@"Cut", nil)
                                          action:@selector(cut:)
                                   keyEquivalent:@"x"
                                    modifierMask:NSEventModifierFlagCommand]];
    [editMenu addItem:[self pv_editItemWithTitle:NSLocalizedString(@"Copy", nil)
                                          action:@selector(copy:)
                                   keyEquivalent:@"c"
                                    modifierMask:NSEventModifierFlagCommand]];
    [editMenu addItem:[self pv_editItemWithTitle:NSLocalizedString(@"Paste", nil)
                                          action:@selector(paste:)
                                   keyEquivalent:@"v"
                                    modifierMask:NSEventModifierFlagCommand]];
    [editMenu addItem:[self pv_editItemWithTitle:NSLocalizedString(@"Paste and Match Style", nil)
                                          action:@selector(pasteAsPlainText:)
                                   keyEquivalent:@"v"
                                    modifierMask:NSEventModifierFlagCommand | NSEventModifierFlagShift]];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItem:[self pv_editItemWithTitle:NSLocalizedString(@"Select All", nil)
                                          action:@selector(selectAll:)
                                   keyEquivalent:@"a"
                                    modifierMask:NSEventModifierFlagCommand]];

    [mainMenu addItem:editMenuItem];
}

- (NSMenuItem *)pv_editItemWithTitle:(NSString *)title
                              action:(SEL)action
                       keyEquivalent:(NSString *)keyEquivalent
                        modifierMask:(NSEventModifierFlags)modifierMask {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:keyEquivalent];
    item.target = nil;
    item.keyEquivalentModifierMask = modifierMask;
    return item;
}

#pragma mark -

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end
