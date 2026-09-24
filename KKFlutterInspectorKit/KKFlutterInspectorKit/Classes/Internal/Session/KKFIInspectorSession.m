#import "KKFIInspectorSession.h"

#import <math.h>

#import "../Connection/KKFIVMServiceClient.h"
#import "../Hierarchy/KKFIHierarchyRequest.h"
#import "../Inspector/KKFIInspectorJSON.h"

static NSString *const KKFIInspectorSessionErrorDomain =
    @"KKFIInspectorSessionErrorDomain";

typedef NS_ENUM(NSInteger, KKFIInspectorSessionErrorCode) {
    KKFIInspectorSessionErrorEngineReleased = 1,
    KKFIInspectorSessionErrorTimedOut,
    KKFIInspectorSessionErrorInvalidated,
    KKFIInspectorSessionErrorInvalidPayload,
    KKFIInspectorSessionErrorStaleElementReference,
    KKFIInspectorSessionErrorInvalidScreenshotOptions,
    KKFIInspectorSessionErrorScreenshotUnavailable,
};

typedef NS_ENUM(NSUInteger, KKFIInspectorSessionState) {
    KKFIInspectorSessionStateIdle,
    KKFIInspectorSessionStateConnecting,
    KKFIInspectorSessionStateConnected,
};

@interface KKFIInspectorSession ()

@property(nonatomic, weak) FlutterEngine *engine;
@property(nonatomic) dispatch_queue_t stateQueue;
@property(nonatomic) KKFIInspectorSessionState state;
@property(nonatomic) NSUInteger attemptID;
@property(nonatomic, strong, nullable) KKFIVMServiceClient *serviceClient;
@property(nonatomic, strong, nullable) NSURL *vmServiceURL;
@property(nonatomic, copy, nullable) NSString *isolateID;
@property(nonatomic, copy, nullable) NSString *activeObjectGroup;
@property(nonatomic, copy, nullable) NSString *activeSnapshotID;
@property(nonatomic, strong, nullable) KKFIHierarchyRequest *hierarchyRequest;
@property(nonatomic, strong)
    NSMutableArray<KKFIInspectorConnectionCompletion> *connectionWaiters;
@property(nonatomic, strong)
    NSMutableArray<KKFIHierarchyCompletion> *hierarchyWaiters;

@end

@implementation KKFIInspectorSession

- (instancetype)initWithEngine:(FlutterEngine *)engine {
    self = [super init];
    if (self) {
        _engine = engine;
        _stateQueue = dispatch_queue_create(
            "com.kkflutterinspector.inspector-session", DISPATCH_QUEUE_SERIAL);
        _state = KKFIInspectorSessionStateIdle;
        _connectionWaiters = [NSMutableArray array];
        _hierarchyWaiters = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    [_serviceClient close];
}

#pragma mark - Connection

- (void)ensureConnectedWithTimeout:(NSTimeInterval)timeout
                        completion:(KKFIInspectorConnectionCompletion)completion {
    KKFIInspectorConnectionCompletion completionCopy = [completion copy];
    dispatch_async(self.stateQueue, ^{
        if (self.state == KKFIInspectorSessionStateConnected) {
            if (completionCopy != nil) {
                completionCopy(nil);
            }
            return;
        }

        if (completionCopy != nil) {
            [self.connectionWaiters addObject:completionCopy];
        }
        if (self.state == KKFIInspectorSessionStateConnecting) {
            return;
        }

        self.state = KKFIInspectorSessionStateConnecting;
        NSUInteger attemptID = ++self.attemptID;
        [self scheduleTimeout:MAX(timeout, 0.1) attemptID:attemptID];
        [self tryConnectWithAttemptID:attemptID];
    });
}

- (void)ensureCurrentConnectionWithTimeout:(NSTimeInterval)timeout
                                completion:(KKFIInspectorConnectionCompletion)completion {
    KKFIInspectorConnectionCompletion completionCopy = [completion copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) {
            return;
        }

        FlutterEngine *engine = self.engine;
        BOOL engineAvailable = engine != nil;
        NSURL *serviceURL = engine.vmServiceUrl;
        NSString *isolateID = [engine.isolateId copy];
        dispatch_async(self.stateQueue, ^{
            if (!engineAvailable) {
                completionCopy([self.class
                    errorWithCode:KKFIInspectorSessionErrorEngineReleased
                       description:@"The Flutter engine was released."]);
                return;
            }

            BOOL identityMatches =
                self.state == KKFIInspectorSessionStateConnected &&
                self.serviceClient != nil && serviceURL != nil &&
                isolateID.length > 0 && [serviceURL isEqual:self.vmServiceURL] &&
                [isolateID isEqualToString:self.isolateID];
            if (identityMatches) {
                completionCopy(nil);
                return;
            }

            BOOL connectedIdentityInvalid =
                self.state == KKFIInspectorSessionStateConnected;
            BOOL disconnectedIdentityChanged =
                self.state == KKFIInspectorSessionStateIdle &&
                self.isolateID.length > 0 && isolateID.length > 0 &&
                (![isolateID isEqualToString:self.isolateID] ||
                 (serviceURL != nil && ![serviceURL isEqual:self.vmServiceURL]));
            if (connectedIdentityInvalid || disconnectedIdentityChanged) {
                NSError *error = [self.class
                    errorWithCode:KKFIInspectorSessionErrorStaleElementReference
                       description:@"The Flutter isolate changed. Fetch a new hierarchy before using old elements."];
                [self retireCurrentConnectionWithError:error];
            }

            [self ensureConnectedWithTimeout:timeout completion:completionCopy];
        });
    });
}

