#import "KKFIVMServiceClient.h"

static NSString *const KKFIVMServiceErrorDomain = @"KKFIVMServiceErrorDomain";

typedef NS_ENUM(NSInteger, KKFIVMServiceErrorCode) {
    KKFIVMServiceErrorInvalidURI = 1,
    KKFIVMServiceErrorDisconnected,
    KKFIVMServiceErrorEncoding,
    KKFIVMServiceErrorRPC,
};

@interface KKFIVMServiceClient ()

@property(nonatomic, strong) NSURLSession *urlSession;
@property(nonatomic, strong, nullable) NSURLSessionWebSocketTask *task;
@property(nonatomic) dispatch_queue_t stateQueue;
@property(nonatomic) dispatch_queue_t callbackQueue;
@property(nonatomic) NSInteger generation;
@property(nonatomic) NSInteger nextRequestID;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, KKFIVMServiceCompletion> *pending;
@property(nonatomic, readwrite) NSURL *webSocketURL;

@end

@implementation KKFIVMServiceClient

- (instancetype)initWithServiceURI:(NSString *)serviceURI
                     callbackQueue:(dispatch_queue_t)callbackQueue
                              error:(NSError **)error {
    NSURL *url = [self.class webSocketURLFromServiceURI:serviceURI error:error];
    if (url == nil) {
        return nil;
    }

    self = [super init];
    if (self) {
        _webSocketURL = url;
        _urlSession = [NSURLSession
            sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration];
        _stateQueue = dispatch_queue_create("com.kkflutterinspector.vm-service",
                                            DISPATCH_QUEUE_SERIAL);
        _callbackQueue = callbackQueue;
        _nextRequestID = 1;
        _pending = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc {
    [_task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway
                        reason:nil];
    [_urlSession invalidateAndCancel];
}

- (void)connect {
    dispatch_async(self.stateQueue, ^{
        [self closeLockedWithError:[self.class disconnectedError]
                  notifyDisconnect:NO];
        NSInteger generation = self.generation;
        NSURLSessionWebSocketTask *task =
            [self.urlSession webSocketTaskWithURL:self.webSocketURL];
        // Inspector layout/detail payloads can exceed NSURLSession's default
        // WebSocket message limit on widget-rich or deeply nested pages.
        // Keep a bounded allowance so a valid VM Service response is not
        // reported as NSPOSIXError "Message too long" before JSON decoding.
        task.maximumMessageSize = 16 * 1024 * 1024;
        self.task = task;
        [task resume];
        [self receiveNextMessageForTask:task generation:generation];
    });
}

- (void)close {
    dispatch_async(self.stateQueue, ^{
        [self closeLockedWithError:[self.class disconnectedError]
                  notifyDisconnect:NO];
    });
}

- (void)callMethod:(NSString *)method
            params:(NSDictionary *)params
        completion:(KKFIVMServiceCompletion)completion {
    dispatch_async(self.stateQueue, ^{
        NSURLSessionWebSocketTask *task = self.task;
        NSInteger generation = self.generation;
        if (task == nil) {
            [self dispatchCompletion:completion
                            response:nil
                               error:[self.class disconnectedError]];
            return;
        }

        NSInteger requestID = self.nextRequestID++;
        self.pending[@(requestID)] = [completion copy];
        NSMutableDictionary *payload = [@{
            @"jsonrpc" : @"2.0",
            @"id" : @(requestID),
            @"method" : method,
        } mutableCopy];
        if (params.count > 0) {
            payload[@"params"] = params;
        }

        NSError *serializationError = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                       options:0
                                                         error:&serializationError];
        NSString *text = data == nil
            ? nil
            : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text == nil) {
            NSError *encodingError = serializationError ?:
                [self.class errorWithCode:KKFIVMServiceErrorEncoding
                              description:@"Failed to encode a JSON-RPC request."];
            [self finishRequestIDLocked:requestID response:nil error:encodingError];
            return;
        }

        NSURLSessionWebSocketMessage *message =
            [[NSURLSessionWebSocketMessage alloc] initWithString:text];
        __weak typeof(self) weakSelf = self;
        [task sendMessage:message completionHandler:^(NSError *sendError) {
            if (sendError == nil) {
                return;
            }
            __strong typeof(weakSelf) self = weakSelf;
            if (self == nil) {
                return;
            }
            dispatch_async(self.stateQueue, ^{
                if (self.task != task ||
                    self.generation != generation) {
                    return;
                }
                [self finishRequestIDLocked:requestID
                                   response:nil
                                      error:sendError];
            });
        }];
    });
}

- (void)receiveNextMessageForTask:(NSURLSessionWebSocketTask *)task
                       generation:(NSInteger)generation {
    __weak typeof(self) weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(
        NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) {
            return;
        }
        dispatch_async(self.stateQueue, ^{
            if (self.task != task || self.generation != generation) {
                return;
            }
            if (error != nil) {
                [self closeLockedWithError:error notifyDisconnect:YES];
                return;
            }
            [self handleMessageLocked:message];
            [self receiveNextMessageForTask:task generation:generation];
        });
    }];
}

