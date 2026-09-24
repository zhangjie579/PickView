#import "KKFIFlutterPageLocator.h"

@implementation KKFIFlutterPageLocator

- (FlutterEngine *)
    flutterEngineForViewController:(FlutterViewController *)viewController {
    NSAssert(NSThread.isMainThread,
             @"Flutter page resolution must run on the main thread.");
    Class flutterViewControllerClass =
        NSClassFromString(@"FlutterViewController");
    if (flutterViewControllerClass == Nil ||
        ![(UIViewController *)viewController
            isKindOfClass:flutterViewControllerClass]) {
        return nil;
    }
    return viewController.engine;
}

- (NSArray<FlutterEngine *> *)flutterEnginesInWindow:(UIWindow *)window {
    NSAssert(NSThread.isMainThread,
             @"Flutter page discovery must run on the main thread.");
    UIViewController *rootViewController = window.rootViewController;
    if (rootViewController == nil) {
        return @[];
    }

    NSMutableArray<FlutterEngine *> *engines = [NSMutableArray array];
    NSHashTable<UIViewController *> *seenControllers =
        [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSHashTable<FlutterEngine *> *seenEngines =
        [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    [self collectFromViewController:rootViewController
                             window:window
                            engines:engines
                    seenControllers:seenControllers
                        seenEngines:seenEngines];
    return engines.copy;
}

- (void)collectFromViewController:(UIViewController *)viewController
                           window:(UIWindow *)window
                          engines:(NSMutableArray<FlutterEngine *> *)engines
                  seenControllers:(NSHashTable<UIViewController *> *)seenControllers
                      seenEngines:(NSHashTable<FlutterEngine *> *)seenEngines {
    if (viewController == nil || [seenControllers containsObject:viewController]) {
        return;
    }
    [seenControllers addObject:viewController];

    Class flutterViewControllerClass = NSClassFromString(@"FlutterViewController");
    if (flutterViewControllerClass != Nil &&
        [viewController isKindOfClass:flutterViewControllerClass]) {
        UIView *hostView = viewController.viewIfLoaded;
        FlutterEngine *engine = [self flutterEngineForViewController:
            (FlutterViewController *)viewController];
        if (hostView.window == window &&
            engine != nil &&
            ![seenEngines containsObject:engine]) {
            [seenEngines addObject:engine];
            [engines addObject:engine];
        }
    }

    if (viewController.presentedViewController != nil) {
        [self collectFromViewController:viewController.presentedViewController
                                 window:window
                                engines:engines
                        seenControllers:seenControllers
                            seenEngines:seenEngines];
    }

    if ([viewController isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in
             ((UINavigationController *)viewController).viewControllers) {
            [self collectFromViewController:child
                                     window:window
                                    engines:engines
                            seenControllers:seenControllers
                                seenEngines:seenEngines];
        }
    }
    if ([viewController isKindOfClass:UITabBarController.class]) {
        for (UIViewController *child in
             ((UITabBarController *)viewController).viewControllers) {
            [self collectFromViewController:child
                                     window:window
                                    engines:engines
                            seenControllers:seenControllers
                                seenEngines:seenEngines];
        }
    }
    if ([viewController isKindOfClass:UISplitViewController.class]) {
        for (UIViewController *child in
             ((UISplitViewController *)viewController).viewControllers) {
            [self collectFromViewController:child
                                     window:window
                                    engines:engines
                            seenControllers:seenControllers
                                seenEngines:seenEngines];
        }
    }
    for (UIViewController *child in viewController.childViewControllers) {
        [self collectFromViewController:child
                                 window:window
                                engines:engines
                        seenControllers:seenControllers
                            seenEngines:seenEngines];
    }
}

@end