- (void)tryConnectWithAttemptID:(NSUInteger)attemptID {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) {
            return;
        }

        FlutterEngine *engine = self.engine;
        BOOL engineAvailable = engine != nil;
        NSURL *serviceURL = engine.vmServiceUrl;
        NSString *isolateID = [engine.isolateId copy];

        dispatch_async(self.stateQueue, ^{
            if (self.state != KKFIInspectorSessionStateConnecting ||
                self.attemptID != attemptID) {
                return;
            }

            if (!engineAvailable) {
                [self finishAttempt:attemptID
                              error:[self.class
                                  errorWithCode:KKFIInspectorSessionErrorEngineReleased
                                     description:@"The Flutter engine was released before the VM Service connected."]];
                return;
            }

            if (serviceURL == nil || isolateID.length == 0) {
                [self clearConnection];
                [self scheduleRetryForAttemptID:attemptID];
                return;
            }

            if (self.serviceClient != nil) {
                return;
            }

            NSError *clientError = nil;
            KKFIVMServiceClient *client = [[KKFIVMServiceClient alloc]
                initWithServiceURI:serviceURL.absoluteString
                     callbackQueue:self.stateQueue
                             error:&clientError];
            if (client == nil) {
                [self finishAttempt:attemptID error:clientError];
                return;
            }

            self.serviceClient = client;
            __weak typeof(self) weakSession = self;
            __weak KKFIVMServiceClient *weakClient = client;
            client.disconnectHandler = ^(__unused NSError *error) {
                __strong typeof(weakSession) self = weakSession;
                KKFIVMServiceClient *disconnectedClient = weakClient;
                if (self == nil || disconnectedClient == nil ||
                    self.serviceClient != disconnectedClient) {
                    return;
                }

                [self clearConnection];
                if (self.state == KKFIInspectorSessionStateConnecting &&
                    self.attemptID == attemptID) {
                    [self scheduleRetryForAttemptID:attemptID];
                } else {
                    self.state = KKFIInspectorSessionStateIdle;
                }
            };

            [client connect];
            [client callMethod:@"getVM"
                        params:nil
                    completion:^(__unused NSDictionary *response,
                                 NSError *error) {
                __strong typeof(weakSession) self = weakSession;
                KKFIVMServiceClient *completedClient = weakClient;
                if (self == nil || completedClient == nil ||
                    self.state != KKFIInspectorSessionStateConnecting ||
                    self.attemptID != attemptID ||
                    self.serviceClient != completedClient) {
                    return;
                }

                if (error != nil) {
                    [self clearConnection];
                    [self scheduleRetryForAttemptID:attemptID];
                    return;
                }

                if (self.isolateID.length > 0 &&
                    ![self.isolateID isEqualToString:isolateID]) {
                    NSError *staleError = [self.class
                        errorWithCode:KKFIInspectorSessionErrorStaleElementReference
                           description:@"The Flutter isolate changed. Fetch a new hierarchy before using old elements."];
                    [self abandonSnapshotStateWithError:staleError];
                }
                self.vmServiceURL = serviceURL;
                self.isolateID = isolateID;
                [self finishAttempt:attemptID error:nil];
            }];
        });
    });
}

