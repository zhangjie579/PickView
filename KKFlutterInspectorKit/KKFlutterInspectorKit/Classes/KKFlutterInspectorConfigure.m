//
//  KKFlutterInspectorConfigure.m
//  KKFlutterInspectorKit
//
//  Created by 张杰 on 2026/9/24.
//

#import "KKFlutterInspectorConfigure.h"

@implementation KKFlutterInspectorConfigure

+ (NSSet<NSString *> *)defaultBlocWidgetTypes {
    // These are the state-management widgets shipped by the `flutter_bloc`
    // family. They are pure plumbing: they inject or observe a Cubit/Bloc but
    // never own a RenderObject of their own, so hiding them never changes the
    // geometry of the subtree they wrap.
    static NSSet<NSString *> *defaultTypes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaultTypes = [NSSet setWithArray:@[
            @"BlocProvider",
            @"BlocBuilder",
            @"BlocListener",
            @"BlocConsumer",
            @"BlocSelector",
            @"RepositoryProvider",
            @"MultiBlocProvider",
            @"MultiBlocListener",
            @"MultiRepositoryProvider",
            @"BlocEffectListener",
            
            // 数据与环境传递
            @"InheritedWidget",
            @"InheritedModel",
            @"InheritedNotifier",
            @"DefaultTextStyle",
            @"Directionality",
            @"MediaQuery",
            @"Localizations",
            @"Theme",
            @"Provider",

            // 状态与异步更新
            @"Builder",
            @"StatefulBuilder",
            @"ValueListenableBuilder",
            @"ListenableBuilder",
            @"AnimatedBuilder",
            @"StreamBuilder",
            @"FutureBuilder",

            // 事件与交互
//            @"GestureDetector",
//            @"RawGestureDetector",
            @"Listener",
            @"NotificationListener",
            @"MouseRegion",
            @"Focus",
            @"FocusScope",
            @"Shortcuts",
            @"Actions",
            @"CallbackShortcuts",
            @"DragTarget",
//            @"IgnorePointer",
//            @"AbsorbPointer",

            // 生命周期与构建控制
//            @"Visibility",
//            @"Offstage",
            @"TickerMode",
            @"RepaintBoundary",
            @"KeyedSubtree",
            @"AutomaticKeepAlive",
            @"KeepAlive",
            @"SliverLayoutBuilder",

            // 布局约束
            @"LayoutBuilder",
            @"OrientationBuilder",
            @"SafeArea",
        ]];
    });
    return defaultTypes;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _blocWidgetFilteringEnabled = NO;
        _blocWidgetTypes = [self.class defaultBlocWidgetTypes];
    }
    return self;
}

- (void)setReportedVMServiceURL:(NSString *)reportedVMServiceURL {
    _reportedVMServiceURL = [reportedVMServiceURL copy];
}

- (void)setVmServiceURLOverride:(NSString *)vmServiceURLOverride {
    _vmServiceURLOverride = [vmServiceURLOverride copy];
}

- (nullable NSSet<NSString *> *)activeBlocWidgetTypes {
    if (!self.isBlocWidgetFilteringEnabled) {
        return nil;
    }
    if (self.blocWidgetTypes.count > 0) {
        return self.blocWidgetTypes;
    }
    return [self.class defaultBlocWidgetTypes];
}

+ (instancetype)sharedManager {
    static dispatch_once_t onceToken;
    static KKFlutterInspectorConfigure *manager;
    dispatch_once(&onceToken, ^{
        if (manager == nil) {
            manager = [[KKFlutterInspectorConfigure alloc] init];
        }
    });
    
    return manager;
}

@end
