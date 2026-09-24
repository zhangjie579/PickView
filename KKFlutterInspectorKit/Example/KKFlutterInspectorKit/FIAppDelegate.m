//
//  FIAppDelegate.m
//  KKFlutterInspectorKit
//
//  Created by kriskice@gmail.com on 07/13/2026.
//  Copyright (c) 2026 kriskice@gmail.com. All rights reserved.
//

#import "FIAppDelegate.h"

#import <Flutter/Flutter.h>
#import <PickViewServer/PickViewServerKit.h>

@interface FIAppDelegate ()

@property(nonatomic, strong, readwrite) FlutterEngine *flutterEngine;

@end

@implementation FIAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    UIViewController *rootViewController = self.window.rootViewController;
    if (rootViewController != nil &&
        ![rootViewController isKindOfClass:UINavigationController.class]) {
        self.window.rootViewController = [[UINavigationController alloc]
            initWithRootViewController:rootViewController];
    }
    [PickViewServer.sharedServer start];
    return YES;
}

- (FlutterEngine *)startFlutterEngineIfNeeded
{
    NSAssert(NSThread.isMainThread, @"FlutterEngine must be started on the main thread.");
    if (self.flutterEngine != nil) {
        return self.flutterEngine;
    }

    FlutterEngine *engine = [[FlutterEngine alloc]
        initWithName:@"com.kkflutterinspector.example"];
    if (![engine runWithEntrypoint:nil]) {
        return nil;
    }
    self.flutterEngine = engine;
    return engine;
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
}

@end
