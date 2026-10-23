#import "PVDetailPrefix.h"

#import "PVDetailAppsManager.h"

#import "PVDetailPreferenceManager.h"
#import "PVDetailStaticHierarchyDataSource.h"
#import "PVHierarchyInfo.h"
#import "PVInspectionRequestClient.h"
#import "PVRequestAttachment.h"
#import "PVRequestType.h"
#import "PickViewClient.h"
#import "PVClientSession.h"
#import "PVClientSessionManager.h"
#import "PVEndpointProtocol.h"
#import "PVPeerIdentity.h"
#import "PVUSBEndpoint.h"
#import "PVFlutterVMServiceProxy.h"

NSString *const PVDetailInspectingAppDidEndNotificationName = @"PVDetailInspectingAppDidEndNotificationName";

@interface PVDetailAppsManager ()

@property(nonatomic, strong) RACSubject *willConnectToApp;
@property(nonatomic, strong) RACSubject *didAutoReconnectSucc;
@property(nonatomic, strong) RACDisposable *connectionMonitorDisposable;
@property(nonatomic, strong) PVAppInfo *reconnectingAppInfo;
@property(nonatomic, strong) NSImage *reconnectingAppIcon;
@property(nonatomic, strong) NSDate *lastReconnectAttemptDate;
@property(nonatomic, assign) BOOL reconnectInFlight;
@property(nonatomic, strong) PVFlutterVMServiceProxy *flutterVMServiceProxy;

@end

@implementation PVDetailAppsManager

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static PVDetailAppsManager *instance = nil;
    dispatch_once(&onceToken,^{
        instance = [[super allocWithZone:NULL] init];
    });
    return instance;
}

+ (id)allocWithZone:(struct _NSZone *)zone {
    return [self sharedInstance];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _willConnectToApp = [RACSubject subject];
        _didAutoReconnectSucc = [RACSubject subject];

        @weakify(self);
        _connectionMonitorDisposable = [[RACSignal interval:1 onScheduler:RACScheduler.mainThreadScheduler] subscribeNext:^(NSDate *date) {
            @strongify(self);
            [self inspectConnectionStateAtDate:date];
        }];
    }
    return self;
}

- (void)setInspectingApp:(PVDetailInspectableApp *)inspectingApp {
    BOOL shouldPostNotification = (_inspectingApp && !inspectingApp);

    _inspectingApp = inspectingApp;
    if (inspectingApp) {
        self.reconnectingAppInfo = nil;
        self.reconnectingAppIcon = nil;
        self.lastReconnectAttemptDate = nil;
        self.reconnectInFlight = NO;
        [self configureFlutterVMServiceRelayForApp:inspectingApp];
        [self refreshFlutterVMServiceInfoForApp:inspectingApp];
        [self.willConnectToApp sendNext:inspectingApp];
    }

    if (shouldPostNotification) {
        [[NSNotificationCenter defaultCenter] postNotificationName:PVDetailInspectingAppDidEndNotificationName object:self];
    }
}

#pragma mark - Inspector settings

- (NSDictionary<NSString *, id> *)currentInspectorSettings {
    NSMutableDictionary<NSString *, id> *settings = [@{
        PVInspectorSettingsKey_HideFlutterBlocWidgets :
            @([PVDetailPreferenceManager mainManager].hideFlutterBlocWidgets),
    } mutableCopy];
    // Always include this key so turning the preference off clears a relay
    // URL which may already have been received by the inspected app.
    settings[PVInspectorSettingsKey_FlutterVMServiceProxyURL] =
        self.flutterVMServiceProxy.deviceURL ?: @"";
    return settings;
}

