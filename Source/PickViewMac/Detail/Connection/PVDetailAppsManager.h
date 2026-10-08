//
//  PVDetailAppsManager.h
//  PickViewMac
//
//  Created by kris cheng on 2026/7/9.
//

#import <Foundation/Foundation.h>
#import "PVDetailInspectableApp.h"

extern NSString *const PVDetailInspectingAppDidEndNotificationName;

@interface PVDetailAppsManager : NSObject

+ (instancetype)sharedInstance;

/// 获取当前所有可查看的 iOS app
/// needImages 是否需要返回截图和图标，不需要则可加快速度
/// localInfos 本地已经存在的 appInfos，传入该参数从而可增量更新
/// data 为 NSArray<PVDetailInspectableApp *>，该方法不会 sendError
- (RACSignal *)fetchAppInfosWithImage:(BOOL)needImages localInfos:(NSArray<PVAppInfo *> *)localInfos;

@property(nonatomic, strong) PVDetailInspectableApp *inspectingApp;

/// 当前 Mac 端偏好面板里的 Inspector 设置，供建立连接时下发给被调试 app。
- (NSDictionary<NSString *, id> *)currentInspectorSettings;

/// 把 Inspector 偏好下发给 app，成功或失败都会 completed（失败时只是打日志），
/// 因此可以安全地串在抓树之前。
- (RACSignal *)pushInspectorSettingsToApp:(PVDetailInspectableApp *)app;

/// 下发偏好后重新拉取层级并刷新界面。没有正在检视的 app 时什么都不做。
- (void)pushInspectorSettingsAndReloadInspection;

/// 断开后自动重连成功
@property(nonatomic, strong, readonly) RACSubject *didAutoReconnectSucc;

@end