- (void)scheduleRetryForAttemptID:(NSUInteger)attemptID {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.15 * NSEC_PER_SEC)),
                   self.stateQueue, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil ||
            self.state != KKFIInspectorSessionStateConnecting ||
            self.attemptID != attemptID) {
            return;
        }
        [self tryConnectWithAttemptID:attemptID];
    });
}

- (void)scheduleTimeout:(NSTimeInterval)timeout
               attemptID:(NSUInteger)attemptID {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(timeout * NSEC_PER_SEC)),
                   self.stateQueue, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil ||
            self.state != KKFIInspectorSessionStateConnecting ||
            self.attemptID != attemptID) {
            return;
        }
        [self finishAttempt:attemptID
                      error:[self.class
                          errorWithCode:KKFIInspectorSessionErrorTimedOut
                             description:@"Timed out while establishing the Flutter VM Service session."]];
    });
}

- (void)finishAttempt:(NSUInteger)attemptID error:(NSError *)error {
    if (self.state != KKFIInspectorSessionStateConnecting ||
        self.attemptID != attemptID) {
        return;
    }

    if (error == nil) {
        self.state = KKFIInspectorSessionStateConnected;
    } else {
        [self clearConnection];
        self.state = KKFIInspectorSessionStateIdle;
    }

    NSArray<KKFIInspectorConnectionCompletion> *waiters =
        self.connectionWaiters.copy;
    [self.connectionWaiters removeAllObjects];
    for (KKFIInspectorConnectionCompletion waiter in waiters) {
        waiter(error);
    }
}

#pragma mark - Hierarchy

- (void)fetchHierarchyWithFallbackRootSize:(CGSize)rootSize
                       excludedWidgetTypes:(NSSet<NSString *> *)excludedWidgetTypes
                                completion:(KKFIHierarchyCompletion)completion {
    KKFIHierarchyCompletion completionCopy = [completion copy];
    NSSet<NSString *> *excludedWidgetTypesCopy = [excludedWidgetTypes copy];
    [self ensureCurrentConnectionWithTimeout:2.5
                                  completion:^(NSError *connectionError) {
        if (connectionError != nil) {
            completionCopy(nil, connectionError);
            return;
        }

        [self.hierarchyWaiters addObject:completionCopy];
        if (self.hierarchyRequest != nil) {
            return;
        }

        NSString *snapshotID = NSUUID.UUID.UUIDString;
        NSString *objectGroup =
            [@"kkfi-" stringByAppendingString:NSUUID.UUID.UUIDString];
        KKFIHierarchyRequest *request = [[KKFIHierarchyRequest alloc]
            initWithClient:self.serviceClient
                 isolateID:self.isolateID
               objectGroup:objectGroup
                snapshotID:snapshotID];
        self.hierarchyRequest = request;

        __weak typeof(self) weakSelf = self;
        __weak KKFIHierarchyRequest *weakRequest = request;
        [request startWithFallbackRootSize:rootSize
                      excludedWidgetTypes:excludedWidgetTypesCopy
                               completion:^(KKFIHierarchySnapshot *snapshot,
                                            NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            KKFIHierarchyRequest *completedRequest = weakRequest;
            if (self == nil || completedRequest == nil) {
                return;
            }
            [self finishHierarchyRequest:completedRequest
                                snapshot:snapshot
                                   error:error];
        }];
    }];
}

