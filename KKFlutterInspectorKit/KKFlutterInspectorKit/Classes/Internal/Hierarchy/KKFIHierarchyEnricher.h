//
//  KKFIHierarchyEnricher.h
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/15.
//

#import <UIKit/UIKit.h>

@class KKFIVMServiceClient;

NS_ASSUME_NONNULL_BEGIN

typedef void (^KKFIHierarchyEnrichmentCompletion)(
    NSDictionary<NSString *, NSArray *> *propertiesByID,
    NSDictionary<NSString *, NSValue *> *resolvedOffsetsByID);

/// Enriches Layout Explorer nodes with diagnostic properties and RenderObject
/// offsets omitted by the summary hierarchy payload.
@interface KKFIHierarchyEnricher : NSObject

- (void)enrichLayoutPayload:(NSDictionary *)layoutPayload
                     client:(KKFIVMServiceClient *)client
                  isolateID:(NSString *)isolateID
                objectGroup:(NSString *)objectGroup
                 completion:(KKFIHierarchyEnrichmentCompletion)completion;

@end

NS_ASSUME_NONNULL_END
