//
//  FITreeDetailViewController.h
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/14.
//

#import <UIKit/UIKit.h>

@class KKFIHierarchySnapshot;
@class KKFlutterInspector;

NS_ASSUME_NONNULL_BEGIN

@interface FITreeDetailViewController : UITableViewController

- (instancetype)initWithInspector:(KKFlutterInspector *)inspector;

- (void)displaySnapshot:(nullable KKFIHierarchySnapshot *)snapshot
                  error:(nullable NSError *)error;

@end

NS_ASSUME_NONNULL_END
