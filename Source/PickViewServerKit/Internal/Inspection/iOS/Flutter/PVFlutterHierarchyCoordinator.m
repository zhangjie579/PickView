//
//  PVFlutterHierarchyCoordinator.m
//  PickViewServer
//

#import "PVFlutterHierarchyCoordinator.h"

#import <KKFlutterInspectorKit/KKFlutterInspector.h>

#import "PVDisplayItem.h"
#import "PVDisplayItemDetail.h"
#import "PVFlutterInspectionModel.h"
#import "PVObject.h"
#import "PVStaticAsyncUpdateTask.h"

/// Whether anything inside this subtree can produce pixels.
///
/// A collapsed row is the *only* row that draws for its whole subtree: while an
/// ancestor stays collapsed every descendant is hidden in the preview. So a
/// collapsed row must fall back to a real subtree screenshot as soon as
/// anything below it paints — including component widgets (ZPButton,
/// BlocBuilder, Builder, ...) that borrow a descendant's RenderObject. Skipping
/// those here is what used to leave a collapsed composite widget blank.
static BOOL PVFlutterSubtreeHasPaintableContent(KKFIInspectorElement *element) {
    if (!element.hasFrame) return NO;
    if (element.captureEligible || element.nativeDecoration != nil) return YES;
    if (element.children.count == 0) return NO;
    for (KKFIInspectorElement *child in element.children) {
        if (PVFlutterSubtreeHasPaintableContent(child)) return YES;
    }
    // Descendants without a resolved frame still paint inside the parent's
    // subtree image, so keep the capture when the parent itself has a frame.
    // This is what lets a layout-only or proxy wrapper show its children.
    return YES;
}

/// Returns the render object identity reported by the Flutter inspector for
/// this element, or nil when the node has no render object at all.
static NSString *PVFlutterRenderObjectIDForElement(
    KKFIInspectorElement *element) {
    NSDictionary *renderObject =
        [element.rawJSON isKindOfClass:NSDictionary.class]
            ? element.rawJSON[@"renderObject"] : nil;
    if (![renderObject isKindOfClass:NSDictionary.class]) return nil;
    NSString *valueID = renderObject[@"valueId"];
    return [valueID isKindOfClass:NSString.class] ? valueID : nil;
}

@interface PVFlutterPageSnapshot : NSObject
@property(nonatomic, weak) UIView *hostView;
@property(nonatomic, weak) FlutterViewController *viewController;
@property(nonatomic, strong) KKFIHierarchySnapshot *snapshot;
@property(nonatomic, copy) NSString *pageIdentifier;
@property(nonatomic, copy) NSArray<PVDisplayItem *> *rootItems;
/// Component widgets such as BlocBuilder or Builder do not own pixels: the
/// Flutter inspector reports a descendant's RenderObject for them, so a
/// screenshot would only duplicate that descendant's content. This table marks
/// such elements so the preview keeps them transparent.
@property(nonatomic, strong) NSMapTable<KKFIInspectorElement *, NSValue *> *proxyElementsByElement;
@end

@implementation PVFlutterPageSnapshot

- (BOOL)isProxyElement:(KKFIInspectorElement *)element {
    return element != nil &&
        [self.proxyElementsByElement objectForKey:element] != nil;
}

@end

/// Whether an expanded node may draw anything in the preview. A Flutter
/// Inspector screenshot always contains every descendant pixel, so an expanded
/// node only draws when those pixels can be attributed to itself:
///  - a leaf has no visible descendants, so the whole image is its own;
///  - a rebuildable decoration reproduces color, border, radius, shadow, and
///    gradient from diagnostics without flattening any child.
/// Everything else stays transparent while expanded. A `selfPaint` node without
/// a rebuildable decoration must not fall back to its subtree image: a
/// page-sized `ColoredBox` would otherwise paint the whole screen again on top
/// of every descendant that already draws itself. Layout-only nodes and
/// `paintEffect` wrappers (ClipRRect, Opacity, Transform, BackdropFilter,
/// FittedBox, ...) are transparent while expanded too; clips, fades, and blurs
/// remain visible through the collapsed group screenshot, where nothing is
/// layered twice.
static BOOL PVFlutterExpandedElementOwnsContent(
    KKFIInspectorElement *element, NSDictionary *decoration) {
    return element.children.count == 0 || decoration != nil;
}

/// Reads the printable value of one diagnostics property.
static NSString *PVFlutterDiagnosticDescription(NSDictionary *property) {
    NSString *description = [property[@"description"] isKindOfClass:NSString.class]
        ? property[@"description"] : nil;
    if (description.length == 0 &&
        [property[@"value"] isKindOfClass:NSString.class]) {
        description = property[@"value"];
    }
    return description;
}

/// Whether a diagnostics property carries a real value. Flutter serialises a
/// property that is not set as the description `null`, and a `DiagnosticsNode`
/// whose value is absent as `NSNull`.
static BOOL PVFlutterDiagnosticPropertyHasValue(NSDictionary *property) {
    if (property == nil || property[@"value"] == NSNull.null) return NO;
    NSString *description = PVFlutterDiagnosticDescription(property);
    return description.length > 0 && ![description isEqualToString:@"null"];
}

/// Whether a diagnostics payload describes a decoration that paints an image,
/// for example `BoxDecoration(image: DecorationImage(...))`.
///
/// The native decoration renderer rebuilds colors, gradients, borders and
/// corner radii, but it can never reproduce a `DecorationImage`. Such a node
/// has to keep using a real subtree capture while it is expanded: a rebuilt
/// decoration paints a flat rect (or nothing at all) exactly where the user
/// expects the image. Only decoration carrying properties are descended into —
/// `DecoratedBox` reports `bg`/`fg`, `Container` reports `bg`, and a
/// RenderObject payload reports `decoration` — so an unrelated nested value
/// named `image` cannot flip this on.
static BOOL PVFlutterPropertiesPaintImage(NSArray *properties) {
    for (id value in properties ?: @[]) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *property = (NSDictionary *)value;
        NSString *name = [property[@"name"] isKindOfClass:NSString.class]
            ? property[@"name"] : @"";
        NSString *description = PVFlutterDiagnosticDescription(property);
        BOOL isDecoration = [name isEqualToString:@"decoration"] ||
            [name isEqualToString:@"bg"] || [name isEqualToString:@"fg"];
        if (([name isEqualToString:@"image"] ||
             [name isEqualToString:@"backgroundImage"]) &&
            PVFlutterDiagnosticPropertyHasValue(property)) {
            return YES;
        }
        if (isDecoration && [description containsString:@"DecorationImage"]) {
            return YES;
        }
        NSArray *children = [property[@"properties"] isKindOfClass:NSArray.class]
            ? property[@"properties"] : nil;
        if (isDecoration && children.count > 0 &&
            PVFlutterPropertiesPaintImage(children)) {
            return YES;
        }
    }
    return NO;
}

/// Returns the `DecorationImage(...)` payload of a diagnostics description,
/// parentheses included. Flutter prints it inline inside the decoration, for
/// example
/// `BoxDecoration(image: DecorationImage(NetworkImage("https://a/b.png", scale: 1.0), BoxFit.cover, Alignment.center, scale 1.0, opacity 1.0, FilterQuality.medium))`.
static NSString *PVFlutterDecorationImagePayload(NSString *description) {
    if (description.length == 0) return nil;
    NSRange start = [description rangeOfString:@"DecorationImage("];
    if (start.location == NSNotFound) return nil;
    NSUInteger index = NSMaxRange(start);
    NSInteger depth = 1;
    BOOL insideLiteral = NO;
    while (index < description.length) {
        unichar character = [description characterAtIndex:index];
        if (insideLiteral) {
            if (character == '\\') index++;
            else if (character == '"') insideLiteral = NO;
        } else if (character == '"') {
            insideLiteral = YES;
        } else if (character == '(') {
            depth++;
        } else if (character == ')') {
            depth--;
            if (depth == 0) break;
        }
        index++;
    }
    if (index >= description.length) return nil;
    return [description substringWithRange:NSMakeRange(start.location,
                                                       index - start.location + 1)];
}

/// Reads the first capture group of a regular expression out of a description.
static NSString *PVFlutterStringForPattern(NSString *description,
                                           NSString *pattern) {
    if (description.length == 0) return nil;
    NSRegularExpression *expression =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                  options:0
                                                    error:nil];
    NSTextCheckingResult *match =
        [expression firstMatchInString:description
                               options:0
                                 range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges < 2) return nil;
    return [description substringWithRange:[match rangeAtIndex:1]];
}

/// Reads the first capture group of a regular expression as a number.
static NSNumber *PVFlutterNumberForPattern(NSString *description,
                                           NSString *pattern) {
    NSString *value = PVFlutterStringForPattern(description, pattern);
    return value.length ? @(value.doubleValue) : nil;
}

/// Reads the first `Provider("value")` pair of a description, for example
/// `NetworkImage("https://a/b.png", scale: 1.0)`. Custom providers such as
/// `CachedNetworkImageProvider("...")` print themselves the same way.
static NSString *PVFlutterQuotedSourceInDescription(NSString *description,
                                                    NSString **provider) {
    NSString *pattern =
        @"([A-Za-z_][A-Za-z0-9_.$]*)\\s*\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\"";
    NSRegularExpression *expression =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                  options:0
                                                    error:nil];
    NSTextCheckingResult *match =
        [expression firstMatchInString:description
                               options:0
                                 range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges < 3) return nil;
    if (provider) {
        *provider = [description substringWithRange:[match rangeAtIndex:1]];
    }
    NSMutableString *value =
        [[description substringWithRange:[match rangeAtIndex:2]] mutableCopy];
    [value replaceOccurrencesOfString:@"\\\""
                           withString:@"\""
                              options:0
                                range:NSMakeRange(0, value.length)];
    [value replaceOccurrencesOfString:@"\\\\"
                           withString:@"\\"
                              options:0
                                range:NSMakeRange(0, value.length)];
    return value.length ? value : nil;
}

