//
//  PVFlutterSettingsHandler.m
//  PickViewServer
//

#import "PVFlutterSettingsHandler.h"

#import "PVArchiveCodec.h"
#import "PVRequestAttachment.h"
#import "PVRequestType.h"
#import "PVResponseAttachment.h"
#if TARGET_OS_IPHONE
#import "KKFlutterInspectorConfigure.h"
#endif

@implementation PVFlutterSettingsHandler

- (BOOL)canHandleRequestType:(uint32_t)type {
    return type == PVRequestTypeInspectorSettings;
}

- (void)handleRequestType:(uint32_t)type
                  payload:(NSData *)payload
               completion:(void (^)(NSData *_Nullable, NSError *_Nullable))completion {
    NSDictionary *settings = [self settingsFromPayload:payload];
    [self applySettings:settings];

    PVResponseAttachment *attachment =
        [PVResponseAttachment attachmentWithData:settings ?: @{}];
    NSError *error = nil;
    NSData *data = [PVArchiveCodec archivedDataWithObject:attachment error:&error];
    if (completion) {
        completion(data, error);
    }
}

- (NSDictionary *)settingsFromPayload:(NSData *)payload {
    if (!payload.length) {
        return nil;
    }

    NSError *error = nil;
    id object = [PVArchiveCodec unarchivedObjectFromData:payload
                                          allowedClasses:[PVArchiveCodec defaultAllowedClasses]
                                                   error:&error];
    if ([object isKindOfClass:NSDictionary.class]) {
        return object;
    } else if ([object isKindOfClass:PVRequestAttachment.class]) {    
        id data = ((PVRequestAttachment *)object).data;
        return [data isKindOfClass:NSDictionary.class] ? data : nil;
    } else {
        return nil;
    }
}

- (void)applySettings:(NSDictionary *)settings {
    id hideBlocWidgets = settings[PVInspectorSettingsKey_HideFlutterBlocWidgets];
    if (![hideBlocWidgets respondsToSelector:@selector(boolValue)]) {
        return;
    }
    
#if TARGET_OS_IPHONE

    // KKFlutterInspectorKit is an iOS-only dependency, while this handler lives
    // in a directory the macOS target compiles as well. Resolving the class at
    // runtime keeps one code path for both and degrades to a no-op whenever the
    // host app does not link the Flutter inspector.
    KKFlutterInspectorConfigure *configure =
        [KKFlutterInspectorConfigure sharedManager];
    if (![configure respondsToSelector:@selector(setBlocWidgetFilteringEnabled:)]) {
        return;
    }
    configure.blocWidgetFilteringEnabled = [hideBlocWidgets boolValue];
    
#endif
}

@end
