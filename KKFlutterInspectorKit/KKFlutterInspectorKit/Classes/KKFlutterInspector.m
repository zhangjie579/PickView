//
//  KKFlutterInspector.m
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/13.
//

#import "KKFlutterInspector.h"

#import "Internal/Runtime/KKFIFlutterPageLocator.h"
#import "Internal/Session/KKFIInspectorSession.h"

static NSString *const KKFlutterInspectorErrorDomain =
    @"KKFlutterInspectorErrorDomain";

typedef NS_ENUM(NSInteger, KKFlutterInspectorErrorCode) {
    KKFlutterInspectorErrorNoFlutterPage = 1,
    KKFlutterInspectorErrorUnknownSnapshot = 2,
    KKFlutterInspectorErrorEngineUnavailable = 3,
};

@interface KKFlutterInspector ()

@property(nonatomic, strong) KKFIFlutterPageLocator *pageLocator;
@property(nonatomic, strong)
    NSMapTable<FlutterEngine *, KKFIInspectorSession *> *sessions;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, KKFIInspectorSession *> *sessionsBySnapshotID;
@property(nonatomic) dispatch_queue_t callbackQueue;

- (void)fetchHierarchyForEngine:(FlutterEngine *)engine
                fallbackRootSize:(CGSize)rootSize
             excludedWidgetTypes:(NSSet<NSString *> *)excludedWidgetTypes
                      completion:(KKFlutterInspectorHierarchyCompletion)completion;

@end

@implementation KKFlutterInspector

