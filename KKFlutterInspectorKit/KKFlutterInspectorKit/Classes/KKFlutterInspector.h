//
//  KKFlutterInspector.h
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/13.
//

#ifndef KKFlutterInspector_h
#define KKFlutterInspector_h

#import <UIKit/UIKit.h>
#import "KKFIInspectorModels.h"

@class FlutterViewController;

NS_ASSUME_NONNULL_BEGIN

typedef void (^KKFlutterInspectorHierarchyCompletion)(
    KKFIHierarchySnapshot *_Nullable snapshot, NSError *_Nullable error);
typedef void (^KKFlutterInspectorPropertiesCompletion)(
    NSArray<NSDictionary *> *_Nullable properties, NSError *_Nullable error);
typedef void (^KKFlutterInspectorScreenshotCompletion)(
    KKFIScreenshotResult *_Nullable result, NSError *_Nullable error);

@interface KKFlutterInspector : NSObject

/// Widget runtime type names omitted from hierarchy snapshots. Children of an
/// omitted node are promoted to its parent, so filtering a wrapper does not
/// discard the inspectable content below it. The default value is empty.
@property(nonatomic, copy) NSSet<NSString *> *excludedWidgetTypes;

/// Asynchronously discovers Flutter engines attached to the supplied window
/// and establishes reusable VM Service sessions for them.
///
/// This method never fetches an Element tree and never blocks the caller.
- (void)warmUpWindow:(UIWindow *)window;

/// Fetches the hierarchy for the first Flutter page attached to `window`.
/// The completion is delivered on a private serial queue.
- (void)fetchHierarchyInWindow:(UIWindow *)window
              fallbackRootSize:(CGSize)rootSize
                    completion:(KKFlutterInspectorHierarchyCompletion)completion;

/// Fetches the hierarchy for a specific Flutter page. Prefer this method when
/// a window can contain more than one FlutterViewController.
/// The completion is delivered on a private serial queue.
- (void)fetchHierarchyForViewController:(FlutterViewController *)viewController
                       fallbackRootSize:(CGSize)rootSize
                             completion:(KKFlutterInspectorHierarchyCompletion)completion;

/// Fetches the complete DiagnosticsNode properties for an element in the
/// current hierarchy snapshot.
- (void)fetchPropertiesForElement:(KKFIElementReference *)reference
                       completion:(KKFlutterInspectorPropertiesCompletion)completion;

/// Captures the pixels represented by an element in the current hierarchy
/// snapshot.
- (void)captureScreenshotForElement:(KKFIElementReference *)reference
                            options:(KKFIScreenshotOptions *)options
                         completion:(KKFlutterInspectorScreenshotCompletion)completion;

@end

NS_ASSUME_NONNULL_END

#endif /* KKFlutterInspector_h */
