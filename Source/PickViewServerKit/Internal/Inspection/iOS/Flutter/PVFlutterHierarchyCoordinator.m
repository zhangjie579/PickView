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
    detail.rawJSON = [self prettyJSONStringForObject:element.rawJSON ?: @{}];

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
            if (record.resolvedDecoration == nil) {
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
                      @"resolved=%d names=%@",
                      record.element.widgetType, record.element.renderObjectType,
                      @(diagnosticProperties.count),
                      record.resolvedDecoration != nil,
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
//    if (!decision.length) return;
//    KKFIInspectorElement *element = record.element;
//    NSLog(@"PV_FLUTTER_PREVIEW widget=%@ renderObject=%@ paintRole=%@ strategy=%@ "
//          @"children=%@ hasFrame=%d proxy=%d decoration=%d resolved=%d frame=%@ task=%@ -> %@",
//          element.widgetType, element.renderObjectType, element.paintRole,
//          element.renderStrategy, @(element.children.count), element.hasFrame,
//          [record.page isProxyElement:element], element.nativeDecoration != nil,
//          record.resolvedDecoration != nil,
//          NSStringFromCGRect(element.frame),
//          task.taskType == PVStaticAsyncUpdateTaskTypeSoloScreenshot ? @"solo"
//              : (task.taskType == PVStaticAsyncUpdateTaskTypeGroupScreenshot
//                     ? @"group" : @"none"),
//          decision);
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
    if (isSolo && !PVFlutterExpandedElementOwnsContent(element, decoration)) {
        // Expanded: descendants already draw their own content, so an ancestor
        // must not flatten them into another full subtree image and stack the
        // same pixels on top of each other.
        [self logPreviewDecision:@"skipExpandedParent" task:task record:record];
        completion();
        return;
    }
    if (isSolo && element.children.count > 0) {
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
    if (isSolo) {
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

- (NSString *)prettyJSONStringForObject:(id)object {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        return [object description] ?: @"";
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    return data.length > 0
        ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        : @"";
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
