//
//  KKFIFlutterCompatibility.h
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/13.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#if __has_include(<Flutter/Flutter.h>)
#import <Flutter/Flutter.h>
#else

/// Minimal Flutter declarations keep the Pod independent from a hard Flutter
/// dependency. The concrete classes are discovered by name at runtime.
@class FlutterViewController;

@interface FlutterEngine : NSObject
@property(nonatomic, readonly, nullable) NSString *isolateId;
@property(nonatomic, readonly, nullable) NSURL *vmServiceUrl;
@end

@interface FlutterViewController : UIViewController
@property(nonatomic, readonly, nullable) FlutterEngine *engine;
@end

#endif

NS_ASSUME_NONNULL_END
