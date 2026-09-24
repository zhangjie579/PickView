//
//  KKFIInspectorJSON.h
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/14.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKFIInspectorJSON : NSObject

+ (nullable id)normalizedPayloadFromResponse:(NSDictionary *)response;
+ (nullable NSString *)nodeIDFromDictionary:(nullable NSDictionary *)dictionary;
+ (nullable NSNumber *)numberFromValue:(nullable id)value;

@end

NS_ASSUME_NONNULL_END
