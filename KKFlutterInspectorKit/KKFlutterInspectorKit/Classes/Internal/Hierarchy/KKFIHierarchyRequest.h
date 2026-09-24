//
//  KKFIHierarchyRequest.h
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/15.
//

#import <UIKit/UIKit.h>

@class KKFIHierarchySnapshot;
@class KKFIVMServiceClient;

NS_ASSUME_NONNULL_BEGIN

typedef void (^KKFIHierarchyRequestCompletion)(
    KKFIHierarchySnapshot *_Nullable snapshot, NSError *_Nullable error);

/// Owns one hierarchy-loading transaction for an already connected isolate.
@interface KKFIHierarchyRequest : NSObject

@property(nonatomic, copy, readonly) NSString *objectGroup;
@property(nonatomic, copy, readonly) NSString *snapshotID;

- (instancetype)initWithClient:(KKFIVMServiceClient *)client
                     isolateID:(NSString *)isolateID
                   objectGroup:(NSString *)objectGroup
                    snapshotID:(NSString *)snapshotID
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)startWithFallbackRootSize:(CGSize)rootSize
              excludedWidgetTypes:(NSSet<NSString *> *)excludedWidgetTypes
                       completion:(KKFIHierarchyRequestCompletion)completion;

- (void)cancel;

@end

NS_ASSUME_NONNULL_END
