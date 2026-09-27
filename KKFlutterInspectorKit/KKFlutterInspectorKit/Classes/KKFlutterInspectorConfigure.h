//
//  KKFlutterInspectorConfigure.h
//  KKFlutterInspectorKit
//
//  Created by 张杰 on 2026/9/24.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKFlutterInspectorConfigure : NSObject

/// flutter 根节点的 widget name
@property (nonatomic, copy, nullable) NSString *flutterRootNodeWidgetName;

+ (instancetype)sharedManager;

@end

NS_ASSUME_NONNULL_END