/// Reads the `Alignment` of a `DecorationImage` description. Flutter prints
/// either a named constant or the raw offset pair.
static CGPoint PVFlutterAlignmentFromDescription(NSString *description) {
    NSString *named = PVFlutterStringForPattern(description,
                                                @"Alignment\\.([a-zA-Z]+)");
    static NSDictionary<NSString *, NSValue *> *namedAlignments;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        namedAlignments = @{
            @"topLeft" : [NSValue valueWithCGPoint:CGPointMake(-1, -1)],
            @"topCenter" : [NSValue valueWithCGPoint:CGPointMake(0, -1)],
            @"topRight" : [NSValue valueWithCGPoint:CGPointMake(1, -1)],
            @"centerLeft" : [NSValue valueWithCGPoint:CGPointMake(-1, 0)],
            @"center" : [NSValue valueWithCGPoint:CGPointMake(0, 0)],
            @"centerRight" : [NSValue valueWithCGPoint:CGPointMake(1, 0)],
            @"bottomLeft" : [NSValue valueWithCGPoint:CGPointMake(-1, 1)],
            @"bottomCenter" : [NSValue valueWithCGPoint:CGPointMake(0, 1)],
            @"bottomRight" : [NSValue valueWithCGPoint:CGPointMake(1, 1)],
        };
    });
    if (named.length) {
        NSValue *value = namedAlignments[named];
        return value ? value.CGPointValue : CGPointZero;
    }
    NSNumber *x = PVFlutterNumberForPattern(
        description, @"Alignment\\(\\s*(-?[0-9]*\\.?[0-9]+)\\s*,");
    NSNumber *y = PVFlutterNumberForPattern(
        description,
        @"Alignment\\(\\s*-?[0-9]*\\.?[0-9]+\\s*,\\s*(-?[0-9]*\\.?[0-9]+)\\s*\\)");
    return CGPointMake(x ? x.doubleValue : 0, y ? y.doubleValue : 0);
}

/// Describes everything needed to repaint a `DecorationImage` natively.
///
/// Returns nil when the description carries no resolvable image source, which
/// is the case for a `MemoryImage`: it prints only an identity hash.
static NSDictionary *PVFlutterDecorationImageInfoFromDescription(
    NSString *description) {
    NSString *payload = PVFlutterDecorationImagePayload(description);
    if (payload.length == 0) return nil;
    NSString *provider = nil;
    NSString *source = PVFlutterQuotedSourceInDescription(payload, &provider);
    if (source.length == 0) {
        // `ExactAssetImage(name: "assets/x.png", scale: 1.0, bundle: ...)`.
        source = PVFlutterStringForPattern(
            payload, @"name:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
    }
    if (source.length == 0) return nil;
    CGPoint alignment = PVFlutterAlignmentFromDescription(payload);
    // The provider prints `scale: 1.0`, the `DecorationImage` prints
    // `scale 1.0`; both divide the decoded pixel size.
    NSNumber *providerScale =
        PVFlutterNumberForPattern(payload, @"\\bscale\\s*:\\s*([0-9]*\\.?[0-9]+)");
    NSNumber *imageScale =
        PVFlutterNumberForPattern(payload, @"\\bscale\\s+([0-9]*\\.?[0-9]+)");
    NSNumber *opacity =
        PVFlutterNumberForPattern(payload, @"\\bopacity\\s+([0-9]*\\.?[0-9]+)");
    NSString *fit = PVFlutterStringForPattern(payload, @"BoxFit\\.([a-zA-Z]+)");
    NSString *lowercased = source.lowercaseString;
    BOOL remote = [lowercased hasPrefix:@"http://"] ||
        [lowercased hasPrefix:@"https://"];
    CGFloat scale = (providerScale ? providerScale.doubleValue : 1.0) *
                    (imageScale ? imageScale.doubleValue : 1.0);
    if (!(scale > 0)) scale = 1;
    CGFloat alpha = opacity ? opacity.doubleValue : 1.0;
    return @{
        @"source" : source,
        @"remote" : @(remote),
        @"provider" : provider ?: @"",
        @"fit" : fit ?: @"scaleDown",
        @"alignmentX" : @(alignment.x),
        @"alignmentY" : @(alignment.y),
        @"scale" : @(scale),
        @"opacity" : @(MIN(MAX(alpha, 0), 1)),
    };
}

/// Finds the diagnostics description that carries a `DecorationImage`.
static NSString *PVFlutterDecorationImageDescriptionInProperties(
    NSArray *properties) {
    for (id value in properties ?: @[]) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *property = (NSDictionary *)value;
        NSString *description = PVFlutterDiagnosticDescription(property);
        if ([description containsString:@"DecorationImage("]) return description;
        NSArray *children = [property[@"properties"] isKindOfClass:NSArray.class]
            ? property[@"properties"] : nil;
        NSString *nested =
            PVFlutterDecorationImageDescriptionInProperties(children);
        if (nested) return nested;
    }
    return nil;
}

/// Mirrors Flutter's `applyBoxFit`: returns the source sub-rect size and the
/// destination size a `BoxFit` produces for one image inside one box.
static void PVFlutterApplyBoxFit(NSString *fit,
                                 CGSize inputSize,
                                 CGSize outputSize,
                                 CGSize *sourceSize,
                                 CGSize *destinationSize) {
    *sourceSize = CGSizeZero;
    *destinationSize = CGSizeZero;
    if (inputSize.width <= 0 || inputSize.height <= 0 ||
        outputSize.width <= 0 || outputSize.height <= 0) {
        return;
    }
    BOOL wider = outputSize.width / outputSize.height >
                 inputSize.width / inputSize.height;
    CGSize source = inputSize;
    CGSize destination = outputSize;
    if ([fit isEqualToString:@"fill"]) {
        source = inputSize;
        destination = outputSize;
    } else if ([fit isEqualToString:@"contain"]) {
        source = inputSize;
        destination = wider
            ? CGSizeMake(inputSize.width * outputSize.height / inputSize.height,
                         outputSize.height)
            : CGSizeMake(outputSize.width,
                         inputSize.height * outputSize.width / inputSize.width);
    } else if ([fit isEqualToString:@"cover"]) {
        source = wider
            ? CGSizeMake(inputSize.width,
                         inputSize.width * outputSize.height / outputSize.width)
            : CGSizeMake(inputSize.height * outputSize.width / outputSize.height,
                         inputSize.height);
        destination = outputSize;
    } else if ([fit isEqualToString:@"fitWidth"]) {
        if (wider) {
            source = CGSizeMake(
                inputSize.width,
                inputSize.width * outputSize.height / outputSize.width);
            destination = outputSize;
        } else {
            source = inputSize;
            destination = CGSizeMake(
                outputSize.width,
                inputSize.height * outputSize.width / inputSize.width);
        }
    } else if ([fit isEqualToString:@"fitHeight"]) {
        if (wider) {
            source = inputSize;
            destination = CGSizeMake(
                inputSize.width * outputSize.height / inputSize.height,
                outputSize.height);
        } else {
            source = CGSizeMake(
                inputSize.height * outputSize.width / outputSize.height,
                inputSize.height);
            destination = outputSize;
        }
    } else if ([fit isEqualToString:@"none"]) {
        source = CGSizeMake(MIN(inputSize.width, outputSize.width),
                            MIN(inputSize.height, outputSize.height));
        destination = source;
    } else {  // scaleDown, and the default when no `BoxFit` is printed
        source = inputSize;
        destination = inputSize;
        CGFloat aspectRatio = inputSize.width / inputSize.height;
        if (destination.height > outputSize.height) {
            destination = CGSizeMake(outputSize.height * aspectRatio,
                                     outputSize.height);
        }
        if (destination.width > outputSize.width) {
            destination = CGSizeMake(outputSize.width,
                                     outputSize.width / aspectRatio);
        }
    }
    *sourceSize = source;
    *destinationSize = destination;
}

/// Mirrors Flutter's `Alignment.inscribe`: places `size` inside `rect`.
static CGRect PVFlutterInscribe(CGSize size, CGRect rect, CGPoint alignment) {
    CGFloat halfWidthDelta = (rect.size.width - size.width) / 2.0;
    CGFloat halfHeightDelta = (rect.size.height - size.height) / 2.0;
    return CGRectMake(rect.origin.x + halfWidthDelta +
                          alignment.x * halfWidthDelta,
                      rect.origin.y + halfHeightDelta +
                          alignment.y * halfHeightDelta,
                      size.width, size.height);
}

/// Reads one component out of a Flutter diagnostics description, for example
/// `red:` out of `Color(alpha: 1.0000, red: 1.0000, ...)`.
static NSNumber *PVFlutterColorComponentFromDescription(NSString *description,
                                                        NSString *component) {
    if (description.length == 0) return nil;
    NSString *pattern =
        [NSString stringWithFormat:@"\\b%@\\s*:\\s*([0-9]*\\.?[0-9]+)", component];
    NSRegularExpression *expression =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                  options:0
                                                    error:nil];
    NSTextCheckingResult *match =
        [expression firstMatchInString:description
                               options:0
                                 range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges < 2) return nil;
    NSString *value = [description substringWithRange:[match rangeAtIndex:1]];
    return @(value.doubleValue * 255.0);
}