- (void)finishHierarchyRequest:(KKFIHierarchyRequest *)request
                      snapshot:(KKFIHierarchySnapshot *)snapshot
                         error:(NSError *)error {
    if (self.hierarchyRequest != request) {
        return;
    }

    self.hierarchyRequest = nil;
    NSArray<KKFIHierarchyCompletion> *waiters = self.hierarchyWaiters.copy;
    [self.hierarchyWaiters removeAllObjects];

    if (snapshot == nil && error == nil) {
        error = [self.class
            errorWithCode:KKFIInspectorSessionErrorInvalidPayload
               description:@"The Flutter hierarchy could not be built."];
    }

    NSString *objectGroup = request.objectGroup;
    if (snapshot != nil && error == nil) {
        NSString *oldObjectGroup = self.activeObjectGroup;
        self.activeObjectGroup = objectGroup;
        self.activeSnapshotID = snapshot.snapshotID;
        if (oldObjectGroup.length > 0 &&
            ![oldObjectGroup isEqualToString:objectGroup]) {
            [self disposeObjectGroup:oldObjectGroup
                         usingClient:self.serviceClient
                           isolateID:self.isolateID
                          completion:nil];
        }
    } else {
        [self disposeObjectGroup:objectGroup
                     usingClient:self.serviceClient
                       isolateID:self.isolateID
                      completion:nil];
    }

    for (KKFIHierarchyCompletion waiter in waiters) {
        waiter(snapshot, error);
    }
}

#pragma mark - Properties

- (void)fetchPropertiesForElement:(KKFIElementReference *)reference
                       completion:(KKFIPropertiesCompletion)completion {
    KKFIPropertiesCompletion completionCopy = [completion copy];
    [self ensureCurrentConnectionWithTimeout:2.5
                                  completion:^(NSError *connectionError) {
        if (connectionError != nil) {
            completionCopy(nil, connectionError);
            return;
        }

        NSError *referenceError = [self validationErrorForReference:reference];
        if (referenceError != nil) {
            completionCopy(nil, referenceError);
            return;
        }

        NSString *snapshotID = reference.snapshotID;
        NSDictionary *params = @{
            @"isolateId" : self.isolateID,
            @"arg" : reference.objectID,
            @"objectGroup" : reference.objectGroup,
        };
        [self.serviceClient callMethod:@"ext.flutter.inspector.getProperties"
                                params:params
                            completion:^(NSDictionary *response,
                                         NSError *error) {
            NSError *currentReferenceError =
                [self validationErrorForReference:reference];
            if (currentReferenceError != nil ||
                ![self.activeSnapshotID isEqualToString:snapshotID]) {
                completionCopy(nil, currentReferenceError ?: [self.class
                    errorWithCode:KKFIInspectorSessionErrorStaleElementReference
                       description:@"The Flutter element belongs to an old hierarchy snapshot."]);
                return;
            }
            if (error != nil) {
                completionCopy(nil, error);
                return;
            }

            id payload = [KKFIInspectorJSON normalizedPayloadFromResponse:response];
            NSDictionary *payloadDictionary =
                [payload isKindOfClass:NSDictionary.class] ? payload : nil;
            NSArray *values = [payload isKindOfClass:NSArray.class]
                ? payload
                : ([payloadDictionary[@"properties"] isKindOfClass:NSArray.class]
                       ? payloadDictionary[@"properties"]
                       : nil);
            if (values == nil) {
                completionCopy(nil, [self.class
                    errorWithCode:KKFIInspectorSessionErrorInvalidPayload
                       description:@"Flutter Inspector properties did not return an array."]);
                return;
            }

            NSMutableArray<NSDictionary *> *properties = [NSMutableArray array];
            for (id value in values) {
                if ([value isKindOfClass:NSDictionary.class]) {
                    [properties addObject:value];
                }
            }
            completionCopy(properties.copy, nil);
        }];
    }];
}

#pragma mark - Screenshot

