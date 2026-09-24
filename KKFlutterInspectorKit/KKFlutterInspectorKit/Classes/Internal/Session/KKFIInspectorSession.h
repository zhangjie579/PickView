//
//  KKFIInspectorSession.h
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/13.
//

#import "../Runtime/KKFIFlutterCompatibility.h"
#import "../Model/KKFIInspectorModels.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^KKFIInspectorConnectionCompletion)(NSError *_Nullable error);
typedef void (^KKFIHierarchyCompletion)(
    KKFIHierarchySnapshot *_Nullable snapshot, NSError *_Nullable error);
typedef void (^KKFIPropertiesCompletion)(
    NSArray<NSDictionary *> *_Nullable properties, NSError *_Nullable error);
typedef void (^KKFIScreenshotCompletion)(
    KKFIScreenshotResult *_Nullable result, NSError *_Nullable error);

/// Owns one reusable VM Service connection for a Flutter engine.
@interface KKFIInspectorSession : NSObject

- (instancetype)initWithEngine:(FlutterEngine *)engine
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Coalesces concurrent callers onto one connection attempt. Completions are
/// delivered on the session's private serial queue.
- (void)ensureConnectedWithTimeout:(NSTimeInterval)timeout
                        completion:(nullable KKFIInspectorConnectionCompletion)completion;

/// Fetches the current Widget/RenderObject hierarchy. Concurrent callers are
/// coalesced onto the same Inspector request. The completion runs on the
/// session's private serial queue.
- (void)fetchHierarchyWithFallbackRootSize:(CGSize)rootSize
                       excludedWidgetTypes:(NSSet<NSString *> *)excludedWidgetTypes
                                completion:(KKFIHierarchyCompletion)completion;

/// Fetches diagnostic properties for an element from the active snapshot.
- (void)fetchPropertiesForElement:(KKFIElementReference *)reference
                       completion:(KKFIPropertiesCompletion)completion;

/// Captures the current pixels for an element from the active snapshot.
- (void)captureScreenshotForElement:(KKFIElementReference *)reference
                            options:(KKFIScreenshotOptions *)options
                         completion:(KKFIScreenshotCompletion)completion;

- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
