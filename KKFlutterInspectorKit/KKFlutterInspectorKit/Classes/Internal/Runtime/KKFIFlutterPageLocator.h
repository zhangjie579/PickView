//
//  KKFIFlutterPageLocator.h
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/13.
//

#import "KKFIFlutterCompatibility.h"

NS_ASSUME_NONNULL_BEGIN

/// Finds Flutter runtimes already attached to a concrete UIKit window.
/// Every method is main-thread confined and never loads an unloaded view.
@interface KKFIFlutterPageLocator : NSObject

- (NSArray<FlutterEngine *> *)flutterEnginesInWindow:(UIWindow *)window;
- (nullable FlutterEngine *)
    flutterEngineForViewController:(FlutterViewController *)viewController;

@end

NS_ASSUME_NONNULL_END