- (void)captureScreenshotForElement:(KKFIElementReference *)reference
                            options:(KKFIScreenshotOptions *)options
                         completion:(KKFIScreenshotCompletion)completion {
    KKFIScreenshotOptions *optionsCopy = [options copy];
    KKFIScreenshotCompletion completionCopy = [completion copy];
    [self ensureCurrentConnectionWithTimeout:2.5
                                  completion:^(NSError *connectionError) {
        if (connectionError != nil) {
            completionCopy(nil, connectionError);
            return;
        }

        NSError *referenceError = [self validationErrorForReference:reference];
        if (referenceError != nil) {
            completionCopy(nil, referenceError);
            return;
        }

        CGSize size = optionsCopy.logicalSize;
        CGFloat margin = optionsCopy.margin;
        CGFloat ratio = optionsCopy.maxPixelRatio;
        BOOL validOptions = isfinite(size.width) && isfinite(size.height) &&
            size.width > 0 && size.height > 0 && isfinite(margin) &&
            margin >= 0 && isfinite(ratio) && ratio > 0;
        if (!validOptions) {
            completionCopy(nil, [self.class
                errorWithCode:KKFIInspectorSessionErrorInvalidScreenshotOptions
                   description:@"Screenshot size, margin, and pixel ratio must be finite positive values."]);
            return;
        }

        NSInteger width = (NSInteger)MIN(
            4096.0, ceil((size.width + margin * 2) * ratio));
        NSInteger height = (NSInteger)MIN(
            4096.0, ceil((size.height + margin * 2) * ratio));
        NSString *snapshotID = reference.snapshotID;
        NSDictionary *params = @{
            @"isolateId" : self.isolateID,
            @"id" : reference.objectID,
            @"width" : [NSString stringWithFormat:@"%ld", (long)MAX(width, 1)],
            @"height" : [NSString stringWithFormat:@"%ld", (long)MAX(height, 1)],
            @"margin" : [NSString stringWithFormat:@"%.3f", margin],
            @"maxPixelRatio" : [NSString stringWithFormat:@"%.3f", ratio],
            @"debugPaint" : optionsCopy.debugPaint ? @"true" : @"false",
        };
        [self.serviceClient callMethod:@"ext.flutter.inspector.screenshot"
                                params:params
                            completion:^(NSDictionary *response,
                                         NSError *error) {
            NSError *currentReferenceError =
                [self validationErrorForReference:reference];
            if (currentReferenceError != nil ||
                ![self.activeSnapshotID isEqualToString:snapshotID]) {
                completionCopy(nil, currentReferenceError ?: [self.class
                    errorWithCode:KKFIInspectorSessionErrorStaleElementReference
                       description:@"The Flutter element belongs to an old hierarchy snapshot."]);
                return;
            }
            if (error != nil) {
                completionCopy(nil, error);
                return;
            }

            id payload = [KKFIInspectorJSON normalizedPayloadFromResponse:response];
            if (![payload isKindOfClass:NSString.class]) {
                completionCopy(nil, [self.class
                    errorWithCode:KKFIInspectorSessionErrorScreenshotUnavailable
                       description:@"Flutter Inspector could not capture this element."]);
                return;
            }
            NSData *data = [[NSData alloc]
                initWithBase64EncodedString:payload
                                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
            UIImage *image = data == nil ? nil : [UIImage imageWithData:data];
            if (image == nil) {
                completionCopy(nil, [self.class
                    errorWithCode:KKFIInspectorSessionErrorInvalidPayload
                       description:@"The Flutter screenshot PNG could not be decoded."]);
                return;
            }
            completionCopy([[KKFIScreenshotResult alloc] initWithImage:image
                                                               pngData:data],
                           nil);
        }];
    }];
}

#pragma mark - Snapshot lifetime

- (NSError *)validationErrorForReference:(KKFIElementReference *)reference {
    BOOL valid = reference.objectID.length > 0 &&
        [reference.isolateID isEqualToString:self.isolateID] &&
        [reference.objectGroup isEqualToString:self.activeObjectGroup] &&
        [reference.snapshotID isEqualToString:self.activeSnapshotID];
    return valid ? nil : [self.class
        errorWithCode:KKFIInspectorSessionErrorStaleElementReference
           description:@"The Flutter element belongs to an old hierarchy snapshot."];
}

- (void)disposeObjectGroup:(NSString *)objectGroup
               usingClient:(KKFIVMServiceClient *)client
                 isolateID:(NSString *)isolateID
                completion:(dispatch_block_t)completion {
    if (objectGroup.length == 0 || client == nil || isolateID.length == 0) {
        if (completion != nil) {
            completion();
        }
        return;
    }
    [client callMethod:@"ext.flutter.inspector.disposeGroup"
                params:@{
                    @"isolateId" : isolateID,
                    @"objectGroup" : objectGroup,
                }
            completion:^(__unused NSDictionary *response,
                         __unused NSError *error) {
        if (completion != nil) {
            completion();
        }
    }];
}

- (void)abandonSnapshotStateWithError:(NSError *)error {
    self.activeObjectGroup = nil;
    self.activeSnapshotID = nil;
    [self.hierarchyRequest cancel];
    self.hierarchyRequest = nil;
    NSArray<KKFIHierarchyCompletion> *waiters = self.hierarchyWaiters.copy;
    [self.hierarchyWaiters removeAllObjects];
    for (KKFIHierarchyCompletion waiter in waiters) {
        waiter(nil, error);
    }
}

- (void)retireCurrentConnectionWithError:(NSError *)error {
    KKFIVMServiceClient *client = self.serviceClient;
    NSString *isolateID = self.isolateID;
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    if (self.activeObjectGroup.length > 0) {
        [groups addObject:self.activeObjectGroup];
    }
    NSString *pendingObjectGroup = self.hierarchyRequest.objectGroup;
    if (pendingObjectGroup.length > 0 &&
        ![groups containsObject:pendingObjectGroup]) {
        [groups addObject:pendingObjectGroup];
    }

    self.serviceClient = nil;
    self.vmServiceURL = nil;
    self.isolateID = nil;
    self.state = KKFIInspectorSessionStateIdle;
    [self abandonSnapshotStateWithError:error];
    [self disposeObjectGroups:groups
                  usingClient:client
                    isolateID:isolateID
                   completion:^{
        [client close];
    }];
}

- (void)disposeObjectGroups:(NSArray<NSString *> *)groups
                usingClient:(KKFIVMServiceClient *)client
                  isolateID:(NSString *)isolateID
                 completion:(dispatch_block_t)completion {
    NSString *firstGroup = groups.firstObject;
    if (firstGroup.length == 0) {
        if (completion != nil) {
            completion();
        }
        return;
    }
    NSArray<NSString *> *remaining =
        [groups subarrayWithRange:NSMakeRange(1, groups.count - 1)];
    [self disposeObjectGroup:firstGroup
                 usingClient:client
                   isolateID:isolateID
                  completion:^{
        [self disposeObjectGroups:remaining
                      usingClient:client
                        isolateID:isolateID
                       completion:completion];
    }];
}

#pragma mark - Invalidation

- (void)invalidate {
    dispatch_async(self.stateQueue, ^{
        self.attemptID += 1;
        NSError *error = [self.class
            errorWithCode:KKFIInspectorSessionErrorInvalidated
               description:@"The Flutter Inspector session was invalidated."];

        NSArray<KKFIInspectorConnectionCompletion> *connectionWaiters =
            self.connectionWaiters.copy;
        [self.connectionWaiters removeAllObjects];
        for (KKFIInspectorConnectionCompletion waiter in connectionWaiters) {
            waiter(error);
        }
        [self retireCurrentConnectionWithError:error];
    });
}

- (void)clearConnection {
    [self.serviceClient close];
    self.serviceClient = nil;
}

+ (NSError *)errorWithCode:(KKFIInspectorSessionErrorCode)code
                description:(NSString *)description {
    return [NSError errorWithDomain:KKFIInspectorSessionErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

@end
