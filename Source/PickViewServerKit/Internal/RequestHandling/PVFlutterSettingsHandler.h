//
//  PVFlutterSettingsHandler.h
//  PickViewServer
//
//  Applies Inspector preferences pushed by the PickView Mac client to
//  KKFlutterInspectorKit before a hierarchy is captured.
//

#import <Foundation/Foundation.h>
#import "PVRequestHandlerProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface PVFlutterSettingsHandler : NSObject <PVRequestHandlerProtocol>

@end

NS_ASSUME_NONNULL_END