/// Parses a Flutter diagnostics color description into the dictionary shape
/// used by the native decoration renderer. Flutter prints either the component
/// form `Color(alpha: 1.0000, red: 1.0000, green: 1.0000, blue: 1.0000, ...)`
/// or the legacy hex form `Color(0xfff5f5f5)`.
static NSDictionary *PVFlutterColorDictionaryFromDescription(
    NSString *description) {
    if (![description isKindOfClass:NSString.class]) return nil;
    NSNumber *alpha = PVFlutterColorComponentFromDescription(description, @"alpha");
    NSNumber *red = PVFlutterColorComponentFromDescription(description, @"red");
    NSNumber *green = PVFlutterColorComponentFromDescription(description, @"green");
    NSNumber *blue = PVFlutterColorComponentFromDescription(description, @"blue");
    if (alpha && red && green && blue) {
        return @{
            @"red" : red, @"green" : green, @"blue" : blue, @"alpha" : alpha,
        };
    }
    static NSRegularExpression *hexExpression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hexExpression = [NSRegularExpression
            regularExpressionWithPattern:@"0x([0-9a-fA-F]{6,8})"
                                 options:0
                                   error:nil];
    });
    NSTextCheckingResult *match =
        [hexExpression firstMatchInString:description
                                  options:0
                                    range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges < 2) return nil;
    NSString *hex = [description substringWithRange:[match rangeAtIndex:1]];
    if (hex.length != 6 && hex.length != 8) return nil;
    unsigned long long value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    if (![scanner scanHexLongLong:&value]) return nil;
    CGFloat parsedAlpha = 255;
    if (hex.length == 8) {
        parsedAlpha = (value >> 24) & 0xFF;
    }
    return @{
        @"red" : @((value >> 16) & 0xFF),
        @"green" : @((value >> 8) & 0xFF),
        @"blue" : @(value & 0xFF),
        @"alpha" : @(parsedAlpha),
    };
}

@interface PVFlutterNodeRecord : NSObject
@property(nonatomic, weak) PVFlutterPageSnapshot *page;
@property(nonatomic, strong) KKFIInspectorElement *element;
@property(nonatomic, copy) NSString *displayItemID;
@property(nonatomic, strong) PVFlutterNodeDetail *detail;
/// Decoration rebuilt from diagnostics that the tree builder could not parse,
/// for example the plain `color` of a `_RenderColoredBox`. It lets a node such
/// as a full-page background draw only its own color instead of flattening the
/// entire screen into its preview image.
@property(nonatomic, strong, nullable) NSDictionary *resolvedDecoration;
/// The node paints a decoration image (`DecorationImage`), which no native
/// rebuild can reproduce. Such a node keeps using the real subtree capture
/// while it is expanded instead of falling back to a flat rebuilt decoration.
@property(nonatomic) BOOL paintsDecorationImage;
/// The diagnostics description carrying the `DecorationImage(...)`. It holds
/// the image source, `BoxFit`, alignment, scale and opacity, which together
/// are enough to repaint the decoration's own image natively.
@property(nonatomic, copy, nullable) NSString *decorationImageDescription;
@end

@implementation PVFlutterNodeRecord
@end

@interface PVFlutterHierarchyCoordinator ()
@property(nonatomic, strong) KKFlutterInspector *inspector;
@property(nonatomic, strong) NSHashTable<UIView *> *flutterHostViews;
@property(nonatomic, strong) NSMapTable<UIView *, PVFlutterPageSnapshot *> *pagesByHostView;
@property(nonatomic, strong) NSMapTable<CALayer *, PVFlutterPageSnapshot *> *pagesByHostLayer;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, PVFlutterNodeRecord *> *recordsByOID;
@property(nonatomic, strong) NSMutableDictionary<NSString *, PVFlutterNodeRecord *> *recordsByDisplayItemID;
@property(nonatomic) NSUInteger preparationGeneration;
@property(nonatomic, getter=isPreparing) BOOL preparing;
@property(nonatomic, strong) NSMutableArray<dispatch_block_t> *preparationWaiters;
@end

@implementation PVFlutterHierarchyCoordinator

- (instancetype)init {
    self = [super init];
    if (self) {
        _inspector = [KKFlutterInspector new];
        _flutterHostViews = [NSHashTable weakObjectsHashTable];
        _pagesByHostView = [NSMapTable weakToStrongObjectsMapTable];
        _pagesByHostLayer = [NSMapTable weakToStrongObjectsMapTable];
        _recordsByOID = [NSMutableDictionary dictionary];
        _recordsByDisplayItemID = [NSMutableDictionary dictionary];
        _preparationWaiters = [NSMutableArray array];
    }
    return self;
}

- (void)prepareWindow:(UIWindow *)window completion:(PVFlutterHierarchyPreparationCompletion)completion {
    dispatch_block_t work = ^{
        NSUInteger generation = ++self.preparationGeneration;
        self.preparing = YES;
        [self.flutterHostViews removeAllObjects];
        [self.pagesByHostView removeAllObjects];
        [self.pagesByHostLayer removeAllObjects];
        [self.recordsByOID removeAllObjects];
        [self.recordsByDisplayItemID removeAllObjects];

        NSArray<FlutterViewController *> *viewControllers =
            [self flutterViewControllersInWindow:window];
        for (FlutterViewController *viewController in viewControllers) {
            UIView *hostView = ((UIViewController *)viewController).viewIfLoaded;
            if (hostView != nil) [self.flutterHostViews addObject:hostView];
        }
        if (viewControllers.count == 0) {
            [self finishPreparationGeneration:generation
                                         error:nil
                                    completion:completion];
            return;
        }

        [self.inspector warmUpWindow:window];
        dispatch_group_t group = dispatch_group_create();
        __block NSError *firstError = nil;
        for (FlutterViewController *viewController in viewControllers) {
            UIView *hostView = ((UIViewController *)viewController).viewIfLoaded;
            CGSize rootSize = hostView.bounds.size;
            dispatch_group_enter(group);
            [self.inspector fetchHierarchyForViewController:viewController
                                           fallbackRootSize:rootSize
                                                 completion:^(KKFIHierarchySnapshot *snapshot,
                                                              NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIView *currentHostView =
                        ((UIViewController *)viewController).viewIfLoaded;
                    if (self.preparationGeneration == generation &&
                        snapshot != nil && currentHostView.window == window) {
                        [self installSnapshot:snapshot
                                    hostView:currentHostView
                              viewController:viewController];
                    } else if (self.preparationGeneration == generation &&
                               error != nil && firstError == nil) {
                        firstError = error;
                    }
                    dispatch_group_leave(group);
                });
            }];
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            [self finishPreparationGeneration:generation
                                         error:firstError
                                    completion:completion];
        });
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

- (void)finishPreparationGeneration:(NSUInteger)generation
                                error:(NSError *)error
                           completion:(PVFlutterHierarchyPreparationCompletion)completion {
    if (generation != self.preparationGeneration) {
        if (completion) completion(nil);
        return;
    }

    self.preparing = NO;
    if (completion) completion(error);
    NSArray<dispatch_block_t> *waiters = self.preparationWaiters.copy;
    [self.preparationWaiters removeAllObjects];
    for (dispatch_block_t waiter in waiters) waiter();
}

