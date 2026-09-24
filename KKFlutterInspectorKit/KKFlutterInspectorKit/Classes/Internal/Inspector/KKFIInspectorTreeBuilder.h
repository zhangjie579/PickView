//
//  KKFIInspectorTreeBuilder.h
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/14.
//

#import <UIKit/UIKit.h>

@class KKFIHierarchySnapshot;

NS_ASSUME_NONNULL_BEGIN

@interface KKFIInspectorTreeBuilder : NSObject

+ (nullable KKFIHierarchySnapshot *)
    snapshotFromLayoutPayload:(NSDictionary *)layoutPayload
                widgetPayload:(nullable id)widgetPayload
         widgetPropertiesByID:(NSDictionary<NSString *, NSArray *> *)widgetPropertiesByID
          resolvedOffsetsByID:(NSDictionary<NSString *, NSValue *> *)resolvedOffsetsByID
                 rootObjectID:(NSString *)rootObjectID
             fallbackRootSize:(CGSize)fallbackRootSize
                    isolateID:(NSString *)isolateID
                  objectGroup:(NSString *)objectGroup
                   snapshotID:(NSString *)snapshotID
          excludedWidgetTypes:(NSSet<NSString *> *)excludedWidgetTypes
                        error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
