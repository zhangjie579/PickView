#import "PVFlutterVMServiceProxy.h"

#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <sys/socket.h>
#import <unistd.h>

static NSString * const PVFlutterVMServiceProxyErrorDomain = @"PVFlutterVMServiceProxy";

@interface PVFlutterVMServiceProxy ()
@property(nonatomic, assign) int listenFD;
@property(nonatomic, assign) BOOL running;
@property(nonatomic, copy) NSString *expectedPath;
@property(nonatomic, copy) NSString *targetPath;
@property(nonatomic, assign) uint16_t targetPort;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy, readwrite) NSString *deviceURL;
@end

@implementation PVFlutterVMServiceProxy

- (instancetype)init {
    if ((self = [super init])) {
        _listenFD = -1;
        _queue = dispatch_queue_create("com.pickview.flutter-vm-service-proxy", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (NSString *)startWithHostVMServiceURL:(NSString *)hostVMServiceURL error:(NSError **)error {
    NSURLComponents *components = [NSURLComponents componentsWithString:hostVMServiceURL];
    NSString *scheme = components.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"http"]) ||
        !components.host.length || components.port.unsignedShortValue == 0) {
        if (error) *error = [NSError errorWithDomain:PVFlutterVMServiceProxyErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid Flutter VM Service URL."}];
        return nil;
    }
    // Android Studio exposes this service only on the host loopback interface.
    if (!([components.host isEqualToString:@"127.0.0.1"] || [components.host isEqualToString:@"localhost"] || [components.host isEqualToString:@"::1"])) {
        if (error) *error = [NSError errorWithDomain:PVFlutterVMServiceProxyErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey: @"Flutter VM Service must be a localhost URL."}];
        return nil;
    }

    [self stop];
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return nil;
    }
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 4) != 0) {
        int socketError = errno;
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:socketError userInfo:nil];
        return nil;
    }
    socklen_t addressLength = sizeof(address);
    getsockname(fd, (struct sockaddr *)&address, &addressLength);
    NSString *lanAddress = [self.class localIPv4Address];
    if (!lanAddress.length) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:PVFlutterVMServiceProxyErrorDomain code:3 userInfo:@{NSLocalizedDescriptionKey: @"No LAN IPv4 address is available for the Flutter relay."}];
        return nil;
    }

    NSString *token = NSUUID.UUID.UUIDString.lowercaseString;
    // KKFIVMServiceClient normalizes every service URI to a WebSocket URI by
    // appending `/ws` when necessary. Include it in the relay URI as well so
    // the client's normalized request still matches the capability path.
    _expectedPath = [NSString stringWithFormat:@"/pickview/%@/ws", token];
    _targetPath = components.percentEncodedPath.length ? components.percentEncodedPath : @"/";
    if (components.percentEncodedQuery.length) _targetPath = [_targetPath stringByAppendingFormat:@"?%@", components.percentEncodedQuery];
    _targetPort = components.port.unsignedShortValue;
    // Only Android Studio's host-forwarded VM service is reachable from this
    // Mac. If the port is iPhone-local (for example an Xcode launch), do not
    // install an override: the existing direct device path must remain intact.
    int probeFD = [self connectToLoopback];
    if (probeFD < 0) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:PVFlutterVMServiceProxyErrorDomain code:4 userInfo:@{NSLocalizedDescriptionKey: @"The reported VM Service is not reachable on this Mac."}];
        return nil;
    }
    close(probeFD);
    _listenFD = fd;
    _running = YES;
    _deviceURL = [NSString stringWithFormat:@"ws://%@:%hu%@", lanAddress, ntohs(address.sin_port), _expectedPath];
    NSLog(@"[PickViewVMProxy] listening %@ -> %@", _deviceURL, hostVMServiceURL);

    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        typeof(self) self = weakSelf;
        while (self && self.running && self.listenFD >= 0) {
            int clientFD = accept(self.listenFD, NULL, NULL);
            if (clientFD < 0) continue;
            int noSigPipe = 1;
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
            dispatch_async(self.queue, ^{ [self handleClientFD:clientFD]; });
        }
    });
    return _deviceURL;
}