- (void)configureFlutterVMServiceRelayForApp:(PVDetailInspectableApp *)app {
    [self.flutterVMServiceProxy stop];
    self.flutterVMServiceProxy = nil;
    if (![PVDetailPreferenceManager mainManager].enableFlutterVMServiceProxy) {
        [[app sendInspectorSettings:[self currentInspectorSettings]]
            subscribeError:^(NSError *sendError) {
                NSLog(@"[PickViewVMProxy] failed to clear relay URL: %@", sendError.localizedDescription);
            }];
        return;
    }
    // The simulator shares the Mac's loopback namespace, so it can reach the
    // Dart VM Service directly. Do not create or send a relay for it.
    if (app.appInfo.deviceType == PVAppInfoDeviceSimulator) {
        return;
    }

    NSString *hostURL = app.appInfo.flutterVMServiceURL;
    if (!hostURL.length) {
        return;
    }

    PVFlutterVMServiceProxy *proxy = [[PVFlutterVMServiceProxy alloc] init];
    NSError *error = nil;
    if (![proxy startWithHostVMServiceURL:hostURL error:&error]) {
        NSLog(@"[PickViewVMProxy] failed to start for %@: %@", hostURL, error.localizedDescription);
        return;
    }
    self.flutterVMServiceProxy = proxy;
    [[app sendInspectorSettings:[self currentInspectorSettings]]
        subscribeError:^(NSError *sendError) {
            NSLog(@"[PickViewVMProxy] failed to send relay URL: %@", sendError.localizedDescription);
        }];
}

- (void)reloadFlutterVMServiceRelayForInspectingApp {
    PVDetailInspectableApp *app = self.inspectingApp;
    if (!app) {
        return;
    }
    [self configureFlutterVMServiceRelayForApp:app];
    if ([PVDetailPreferenceManager mainManager].enableFlutterVMServiceProxy) {
        [self refreshFlutterVMServiceInfoForApp:app];
    }
}

- (void)refreshFlutterVMServiceInfoForApp:(PVDetailInspectableApp *)app {
    if (!app.session || app.appInfo.deviceType == PVAppInfoDeviceSimulator ||
        app.appInfo.flutterVMServiceURL.length) {
        return;
    }
    // The launch screen may have fetched AppInfo before Dart had obtained its
    // VM Service URI. Bypass the normal 8-second cache when this app is picked
    // so the relay is configured from the current, not stale, response.
    @weakify(self);
    [[self fetchInspectableAppForSession:app.session needImages:NO localInfos:@[]]
        subscribeNext:^(PVDetailInspectableApp *freshApp) {
            @strongify(self);
            if (!self || self.inspectingApp != app || !freshApp.appInfo.flutterVMServiceURL.length) {
                return;
            }
            app.appInfo.flutterVMServiceURL = freshApp.appInfo.flutterVMServiceURL;
            [self configureFlutterVMServiceRelayForApp:app];
        }];
}

- (RACSignal *)pushInspectorSettingsToApp:(PVDetailInspectableApp *)app {
    if (!app) {
        return [RACSignal empty];
    }
    // Apps embedding an older PickViewServer do not know this request type and
    // answer with an error immediately. The preference simply will not apply,
    // so swallow it instead of failing the whole inspection.
    return [[app sendInspectorSettings:[self currentInspectorSettings]]
        catch:^RACSignal *(NSError *error) {
            NSLog(@"[PickView] Inspector settings were not applied: %@",
                  error.localizedDescription);
            return [RACSignal empty];
        }];
}

- (void)pushInspectorSettingsAndReloadInspection {
    PVDetailInspectableApp *app = self.inspectingApp;
    if (!app) {
        return;
    }

    // pushInspectorSettingsToApp: swallows errors, so this always completes —
    // either after the app confirmed the settings or right after the failure.
    @weakify(self);
    [[[self pushInspectorSettingsToApp:app] deliverOnMainThread]
        subscribeCompleted:^{
            @strongify(self);
            [self reloadHierarchyForApp:app];
        }];
}

- (void)reloadHierarchyForApp:(PVDetailInspectableApp *)app {
    if (!app || app != self.inspectingApp) {
        return;
    }
    @weakify(self);
    [[[app fetchHierarchyData] deliverOnMainThread]
        subscribeNext:^(PVHierarchyInfo *info) {
            @strongify(self);
            if (!info || app != self.inspectingApp) {
                return;
            }
            [[PVDetailStaticHierarchyDataSource sharedInstance]
                reloadWithHierarchyInfo:info
                              keepState:NO];
        }
        error:^(NSError *error) {
            NSLog(@"[PickView] Failed to reload hierarchy: %@",
                  error.localizedDescription);
        }];
}