- (void)handleMessageLocked:(NSURLSessionWebSocketMessage *)message {
    NSData *data = nil;
    if (message.type == NSURLSessionWebSocketMessageTypeString) {
        data = [message.string dataUsingEncoding:NSUTF8StringEncoding];
    } else if (message.type == NSURLSessionWebSocketMessageTypeData) {
        data = message.data;
    }
    if (data == nil) {
        return;
    }

    NSError *decodingError = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:&decodingError];
    if (![value isKindOfClass:NSDictionary.class]) {
        if (decodingError != nil) {
            [self closeLockedWithError:decodingError notifyDisconnect:YES];
        }
        return;
    }

    NSDictionary *response = value;
    NSNumber *requestID = [response[@"id"] isKindOfClass:NSNumber.class]
        ? response[@"id"]
        : nil;
    if (requestID == nil) {
        // VM Service events are notifications and have no request ID.
        return;
    }

    id rpcError = response[@"error"];
    if (rpcError != nil) {
        NSString *description = [rpcError description];
        if ([NSJSONSerialization isValidJSONObject:rpcError]) {
            NSData *errorData = [NSJSONSerialization dataWithJSONObject:rpcError
                                                                 options:0
                                                                   error:nil];
            description = [[NSString alloc] initWithData:errorData
                                                 encoding:NSUTF8StringEncoding]
                ?: description;
        }
        NSError *error = [self.class
            errorWithCode:KKFIVMServiceErrorRPC
               description:[@"VM Service returned a JSON-RPC error: "
                               stringByAppendingString:description ?: @"Unknown error"]];
        [self finishRequestIDLocked:requestID.integerValue
                           response:response
                              error:error];
        return;
    }
    [self finishRequestIDLocked:requestID.integerValue
                       response:response
                          error:nil];
}

- (void)finishRequestIDLocked:(NSInteger)requestID
                     response:(NSDictionary *)response
                        error:(NSError *)error {
    NSNumber *key = @(requestID);
    KKFIVMServiceCompletion completion = self.pending[key];
    [self.pending removeObjectForKey:key];
    if (completion != nil) {
        [self dispatchCompletion:completion response:response error:error];
    }
}

- (void)closeLockedWithError:(NSError *)error
            notifyDisconnect:(BOOL)notifyDisconnect {
    NSURLSessionWebSocketTask *task = self.task;
    self.task = nil;
    self.generation += 1;
    [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];

    NSArray<KKFIVMServiceCompletion> *completions = self.pending.allValues;
    [self.pending removeAllObjects];
    for (KKFIVMServiceCompletion completion in completions) {
        [self dispatchCompletion:completion response:nil error:error];
    }

    KKFIVMServiceDisconnectHandler handler =
        notifyDisconnect ? self.disconnectHandler : nil;
    if (handler != nil) {
        dispatch_async(self.callbackQueue, ^{
            handler(error);
        });
    }
}

- (void)dispatchCompletion:(KKFIVMServiceCompletion)completion
                   response:(NSDictionary *)response
                      error:(NSError *)error {
    dispatch_async(self.callbackQueue, ^{
        completion(response, error);
    });
}

+ (NSURL *)webSocketURLFromServiceURI:(NSString *)serviceURI
                                error:(NSError **)error {
    NSString *trimmed = [serviceURI
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURLComponents *components = [NSURLComponents componentsWithString:trimmed];
    NSString *scheme = components.scheme.lowercaseString;
    if ([scheme isEqualToString:@"http"]) {
        components.scheme = @"ws";
    } else if ([scheme isEqualToString:@"https"]) {
        components.scheme = @"wss";
    } else if (![scheme isEqualToString:@"ws"] &&
               ![scheme isEqualToString:@"wss"]) {
        if (error != NULL) {
            *error = [self errorWithCode:KKFIVMServiceErrorInvalidURI
                             description:[NSString stringWithFormat:
                                 @"Invalid VM Service URI: %@", serviceURI]];
        }
        return nil;
    }

    NSString *path = components.percentEncodedPath.length > 0
        ? components.percentEncodedPath
        : @"/";
    if (![path hasSuffix:@"/ws"]) {
        path = [path hasSuffix:@"/"]
            ? [path stringByAppendingString:@"ws"]
            : [path stringByAppendingString:@"/ws"];
    }
    components.percentEncodedPath = path;
    NSURL *url = components.URL;
    if (url == nil && error != NULL) {
        *error = [self errorWithCode:KKFIVMServiceErrorInvalidURI
                         description:[NSString stringWithFormat:
                             @"Invalid VM Service URI: %@", serviceURI]];
    }
    return url;
}

+ (NSError *)disconnectedError {
    return [self errorWithCode:KKFIVMServiceErrorDisconnected
                   description:@"The VM Service WebSocket is disconnected."];
}

+ (NSError *)errorWithCode:(KKFIVMServiceErrorCode)code
                description:(NSString *)description {
    return [NSError errorWithDomain:KKFIVMServiceErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

@end
