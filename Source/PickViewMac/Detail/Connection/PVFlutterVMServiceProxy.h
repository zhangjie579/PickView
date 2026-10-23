#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Relays one device WebSocket connection to the Flutter tool's localhost-only
/// VM Service.  The random path is checked before any bytes are forwarded.
@interface PVFlutterVMServiceProxy : NSObject

@property(nonatomic, copy, readonly, nullable) NSString *deviceURL;

- (nullable NSString *)startWithHostVMServiceURL:(NSString *)hostVMServiceURL
                                           error:(NSError **)error;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
