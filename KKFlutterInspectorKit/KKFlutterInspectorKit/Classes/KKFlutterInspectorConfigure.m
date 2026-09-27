//
//  KKFlutterInspectorConfigure.m
//  KKFlutterInspectorKit
//
//  Created by 张杰 on 2026/9/24.
//

#import "KKFlutterInspectorConfigure.h"

@implementation KKFlutterInspectorConfigure

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