- (void)inspectConnectionStateAtDate:(NSDate *)date {
    if (self.inspectingApp) {
        PVClientSession *session = self.inspectingApp.session;
        BOOL sessionIsAvailable = session &&
                                  [PickViewClient.sharedClient.sessionManager.allSessions containsObject:session] &&
                                  session.state == PVClientSessionStateReady;
        if (!sessionIsAvailable) {
            self.reconnectingAppInfo = self.inspectingApp.appInfo;
            self.reconnectingAppIcon = self.inspectingApp.appInfo.appIcon;
            _inspectingApp = nil;
            [[NSNotificationCenter defaultCenter] postNotificationName:PVDetailInspectingAppDidEndNotificationName object:self];
        }
    }

    if (!self.reconnectingAppInfo || self.reconnectInFlight) {
        return;
    }
    if (self.lastReconnectAttemptDate && [date timeIntervalSinceDate:self.lastReconnectAttemptDate] < 3) {
        return;
    }

    self.lastReconnectAttemptDate = date;
    self.reconnectInFlight = YES;
    PVAppInfo *targetInfo = self.reconnectingAppInfo;
    @weakify(self);
    [[self fetchAppInfosWithImage:NO localInfos:nil] subscribeNext:^(NSArray<PVDetailInspectableApp *> *apps) {
        @strongify(self);
        PVDetailInspectableApp *matchedApp = [apps pv_inspect_firstFiltered:^BOOL(PVDetailInspectableApp *app) {
            return [targetInfo isEqualToAppInfo:app.appInfo];
        }];
        if (matchedApp) {
            matchedApp.appInfo.appIcon = self.reconnectingAppIcon;
            self.inspectingApp = matchedApp;
            [self.didAutoReconnectSucc sendNext:matchedApp];
        }
    } error:^(NSError *error) {
        @strongify(self);
        self.reconnectInFlight = NO;
    } completed:^{
        @strongify(self);
        self.reconnectInFlight = NO;
    }];
}

- (RACSignal *)fetchAppInfosWithImage:(BOOL)needImages localInfos:(NSArray<PVAppInfo *> *)localInfos {
    NSArray<PVClientSession *> *sessions = PickViewClient.sharedClient.sessionManager.allSessions ?: @[];
    NSArray<PVClientSession *> *allReadySessions = [sessions pv_inspect_filter:^BOOL(PVClientSession *session) {
        return session.state == PVClientSessionStateReady;
    }];
    NSMutableDictionary<NSString *, PVClientSession *> *preferredSessions = [NSMutableDictionary dictionary];
    for (PVClientSession *session in allReadySessions) {
        NSString *peerID = session.peerIdentity.uuid.length ? session.peerIdentity.uuid : session.identifier;
        PVClientSession *current = preferredSessions[peerID];
        BOOL sessionUsesUSB = [session.endpoint isKindOfClass:PVUSBEndpoint.class];
        BOOL currentUsesUSB = [current.endpoint isKindOfClass:PVUSBEndpoint.class];
        if (!current || (sessionUsesUSB && !currentUsesUSB)) {
            preferredSessions[peerID] = session;
        }
    }
    NSArray<PVClientSession *> *readySessions = preferredSessions.allValues;

    if (!readySessions.count) {
        return [RACSignal return:@[]];
    }

    NSArray<RACSignal *> *signals = [readySessions pv_inspect_map:^id(NSUInteger idx, PVClientSession *session) {
        return [self fetchInspectableAppForSession:session needImages:needImages localInfos:localInfos];
    }];

    return [[RACSignal zip:signals] map:^id _Nullable(RACTuple *tuple) {
        return [tuple.allObjects pv_inspect_filter:^BOOL(id obj) {
            return [obj isKindOfClass:PVDetailInspectableApp.class];
        }];
    }];
}