- (void)performAfterPendingPreparation:(dispatch_block_t)block {
    if (block == nil) return;
    dispatch_block_t work = ^{
        if (self.isPreparing) {
            [self.preparationWaiters addObject:[block copy]];
        } else {
            block();
        }
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

- (NSArray<FlutterViewController *> *)flutterViewControllersInWindow:(UIWindow *)window {
    UIViewController *rootViewController = window.rootViewController;
    if (rootViewController == nil) return @[];

    NSMutableArray<FlutterViewController *> *result = [NSMutableArray array];
    NSHashTable<UIViewController *> *seenControllers =
        [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    [self collectFlutterViewControllersFrom:rootViewController
                                     window:window
                                     result:result
                            seenControllers:seenControllers];
    return result.copy;
}

- (void)collectFlutterViewControllersFrom:(UIViewController *)viewController
                                    window:(UIWindow *)window
                                    result:(NSMutableArray<FlutterViewController *> *)result
                           seenControllers:(NSHashTable<UIViewController *> *)seenControllers {
    if (viewController == nil || [seenControllers containsObject:viewController]) return;
    [seenControllers addObject:viewController];

    Class flutterClass = NSClassFromString(@"FlutterViewController");
    UIView *hostView = viewController.viewIfLoaded;
    if (flutterClass != Nil && [viewController isKindOfClass:flutterClass] &&
        hostView.window == window && !hostView.hidden && hostView.alpha > 0.01 &&
        !CGRectIsEmpty(hostView.bounds)) {
        [result addObject:(FlutterViewController *)viewController];
    }

    if (viewController.presentedViewController != nil) {
        [self collectFlutterViewControllersFrom:viewController.presentedViewController
                                         window:window
                                         result:result
                                seenControllers:seenControllers];
    }
    for (UIViewController *child in viewController.childViewControllers) {
        [self collectFlutterViewControllersFrom:child
                                         window:window
                                         result:result
                                seenControllers:seenControllers];
    }
}

- (void)installSnapshot:(KKFIHierarchySnapshot *)snapshot
                hostView:(UIView *)hostView
          viewController:(FlutterViewController *)viewController {
    PVFlutterPageSnapshot *page = [PVFlutterPageSnapshot new];
    page.hostView = hostView;
    page.viewController = viewController;
    page.snapshot = snapshot;
    page.pageIdentifier = [NSString stringWithFormat:@"%@:%p",
        NSStringFromClass(((UIViewController *)viewController).class),
        viewController];
    page.proxyElementsByElement = [NSMapTable weakToStrongObjectsMapTable];
    if (snapshot.rootElement != nil) {
        NSMutableSet<NSString *> *descendantRenderObjectIDs = [NSMutableSet set];
        [self detectProxyElements:snapshot.rootElement
                intoProxyElements:page.proxyElementsByElement
      descendantRenderObjectIDs:descendantRenderObjectIDs];
    }
    page.rootItems = snapshot.rootElement == nil
        ? @[]
        : @[[self displayItemForElement:snapshot.rootElement page:page]];
    [self.pagesByHostView setObject:page forKey:hostView];
    [self.pagesByHostLayer setObject:page forKey:hostView.layer];
    NSLog(@"PV_FLUTTER_HIERARCHY_PREPARED hostView=%@ snapshot=%@ rootItems=%@",
          hostView, snapshot.snapshotID, @(page.rootItems.count));
}

// Marks every element whose render object actually belongs to one of its
// descendants. Component widgets (BlocBuilder, Builder, Consumer, Container,
// ...) own no pixels; `Element.renderObject` in Flutter walks down to the
// first descendant RenderObject, so their reported render object matches the
// descendant's. Without this check the tree builder classifies them as
// self-painting and the preview ends up duplicating the descendant's pixels.
- (void)detectProxyElements:(KKFIInspectorElement *)element
          intoProxyElements:(NSMapTable<KKFIInspectorElement *, NSValue *> *)proxyElements
  descendantRenderObjectIDs:(NSMutableSet<NSString *> *)descendantRenderObjectIDs {
    for (KKFIInspectorElement *child in element.children) {
        NSMutableSet<NSString *> *childRenderObjectIDs = [NSMutableSet set];
        [self detectProxyElements:child
                intoProxyElements:proxyElements
      descendantRenderObjectIDs:childRenderObjectIDs];
        [descendantRenderObjectIDs unionSet:childRenderObjectIDs];
    }
    NSString *renderObjectID = PVFlutterRenderObjectIDForElement(element);
    if (renderObjectID.length == 0) return;
    if ([descendantRenderObjectIDs containsObject:renderObjectID]) {
        [proxyElements setObject:@YES forKey:element];
    } else {
        [descendantRenderObjectIDs addObject:renderObjectID];
    }
}

- (PVDisplayItem *)displayItemForElement:(KKFIInspectorElement *)element
                                     page:(PVFlutterPageSnapshot *)page {
    PVFlutterNodeRecord *record = [PVFlutterNodeRecord new];
    record.page = page;
    record.element = element;
    record.displayItemID = [NSString stringWithFormat:@"flutter:%@:%@",
                            page.pageIdentifier, element.reference.objectID];
    record.detail = [self detailForElement:element page:page];
    unsigned long oid = (unsigned long)(uintptr_t)record;
    self.recordsByOID[@(oid)] = record;
    self.recordsByDisplayItemID[record.displayItemID] = record;

    PVObject *object = [PVObject new];
    object.oid = oid;
    object.memoryAddress = [NSString stringWithFormat:@"flutter://%@/%@",
                            page.snapshot.isolateID, element.reference.objectID];
    object.classChainList = @[
        element.widgetType.length ? element.widgetType : @"FlutterWidget",
        element.renderObjectType.length ? element.renderObjectType : @"RenderObject",
        @"FlutterRenderObject"
    ];

    PVDisplayItem *item = [PVDisplayItem new];
    item.objectID = record.displayItemID;
    item.displayName = element.widgetType;
    item.viewClassName = element.widgetType;
    item.layerClassName = element.renderObjectType;
    item.layerObject = object;
    item.contentKind = PVDisplayItemContentKindFlutter;
    item.flutterLoadState = PVFlutterLoadStateLoaded;
    item.flutterReference = record.detail.reference;
    item.flutterDetail = record.detail;
    item.frame = element.frame;
    item.bounds = (CGRect){CGPointZero, element.frame.size};
    item.alpha = 1;
    item.noPreview = !element.hasFrame;
    // A proxy wrapper owns no pixels of its own, but while it is collapsed it
    // is still the only row drawn for its subtree, so it needs the subtree
    // image. The proxy rule only suppresses its *own* layer, which is applied
    // in captureForTask: when the item is expanded.
    item.shouldCaptureImage = element.hasFrame &&
        PVFlutterSubtreeHasPaintableContent(element);
    item.attributesGroupList = @[];
    item.customAttrGroupList = @[];

    NSDictionary *color = [element.nativeDecoration[@"backgroundColor"] isKindOfClass:NSDictionary.class]
        ? element.nativeDecoration[@"backgroundColor"] : nil;
    if (color) {
        item.backgroundColor = [self colorFromDictionary:color];
        item.backgroundColorText = [self colorDescription:color];
    }

    NSMutableArray<PVDisplayItem *> *children = [NSMutableArray array];
    for (KKFIInspectorElement *child in element.children) {
        [children addObject:[self displayItemForElement:child page:page]];
    }
    item.subitems = children.copy;
    item.children = children.copy;
    return item;
}

- (PVFlutterNodeDetail *)detailForElement:(KKFIInspectorElement *)element
                                      page:(PVFlutterPageSnapshot *)page {
    PVFlutterNodeReference *reference = [PVFlutterNodeReference new];
    reference.recordIdentifier = page.pageIdentifier;
    reference.engineIdentifier = @"KKFlutterInspectorKit";
    reference.isolateID = element.reference.isolateID;
    reference.objectGroup = element.reference.objectGroup;
    reference.objectID = element.reference.objectID;

    PVFlutterNodeDetail *detail = [PVFlutterNodeDetail new];
    detail.reference = reference;
    detail.widgetType = element.widgetType;
    detail.elementType = element.elementDescription.length
        ? element.elementDescription : element.widgetType;
    detail.renderObjectType = element.renderObjectType;
    detail.capabilities = element.capabilities.copy;
    // `element.rawJSON` is the raw layout node, whose `children` array still
    // carries the whole subtree nested. Pretty-printing that per node makes the
    // archived tree grow as O(nodes × depth); a few thousand nodes are enough
    // to push a details response past the 4 GiB frame limit and abort the host
    // app inside PeerTalk. Collapse descendants to an id/type summary first.
    detail.rawJSON = [self prettyJSONStringForObject:[self collapsedLayoutJSON:element.rawJSON] ?: @{}];

    PVFlutterDetailSection *geometry = [PVFlutterDetailSection new];
    geometry.identifier = @"geometry";
    geometry.title = @"Geometry";
    geometry.fields = @[
        [self boolField:@"frameAvailable" title:@"Frame available"
                  value:element.hasFrame],
        [self rectField:@"frame" title:@"Frame in parent" rect:element.frame],
        [self sizeField:@"size" title:@"Size" size:element.frame.size]
    ];

    NSMutableArray<PVFlutterDetailField *> *renderFields = [NSMutableArray arrayWithArray:@[
        [self textField:@"kind" title:@"Kind" value:element.nodeKind],
        [self textField:@"paintRole" title:@"Paint role" value:element.paintRole],
        [self textField:@"renderStrategy" title:@"Render strategy" value:element.renderStrategy],
        [self boolField:@"captureEligible" title:@"Screenshot eligible" value:element.captureEligible]
    ]];
    if (element.textPreview.length) {
        [renderFields addObject:[self textField:@"text" title:@"Text" value:element.textPreview]];
    }
    PVFlutterDetailSection *rendering = [PVFlutterDetailSection new];
    rendering.identifier = @"rendering";
    rendering.title = @"Rendering";
    rendering.fields = renderFields.copy;

    NSMutableArray<PVFlutterDetailSection *> *sections =
        [NSMutableArray arrayWithObjects:geometry, rendering, nil];
    [self appendJSONSection:@"decoration" title:@"Decoration"
                     values:element.nativeDecoration ? @[element.nativeDecoration] : @[] to:sections];
    [self appendJSONSection:@"layoutModifiers" title:@"Layout modifiers"
                     values:element.layoutModifiers to:sections];
    [self appendJSONSection:@"interactions" title:@"Interactions"
                     values:element.interactions to:sections];
    [self appendJSONSection:@"semantics" title:@"Semantics"
                     values:element.semantics to:sections];
    detail.sections = sections.copy;

    NSMutableArray<PVFlutterLayoutGroup *> *layoutGroups = [NSMutableArray array];
    for (NSDictionary *relation in element.childrenLayouts) {
        PVFlutterLayoutGroup *group = [PVFlutterLayoutGroup new];
        group.objectID = [relation[@"objectId"] isKindOfClass:NSString.class]
            ? relation[@"objectId"] : @"";
        group.widgetType = [relation[@"type"] isKindOfClass:NSString.class]
            ? relation[@"type"] : @"Unknown";
        group.renderObjectType = [relation[@"renderObjectType"] isKindOfClass:NSString.class]
            ? relation[@"renderObjectType"] : @"Unknown";
        NSMutableArray<NSString *> *managedIDs = [NSMutableArray array];
        for (NSDictionary *managed in [relation[@"managedChildren"] isKindOfClass:NSArray.class]
                                      ? relation[@"managedChildren"] : @[]) {
            NSString *managedID = [managed[@"objectId"] isKindOfClass:NSString.class]
                ? managed[@"objectId"] : nil;
            if (managedID.length) [managedIDs addObject:managedID];
        }
        group.managedNodeIDs = managedIDs.copy;
        group.fields = @[[self jsonField:@"layout" title:@"Layout data" value:relation]];
        group.rawJSON = [self prettyJSONStringForObject:relation];
        [layoutGroups addObject:group];
    }
    detail.layoutGroups = layoutGroups.copy;
    return detail;
}

/// Returns a copy of the layout node whose `children` no longer embed their own
/// subtrees. Every element keeps a reference to the raw layout node, so without
/// this the same descendant JSON is serialised once per ancestor.
- (NSDictionary *)collapsedLayoutJSON:(NSDictionary *)layoutJSON {
    if (![layoutJSON isKindOfClass:NSDictionary.class]) return nil;
    NSArray *children = [layoutJSON[@"children"] isKindOfClass:NSArray.class]
        ? layoutJSON[@"children"] : nil;
    if (children.count == 0) return layoutJSON;
    NSMutableArray<NSDictionary *> *summary =
        [NSMutableArray arrayWithCapacity:children.count];
    for (id value in children) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *child = (NSDictionary *)value;
        NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithCapacity:2];
        NSString *nodeID = [child[@"valueId"] isKindOfClass:NSString.class]
            ? child[@"valueId"]
            : ([child[@"objectId"] isKindOfClass:NSString.class] ? child[@"objectId"] : nil);
        if (nodeID.length) entry[@"objectId"] = nodeID;
        for (NSString *key in @[@"widgetRuntimeType", @"runtimeType", @"type"]) {
            NSString *type = [child[key] isKindOfClass:NSString.class] ? child[key] : nil;
            if (type.length) {
                entry[@"type"] = type;
                break;
            }
        }
        [summary addObject:entry.copy];
    }
    NSMutableDictionary *collapsed = [layoutJSON mutableCopy];
    collapsed[@"children"] = summary.copy;
    return collapsed.copy;
}

// The tree builder only parses a decoration when the diagnostics were already
// present, which misses plain cases such as `_RenderColoredBox.color`. The
// properties fetched during the detail pass carry that information, so rebuild
// a conservative decoration here: a solid background and an optional uniform
// corner radius. Anything richer is left to the collapsed screenshot.
- (NSDictionary *)decorationFromDiagnosticProperties:(NSArray *)properties {
    NSDictionary *color = [self diagnosticColorInProperties:properties];
    if (color == nil) return nil;
    NSMutableDictionary *decoration = [@{
        @"kind" : @"solidColor",
        @"shape" : @"rectangle",
        @"backgroundColor" : color,
    } mutableCopy];
    NSNumber *radius = [self uniformCornerRadiusInProperties:properties];
    if (radius != nil) {
        decoration[@"cornerRadius"] = radius;
    }
    return decoration.copy;
}

- (NSDictionary *)diagnosticColorInProperties:(NSArray *)properties {
    for (id value in properties ?: @[]) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *property = value;
        NSString *name = [property[@"name"] isKindOfClass:NSString.class]
            ? property[@"name"] : @"";
        static NSSet<NSString *> *colorNames;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            colorNames = [NSSet setWithArray:@[
                @"color", @"bg", @"backgroundColor", @"fillColor", @"decoration",
            ]];
        });
        if ([colorNames containsObject:name]) {
            NSDictionary *color = PVFlutterColorDictionaryFromDescription(
                [property[@"description"] isKindOfClass:NSString.class]
                    ? property[@"description"] : nil);
            if (color) return color;
        }
        NSArray *children = [property[@"properties"] isKindOfClass:NSArray.class]
            ? property[@"properties"] : nil;
        NSDictionary *nested = [self diagnosticColorInProperties:children];
        if (nested) return nested;
    }
    return nil;
}