- (void)stop {
    _running = NO;
    if (_listenFD >= 0) {
        shutdown(_listenFD, SHUT_RDWR);
        close(_listenFD);
        _listenFD = -1;
    }
    _deviceURL = nil;
}

- (void)handleClientFD:(int)clientFD {
    NSMutableData *request = [NSMutableData data];
    char buffer[4096];
    while (request.length <= 32768) {
        ssize_t count = recv(clientFD, buffer, sizeof(buffer), 0);
        if (count <= 0) { close(clientFD); return; }
        [request appendBytes:buffer length:(NSUInteger)count];
        if ([request rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, request.length)].location != NSNotFound) break;
    }
    NSString *header = [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *lines = [header componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *parts = [lines.firstObject componentsSeparatedByString:@" "];
    if (parts.count < 3 || ![parts[0] isEqualToString:@"GET"] || ![parts[1] isEqualToString:self.expectedPath]) {
        NSLog(@"[PickViewVMProxy] rejected request path=%@ expected=%@", parts.count > 1 ? parts[1] : @"(invalid)", self.expectedPath);
        static const char forbidden[] = "HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n";
        send(clientFD, forbidden, sizeof(forbidden) - 1, 0);
        close(clientFD);
        return;
    }
    NSMutableArray<NSString *> *rewritten = lines.mutableCopy;
    rewritten[0] = [NSString stringWithFormat:@"GET %@ %@", self.targetPath, parts[2]];
    NSData *rewrittenHeader = [[rewritten componentsJoinedByString:@"\r\n"] dataUsingEncoding:NSUTF8StringEncoding];
    int upstreamFD = [self connectToLoopback];
    if (upstreamFD < 0 || ![self writeData:rewrittenHeader toFD:upstreamFD]) {
        NSLog(@"[PickViewVMProxy] upstream connection failed target=127.0.0.1:%hu", self.targetPort);
        if (upstreamFD >= 0) close(upstreamFD);
        close(clientFD);
        return;
    }
    NSLog(@"[PickViewVMProxy] relaying %@ -> %@", self.expectedPath, self.targetPath);
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, self.queue, ^{ [self relayFromFD:clientFD toFD:upstreamFD]; });
    dispatch_group_async(group, self.queue, ^{ [self relayFromFD:upstreamFD toFD:clientFD]; });
    dispatch_group_notify(group, self.queue, ^{
        shutdown(clientFD, SHUT_RDWR); close(clientFD);
        shutdown(upstreamFD, SHUT_RDWR); close(upstreamFD);
    });
}

- (int)connectToLoopback {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int noSigPipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(self.targetPort);
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) { close(fd); return -1; }
    return fd;
}

- (void)relayFromFD:(int)sourceFD toFD:(int)destinationFD {
    char buffer[16384];
    ssize_t count = 0;
    while ((count = recv(sourceFD, buffer, sizeof(buffer), 0)) > 0) {
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written = send(destinationFD, buffer + offset, (size_t)(count - offset), 0);
            if (written <= 0) return;
            offset += written;
        }
    }
}

- (BOOL)writeData:(NSData *)data toFD:(int)fd {
    const char *bytes = data.bytes;
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t written = send(fd, bytes + offset, data.length - offset, 0);
        if (written <= 0) return NO;
        offset += (NSUInteger)written;
    }
    return YES;
}

+ (NSString *)localIPv4Address {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return nil;
    NSString *result = nil;
    for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET || !(item->ifa_flags & IFF_UP) || (item->ifa_flags & IFF_LOOPBACK)) continue;
        char address[INET_ADDRSTRLEN] = {0};
        const struct sockaddr_in *socketAddress = (const struct sockaddr_in *)item->ifa_addr;
        if (inet_ntop(AF_INET, &socketAddress->sin_addr, address, sizeof(address))) {
            NSString *candidate = [NSString stringWithUTF8String:address];
            if ([candidate hasPrefix:@"10."] || [candidate hasPrefix:@"192.168."] || [candidate hasPrefix:@"172."]) { result = candidate; break; }
        }
    }
    freeifaddrs(interfaces);
    return result;
}

@end