- (instancetype)init {
    self = [super init];
    if (self) {
        _pageLocator = [[KKFIFlutterPageLocator alloc] init];
        // Engines are owned by the host application. A weak key lets the
        // corresponding session disappear when its engine is released, while
        // the strong value keeps a successfully warmed session alive.
        _sessions = [NSMapTable weakToStrongObjectsMapTable];
        _sessionsBySnapshotID = [NSMutableDictionary dictionary];
        _excludedWidgetTypes = [NSSet set];
        _callbackQueue = dispatch_queue_create(
            "com.kkflutterinspector.public-callback", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    for (KKFIInspectorSession *session in self.sessions.objectEnumerator) {
        [session invalidate];
    }
}

- (void)warmUpWindow:(UIWindow *)window {
    dispatch_block_t discover = ^{
        NSArray<FlutterEngine *> *engines =
            [self.pageLocator flutterEnginesInWindow:window];
        for (FlutterEngine *engine in engines) {
            KKFIInspectorSession *session = [self sessionForEngine:engine];
            [session ensureConnectedWithTimeout:2.5
                                     completion:^(NSError *error) {
#if DEBUG
                if (error != nil) {
                    NSLog(@"[KKFlutterInspectorKit] Session warm-up failed: %@",
                          error.localizedDescription);
                }
#endif
            }];
        }
    };

    if (NSThread.isMainThread) {
        discover();
    } else {
        dispatch_async(dispatch_get_main_queue(), discover);
    }
}

- (void)fetchHierarchyInWindow:(UIWindow *)window
              fallbackRootSize:(CGSize)rootSize
                    completion:(KKFlutterInspectorHierarchyCompletion)completion {
    KKFlutterInspectorHierarchyCompletion completionCopy = [completion copy];
    NSSet<NSString *> *excludedWidgetTypes = [self.excludedWidgetTypes copy];
    dispatch_block_t fetch = ^{
        FlutterEngine *engine =
            [self.pageLocator flutterEnginesInWindow:window].firstObject;
        if (engine == nil) {
            NSError *error = [self.class
                errorWithCode:KKFlutterInspectorErrorNoFlutterPage
                   description:@"No Flutter page is attached to this window."];
            dispatch_async(self.callbackQueue, ^{
                completionCopy(nil, error);
            });
            return;
        }

        [self fetchHierarchyForEngine:engine
                     fallbackRootSize:rootSize
                  excludedWidgetTypes:excludedWidgetTypes
                           completion:completionCopy];
    };

    if (NSThread.isMainThread) {
        fetch();
    } else {
        dispatch_async(dispatch_get_main_queue(), fetch);
    }
}

- (void)fetchHierarchyForViewController:(FlutterViewController *)viewController
                       fallbackRootSize:(CGSize)rootSize
                             completion:(KKFlutterInspectorHierarchyCompletion)completion {
    KKFlutterInspectorHierarchyCompletion completionCopy = [completion copy];
    NSSet<NSString *> *excludedWidgetTypes = [self.excludedWidgetTypes copy];
    dispatch_block_t fetch = ^{
        FlutterEngine *engine = [self.pageLocator
            flutterEngineForViewController:viewController];
        if (engine == nil) {
            NSError *error = [self.class
                errorWithCode:KKFlutterInspectorErrorEngineUnavailable
                   description:@"The FlutterViewController has no available FlutterEngine."];
            dispatch_async(self.callbackQueue, ^{
                completionCopy(nil, error);
            });
            return;
        }

        [self fetchHierarchyForEngine:engine
                     fallbackRootSize:rootSize
                  excludedWidgetTypes:excludedWidgetTypes
                           completion:completionCopy];
    };

    if (NSThread.isMainThread) {
        fetch();
    } else {
        dispatch_async(dispatch_get_main_queue(), fetch);
    }
}

- (void)fetchHierarchyForEngine:(FlutterEngine *)engine
                fallbackRootSize:(CGSize)rootSize
             excludedWidgetTypes:(NSSet<NSString *> *)excludedWidgetTypes
                      completion:(KKFlutterInspectorHierarchyCompletion)completion {
    NSAssert(NSThread.isMainThread,
             @"Flutter hierarchy target selection must run on the main thread.");
    KKFIInspectorSession *session = [self sessionForEngine:engine];
    [session fetchHierarchyWithFallbackRootSize:rootSize
                           excludedWidgetTypes:excludedWidgetTypes
                                     completion:^(KKFIHierarchySnapshot *snapshot,
                                                  NSError *error) {
        dispatch_async(self.callbackQueue, ^{
            if (snapshot != nil && error == nil) {
                [self registerSession:session forSnapshot:snapshot];
            }
            completion(snapshot, error);
        });
    }];
}

- (void)fetchPropertiesForElement:(KKFIElementReference *)reference
                       completion:(KKFlutterInspectorPropertiesCompletion)completion {
    KKFlutterInspectorPropertiesCompletion completionCopy = [completion copy];
    dispatch_async(self.callbackQueue, ^{
        KKFIInspectorSession *session =
            self.sessionsBySnapshotID[reference.snapshotID];
        if (session == nil) {
            completionCopy(nil, [self.class errorForUnknownSnapshot]);
            return;
        }
        [session fetchPropertiesForElement:reference
                                completion:^(NSArray<NSDictionary *> *properties,
                                             NSError *error) {
            dispatch_async(self.callbackQueue, ^{
                completionCopy(properties, error);
            });
        }];
    });
}

- (void)captureScreenshotForElement:(KKFIElementReference *)reference
                            options:(KKFIScreenshotOptions *)options
                         completion:(KKFlutterInspectorScreenshotCompletion)completion {
    KKFlutterInspectorScreenshotCompletion completionCopy = [completion copy];
    KKFIScreenshotOptions *optionsCopy = [options copy];
    dispatch_async(self.callbackQueue, ^{
        KKFIInspectorSession *session =
            self.sessionsBySnapshotID[reference.snapshotID];
        if (session == nil) {
            completionCopy(nil, [self.class errorForUnknownSnapshot]);
            return;
        }
        [session captureScreenshotForElement:reference
                                     options:optionsCopy
                                  completion:^(KKFIScreenshotResult *result,
                                               NSError *error) {
            dispatch_async(self.callbackQueue, ^{
                completionCopy(result, error);
            });
        }];
    });
}

- (void)registerSession:(KKFIInspectorSession *)session
             forSnapshot:(KKFIHierarchySnapshot *)snapshot {
    NSMutableArray<NSString *> *oldSnapshotIDs = [NSMutableArray array];
    [self.sessionsBySnapshotID
        enumerateKeysAndObjectsUsingBlock:^(NSString *snapshotID,
                                             KKFIInspectorSession *value,
                                             BOOL *stop) {
        if (value == session) {
            [oldSnapshotIDs addObject:snapshotID];
        }
    }];
    [self.sessionsBySnapshotID removeObjectsForKeys:oldSnapshotIDs];
    self.sessionsBySnapshotID[snapshot.snapshotID] = session;
}

+ (NSError *)errorForUnknownSnapshot {
    return [self errorWithCode:KKFlutterInspectorErrorUnknownSnapshot
                   description:@"The Flutter hierarchy snapshot is no longer active."];
}

+ (NSError *)errorWithCode:(KKFlutterInspectorErrorCode)code
                description:(NSString *)description {
    return [NSError errorWithDomain:KKFlutterInspectorErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

- (KKFIInspectorSession *)sessionForEngine:(FlutterEngine *)engine {
    NSAssert(NSThread.isMainThread,
             @"Flutter session lookup must run on the main thread.");
    KKFIInspectorSession *session = [self.sessions objectForKey:engine];
    if (session == nil) {
        session = [[KKFIInspectorSession alloc] initWithEngine:engine];
        [self.sessions setObject:session forKey:engine];
    }
    return session;
}

@end