- (RACSignal *)fetchInspectableAppForSession:(PVClientSession *)session
                                  needImages:(BOOL)needImages
                                  localInfos:(NSArray<PVAppInfo *> *)localInfos {
    NSArray<PVAppInfo *> *validAppInfos = [localInfos pv_inspect_filter:^BOOL(PVAppInfo *info) {
        BOOL cacheIsFresh = [[NSDate date] timeIntervalSince1970] - info.cachedTimestamp <= 8;
        BOOL hasRequestedImages = !needImages || info.screenshot != nil;
        return cacheIsFresh && hasRequestedImages;
    }];
    NSArray<NSNumber *> *localInfoIdentifiers = [validAppInfos pv_inspect_map:^id(NSUInteger idx, PVAppInfo *value) {
        return @(value.appInfoIdentifier);
    }] ?: @[];

    NSDictionary *params = @{@"needImages": @(needImages), @"local": localInfoIdentifiers};
    PVRequestAttachment *request = [PVRequestAttachment attachmentWithData:params];
    PVInspectionRequestClient *requestClient = [[PVInspectionRequestClient alloc] initWithSession:session];

    @weakify(self);
    return [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        if (!self) {
            [subscriber sendCompleted];
            return nil;
        }

        [requestClient sendRequestType:PVRequestTypeAppInfo object:request timeoutInterval:8 completion:^(id responseData, BOOL finished, NSError *error) {
            @strongify(self);
            if (!self) return;

            PVAppInfo *appInfo = error ? nil : [self appInfoFromResponseObject:responseData validLocalInfos:validAppInfos];
            if (!appInfo) {
                appInfo = [self appInfoForSession:session localInfos:validAppInfos];
            }

            [subscriber sendNext:[self inspectableAppForSession:session appInfo:appInfo]];
            [subscriber sendCompleted];
        }];

        return nil;
    }];
}

- (PVDetailInspectableApp *)inspectableAppForSession:(PVClientSession *)session appInfo:(PVAppInfo *)appInfo {
    PVDetailInspectableApp *app = [[PVDetailInspectableApp alloc] init];
    app.session = session;
    app.appInfo = appInfo;
    return app;
}

- (PVAppInfo *)appInfoFromResponseObject:(id)responseData validLocalInfos:(NSArray<PVAppInfo *> *)validAppInfos {
    if (![responseData isKindOfClass:PVAppInfo.class]) {
        return nil;
    }

    PVAppInfo *receivedInfo = (PVAppInfo *)responseData;
    receivedInfo.cachedTimestamp = [[NSDate date] timeIntervalSince1970];
    if (receivedInfo.shouldUseCache) {
        PVAppInfo *localInfo = [validAppInfos pv_inspect_firstFiltered:^BOOL(PVAppInfo *obj) {
            return obj.appInfoIdentifier == receivedInfo.appInfoIdentifier;
        }];
        if (localInfo) {
            receivedInfo = localInfo;
        }
    }
    return receivedInfo;
}

- (PVAppInfo *)appInfoForSession:(PVClientSession *)session localInfos:(NSArray<PVAppInfo *> *)localInfos {
    PVPeerIdentity *identity = session.peerIdentity;
    PVAppInfo *info = [[PVAppInfo alloc] init];
    info.appInfoIdentifier = (NSUInteger)labs((long)(session.identifier ?: identity.uuid ?: @"").hash);
    info.appName = identity.appName.length ? identity.appName : @"PickView";
    info.appBundleIdentifier = identity.bundleID ?: @"";
    info.deviceDescription = identity.deviceName.length ? identity.deviceName : session.endpoint.displayName ?: @"Device";
    info.osDescription = identity.systemVersion ?: @"";
    info.serverReadableVersion = identity.protocolVersion ?: @"";
    info.serverVersion = 1;
    info.swiftEnabledInPickViewServer = 0;
    info.deviceType = [self deviceTypeForSession:session];
    info.cachedTimestamp = [[NSDate date] timeIntervalSince1970];

    PVAppInfo *cachedInfo = [localInfos pv_inspect_firstFiltered:^BOOL(PVAppInfo *obj) {
        return [obj isEqualToAppInfo:info];
    }];
    if (cachedInfo) {
        info.appIcon = cachedInfo.appIcon;
        info.screenshot = cachedInfo.screenshot;
    }

    return info;
}

- (PVAppInfoDevice)deviceTypeForSession:(PVClientSession *)session {
    switch (session.peerIdentity.platform) {
        case PVPeerPlatformIOSSimulator:
            return PVAppInfoDeviceSimulator;
        case PVPeerPlatformMacOS:
            return PVAppInfoDeviceMac;
        case PVPeerPlatformIOSDevice:
        case PVPeerPlatformUnknown:
            if ([session.peerIdentity.deviceName localizedCaseInsensitiveContainsString:@"iPad"]) {
                return PVAppInfoDeviceIPad;
            }
            return PVAppInfoDeviceOthers;
    }
    return PVAppInfoDeviceOthers;
}

@end