- (NSNumber *)uniformCornerRadiusInProperties:(NSArray *)properties {
    for (id value in properties ?: @[]) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *property = value;
        NSString *name = [property[@"name"] isKindOfClass:NSString.class]
            ? property[@"name"] : @"";
        NSString *description =
            [property[@"description"] isKindOfClass:NSString.class]
                ? property[@"description"] : nil;
        if ([name isEqualToString:@"borderRadius"] && description.length) {
            NSRegularExpression *expression = [NSRegularExpression
                regularExpressionWithPattern:@"([0-9]+\\.?[0-9]*)"
                                     options:0
                                       error:nil];
            NSTextCheckingResult *match =
                [expression firstMatchInString:description
                                       options:0
                                         range:NSMakeRange(0, description.length)];
            if (match.numberOfRanges >= 2) {
                NSString *number =
                    [description substringWithRange:[match rangeAtIndex:1]];
                return @(number.doubleValue);
            }
        }
        NSArray *children = [property[@"properties"] isKindOfClass:NSArray.class]
            ? property[@"properties"] : nil;
        NSNumber *nested = [self uniformCornerRadiusInProperties:children];
        if (nested) return nested;
    }
    return nil;
}

- (void)appendJSONSection:(NSString *)identifier
                    title:(NSString *)title
                   values:(NSArray *)values
                       to:(NSMutableArray<PVFlutterDetailSection *> *)sections {
    if (values.count == 0) return;
    PVFlutterDetailSection *section = [PVFlutterDetailSection new];
    section.identifier = identifier;
    section.title = title;
    NSMutableArray *fields = [NSMutableArray arrayWithCapacity:values.count];
    [values enumerateObjectsUsingBlock:^(id value, NSUInteger index, BOOL *stop) {
        [fields addObject:[self jsonField:[NSString stringWithFormat:@"%@.%@", identifier, @(index)]
                                    title:[NSString stringWithFormat:@"%@ %@", title, @(index + 1)]
                                    value:value]];
    }];
    section.fields = fields.copy;
    [sections addObject:section];
}

- (NSArray<PVDisplayItem *> *)virtualItemsForHostView:(UIView *)hostView {
    return [self.pagesByHostView objectForKey:hostView].rootItems ?: @[];
}

- (BOOL)isFlutterHostView:(UIView *)view {
    return view != nil && [self.flutterHostViews containsObject:view];
}

- (BOOL)isFlutterHostLayer:(CALayer *)layer {
    id delegate = layer.delegate;
    return [delegate isKindOfClass:UIView.class] &&
        [self isFlutterHostView:(UIView *)delegate];
}

- (NSArray<PVDisplayItem *> *)virtualItemsForHostLayer:(CALayer *)hostLayer {
    return [self.pagesByHostLayer objectForKey:hostLayer].rootItems ?: @[];
}

- (BOOL)ownsObjectOID:(unsigned long)oid {
    return self.recordsByOID[@(oid)] != nil;
}

- (BOOL)ownsDisplayItemID:(NSString *)displayItemID {
    return self.recordsByDisplayItemID[displayItemID] != nil;
}

- (void)detailsForTaskPackages:(NSArray<PVStaticAsyncUpdateTasksPackage *> *)packages
               lowImageQuality:(BOOL)lowImageQuality
                    completion:(PVFlutterHierarchyDetailsCompletion)completion {
    NSMutableArray<PVStaticAsyncUpdateTask *> *tasks = [NSMutableArray array];
    for (PVStaticAsyncUpdateTasksPackage *package in packages) {
        for (PVStaticAsyncUpdateTask *task in package.tasks) {
            if ([self ownsObjectOID:task.oid]) [tasks addObject:task];
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self processTaskAtIndex:0 tasks:tasks lowImageQuality:lowImageQuality
                         results:[NSMutableArray array] completion:completion];
    });
}

- (void)processTaskAtIndex:(NSUInteger)index
                      tasks:(NSArray<PVStaticAsyncUpdateTask *> *)tasks
            lowImageQuality:(BOOL)lowImageQuality
                    results:(NSMutableArray<PVDisplayItemDetail *> *)results
                 completion:(PVFlutterHierarchyDetailsCompletion)completion {
    if (index >= tasks.count) {
        completion(results.copy);
        return;
    }
    PVStaticAsyncUpdateTask *task = tasks[index];
    PVFlutterNodeRecord *record = self.recordsByOID[@(task.oid)];
    if (!record) {
        [self processTaskAtIndex:index + 1 tasks:tasks lowImageQuality:lowImageQuality
                         results:results completion:completion];
        return;
    }

    PVDisplayItemDetail *detail = [self baseDetailForRecord:record oid:task.oid];
    void (^capture)(void) = ^{
        dispatch_block_t work = ^{
            [self captureForTask:task record:record detail:detail
                 lowImageQuality:lowImageQuality completion:^{
                [results addObject:detail];
                [self processTaskAtIndex:index + 1 tasks:tasks
                         lowImageQuality:lowImageQuality
                                  results:results
                               completion:completion];
            }];
        };
        if (NSThread.isMainThread) work();
        else dispatch_async(dispatch_get_main_queue(), work);
    };
    // Automatic is the default request mode. Flutter diagnostics are not part
    // of the native attribute groups, so the coordinator must resolve it as
    // "fetch" unless the client explicitly opted out.
    if (task.attrRequest == PVDetailUpdateTaskAttrRequest_NotNeed) {
        capture();
        return;
    }
    [self.inspector fetchPropertiesForElement:record.element.reference
                                   completion:^(NSArray<NSDictionary *> *properties,
                                                NSError *error) {
        if (!error && properties) {
            detail.flutterDetail = [self detailByAddingDiagnostics:properties
                                                           toDetail:detail.flutterDetail];
            record.detail = detail.flutterDetail;
            // The Inspector returns either a property array or a payload
            // dictionary wrapping one, exactly like -detailByAddingDiagnostics:.
            NSArray *diagnosticProperties = @[];
            if ([properties isKindOfClass:NSArray.class]) {
                diagnosticProperties = (NSArray *)properties;
            } else if ([properties isKindOfClass:NSDictionary.class]) {
                NSDictionary *payload = (NSDictionary *)properties;
                NSArray *wrapped = payload[@"properties"];
                if ([wrapped isKindOfClass:NSArray.class]) {
                    diagnosticProperties = wrapped;
                }
            }
            // A decoration image can never be rebuilt natively, so it has to be
            // detected even when the pass below already resolved a color from
            // the same payload: `BoxDecoration(color: ..., image: ...)` yields
            // both, and the color alone would still hide the image.
            if (!record.paintsDecorationImage &&
                PVFlutterPropertiesPaintImage(diagnosticProperties)) {
                record.paintsDecorationImage = YES;
                record.resolvedDecoration = nil;
            }
            if (record.decorationImageDescription == nil) {
                record.decorationImageDescription =
                    PVFlutterDecorationImageDescriptionInProperties(
                        diagnosticProperties);
            }
            if (record.resolvedDecoration == nil) {
                record.resolvedDecoration =
                    [self decorationFromDiagnosticProperties:diagnosticProperties];
                NSMutableArray<NSString *> *names = [NSMutableArray array];
                for (id value in diagnosticProperties) {
                    NSString *name =
                        [value isKindOfClass:NSDictionary.class] ? value[@"name"] : nil;
                    NSString *description =
                        [value isKindOfClass:NSDictionary.class] ? value[@"description"] : nil;
                    if ([name isKindOfClass:NSString.class]) {
                        [names addObject:[NSString stringWithFormat:@"%@=%@",
                                          name,
                                          [description isKindOfClass:NSString.class]
                                              ? description : @""]];
                    }
                }
                NSLog(@"PV_FLUTTER_DECORATION widget=%@ renderObject=%@ count=%@ "
                      @"resolved=%d image=%d names=%@",
                      record.element.widgetType, record.element.renderObjectType,
                      @(diagnosticProperties.count),
                      record.resolvedDecoration != nil,
                      record.paintsDecorationImage,
                      [names componentsJoinedByString:@", "]);
            }
        }
        capture();
    }];
}

