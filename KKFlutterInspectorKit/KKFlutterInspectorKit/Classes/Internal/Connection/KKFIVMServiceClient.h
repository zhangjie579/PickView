//
//  KKFIVMServiceClient.h
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/13.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^KKFIVMServiceCompletion)(NSDictionary *_Nullable response,
                                        NSError *_Nullable error);
typedef void (^KKFIVMServiceDisconnectHandler)(NSError *error);

/// A small JSON-RPC client for the Dart VM Service WebSocket endpoint.
@interface KKFIVMServiceClient : NSObject

@property(nonatomic, readonly) NSURL *webSocketURL;
@property(nonatomic, copy, nullable)
    KKFIVMServiceDisconnectHandler disconnectHandler;

/// JSON-RPC completions and disconnect notifications are delivered
/// asynchronously on callbackQueue.
- (nullable instancetype)initWithServiceURI:(NSString *)serviceURI
                               callbackQueue:(dispatch_queue_t)callbackQueue
                                       error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)connect;
- (void)close;
- (void)callMethod:(NSString *)method
            params:(nullable NSDictionary *)params
        completion:(KKFIVMServiceCompletion)completion;

@end

NS_ASSUME_NONNULL_END
