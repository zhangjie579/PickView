//
//  KKFIHierarchyRequest.m
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/15.
//

#import "KKFIHierarchyRequest.h"

#import "KKFIHierarchyEnricher.h"
#import "../Connection/KKFIVMServiceClient.h"
#import "../Inspector/KKFIInspectorJSON.h"
#import "../Inspector/KKFIInspectorTreeBuilder.h"
#import "../Model/KKFIInspectorModels.h"

static NSString *const KKFIHierarchyRequestErrorDomain =
    @"KKFIHierarchyRequestErrorDomain";

@interface KKFIHierarchyRequest ()

@property(nonatomic, strong) KKFIVMServiceClient *client;
@property(nonatomic, copy) NSString *isolateID;
@property(nonatomic, copy, readwrite) NSString *objectGroup;
@property(nonatomic, copy, readwrite) NSString *snapshotID;
@property(nonatomic, strong) KKFIHierarchyEnricher *enricher;
@property(nonatomic, copy, nullable) KKFIHierarchyRequestCompletion completion;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL cancelled;

@end

@implementation KKFIHierarchyRequest

- (instancetype)initWithClient:(KKFIVMServiceClient *)client
                     isolateID:(NSString *)isolateID
                   objectGroup:(NSString *)objectGroup
                    snapshotID:(NSString *)snapshotID {
    self = [super init];
    if (self) {
        _client = client;
        _isolateID = [isolateID copy];
        _objectGroup = [objectGroup copy];
        _snapshotID = [snapshotID copy];
        _enricher = [[KKFIHierarchyEnricher alloc] init];
    }
    return self;
}

- (void)startWithFallbackRootSize:(CGSize)rootSize
              excludedWidgetTypes:(NSSet<NSString *> *)excludedWidgetTypes
                       completion:(KKFIHierarchyRequestCompletion)completion {
    NSAssert(!self.started, @"A hierarchy request can only be started once.");
    if (self.started || self.cancelled) {
        return;
    }
    self.started = YES;
    self.completion = [completion copy];
    NSSet<NSString *> *excludedTypes = [excludedWidgetTypes copy];

    __weak typeof(self) weakSelf = self;
    [self fetchRootWidgetTreeWithCompletion:^(id widgetPayload,
                                               NSError *treeError) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil || self.cancelled) {
            return;
        }
        if (treeError != nil) {
            [self finishWithSnapshot:nil error:treeError];
            return;
        }

        NSDictionary *widgetRoot =
            [widgetPayload isKindOfClass:NSDictionary.class]
                ? widgetPayload
                : nil;
        NSString *rootObjectID =
            [KKFIInspectorJSON nodeIDFromDictionary:widgetRoot];
        if (rootObjectID.length == 0) {
            [self finishWithSnapshot:nil
                               error:[self.class errorWithDescription:
                                   @"The Flutter Widget tree root has no Inspector object ID."]];
            return;
        }

        NSDictionary *params = @{
            @"isolateId" : self.isolateID,
            @"id" : rootObjectID,
            @"groupName" : self.objectGroup,
            @"subtreeDepth" : @"100",
        };
        [self.client callMethod:@"ext.flutter.inspector.getLayoutExplorerNode"
                         params:params
                     completion:^(NSDictionary *response,
                                  NSError *layoutError) {
            __strong typeof(weakSelf) self = weakSelf;
            if (self == nil || self.cancelled) {
                return;
            }
            id layoutPayload = layoutError == nil
                ? [KKFIInspectorJSON normalizedPayloadFromResponse:response]
                : nil;
            if (layoutError != nil ||
                ![layoutPayload isKindOfClass:NSDictionary.class]) {
                [self finishWithSnapshot:nil
                                   error:layoutError ?: [self.class
                                       errorWithDescription:
                                           @"The Flutter Layout Explorer did not return an object."]];
                return;
            }

            [self.enricher enrichLayoutPayload:layoutPayload
                                        client:self.client
                                     isolateID:self.isolateID
                                   objectGroup:self.objectGroup
                                    completion:^(NSDictionary<NSString *, NSArray *> *propertiesByID,
                                                 NSDictionary<NSString *, NSValue *> *resolvedOffsetsByID) {
                __strong typeof(weakSelf) self = weakSelf;
                if (self == nil || self.cancelled) {
                    return;
                }
                NSError *buildError = nil;
                KKFIHierarchySnapshot *snapshot = [KKFIInspectorTreeBuilder
                    snapshotFromLayoutPayload:layoutPayload
                                widgetPayload:widgetPayload
                         widgetPropertiesByID:propertiesByID
                          resolvedOffsetsByID:resolvedOffsetsByID
                                 rootObjectID:rootObjectID
                             fallbackRootSize:rootSize
                                    isolateID:self.isolateID
                                  objectGroup:self.objectGroup
                                   snapshotID:self.snapshotID
                           excludedWidgetTypes:excludedTypes
                                        error:&buildError];
                [self finishWithSnapshot:snapshot error:buildError];
            }];
        }];
    }];
}

- (void)cancel {
    self.cancelled = YES;
    self.completion = nil;
}

- (void)fetchRootWidgetTreeWithCompletion:(void (^)(id _Nullable payload,
                                                     NSError *_Nullable error))completion {
    NSDictionary *params = @{
        @"isolateId" : self.isolateID,
        @"groupName" : self.objectGroup,
        @"isSummaryTree" : @"true",
        @"withPreviews" : @"true",
        @"fullDetails" : @"true",
    };
    [self.client callMethod:@"ext.flutter.inspector.getRootWidgetTree"
                     params:params
                 completion:^(NSDictionary *response, NSError *error) {
        if (self.cancelled) {
            return;
        }
        if (error == nil) {
            completion([KKFIInspectorJSON normalizedPayloadFromResponse:response],
                       nil);
            return;
        }

        [self.client callMethod:@"ext.flutter.inspector.getRootWidgetSummaryTree"
                         params:@{
                             @"isolateId" : self.isolateID,
                             @"objectGroup" : self.objectGroup,
                         }
                     completion:^(NSDictionary *legacyResponse,
                                  NSError *legacyError) {
            if (self.cancelled) {
                return;
            }
            completion(legacyError == nil
                           ? [KKFIInspectorJSON
                                 normalizedPayloadFromResponse:legacyResponse]
                           : nil,
                       legacyError);
        }];
    }];
}

- (void)finishWithSnapshot:(KKFIHierarchySnapshot *)snapshot
                      error:(NSError *)error {
    if (self.cancelled || self.completion == nil) {
        return;
    }
    KKFIHierarchyRequestCompletion completion = self.completion;
    self.completion = nil;
    completion(snapshot, error);
}

+ (NSError *)errorWithDescription:(NSString *)description {
    return [NSError errorWithDomain:KKFIHierarchyRequestErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

@end