- (void)detailsForDisplayItemIDs:(NSArray<NSString *> *)displayItemIDs
                  needsSoloImage:(BOOL)needsSoloImage
                 needsGroupImage:(BOOL)needsGroupImage
                 lowImageQuality:(BOOL)lowImageQuality
                      completion:(PVFlutterHierarchyDetailsCompletion)completion {
    NSMutableArray<PVStaticAsyncUpdateTask *> *tasks = [NSMutableArray array];
    for (NSString *displayItemID in displayItemIDs) {
        PVFlutterNodeRecord *record = self.recordsByDisplayItemID[displayItemID];
        if (!record) continue;
        PVStaticAsyncUpdateTask *task = [PVStaticAsyncUpdateTask new];
        task.oid = (unsigned long)(uintptr_t)record;
        task.frameSize = record.element.frame.size;
        task.attrRequest = PVDetailUpdateTaskAttrRequest_Need;
        task.taskType = needsGroupImage ? PVStaticAsyncUpdateTaskTypeGroupScreenshot :
            (needsSoloImage ? PVStaticAsyncUpdateTaskTypeSoloScreenshot :
             PVStaticAsyncUpdateTaskTypeNoScreenshot);
        [tasks addObject:task];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self processTaskAtIndex:0 tasks:tasks lowImageQuality:lowImageQuality
                         results:[NSMutableArray array] completion:completion];
    });
}

- (PVDisplayItemDetail *)baseDetailForRecord:(PVFlutterNodeRecord *)record
                                          oid:(unsigned long)oid {
    KKFIInspectorElement *element = record.element;
    PVDisplayItemDetail *detail = [PVDisplayItemDetail new];
    detail.displayItemID = record.displayItemID;
    detail.displayItemOid = oid;
    detail.contentKind = PVDisplayItemContentKindFlutter;
    detail.flutterDetail = record.detail;
    detail.frame = element.frame;
    detail.bounds = (CGRect){CGPointZero, element.frame.size};
    detail.frameValue = [NSValue valueWithCGRect:detail.frame];
    detail.boundsValue = [NSValue valueWithCGRect:detail.bounds];
    detail.hiddenValue = @NO;
    detail.alphaValue = @1;
    detail.alpha = 1;
    return detail;
}

// Debug aid: prints why a Flutter row does or does not receive preview pixels.
- (void)logPreviewDecision:(NSString *)decision
                      task:(PVStaticAsyncUpdateTask *)task
                    record:(PVFlutterNodeRecord *)record {
    if (!decision.length) return;
    KKFIInspectorElement *element = record.element;
    NSLog(@"PV_FLUTTER_PREVIEW widget=%@ renderObject=%@ paintRole=%@ strategy=%@ "
          @"children=%@ hasFrame=%d proxy=%d decoration=%d resolved=%d image=%d "
          @"frame=%@ task=%@ -> %@",
          element.widgetType, element.renderObjectType, element.paintRole,
          element.renderStrategy, @(element.children.count), element.hasFrame,
          [record.page isProxyElement:element], element.nativeDecoration != nil,
          record.resolvedDecoration != nil, record.paintsDecorationImage,
          NSStringFromCGRect(element.frame),
          task.taskType == PVStaticAsyncUpdateTaskTypeSoloScreenshot ? @"solo"
              : (task.taskType == PVStaticAsyncUpdateTaskTypeGroupScreenshot
                     ? @"group" : @"none"),
          decision);
}

- (void)captureForTask:(PVStaticAsyncUpdateTask *)task
                 record:(PVFlutterNodeRecord *)record
                 detail:(PVDisplayItemDetail *)detail
        lowImageQuality:(BOOL)lowImageQuality
             completion:(dispatch_block_t)completion {
    KKFIInspectorElement *element = record.element;
    /// solo == 已展开，只画自己这一层；group == 折叠，要画出整棵子树
    BOOL isSolo = (task.taskType == PVStaticAsyncUpdateTaskTypeSoloScreenshot);
    if (task.taskType == PVStaticAsyncUpdateTaskTypeNoScreenshot) {
        completion();
        return;
    }
    if (!element.hasFrame) {
        [self logPreviewDecision:@"skipNoFrame" task:task record:record];
        completion();
        return;
    }
    if (isSolo && [record.page isProxyElement:element]) {
        // BlocBuilder / Builder / ZPButton style wrappers borrow a descendant's
        // render object, so both the screenshot and the parsed decoration really
        // belong to that descendant. While expanded, the owner row is visible and
        // already draws them, so the wrapper itself draws nothing at all — not
        // even a rebuilt decoration, since here the decoration was parsed from
        // the borrowed render object rather than from the wrapper's own widget.
        // While collapsed the rule is the opposite: every descendant is hidden,
        // so the wrapper is the only row that can show the subtree (see below).
        [self logPreviewDecision:@"skipProxy" task:task record:record];
        completion();
        return;
    }
    NSDictionary *decoration =
        element.nativeDecoration ?: record.resolvedDecoration;
    /// A decoration that paints a `DecorationImage` owns real pixels, but no
    /// rebuild can reproduce them: the reconstructed image only knows color,
    /// gradient, border and radius, so while expanded the row showed a flat
    /// rect (or stayed empty) exactly where the image belongs. Such a node is
    /// repainted from the image source instead (see below). Drop any decoration
    /// rebuilt from the same payload, since a
    /// `BoxDecoration(color:..., image:...)` also resolves a color that would
    /// cover the image up.
    BOOL paintsOwnImage = record.paintsDecorationImage;
    if (paintsOwnImage) {
        decoration = nil;
    }
    if (isSolo && paintsOwnImage && element.children.count > 0) {
        // A `DecorationImage` is this node's own background, but an Inspector
        // screenshot always flattens the whole render subtree, so the expanded
        // row used to paint its children's pixels a second time on top of the
        // rows that already draw themselves. Repaint the image source instead
        // and let the children keep drawing themselves.
        [self captureDecorationImageForTask:task
                                     record:record
                                     detail:detail
                            lowImageQuality:lowImageQuality
                                 completion:^(BOOL painted) {
            if (painted) {
                completion();
                return;
            }
            // No resolvable source (a `MemoryImage`, for instance): keep the
            // subtree capture rather than leaving the row empty.
            [self captureSubtreeForTask:task
                                 record:record
                                 detail:detail
                        lowImageQuality:lowImageQuality
                             completion:completion];
        }];
        return;
    }
    if (isSolo && !paintsOwnImage &&
        !PVFlutterExpandedElementOwnsContent(element, decoration)) {
        // Expanded: descendants already draw their own content, so an ancestor
        // must not flatten them into another full subtree image and stack the
        // same pixels on top of each other.
        [self logPreviewDecision:@"skipExpandedParent" task:task record:record];
        completion();
        return;
    }
    if (isSolo && element.children.count > 0 && !paintsOwnImage) {
        // An Inspector screenshot always contains the complete render subtree.
        // For an expanded parent, only keep a reconstructed decoration and let
        // visible children provide their own screenshots. A page-sized
        // ColoredBox shows exactly this: its subtree image would paint the
        // whole screen a second time.
        CGFloat displayScale = MAX(record.page.hostView.traitCollection.displayScale, 1);
        UIImage *image = [self decorationImageForDecoration:decoration
                                                     size:element.frame.size
                                          lowImageQuality:lowImageQuality
                                              displayScale:displayScale];
        [self logPreviewDecision:image ? @"expandedDecoration" : @"expandedDecorationNil"
                            task:task
                          record:record];
        if (image) {
            NSData *data = UIImagePNGRepresentation(image);
            detail.soloImageData = data;
            detail.soloScreenshot = image;
        }
        completion();
        return;
    }
    if (isSolo && element.children.count == 0) {
        // 已展开的叶子节点：只画自己这一层，没有可绘制内容就保持空白
        if (!element.captureEligible && decoration == nil) {
            [self logPreviewDecision:@"skipNotEligible" task:task record:record];
            completion();
            return;
        }
    } else if (!PVFlutterSubtreeHasPaintableContent(element)) {
        // 折叠状态：整棵子树（含所有 child node）都由这一行负责绘制；子树里
        // 确实没有任何可绘制内容时才保持空白。
        [self logPreviewDecision:@"skipSubtreeEmpty" task:task record:record];
        completion();
        return;
    }
    [self captureSubtreeForTask:task
                         record:record
                         detail:detail
                lowImageQuality:lowImageQuality
                     completion:completion];
}

/// Takes the real Inspector screenshot, which always contains the complete
/// render subtree.
- (void)captureSubtreeForTask:(PVStaticAsyncUpdateTask *)task
                       record:(PVFlutterNodeRecord *)record
                       detail:(PVDisplayItemDetail *)detail
              lowImageQuality:(BOOL)lowImageQuality
                   completion:(dispatch_block_t)completion {
    KKFIInspectorElement *element = record.element;
    [self logPreviewDecision:task.taskType == PVStaticAsyncUpdateTaskTypeSoloScreenshot
                                 ? @"captureSolo" : @"captureGroup"
                        task:task
                      record:record];

    CGFloat displayScale = MAX(record.page.hostView.traitCollection.displayScale, 1);
    // PickView displays these images on a Retina canvas and can further scale
    // them during 3D transforms. A 1x Flutter capture becomes visibly soft, so
    // keep the source image at the host view's native density (capped at 3x).
    CGFloat ratio = MIN(MAX(displayScale, 2), 3);
    KKFIScreenshotOptions *options = [[KKFIScreenshotOptions alloc]
        initWithLogicalSize:element.frame.size];
    options.maxPixelRatio = ratio;
    [self.inspector captureScreenshotForElement:element.reference
                                        options:options
                                     completion:^(KKFIScreenshotResult *result,
                                                  NSError *error) {
        if (!error && result.image && result.pngData.length) {
            if (task.taskType == PVStaticAsyncUpdateTaskTypeSoloScreenshot) {
                detail.soloImageData = result.pngData;
                detail.soloScreenshot = result.image;
            } else {
                detail.groupImageData = result.pngData;
                detail.groupScreenshot = result.image;
            }
            NSLog(@"PV_FLUTTER_SCREENSHOT_OK widget=%@ renderObject=%@ task=%@ "
                  @"image=%@ bytes=%@",
                  element.widgetType, element.renderObjectType,
                  task.taskType == PVStaticAsyncUpdateTaskTypeSoloScreenshot
                      ? @"solo" : @"group",
                  NSStringFromCGSize(result.image.size), @(result.pngData.length));
        } else {
            NSLog(@"PV_FLUTTER_SCREENSHOT_FAILED objectID=%@ widget=%@ strategy=%@ error=%@",
                  element.reference.objectID, element.widgetType,
                  element.renderStrategy, error);
        }
        completion();
    }];
}

