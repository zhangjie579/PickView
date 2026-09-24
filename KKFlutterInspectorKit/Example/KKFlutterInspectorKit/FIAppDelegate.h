//
//  FIAppDelegate.h
//  KKFlutterInspectorKit
//
//  Created by kriskice@gmail.com on 07/13/2026.
//  Copyright (c) 2026 kriskice@gmail.com. All rights reserved.
//

@import UIKit;

@class FlutterEngine;

@interface FIAppDelegate : UIResponder <UIApplicationDelegate>

@property (strong, nonatomic) UIWindow *window;
@property(nonatomic, strong, readonly) FlutterEngine *flutterEngine;

- (FlutterEngine *)startFlutterEngineIfNeeded;

@end
