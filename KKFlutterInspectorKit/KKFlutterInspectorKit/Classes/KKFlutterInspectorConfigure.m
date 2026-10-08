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