/// Repaints a node's own `DecorationImage` and uses it as the expanded preview.
///
/// An Inspector screenshot always contains the complete render subtree, so for
/// a `DecoratedBox` whose decoration paints an image it also carries every
/// child — pixels the child rows already draw themselves. Repainting the image
/// source keeps the row's own background and nothing else.
- (void)captureDecorationImageForTask:(PVStaticAsyncUpdateTask *)task
                               record:(PVFlutterNodeRecord *)record
                               detail:(PVDisplayItemDetail *)detail
                      lowImageQuality:(BOOL)lowImageQuality
                           completion:(void (^)(BOOL painted))completion {
    KKFIInspectorElement *element = record.element;
    NSDictionary *info = PVFlutterDecorationImageInfoFromDescription(
        record.decorationImageDescription);
    NSString *source = [info[@"source"] isKindOfClass:NSString.class]
        ? info[@"source"] : nil;
    if (source.length == 0) {
        NSLog(@"PV_FLUTTER_DECORATION_IMAGE widget=%@ renderObject=%@ "
              @"description=%@ -> noResolvableSource",
              element.widgetType, element.renderObjectType,
              record.decorationImageDescription);
        completion(NO);
        return;
    }
    [self loadDecorationImageWithInfo:info
                           completion:^(UIImage *image) {
        if (!image) {
            NSLog(@"PV_FLUTTER_DECORATION_IMAGE widget=%@ provider=%@ "
                  @"source=%@ -> loadFailed",
                  element.widgetType, info[@"provider"], source);
            completion(NO);
            return;
        }
        CGFloat displayScale =
            MAX(record.page.hostView.traitCollection.displayScale, 1);
        UIImage *painted = [self imageByPaintingDecorationImage:image
                                                           info:info
                                                           size:element.frame.size
                                                  displayScale:displayScale];
        if (!painted) {
            completion(NO);
            return;
        }
        [self logPreviewDecision:@"decorationImageRepainted" task:task record:record];
        NSLog(@"PV_FLUTTER_DECORATION_IMAGE widget=%@ provider=%@ source=%@ "
              @"fit=%@ scale=%@ opacity=%@ -> %@",
              element.widgetType, info[@"provider"], source, info[@"fit"],
              info[@"scale"], info[@"opacity"],
              NSStringFromCGSize(painted.size));
        detail.soloImageData = UIImagePNGRepresentation(painted);
        detail.soloScreenshot = painted;
        completion(YES);
    }];
}

/// Loads the image a `DecorationImage` points at. Network sources are fetched
/// again by the host app; Flutter's own image cache is not reachable natively.
- (void)loadDecorationImageWithInfo:(NSDictionary *)info
                         completion:(void (^)(UIImage *image))completion {
    NSString *source = info[@"source"];
    if ([info[@"remote"] boolValue]) {
        NSURL *url = [NSURL URLWithString:source];
        if (!url) {
            completion(nil);
            return;
        }
        NSURLRequest *request =
            [NSURLRequest requestWithURL:url
                             cachePolicy:NSURLRequestReturnCacheDataElseLoad
                         timeoutInterval:10];
        [[NSURLSession.sharedSession dataTaskWithRequest:request
                    completionHandler:^(NSData *data, NSURLResponse *response,
                                        NSError *error) {
            UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(image); });
        }] resume];
        return;
    }
    NSString *path = [self localPathForDecorationImageSource:source];
    completion(path.length ? [UIImage imageWithContentsOfFile:path] : nil);
}

/// Resolves an `AssetImage` / `FileImage` source to a file on disk. Flutter
/// ships its assets inside `App.framework/flutter_assets`, keyed by the name
/// the Dart code asked for.
- (NSString *)localPathForDecorationImageSource:(NSString *)source {
    NSFileManager *manager = NSFileManager.defaultManager;
    if ([source hasPrefix:@"/"] && [manager fileExistsAtPath:source]) {
        return source;
    }
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *resourceRoot = bundle.resourcePath;
    NSArray<NSString *> *roots = @[
        resourceRoot,
        [resourceRoot stringByAppendingPathComponent:@"flutter_assets"],
        [resourceRoot stringByAppendingPathComponent:
            @"Frameworks/App.framework/flutter_assets"],
        [bundle.bundlePath stringByAppendingPathComponent:@"flutter_assets"],
    ];
    for (NSString *root in roots) {
        NSString *candidate = [root stringByAppendingPathComponent:source];
        if ([manager fileExistsAtPath:candidate]) return candidate;
    }
    // `-[NSBundle pathForResource:ofType:inDirectory:]` additionally resolves
    // the asset through the bundle's own lookup tables, which covers asset
    // keys that were renamed while building the app.
    NSArray<NSString *> *relativeRoots = @[
        @"",
        @"flutter_assets",
        @"Frameworks/App.framework/flutter_assets",
    ];
    NSString *directory = source.stringByDeletingLastPathComponent;
    NSString *name = source.lastPathComponent;
    for (NSString *root in relativeRoots) {
        NSString *scope = directory.length
            ? [root stringByAppendingPathComponent:directory] : root;
        NSString *resolved = [bundle pathForResource:name
                                             ofType:nil
                                        inDirectory:scope.length ? scope : nil];
        if (resolved.length && [manager fileExistsAtPath:resolved]) return resolved;
    }
    return nil;
}

/// Draws a decoration image into `size` the way Flutter would: `applyBoxFit`
/// picks the source sub-rect, then the alignment places it inside the box.
- (UIImage *)imageByPaintingDecorationImage:(UIImage *)source
                                       info:(NSDictionary *)info
                                       size:(CGSize)size
                               displayScale:(CGFloat)displayScale {
    if (!source || size.width <= 0 || size.height <= 0) return nil;
    CGImageRef full = source.CGImage;
    if (!full) return nil;
    CGFloat scale = [info[@"scale"] doubleValue];
    if (!(scale > 0)) scale = 1;
    /// Flutter feeds `applyBoxFit` the image size already divided by the scale.
    CGSize inputSize = CGSizeMake(CGImageGetWidth(full) / scale,
                                  CGImageGetHeight(full) / scale);
    if (inputSize.width <= 0 || inputSize.height <= 0) return nil;
    NSString *fit = [info[@"fit"] isKindOfClass:NSString.class]
        ? info[@"fit"] : @"scaleDown";
    CGSize sourceSize = CGSizeZero;
    CGSize destinationSize = CGSizeZero;
    PVFlutterApplyBoxFit(fit, inputSize, size, &sourceSize, &destinationSize);
    if (sourceSize.width <= 0 || sourceSize.height <= 0 ||
        destinationSize.width <= 0 || destinationSize.height <= 0) {
        return nil;
    }
    CGPoint alignment = CGPointMake([info[@"alignmentX"] doubleValue],
                                    [info[@"alignmentY"] doubleValue]);
    /// Flutter centres the source sub-rect, then aligns the destination.
    CGRect inputRect = PVFlutterInscribe(sourceSize,
                                         (CGRect){CGPointZero, inputSize},
                                         CGPointZero);
    CGRect outputRect = PVFlutterInscribe(destinationSize,
                                          (CGRect){CGPointZero, size},
                                          alignment);
    CGFloat alpha = [info[@"opacity"] doubleValue];
    UIGraphicsImageRendererFormat *format =
        [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = MIN(MAX(displayScale, 2), 3);
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        if (source.imageOrientation != UIImageOrientationUp) {
            // Cropping operates on raw pixels, which an oriented image does not
            // describe; fall back to drawing the whole image fitted to the box.
            [source drawInRect:outputRect
                     blendMode:kCGBlendModeNormal
                         alpha:MAX(MIN(alpha, 1), 0)];
            return;
        }
        /// Back from logical units to decoded pixels: `inputRect` lives in the
        /// scaled-down space `applyBoxFit` was fed.
        CGRect pixelRect = CGRectMake(inputRect.origin.x * scale,
                                      inputRect.origin.y * scale,
                                      inputRect.size.width * scale,
                                      inputRect.size.height * scale);
        pixelRect = CGRectIntersection(
            pixelRect, CGRectMake(0, 0, CGImageGetWidth(full),
                                  CGImageGetHeight(full)));
        if (CGRectIsEmpty(pixelRect) || CGRectIsNull(pixelRect)) return;
        CGImageRef cropped = CGImageCreateWithImageInRect(full, pixelRect);
        if (!cropped) return;
        UIImage *piece = [UIImage imageWithCGImage:cropped
                                            scale:1
                                      orientation:UIImageOrientationUp];
        CGImageRelease(cropped);
        [piece drawInRect:outputRect
                blendMode:kCGBlendModeNormal
                    alpha:MAX(MIN(alpha, 1), 0)];
    }];
}

- (UIImage *)decorationImageForElement:(KKFIInspectorElement *)element
                       lowImageQuality:(BOOL)lowImageQuality
                           displayScale:(CGFloat)displayScale {
    return [self decorationImageForDecoration:element.nativeDecoration
                                         size:element.frame.size
                              lowImageQuality:lowImageQuality
                                  displayScale:displayScale];
}

- (UIImage *)decorationImageForDecoration:(NSDictionary *)decoration
                                     size:(CGSize)size
                          lowImageQuality:(BOOL)lowImageQuality
                              displayScale:(CGFloat)displayScale {
    if (!decoration || size.width <= 0 || size.height <= 0) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = MIN(MAX(displayScale, 2), 3);
    (void)lowImageQuality;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect rect = (CGRect){CGPointZero, size};
        NSDictionary *contentInsets =
            [decoration[@"contentInsets"] isKindOfClass:NSDictionary.class]
                ? decoration[@"contentInsets"]
                : nil;
        if (contentInsets != nil) {
            UIEdgeInsets insets = UIEdgeInsetsMake(
                [contentInsets[@"top"] doubleValue],
                [contentInsets[@"left"] doubleValue],
                [contentInsets[@"bottom"] doubleValue],
                [contentInsets[@"right"] doubleValue]);
            rect = UIEdgeInsetsInsetRect(rect, insets);
        }
        if (rect.size.width <= 0 || rect.size.height <= 0) return;
        CGFloat radius = [decoration[@"cornerRadius"] doubleValue];
        UIBezierPath *path = [decoration[@"shape"] isEqual:@"circle"]
            ? [UIBezierPath bezierPathWithOvalInRect:rect]
            : [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
        NSArray *shadows = [decoration[@"shadows"] isKindOfClass:NSArray.class]
            ? decoration[@"shadows"] : @[];
        NSDictionary *shadow = shadows.firstObject;
        NSDictionary *gradient = [decoration[@"gradient"] isKindOfClass:NSDictionary.class]
            ? decoration[@"gradient"] : nil;
        NSArray *gradientColors = [gradient[@"colors"] isKindOfClass:NSArray.class]
            ? gradient[@"colors"] : @[];
        UIColor *fillColor = [self colorFromDictionary:decoration[@"backgroundColor"]];
        if (fillColor == nil && gradientColors.count > 0) {
            fillColor = [self colorFromDictionary:gradientColors.firstObject];
        }
        fillColor = fillColor ?: UIColor.clearColor;
        CGContextRef cg = context.CGContext;
        CGContextSaveGState(cg);
        if (shadow) {
            CGSize offset = CGSizeMake([shadow[@"offsetX"] doubleValue],
                                       [shadow[@"offsetY"] doubleValue]);
            UIColor *shadowColor = [self colorFromDictionary:shadow[@"color"]]
                ?: UIColor.clearColor;
            CGContextSetShadowWithColor(cg, offset, [shadow[@"blurRadius"] doubleValue],
                                        shadowColor.CGColor);
        }
        [fillColor setFill];
        [path fill];
        CGContextRestoreGState(cg);

        if ([gradient[@"type"] isEqual:@"linear"] &&
            gradientColors.count >= 2) {
            NSMutableArray *cgColors =
                [NSMutableArray arrayWithCapacity:gradientColors.count];
            for (NSDictionary *colorDictionary in gradientColors) {
                UIColor *color = [self colorFromDictionary:colorDictionary];
                if (color != nil) {
                    [cgColors addObject:(__bridge id)color.CGColor];
                }
            }
            if (cgColors.count == gradientColors.count) {
                NSArray *stops = [gradient[@"stops"] isKindOfClass:NSArray.class]
                    ? gradient[@"stops"] : nil;
                CGFloat *locations = NULL;
                if (stops.count == cgColors.count) {
                    locations = calloc(stops.count, sizeof(CGFloat));
                    [stops enumerateObjectsUsingBlock:^(NSNumber *value,
                                                         NSUInteger index,
                                                         BOOL *stop) {
                        locations[index] = value.doubleValue;
                    }];
                }
                CGGradientRef cgGradient = CGGradientCreateWithColors(
                    NULL, (__bridge CFArrayRef)cgColors, locations);
                free(locations);
                if (cgGradient != NULL) {
                    CGPoint start = CGPointMake(
                        CGRectGetMinX(rect) + CGRectGetWidth(rect) *
                            [gradient[@"startX"] doubleValue],
                        CGRectGetMinY(rect) + CGRectGetHeight(rect) *
                            [gradient[@"startY"] doubleValue]);
                    CGPoint end = CGPointMake(
                        CGRectGetMinX(rect) + CGRectGetWidth(rect) *
                            [gradient[@"endX"] doubleValue],
                        CGRectGetMinY(rect) + CGRectGetHeight(rect) *
                            [gradient[@"endY"] doubleValue]);
                    CGContextSaveGState(cg);
                    [path addClip];
                    CGContextDrawLinearGradient(
                        cg, cgGradient, start, end,
                        kCGGradientDrawsBeforeStartLocation |
                            kCGGradientDrawsAfterEndLocation);
                    CGContextRestoreGState(cg);
                    CGGradientRelease(cgGradient);
                }
            }
        }

        NSDictionary *border = [decoration[@"border"] isKindOfClass:NSDictionary.class]
            ? decoration[@"border"] : nil;
        CGFloat width = [border[@"width"] doubleValue];
        UIColor *borderColor = [self colorFromDictionary:border[@"color"]];
        if (width > 0 && borderColor) {
            CGRect borderRect = CGRectInset(rect, width * 0.5, width * 0.5);
            CGFloat borderRadius = MAX(0, radius - width * 0.5);
            UIBezierPath *borderPath = [decoration[@"shape"] isEqual:@"circle"]
                ? [UIBezierPath bezierPathWithOvalInRect:borderRect]
                : [UIBezierPath bezierPathWithRoundedRect:borderRect
                                              cornerRadius:borderRadius];
            [borderColor setStroke];
            borderPath.lineWidth = width;
            [borderPath stroke];
        }
    }];
}

- (PVFlutterNodeDetail *)detailByAddingDiagnostics:(id)payload
                                           toDetail:(PVFlutterNodeDetail *)detail {
    NSArray *properties = [payload isKindOfClass:NSArray.class] ? payload :
        ([payload[@"properties"] isKindOfClass:NSArray.class] ? payload[@"properties"] : @[]);
    if (properties.count == 0) return detail;
    PVFlutterNodeDetail *updated = detail.copy;
    PVFlutterDetailSection *section = [PVFlutterDetailSection new];
    section.identifier = @"diagnostics";
    section.title = @"Diagnostics properties";
    NSMutableArray *fields = [NSMutableArray arrayWithCapacity:properties.count];
    [properties enumerateObjectsUsingBlock:^(id value, NSUInteger index, BOOL *stop) {
        NSString *name = [value[@"name"] isKindOfClass:NSString.class]
            ? value[@"name"] : [NSString stringWithFormat:@"Property %@", @(index + 1)];
        [fields addObject:[self jsonField:[NSString stringWithFormat:@"diagnostics.%@", @(index)]
                                    title:name value:value]];
    }];
    section.fields = fields.copy;
    NSMutableArray *sections = updated.sections.mutableCopy ?: [NSMutableArray array];
    NSIndexSet *old = [sections indexesOfObjectsPassingTest:^BOOL(PVFlutterDetailSection *value,
                                                                  NSUInteger index,
                                                                  BOOL *stop) {
        return [value.identifier isEqual:@"diagnostics"];
    }];
    [sections removeObjectsAtIndexes:old];
    [sections addObject:section];
    updated.sections = sections.copy;
    return updated;
}

- (PVFlutterDetailField *)textField:(NSString *)identifier
                               title:(NSString *)title
                               value:(NSString *)value {
    PVFlutterDetailField *field = [PVFlutterDetailField new];
    field.identifier = identifier;
    field.title = title;
    field.valueKind = PVFlutterDetailValueKindText;
    field.textValue = value ?: @"";
    return field;
}

- (PVFlutterDetailField *)boolField:(NSString *)identifier
                               title:(NSString *)title
                               value:(BOOL)value {
    PVFlutterDetailField *field = [PVFlutterDetailField new];
    field.identifier = identifier;
    field.title = title;
    field.valueKind = PVFlutterDetailValueKindBoolean;
    field.numberValue = @(value);
    return field;
}

- (PVFlutterDetailField *)rectField:(NSString *)identifier
                               title:(NSString *)title
                                rect:(CGRect)rect {
    PVFlutterDetailField *field = [PVFlutterDetailField new];
    field.identifier = identifier;
    field.title = title;
    field.valueKind = PVFlutterDetailValueKindRect;
    field.rectValue = rect;
    return field;
}

- (PVFlutterDetailField *)sizeField:(NSString *)identifier
                               title:(NSString *)title
                                size:(CGSize)size {
    PVFlutterDetailField *field = [PVFlutterDetailField new];
    field.identifier = identifier;
    field.title = title;
    field.valueKind = PVFlutterDetailValueKindSize;
    field.sizeValue = size;
    return field;
}

- (PVFlutterDetailField *)jsonField:(NSString *)identifier
                               title:(NSString *)title
                               value:(id)value {
    PVFlutterDetailField *field = [PVFlutterDetailField new];
    field.identifier = identifier;
    field.title = title;
    field.valueKind = PVFlutterDetailValueKindJSON;
    field.textValue = [self prettyJSONStringForObject:value ?: @{}];
    return field;
}

/// Hard ceiling for a single JSON detail string. A single field must never be
/// able to dominate a response that still has to fit into one PeerTalk frame.
static NSUInteger const PVFlutterPrettyJSONCharacterLimit = 256u * 1024u;

- (NSString *)prettyJSONStringForObject:(id)object {
    NSString *text = nil;
    if ([NSJSONSerialization isValidJSONObject:object]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:nil];
        text = data.length > 0
            ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
            : nil;
    } else {
        text = [object description];
    }
    text = text ?: @"";
    if (text.length <= PVFlutterPrettyJSONCharacterLimit) return text;
    NSString *suffix = [NSString stringWithFormat:@"\n… truncated, %@ characters total",
                        @(text.length)];
    return [[text substringToIndex:PVFlutterPrettyJSONCharacterLimit]
               stringByAppendingString:suffix];
}

- (UIColor *)colorFromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    CGFloat red = [dictionary[@"red"] doubleValue];
    CGFloat green = [dictionary[@"green"] doubleValue];
    CGFloat blue = [dictionary[@"blue"] doubleValue];
    CGFloat alpha = [dictionary[@"alpha"] doubleValue];
    if (red > 1 || green > 1 || blue > 1 || alpha > 1) {
        red /= 255; green /= 255; blue /= 255; alpha /= 255;
    }
    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

- (NSString *)colorDescription:(NSDictionary *)dictionary {
    UIColor *color = [self colorFromDictionary:dictionary];
    return color ? color.description : @"";
}

@end
