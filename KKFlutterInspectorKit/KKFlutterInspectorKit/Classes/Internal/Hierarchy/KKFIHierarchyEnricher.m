//
//  KKFIHierarchyEnricher.m
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/15.
//

#import "KKFIHierarchyEnricher.h"

#import <math.h>

#import "../Connection/KKFIVMServiceClient.h"
#import "../Inspector/KKFIInspectorJSON.h"

@implementation KKFIHierarchyEnricher

- (void)enrichLayoutPayload:(NSDictionary *)layoutPayload
                     client:(KKFIVMServiceClient *)client
                  isolateID:(NSString *)isolateID
                objectGroup:(NSString *)objectGroup
                 completion:(KKFIHierarchyEnrichmentCompletion)completion {
    NSMutableOrderedSet<NSString *> *objectIDs = [NSMutableOrderedSet orderedSet];
    NSMutableSet<NSString *> *cardObjectIDs = [NSMutableSet set];
    NSMutableSet<NSString *> *containerObjectIDs = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSSet<NSString *> *> *scrollViewChildObjectIDsByID =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSSet<NSString *> *> *customScrollTargetObjectIDsByID =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSSet<NSString *> *> *offsetBridgeChildObjectIDsByID =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *offsetBridgeRenderObjectIDsByID =
        [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *deepSubtreeObjectIDs = [NSMutableSet set];
    [self collectLayoutPropertyObjectIDsFromValue:layoutPayload
                                             into:objectIDs
                                    cardObjectIDs:cardObjectIDs
                               containerObjectIDs:containerObjectIDs
                       scrollViewChildObjectIDsByID:scrollViewChildObjectIDsByID
                  customScrollTargetObjectIDsByID:customScrollTargetObjectIDsByID
                    offsetBridgeChildObjectIDsByID:offsetBridgeChildObjectIDsByID
                    offsetBridgeRenderObjectIDsByID:offsetBridgeRenderObjectIDsByID
                              deepSubtreeObjectIDs:deepSubtreeObjectIDs];
    if (objectIDs.count == 0) {
        completion(@{}, @{});
        return;
    }

    NSMutableDictionary<NSString *, NSArray *> *propertiesByID =
        [NSMutableDictionary dictionaryWithCapacity:objectIDs.count];
    NSMutableDictionary<NSString *, NSValue *> *resolvedOffsetsByID =
        [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *offsetBridgeTargetObjectIDs =
        [NSMutableSet set];
    for (NSSet<NSString *> *targetObjectIDs in
         offsetBridgeChildObjectIDsByID.allValues) {
        [offsetBridgeTargetObjectIDs unionSet:targetObjectIDs];
    }
    NSDictionary<NSString *, NSValue *> *offsetBridgeLocalOffsetsByID =
        [self directOffsetsForTargetObjectIDs:offsetBridgeTargetObjectIDs
                                inLayoutValue:layoutPayload];
    __block NSUInteger remaining = objectIDs.count;
    for (NSString *objectID in objectIDs) {
        BOOL isCard = [cardObjectIDs containsObject:objectID];
        BOOL isContainer = [containerObjectIDs containsObject:objectID];
        NSSet<NSString *> *scrollViewChildObjectIDs =
            scrollViewChildObjectIDsByID[objectID];
        BOOL isScrollableList = scrollViewChildObjectIDs.count > 0;
        NSSet<NSString *> *customScrollTargetObjectIDs =
            customScrollTargetObjectIDsByID[objectID];
        BOOL isCustomScrollView = customScrollTargetObjectIDs.count > 0;
        NSSet<NSString *> *offsetBridgeChildObjectIDs =
            offsetBridgeChildObjectIDsByID[objectID];
        BOOL isOffsetBridgeRoot = offsetBridgeChildObjectIDs.count > 0;
        // A NestedScrollView nests a second scrollable inside its body, so its
        // items sit one full viewport deeper than a plain CustomScrollView.
        BOOL needsDeepSubtree =
            isOffsetBridgeRoot || [deepSubtreeObjectIDs containsObject:objectID];
        BOOL needsDetailsSubtree =
            isCard || isContainer || isScrollableList || isCustomScrollView ||
            isOffsetBridgeRoot;
        NSString *method = needsDetailsSubtree
            ? @"ext.flutter.inspector.getDetailsSubtree"
            : @"ext.flutter.inspector.getProperties";
        NSDictionary *params = needsDetailsSubtree
            ? @{
                @"isolateId" : isolateID,
                @"arg" : objectID,
                @"objectGroup" : objectGroup,
                @"subtreeDepth" : needsDeepSubtree
                    ? @"32"
                    : ((isScrollableList || isCustomScrollView) ? @"16" : @"4"),
            }
            : @{
                @"isolateId" : isolateID,
                @"arg" : objectID,
                @"objectGroup" : objectGroup,
            };
        [client callMethod:method
                    params:params
                completion:^(NSDictionary *response, NSError *error) {
            if (error == nil) {
                id payload = [KKFIInspectorJSON normalizedPayloadFromResponse:response];
                NSArray *properties = nil;
                if (isOffsetBridgeRoot) {
                    NSDictionary<NSString *, NSValue *> *offsets =
                        [self resolvedOffsetsForTargetObjectIDs:offsetBridgeChildObjectIDs
                                            rootRenderObjectID:offsetBridgeRenderObjectIDsByID[objectID]
                                                detailsPayload:payload
                                          targetLocalOffsets:offsetBridgeLocalOffsetsByID];
                    [resolvedOffsetsByID addEntriesFromDictionary:offsets];
                    properties =
                        [self resolvedMaterialPropertiesFromDetailsPayload:payload];
                } else if (isCustomScrollView) {
                    NSDictionary<NSString *, NSValue *> *offsets =
                        [self sliverResolvedOffsetsForTargetObjectIDs:
                            customScrollTargetObjectIDs
                                                       detailsPayload:payload];
                    if (offsets.count == 0) {
                        NSLog(@"[KKFlutterInspectorKit] Custom scroll item "
                              @"offsets unresolved: targets=%@",
                              @(customScrollTargetObjectIDs.count));
                    }
                    [resolvedOffsetsByID addEntriesFromDictionary:offsets];
                } else if (isScrollableList) {
                    // ListView and GridView place their items through slivers as
                    // well, so the sliver walk handles both. It reads the layout
                    // of the render objects instead of the ScrollView widget
                    // properties, which is the only shape a shrink wrapped
                    // GridView (for example one nested in a
                    // SingleChildScrollView) exposes.
                    NSDictionary<NSString *, NSValue *> *offsets =
                        [self sliverResolvedOffsetsForTargetObjectIDs:
                            scrollViewChildObjectIDs
                                                       detailsPayload:payload];
                    if (offsets.count == 0) {
                        // No sliver in the details subtree exposed its
                        // constraints, so the sliver based walk cannot place
                        // anything. Fall back to the ScrollView property driven
                        // estimate instead of leaving every item at the
                        // scrollable origin.
                        offsets = [self resolvedOffsetsForScrollTargetObjectIDs:
                            scrollViewChildObjectIDs
                                                              detailsPayload:payload];
                    }
                    if (offsets.count == 0) {
                        NSLog(@"[KKFlutterInspectorKit] Scroll item offsets "
                              @"unresolved: targets=%@",
                              @(scrollViewChildObjectIDs.count));
                    }
                    [resolvedOffsetsByID addEntriesFromDictionary:offsets];
                    if ([payload isKindOfClass:NSDictionary.class]) {
                        properties = [payload[@"properties"] isKindOfClass:NSArray.class]
                            ? payload[@"properties"]
                            : nil;
                    }
                } else if (isCard) {
                    properties = [self resolvedCardPropertiesFromDetailsPayload:payload];
                } else if (isContainer &&
                           [payload isKindOfClass:NSDictionary.class]) {
                    properties = [payload[@"properties"] isKindOfClass:NSArray.class]
                        ? payload[@"properties"]
                        : nil;
                } else if ([payload isKindOfClass:NSArray.class]) {
                    properties = payload;
                }
                if (properties.count > 0) {
                    propertiesByID[objectID] = properties;
                }
            }

            remaining -= 1;
            if (remaining == 0) {
                completion(propertiesByID.copy, resolvedOffsetsByID.copy);
            }
        }];
    }
}

- (NSDictionary<NSString *, NSValue *> *)
    directOffsetsForTargetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                       inLayoutValue:(id)value {
    if (targetObjectIDs.count == 0) {
        return @{};
    }
    NSMutableDictionary<NSString *, NSValue *> *result =
        [NSMutableDictionary dictionary];
    [self collectDirectOffsetsInLayoutValue:value
                            targetObjectIDs:targetObjectIDs
                                     result:result];
    return result.copy;
}

- (void)collectDirectOffsetsInLayoutValue:(id)value
                          targetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                                   result:(NSMutableDictionary<NSString *, NSValue *> *)result {
    if (![value isKindOfClass:NSDictionary.class] ||
        result.count == targetObjectIDs.count) {
        return;
    }

    NSDictionary *node = value;
    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:node];
    if ([targetObjectIDs containsObject:objectID]) {
        BOOL foundOffset = NO;
        CGPoint offset = CGPointZero;
        NSDictionary *parentData =
            [node[@"parentData"] isKindOfClass:NSDictionary.class]
                ? node[@"parentData"]
                : nil;
        NSNumber *offsetX =
            [KKFIInspectorJSON numberFromValue:parentData[@"offsetX"]];
        NSNumber *offsetY =
            [KKFIInspectorJSON numberFromValue:parentData[@"offsetY"]];
        if (offsetX != nil && offsetY != nil) {
            offset = CGPointMake(offsetX.doubleValue, offsetY.doubleValue);
            foundOffset = YES;
        } else {
            NSDictionary *renderObject =
                [self renderObjectPropertyFromInspectorNode:node];
            offset = [self parentDataOffsetFromValue:renderObject
                                               found:&foundOffset];
        }
        if (foundOffset) {
            result[objectID] = [NSValue valueWithCGPoint:offset];
        }
    }

    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        [self collectDirectOffsetsInLayoutValue:child
                                targetObjectIDs:targetObjectIDs
                                         result:result];
    }
}

- (void)collectLayoutPropertyObjectIDsFromValue:(id)value
                                            into:(NSMutableOrderedSet<NSString *> *)objectIDs
                                   cardObjectIDs:(NSMutableSet<NSString *> *)cardObjectIDs
                              containerObjectIDs:(NSMutableSet<NSString *> *)containerObjectIDs
                      scrollViewChildObjectIDsByID:(NSMutableDictionary<NSString *, NSSet<NSString *> *> *)scrollViewChildObjectIDsByID
                 customScrollTargetObjectIDsByID:(NSMutableDictionary<NSString *, NSSet<NSString *> *> *)customScrollTargetObjectIDsByID
                   offsetBridgeChildObjectIDsByID:(NSMutableDictionary<NSString *, NSSet<NSString *> *> *)offsetBridgeChildObjectIDsByID
                   offsetBridgeRenderObjectIDsByID:(NSMutableDictionary<NSString *, NSString *> *)offsetBridgeRenderObjectIDsByID
                             deepSubtreeObjectIDs:(NSMutableSet<NSString *> *)deepSubtreeObjectIDs {
    if (![value isKindOfClass:NSDictionary.class]) {
        return;
    }

    NSDictionary *node = value;
    NSString *widgetType = [node[@"widgetRuntimeType"] isKindOfClass:NSString.class]
        ? node[@"widgetRuntimeType"]
        : ([node[@"description"] isKindOfClass:NSString.class]
               ? node[@"description"]
               : nil);
    NSString *baseWidgetType =
        [[widgetType componentsSeparatedByString:@"<"] firstObject];
    static NSSet<NSString *> *offsetBridgeRootTypes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        offsetBridgeRootTypes = [NSSet setWithArray:@[
            @"AppBar", @"CheckboxListTile", @"CupertinoButton",
            @"ElevatedButton", @"FilledButton", @"FloatingActionButton",
            @"IconButton", @"OutlinedButton", @"SwitchListTile",
            @"TextButton", @"TextField",
        ]];
    });
    BOOL isOffsetBridgeRoot =
        [offsetBridgeRootTypes containsObject:baseWidgetType];
    // ListView and GridView share the same problem: Layout Explorer skips the
    // intermediate RenderSliver nodes and reports their box children without
    // an offset, because SliverLogicalParentData carries layoutOffset and
    // crossAxisOffset instead of a box offset. Both need the details subtree
    // pass below to recover a frame for every visible item.
    BOOL isScrollableListWidget =
        [baseWidgetType isEqualToString:@"ListView"] ||
        [baseWidgetType isEqualToString:@"GridView"];
    // A NestedScrollView drives two scrollables: the outer one lays out the
    // header slivers, the inner one owns the body. Both report their items
    // through SliverLogicalParentData / SliverPhysicalParentData instead of a
    // box offset, so it needs the same sliver-aware pass as CustomScrollView.
    BOOL isCustomScrollRootWidget =
        [baseWidgetType isEqualToString:@"CustomScrollView"] ||
        [baseWidgetType isEqualToString:@"NestedScrollView"] ||
        [baseWidgetType isEqualToString:@"PageView"] ||
        [baseWidgetType isEqualToString:@"TabBarView"];
    if (isScrollableListWidget ||
        isCustomScrollRootWidget ||
        [baseWidgetType isEqualToString:@"Card"] ||
        [baseWidgetType isEqualToString:@"Container"] ||
        isOffsetBridgeRoot) {
        NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:node];
        if (objectID.length > 0) {
            if ([baseWidgetType isEqualToString:@"Card"]) {
                [objectIDs addObject:objectID];
                [cardObjectIDs addObject:objectID];
            } else if ([baseWidgetType isEqualToString:@"Container"]) {
                [objectIDs addObject:objectID];
                [containerObjectIDs addObject:objectID];
            } else if (isScrollableListWidget) {
                NSMutableSet<NSString *> *childObjectIDs = [NSMutableSet set];
                NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
                    ? node[@"children"]
                    : @[];
                for (id childValue in children) {
                    if (![childValue isKindOfClass:NSDictionary.class]) {
                        continue;
                    }
                    [self collectScrollChildObjectIDsFromLayoutNode:childValue
                                                              into:childObjectIDs];
                }
                [objectIDs addObject:objectID];
                if (childObjectIDs.count > 0) {
                    scrollViewChildObjectIDsByID[objectID] = childObjectIDs.copy;
                }
            } else if (isCustomScrollRootWidget) {
                NSMutableSet<NSString *> *targetObjectIDs = [NSMutableSet set];
                NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
                    ? node[@"children"]
                    : @[];
                for (id child in children) {
                    if ([child isKindOfClass:NSDictionary.class]) {
                        [self collectCustomScrollTargetObjectIDsFromLayoutNode:child
                                                                          into:targetObjectIDs];
                    }
                }
                [objectIDs addObject:objectID];
                if (targetObjectIDs.count > 0) {
                    customScrollTargetObjectIDsByID[objectID] =
                        targetObjectIDs.copy;
                }
                if ([baseWidgetType isEqualToString:@"NestedScrollView"]) {
                    [deepSubtreeObjectIDs addObject:objectID];
                }
            } else if (isOffsetBridgeRoot) {
                NSMutableSet<NSString *> *childObjectIDs = [NSMutableSet set];
                NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
                    ? node[@"children"]
                    : @[];
                for (id childValue in children) {
                    if (![childValue isKindOfClass:NSDictionary.class]) {
                        continue;
                    }
                    NSString *childObjectID =
                        [KKFIInspectorJSON nodeIDFromDictionary:childValue];
                    if (childObjectID.length > 0) {
                        [childObjectIDs addObject:childObjectID];
                    }
                }
                if (childObjectIDs.count > 0) {
                    [objectIDs addObject:objectID];
                    offsetBridgeChildObjectIDsByID[objectID] = childObjectIDs.copy;
                    NSDictionary *renderObject =
                        [node[@"renderObject"] isKindOfClass:NSDictionary.class]
                            ? node[@"renderObject"]
                            : nil;
                    NSString *renderObjectID =
                        [renderObject[@"valueId"] isKindOfClass:NSString.class]
                            ? renderObject[@"valueId"]
                            : nil;
                    if (renderObjectID.length > 0) {
                        offsetBridgeRenderObjectIDsByID[objectID] = renderObjectID;
                    }
                }
            }
        }
    }

    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        [self collectLayoutPropertyObjectIDsFromValue:child
                                                 into:objectIDs
                                        cardObjectIDs:cardObjectIDs
                                   containerObjectIDs:containerObjectIDs
                           scrollViewChildObjectIDsByID:scrollViewChildObjectIDsByID
                      customScrollTargetObjectIDsByID:customScrollTargetObjectIDsByID
                        offsetBridgeChildObjectIDsByID:offsetBridgeChildObjectIDsByID
                        offsetBridgeRenderObjectIDsByID:offsetBridgeRenderObjectIDsByID
                                  deepSubtreeObjectIDs:deepSubtreeObjectIDs];
    }
}

/// Collects the object IDs whose position a ListView or GridView has to
/// resolve. Layout Explorer usually reports the box children of the inner
/// sliver directly under the scrollable, but some layouts keep an
/// intermediate RenderSliverPadding / RenderSliverGrid node. Such a bridge
/// never carries a `layoutOffset` of its own, so descend through it and
/// collect the real items in both shapes.
- (void)collectScrollChildObjectIDsFromLayoutNode:(NSDictionary *)node
                                             into:(NSMutableSet<NSString *> *)objectIDs {
    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:node];
    if (objectID.length > 0) {
        [objectIDs addObject:objectID];
    }
    if (![self isSliverBridgeLayoutNode:node]) {
        return;
    }

    NSString *widgetType = [node[@"widgetRuntimeType"] isKindOfClass:NSString.class]
        ? node[@"widgetRuntimeType"]
        : ([node[@"description"] isKindOfClass:NSString.class]
               ? node[@"description"]
               : nil);
    NSString *baseWidgetType =
        [[widgetType componentsSeparatedByString:@"<"] firstObject];
    NSSet<NSString *> *nestedScrollViews = [NSSet setWithArray:@[
        @"ListView", @"GridView", @"PageView", @"SingleChildScrollView",
        @"CustomScrollView", @"NestedScrollView", @"TabBarView",
    ]];
    if ([nestedScrollViews containsObject:baseWidgetType]) {
        return;
    }

    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        if ([child isKindOfClass:NSDictionary.class]) {
            [self collectScrollChildObjectIDsFromLayoutNode:child
                                                       into:objectIDs];
        }
    }
}

/// Whether a layout node only forwards a sliver's geometry instead of owning a
/// box of its own. Sliver bridges are rendered as `RenderSliverPadding`,
/// `RenderSliverGrid`, `RenderSliverList`, and friends. A node without any
/// RenderObject description is treated the same way, because it cannot carry
/// an offset either. Everything else is a real item and stops the descent, so
/// nodes that already resolve their own offset are never overwritten.
- (BOOL)isSliverBridgeLayoutNode:(NSDictionary *)node {
    NSDictionary *renderObject =
        [self renderObjectPropertyFromInspectorNode:node];
    NSString *description =
        [renderObject[@"description"] isKindOfClass:NSString.class]
            ? renderObject[@"description"]
            : nil;
    if (description.length == 0) {
        return YES;
    }
    NSString *renderObjectType =
        [[description componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"# "]]
                firstObject];
    return [renderObjectType containsString:@"Sliver"];
}

- (void)collectCustomScrollTargetObjectIDsFromLayoutNode:(NSDictionary *)node
                                                    into:(NSMutableSet<NSString *> *)objectIDs {
    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:node];
    if (objectID.length > 0) {
        [objectIDs addObject:objectID];
    }

    NSString *widgetType = [node[@"widgetRuntimeType"] isKindOfClass:NSString.class]
        ? node[@"widgetRuntimeType"]
        : ([node[@"description"] isKindOfClass:NSString.class]
               ? node[@"description"]
               : nil);
    NSString *baseWidgetType =
        [[widgetType componentsSeparatedByString:@"<"] firstObject];
    NSSet<NSString *> *nestedBoxScrollViews = [NSSet setWithArray:@[
        @"ListView", @"GridView", @"PageView", @"SingleChildScrollView",
        @"CustomScrollView", @"NestedScrollView", @"TabBarView",
    ]];
    if ([nestedBoxScrollViews containsObject:baseWidgetType]) {
        return;
    }

    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        if ([child isKindOfClass:NSDictionary.class]) {
            [self collectCustomScrollTargetObjectIDsFromLayoutNode:child
                                                               into:objectIDs];
        }
    }
}

- (NSDictionary<NSString *, NSValue *> *)
    sliverResolvedOffsetsForTargetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                             detailsPayload:(id)payload {
    if (![payload isKindOfClass:NSDictionary.class] ||
        targetObjectIDs.count == 0) {
        return @{};
    }

    NSMutableDictionary<NSString *, NSValue *> *result =
        [NSMutableDictionary dictionary];
    [self collectCustomScrollResolvedOffsetsInDetailsNode:payload
                                           targetObjectIDs:targetObjectIDs
                                            axisDirection:nil
                                              scrollOffset:0
                                        sliverPaintOffset:CGPointZero
                                            hasPaintOffset:NO
                                               baseOffset:CGPointZero
                                             isScrollRoot:YES
                                          insideViewport:NO
                                      seenRenderObjectIDs:[NSSet set]
                                                   result:result];
    return result.copy;
}

/// Resolves one node's origin and the coordinate space its children use.
///
/// `baseOffset` is the origin of the viewport that currently owns the
/// coordinate space, relative to the scroll root's own box.
/// `sliverPaintOffset` accumulates the paintOffset of every sliver from that
/// viewport down to the current one: a sliver reports its origin against the
/// visible top left corner of the viewport, and a box child of a sliver adds
/// its own `layoutOffset` on top of it. A box child also anchors a new
/// coordinate space, which is exactly how the inner viewport of a
/// `NestedScrollView` body behaves.
///
/// Widgets without a RenderObject of their own report the first descendant's,
/// so a proxy chain repeats one RenderObject at every level. Each RenderObject
/// contributes its box offset once per path, exactly like the offset bridge
/// pass does.
- (void)collectCustomScrollResolvedOffsetsInDetailsNode:(NSDictionary *)node
                                         targetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                                          axisDirection:(NSString *)axisDirection
                                            scrollOffset:(CGFloat)scrollOffset
                                      sliverPaintOffset:(CGPoint)sliverPaintOffset
                                          hasPaintOffset:(BOOL)hasPaintOffset
                                             baseOffset:(CGPoint)baseOffset
                                           isScrollRoot:(BOOL)isScrollRoot
                                        insideViewport:(BOOL)insideViewport
                                    seenRenderObjectIDs:(NSSet<NSString *> *)seenRenderObjectIDs
                                                 result:(NSMutableDictionary<NSString *, NSValue *> *)result {
    NSString *nextAxisDirection = axisDirection;
    CGFloat nextScrollOffset = scrollOffset;
    CGPoint nextPaintOffset = sliverPaintOffset;
    BOOL nextHasPaintOffset = hasPaintOffset;
    CGPoint nextBaseOffset = baseOffset;
    BOOL nextInsideViewport = insideViewport;

    NSDictionary *renderObject =
        [self renderObjectPropertyFromInspectorNode:node];
    NSString *renderObjectID =
        [renderObject[@"valueId"] isKindOfClass:NSString.class]
            ? renderObject[@"valueId"]
            : nil;
    BOOL renderObjectAlreadySeen = renderObjectID.length > 0 &&
        [seenRenderObjectIDs containsObject:renderObjectID];
    NSMutableSet<NSString *> *nextSeenRenderObjectIDs =
        [seenRenderObjectIDs mutableCopy];
    if (renderObjectID.length > 0) {
        [nextSeenRenderObjectIDs addObject:renderObjectID];
    }

    BOOL isSliverRenderObject = [self sliverContextFromInspectorNode:node
                                                        axisDirection:&nextAxisDirection
                                                          scrollOffset:&nextScrollOffset];
    if ([self isViewportInspectorNode:node]) {
        nextInsideViewport = YES;
    }

    NSString *targetObjectID = nil;
    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:node];
    if ([targetObjectIDs containsObject:objectID]) {
        targetObjectID = objectID;
    }

    // Only slivers carry SliverPhysicalParentData, so a paintOffset marks a
    // sliver even when its constraints are not serialized. Slivers nest, so
    // the chain has to be accumulated instead of read from the nearest one.
    BOOL foundPaintOffset = NO;
    CGPoint paintOffset = [self sliverPaintOffsetFromInspectorNode:node
                                                             found:&foundPaintOffset];
    if (foundPaintOffset && !isScrollRoot) {
        nextPaintOffset = CGPointMake(sliverPaintOffset.x + paintOffset.x,
                                      sliverPaintOffset.y + paintOffset.y);
        nextHasPaintOffset = YES;
        if (targetObjectID.length == 0) {
            targetObjectID = [self firstTargetObjectID:targetObjectIDs
                                          inDetailsNode:node];
        }
        if (targetObjectID.length > 0 && result[targetObjectID] == nil) {
            result[targetObjectID] = [NSValue valueWithCGPoint:
                CGPointMake(baseOffset.x + nextPaintOffset.x,
                            baseOffset.y + nextPaintOffset.y)];
        }
    }

    if (!isScrollRoot && !isSliverRenderObject) {
        BOOL foundLayoutOffset = NO;
        CGFloat layoutOffset = [self sliverLayoutOffsetFromInspectorNode:node
                                                                   found:&foundLayoutOffset];
        if (foundLayoutOffset &&
            ([nextAxisDirection isEqualToString:@"down"] ||
             [nextAxisDirection isEqualToString:@"right"])) {
            BOOL foundCrossAxisOffset = NO;
            CGFloat crossAxisOffset =
                [self sliverCrossAxisOffsetFromInspectorNode:node
                                                       found:&foundCrossAxisOffset];
            if (!foundCrossAxisOffset) {
                crossAxisOffset = 0;
            }
            // The accumulated paintOffset already measures the sliver's origin
            // from the visible top left corner of the viewport, so it already
            // contains -scrollOffset once the sliver straddles that corner.
            // Subtracting scrollOffset again shifts every visible item by the
            // scroll position. Only use that term when no sliver in this
            // branch exposed a paintOffset at all.
            CGFloat mainAxisOffset = nextHasPaintOffset
                ? layoutOffset
                : layoutOffset - nextScrollOffset;
            CGPoint localOffset = [nextAxisDirection isEqualToString:@"down"]
                ? CGPointMake(nextPaintOffset.x + crossAxisOffset,
                              nextPaintOffset.y + mainAxisOffset)
                : CGPointMake(nextPaintOffset.x + mainAxisOffset,
                              nextPaintOffset.y + crossAxisOffset);
            CGPoint absoluteOffset = CGPointMake(baseOffset.x + localOffset.x,
                                                 baseOffset.y + localOffset.y);
            if (targetObjectID.length == 0) {
                targetObjectID = [self firstTargetObjectID:targetObjectIDs
                                              inDetailsNode:node];
            }
            if (targetObjectID.length > 0 && result[targetObjectID] == nil) {
                result[targetObjectID] =
                    [NSValue valueWithCGPoint:absoluteOffset];
            }
            // A box child of a sliver anchors its own coordinate space.
            nextBaseOffset = absoluteOffset;
            nextPaintOffset = CGPointZero;
            nextHasPaintOffset = NO;
        } else if (!foundPaintOffset && nextInsideViewport &&
                   !renderObjectAlreadySeen) {
            BOOL foundBoxOffset = NO;
            CGPoint boxOffset = [self parentDataOffsetFromValue:renderObject
                                                          found:&foundBoxOffset];
            if (foundBoxOffset) {
                nextBaseOffset = CGPointMake(baseOffset.x + boxOffset.x,
                                             baseOffset.y + boxOffset.y);
            }
        }
    }

    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        if ([child isKindOfClass:NSDictionary.class]) {
            [self collectCustomScrollResolvedOffsetsInDetailsNode:child
                                                   targetObjectIDs:targetObjectIDs
                                                    axisDirection:nextAxisDirection
                                                      scrollOffset:nextScrollOffset
                                                sliverPaintOffset:nextPaintOffset
                                                    hasPaintOffset:nextHasPaintOffset
                                                        baseOffset:nextBaseOffset
                                                      isScrollRoot:NO
                                                   insideViewport:nextInsideViewport
                                               seenRenderObjectIDs:nextSeenRenderObjectIDs
                                                           result:result];
        }
    }
}

/// Whether this node is a viewport box: everything below it is measured
/// against the viewport instead of the scroll root's own box, so it is the
/// point where a box offset starts to move the coordinate space.
- (BOOL)isViewportInspectorNode:(NSDictionary *)node {
    NSDictionary *renderObject =
        [self renderObjectPropertyFromInspectorNode:node];
    NSString *description =
        [renderObject[@"description"] isKindOfClass:NSString.class]
            ? renderObject[@"description"]
            : nil;
    return [description containsString:@"Viewport"];
}

- (BOOL)sliverContextFromInspectorNode:(NSDictionary *)node
                         axisDirection:(NSString **)axisDirection
                           scrollOffset:(CGFloat *)scrollOffset {
    NSDictionary *renderObject = [self renderObjectPropertyFromInspectorNode:node];
    NSArray *properties = [renderObject[@"properties"] isKindOfClass:NSArray.class]
        ? renderObject[@"properties"]
        : @[];
    NSDictionary *constraints = [self inspectorPropertyNamed:@"constraints"
                                                 inProperties:properties];
    NSString *description = [self inspectorDescriptionForProperty:constraints];
    if (![description containsString:@"SliverConstraints("]) {
        return NO;
    }

    NSRegularExpression *axisRegex = [NSRegularExpression
        regularExpressionWithPattern:@"AxisDirection\\.(down|right|up|left)"
                             options:0
                               error:nil];
    NSTextCheckingResult *axisMatch =
        [axisRegex firstMatchInString:description
                              options:0
                                range:NSMakeRange(0, description.length)];
    NSRegularExpression *scrollRegex = [NSRegularExpression
        regularExpressionWithPattern:@"scrollOffset:\\s*([-+0-9.eE]+)"
                             options:0
                               error:nil];
    NSTextCheckingResult *scrollMatch =
        [scrollRegex firstMatchInString:description
                                options:0
                                  range:NSMakeRange(0, description.length)];
    if (axisMatch.numberOfRanges != 2 || scrollMatch.numberOfRanges != 2) {
        return NO;
    }

    CGFloat parsedScrollOffset = [[description substringWithRange:
        [scrollMatch rangeAtIndex:1]] doubleValue];
    if (!isfinite(parsedScrollOffset)) {
        return NO;
    }
    if (axisDirection != NULL) {
        *axisDirection = [description substringWithRange:[axisMatch rangeAtIndex:1]];
    }
    if (scrollOffset != NULL) {
        *scrollOffset = parsedScrollOffset;
    }
    return YES;
}

- (CGPoint)sliverPaintOffsetFromInspectorNode:(NSDictionary *)node
                                         found:(BOOL *)found {
    NSDictionary *renderObject = [self renderObjectPropertyFromInspectorNode:node];
    NSString *description = [self parentDataDescriptionInValue:renderObject];
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:
            @"paintOffset=Offset\\(\\s*([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)\\s*\\)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:description ?: @""
                                                   options:0
                                                     range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges == 3) {
        CGFloat x = [[description substringWithRange:[match rangeAtIndex:1]]
            doubleValue];
        CGFloat y = [[description substringWithRange:[match rangeAtIndex:2]]
            doubleValue];
        if (isfinite(x) && isfinite(y)) {
            if (found != NULL) {
                *found = YES;
            }
            return CGPointMake(x, y);
        }
    }
    if (found != NULL) {
        *found = NO;
    }
    return CGPointZero;
}

- (CGFloat)sliverCrossAxisOffsetFromInspectorNode:(NSDictionary *)node
                                             found:(BOOL *)found {
    NSDictionary *renderObject = [self renderObjectPropertyFromInspectorNode:node];
    NSString *description = [self parentDataDescriptionInValue:renderObject];
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"crossAxisOffset=\\s*([-+0-9.eE]+)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:description ?: @""
                                                   options:0
                                                     range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges == 2) {
        CGFloat value = [[description substringWithRange:[match rangeAtIndex:1]]
            doubleValue];
        if (isfinite(value)) {
            if (found != NULL) {
                *found = YES;
            }
            return value;
        }
    }
    if (found != NULL) {
        *found = NO;
    }
    return 0;
}

- (NSDictionary<NSString *, NSValue *> *)
    resolvedOffsetsForScrollTargetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                                detailsPayload:(id)payload {
    if (![payload isKindOfClass:NSDictionary.class] ||
        targetObjectIDs.count == 0) {
        return @{};
    }

    NSDictionary *root = payload;
    NSArray *properties = [root[@"properties"] isKindOfClass:NSArray.class]
        ? root[@"properties"]
        : @[];
    NSDictionary *axisProperty =
        [self inspectorPropertyNamed:@"scrollDirection"
                        inProperties:properties];
    NSString *axisDirection =
        [self inspectorDescriptionForProperty:axisProperty];
    if (![axisDirection isEqualToString:@"vertical"] &&
        ![axisDirection isEqualToString:@"horizontal"]) {
        return @{};
    }

    NSDictionary *reverseProperty =
        [self inspectorPropertyNamed:@"reverse" inProperties:properties];
    if ([[self inspectorDescriptionForProperty:reverseProperty]
            isEqualToString:@"true"]) {
        return @{};
    }

    UIEdgeInsets padding = UIEdgeInsetsZero;
    NSDictionary *paddingProperty =
        [self inspectorPropertyNamed:@"padding" inProperties:properties];
    if (paddingProperty != nil &&
        ![self edgeInsetsFromInspectorProperty:paddingProperty value:&padding]) {
        return @{};
    }

    BOOL foundScrollOffset = NO;
    CGFloat scrollOffset =
        [self listViewScrollOffsetFromValue:payload found:&foundScrollOffset];
    if (!foundScrollOffset) {
        return @{};
    }

    NSMutableDictionary<NSString *, NSValue *> *result =
        [NSMutableDictionary dictionary];
    [self collectScrollResolvedOffsetsInDetailsNode:root
                                      targetObjectIDs:targetObjectIDs
                                              padding:padding
                                         scrollOffset:scrollOffset
                                         axisDirection:axisDirection
                                               result:result];
    if (result.count == 0) {
        // Nothing resolved means every item of this ListView or GridView keeps
        // an unresolved frame, so the client cannot draw or place it. Log the
        // reason once per snapshot to make that case diagnosable.
        NSLog(@"[KKFlutterInspectorKit] Scroll item offsets unresolved: "
              @"targets=%@ axis=%@ scrollOffset=%@",
              @(targetObjectIDs.count), axisDirection, @(scrollOffset));
    }
    return result.copy;
}

- (void)collectScrollResolvedOffsetsInDetailsNode:(NSDictionary *)node
                                    targetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                                            padding:(UIEdgeInsets)padding
                                       scrollOffset:(CGFloat)scrollOffset
                                      axisDirection:(NSString *)axisDirection
                                             result:(NSMutableDictionary<NSString *, NSValue *> *)result {
    BOOL foundLayoutOffset = NO;
    CGFloat layoutOffset =
        [self sliverLayoutOffsetFromInspectorNode:node
                                           found:&foundLayoutOffset];
    if (foundLayoutOffset) {
        NSString *targetObjectID =
            [self firstTargetObjectID:targetObjectIDs inDetailsNode:node];
        if (targetObjectID.length > 0 && result[targetObjectID] == nil) {
            BOOL foundCrossAxisOffset = NO;
            CGFloat crossAxisOffset =
                [self sliverCrossAxisOffsetFromInspectorNode:node
                                                       found:&foundCrossAxisOffset];
            if (!foundCrossAxisOffset) {
                crossAxisOffset = 0;
            }
            CGPoint offset = [axisDirection isEqualToString:@"vertical"]
                ? CGPointMake(padding.left + crossAxisOffset,
                              padding.top + layoutOffset - scrollOffset)
                : CGPointMake(padding.left + layoutOffset - scrollOffset,
                              padding.top + crossAxisOffset);
            result[targetObjectID] = [NSValue valueWithCGPoint:offset];
            return;
        }
    }

    if (result.count == targetObjectIDs.count) {
        return;
    }
    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        if (![child isKindOfClass:NSDictionary.class]) {
            continue;
        }
        [self collectScrollResolvedOffsetsInDetailsNode:child
                                          targetObjectIDs:targetObjectIDs
                                                  padding:padding
                                             scrollOffset:scrollOffset
                                            axisDirection:axisDirection
                                                   result:result];
    }
}

- (NSString *)firstTargetObjectID:(NSSet<NSString *> *)targetObjectIDs
                     inDetailsNode:(NSDictionary *)node {
    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:node];
    if ([targetObjectIDs containsObject:objectID]) {
        return objectID;
    }

    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        if (![child isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *match = [self firstTargetObjectID:targetObjectIDs
                                      inDetailsNode:child];
        if (match.length > 0) {
            return match;
        }
    }
    return nil;
}

- (CGFloat)sliverLayoutOffsetFromInspectorNode:(NSDictionary *)node
                                         found:(BOOL *)found {
    NSDictionary *renderObject =
        [self renderObjectPropertyFromInspectorNode:node];
    NSString *description = [self parentDataDescriptionInValue:renderObject];
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"layoutOffset=\\s*([-+0-9.eE]+)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:description ?: @""
                                                   options:0
                                                     range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges == 2) {
        CGFloat value = [[description substringWithRange:[match rangeAtIndex:1]]
            doubleValue];
        if (isfinite(value)) {
            if (found != NULL) {
                *found = YES;
            }
            return value;
        }
    }
    if (found != NULL) {
        *found = NO;
    }
    return 0;
}

- (CGFloat)listViewScrollOffsetFromValue:(id)value found:(BOOL *)found {
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        if ([dictionary[@"propertyType"] isEqual:@"ViewportOffset"] &&
            [dictionary[@"description"] isKindOfClass:NSString.class]) {
            NSString *description = dictionary[@"description"];
            NSRegularExpression *regex = [NSRegularExpression
                regularExpressionWithPattern:@"\\boffset:\\s*([-+0-9.eE]+)"
                                     options:0
                                       error:nil];
            NSTextCheckingResult *match =
                [regex firstMatchInString:description
                                  options:0
                                    range:NSMakeRange(0, description.length)];
            if (match.numberOfRanges == 2) {
                CGFloat offset = [[description substringWithRange:
                    [match rangeAtIndex:1]] doubleValue];
                if (isfinite(offset)) {
                    if (found != NULL) {
                        *found = YES;
                    }
                    return offset;
                }
            }
        }
        for (id child in dictionary.allValues) {
            BOOL childFound = NO;
            CGFloat offset = [self listViewScrollOffsetFromValue:child
                                                            found:&childFound];
            if (childFound) {
                if (found != NULL) {
                    *found = YES;
                }
                return offset;
            }
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id child in value) {
            BOOL childFound = NO;
            CGFloat offset = [self listViewScrollOffsetFromValue:child
                                                            found:&childFound];
            if (childFound) {
                if (found != NULL) {
                    *found = YES;
                }
                return offset;
            }
        }
    }

    if (found != NULL) {
        *found = NO;
    }
    return 0;
}

- (NSDictionary *)inspectorPropertyNamed:(NSString *)name
                             inProperties:(NSArray *)properties {
    for (id value in properties) {
        if ([value isKindOfClass:NSDictionary.class] &&
            [value[@"name"] isEqual:name]) {
            return value;
        }
    }
    return nil;
}

- (NSString *)inspectorDescriptionForProperty:(NSDictionary *)property {
    if ([property[@"description"] isKindOfClass:NSString.class]) {
        return property[@"description"];
    }
    if ([property[@"value"] isKindOfClass:NSString.class]) {
        return property[@"value"];
    }
    return nil;
}

- (BOOL)edgeInsetsFromInspectorProperty:(NSDictionary *)property
                                  value:(UIEdgeInsets *)value {
    NSString *description = [self inspectorDescriptionForProperty:property];
    if (description.length == 0 ||
        [description isEqualToString:@"null"] ||
        [description isEqualToString:@"EdgeInsets.zero"]) {
        if (value != NULL) {
            *value = UIEdgeInsetsZero;
        }
        return YES;
    }

    NSRegularExpression *allRegex = [NSRegularExpression
        regularExpressionWithPattern:@"^EdgeInsets\\.all\\(\\s*([-+0-9.eE]+)\\s*\\)$"
                             options:0
                               error:nil];
    NSTextCheckingResult *allMatch =
        [allRegex firstMatchInString:description
                             options:0
                               range:NSMakeRange(0, description.length)];
    if (allMatch.numberOfRanges == 2) {
        CGFloat inset = [[description substringWithRange:
            [allMatch rangeAtIndex:1]] doubleValue];
        if (isfinite(inset)) {
            if (value != NULL) {
                *value = UIEdgeInsetsMake(inset, inset, inset, inset);
            }
            return YES;
        }
    }

    NSRegularExpression *fourValueRegex = [NSRegularExpression
        regularExpressionWithPattern:
            @"^EdgeInsets(?:\\.fromLTRB)?\\(\\s*([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)\\s*\\)$"
                             options:0
                               error:nil];
    NSTextCheckingResult *fourValueMatch =
        [fourValueRegex firstMatchInString:description
                                   options:0
                                     range:NSMakeRange(0, description.length)];
    if (fourValueMatch.numberOfRanges == 5) {
        CGFloat left = [[description substringWithRange:
            [fourValueMatch rangeAtIndex:1]] doubleValue];
        CGFloat top = [[description substringWithRange:
            [fourValueMatch rangeAtIndex:2]] doubleValue];
        CGFloat right = [[description substringWithRange:
            [fourValueMatch rangeAtIndex:3]] doubleValue];
        CGFloat bottom = [[description substringWithRange:
            [fourValueMatch rangeAtIndex:4]] doubleValue];
        if (isfinite(left) && isfinite(top) && isfinite(right) &&
            isfinite(bottom)) {
            if (value != NULL) {
                *value = UIEdgeInsetsMake(top, left, bottom, right);
            }
            return YES;
        }
    }

    if ([description containsString:@"EdgeInsets.symmetric("]) {
        CGFloat horizontal = 0;
        CGFloat vertical = 0;
        NSRegularExpression *horizontalRegex = [NSRegularExpression
            regularExpressionWithPattern:@"horizontal:\\s*([-+0-9.eE]+)"
                                 options:0
                                   error:nil];
        NSRegularExpression *verticalRegex = [NSRegularExpression
            regularExpressionWithPattern:@"vertical:\\s*([-+0-9.eE]+)"
                                 options:0
                                   error:nil];
        NSTextCheckingResult *horizontalMatch =
            [horizontalRegex firstMatchInString:description
                                         options:0
                                           range:NSMakeRange(0, description.length)];
        NSTextCheckingResult *verticalMatch =
            [verticalRegex firstMatchInString:description
                                       options:0
                                         range:NSMakeRange(0, description.length)];
        if (horizontalMatch.numberOfRanges == 2) {
            horizontal = [[description substringWithRange:
                [horizontalMatch rangeAtIndex:1]] doubleValue];
        }
        if (verticalMatch.numberOfRanges == 2) {
            vertical = [[description substringWithRange:
                [verticalMatch rangeAtIndex:1]] doubleValue];
        }
        if (isfinite(horizontal) && isfinite(vertical)) {
            if (value != NULL) {
                *value = UIEdgeInsetsMake(vertical, horizontal,
                                          vertical, horizontal);
            }
            return YES;
        }
    }

    if ([description containsString:@"EdgeInsets.only("]) {
        CGFloat insets[4] = {0, 0, 0, 0};
        NSArray<NSString *> *edges = @[@"left", @"top", @"right", @"bottom"];
        BOOL matchedEdge = NO;
        for (NSUInteger index = 0; index < edges.count; index++) {
            NSString *pattern = [NSString stringWithFormat:
                @"%@:\\s*([-+0-9.eE]+)", edges[index]];
            NSRegularExpression *regex = [NSRegularExpression
                regularExpressionWithPattern:pattern options:0 error:nil];
            NSTextCheckingResult *match =
                [regex firstMatchInString:description
                                  options:0
                                    range:NSMakeRange(0, description.length)];
            if (match.numberOfRanges != 2) {
                continue;
            }
            CGFloat inset = [[description substringWithRange:
                [match rangeAtIndex:1]] doubleValue];
            if (!isfinite(inset)) {
                return NO;
            }
            insets[index] = inset;
            matchedEdge = YES;
        }
        if (matchedEdge) {
            if (value != NULL) {
                *value = UIEdgeInsetsMake(insets[1], insets[0],
                                          insets[3], insets[2]);
            }
            return YES;
        }
    }
    return NO;
}

- (NSDictionary<NSString *, NSValue *> *)
    resolvedOffsetsForTargetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                   rootRenderObjectID:(NSString *)rootRenderObjectID
                       detailsPayload:(id)payload
                  targetLocalOffsets:(NSDictionary<NSString *, NSValue *> *)targetLocalOffsets {
    if (![payload isKindOfClass:NSDictionary.class] ||
        targetObjectIDs.count == 0) {
        return @{};
    }

    NSDictionary *root = payload;
    NSMutableSet<NSString *> *rootRenderObjectIDs = [NSMutableSet set];
    NSDictionary *rootRenderObject =
        [self renderObjectPropertyFromInspectorNode:root];
    NSString *detailsRootRenderObjectID =
        [rootRenderObject[@"valueId"] isKindOfClass:NSString.class]
            ? rootRenderObject[@"valueId"]
            : nil;
    if (rootRenderObjectID.length > 0) {
        [rootRenderObjectIDs addObject:rootRenderObjectID];
    }
    if (detailsRootRenderObjectID.length > 0) {
        [rootRenderObjectIDs addObject:detailsRootRenderObjectID];
    }

    NSMutableDictionary<NSString *, NSValue *> *result =
        [NSMutableDictionary dictionary];
    NSArray *children = [root[@"children"] isKindOfClass:NSArray.class]
        ? root[@"children"]
        : @[];
    for (id child in children) {
        if (![child isKindOfClass:NSDictionary.class]) {
            continue;
        }
        [self collectResolvedOffsetsInDetailsNode:child
                                  targetObjectIDs:targetObjectIDs
                                 cumulativeOffset:CGPointZero
                             hasNonZeroBridgeOffset:NO
                              seenRenderObjectIDs:rootRenderObjectIDs
                              targetLocalOffsets:targetLocalOffsets
                                           result:result];
    }
    return result.copy;
}

- (void)collectResolvedOffsetsInDetailsNode:(NSDictionary *)node
                            targetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                           cumulativeOffset:(CGPoint)cumulativeOffset
                       hasNonZeroBridgeOffset:(BOOL)hasNonZeroBridgeOffset
                        seenRenderObjectIDs:(NSSet<NSString *> *)seenRenderObjectIDs
                       targetLocalOffsets:(NSDictionary<NSString *, NSValue *> *)targetLocalOffsets
                                     result:(NSMutableDictionary<NSString *, NSValue *> *)result {
    CGPoint nextOffset = cumulativeOffset;
    BOOL nextHasNonZeroBridgeOffset = hasNonZeroBridgeOffset;
    NSMutableSet<NSString *> *nextSeenRenderObjectIDs =
        [seenRenderObjectIDs mutableCopy];
    NSDictionary *renderObject =
        [self renderObjectPropertyFromInspectorNode:node];
    NSString *renderObjectID =
        [renderObject[@"valueId"] isKindOfClass:NSString.class]
            ? renderObject[@"valueId"]
            : nil;
    BOOL foundRenderOffset = NO;
    CGPoint renderOffset = CGPointZero;
    if (renderObjectID.length > 0 &&
        ![nextSeenRenderObjectIDs containsObject:renderObjectID]) {
        [nextSeenRenderObjectIDs addObject:renderObjectID];
        renderOffset = [self parentDataOffsetFromValue:renderObject
                                                 found:&foundRenderOffset];
        if (foundRenderOffset) {
            nextOffset.x += renderOffset.x;
            nextOffset.y += renderOffset.y;
            if (fabs(renderOffset.x) > 0.01 || fabs(renderOffset.y) > 0.01) {
                nextHasNonZeroBridgeOffset = YES;
            }
        }
    }

    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:node];
    if (hasNonZeroBridgeOffset &&
        [targetObjectIDs containsObject:objectID]) {
        // getDetailsSubtree often stops at the public Widget node. In that
        // shape the accumulated value contains the hidden Row/Padding bridge,
        // while the target's own RenderObject parentData is only present in
        // getLayoutExplorerNode. Add that final local segment so siblings such
        // as a button Icon and Text do not collapse onto the same origin.
        CGPoint targetOffset = cumulativeOffset;
        NSValue *targetLocalOffsetValue = targetLocalOffsets[objectID];
        if (targetLocalOffsetValue != nil) {
            CGPoint targetLocalOffset = targetLocalOffsetValue.CGPointValue;
            targetOffset.x += targetLocalOffset.x;
            targetOffset.y += targetLocalOffset.y;
        } else if (foundRenderOffset) {
            targetOffset.x += renderOffset.x;
            targetOffset.y += renderOffset.y;
        }
        result[objectID] = [NSValue valueWithCGPoint:targetOffset];
    }

    if (result.count == targetObjectIDs.count) {
        return;
    }
    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        if (![child isKindOfClass:NSDictionary.class]) {
            continue;
        }
        [self collectResolvedOffsetsInDetailsNode:child
                                  targetObjectIDs:targetObjectIDs
                                 cumulativeOffset:nextOffset
                             hasNonZeroBridgeOffset:nextHasNonZeroBridgeOffset
                              seenRenderObjectIDs:nextSeenRenderObjectIDs
                              targetLocalOffsets:targetLocalOffsets
                                           result:result];
    }
}

- (NSDictionary *)renderObjectPropertyFromInspectorNode:(NSDictionary *)node {
    if ([node[@"renderObject"] isKindOfClass:NSDictionary.class]) {
        return node[@"renderObject"];
    }
    NSArray *properties = [node[@"properties"] isKindOfClass:NSArray.class]
        ? node[@"properties"]
        : @[];
    for (id value in properties) {
        if ([value isKindOfClass:NSDictionary.class] &&
            [value[@"name"] isEqual:@"renderObject"]) {
            return value;
        }
    }
    return nil;
}

- (CGPoint)parentDataOffsetFromValue:(id)value found:(BOOL *)found {
    NSString *description = [self parentDataDescriptionInValue:value];
    if (description.length > 0) {
        NSRegularExpression *regex = [NSRegularExpression
            regularExpressionWithPattern:
                @"offset=Offset\\(\\s*([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)\\s*\\)"
                                 options:0
                                   error:nil];
        NSTextCheckingResult *match =
            [regex firstMatchInString:description
                              options:0
                                range:NSMakeRange(0, description.length)];
        if (match.numberOfRanges == 3) {
            double x = [[description substringWithRange:
                [match rangeAtIndex:1]] doubleValue];
            double y = [[description substringWithRange:
                [match rangeAtIndex:2]] doubleValue];
            if (isfinite(x) && isfinite(y)) {
                if (found != NULL) {
                    *found = YES;
                }
                return CGPointMake(x, y);
            }
        }
    }

    if (found != NULL) {
        *found = NO;
    }
    return CGPointZero;
}

- (NSString *)parentDataDescriptionInValue:(id)value {
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        if ([dictionary[@"name"] isEqual:@"parentData"] &&
            [dictionary[@"description"] isKindOfClass:NSString.class]) {
            return dictionary[@"description"];
        }
        for (id child in dictionary.allValues) {
            NSString *description =
                [self parentDataDescriptionInValue:child];
            if (description.length > 0) {
                return description;
            }
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id child in value) {
            NSString *description =
                [self parentDataDescriptionInValue:child];
            if (description.length > 0) {
                return description;
            }
        }
    }
    return nil;
}

- (NSArray *)resolvedCardPropertiesFromDetailsPayload:(id)payload {
    if (![payload isKindOfClass:NSDictionary.class]) {
        return @[];
    }

    NSDictionary *paddingNode = [self firstInspectorNodeWithWidgetType:@"Padding"
                                                                inValue:payload];
    NSMutableArray *result = [NSMutableArray array];

    NSArray *paddingProperties =
        [paddingNode[@"properties"] isKindOfClass:NSArray.class]
            ? paddingNode[@"properties"]
            : @[];
    for (id value in paddingProperties) {
        if (![value isKindOfClass:NSDictionary.class] ||
            ![value[@"name"] isEqual:@"padding"]) {
            continue;
        }
        NSMutableDictionary *marginProperty = [value mutableCopy];
        marginProperty[@"name"] = @"margin";
        [result addObject:marginProperty.copy];
        break;
    }

    [result addObjectsFromArray:
        [self resolvedMaterialPropertiesFromDetailsPayload:payload]];
    return result.copy;
}

- (NSArray *)resolvedMaterialPropertiesFromDetailsPayload:(id)payload {
    if (![payload isKindOfClass:NSDictionary.class]) {
        return @[];
    }
    NSDictionary *materialNode = [self firstInspectorNodeWithWidgetType:@"Material"
                                                                 inValue:payload];
    NSSet<NSString *> *materialPropertyNames = [NSSet setWithArray:@[
        @"color", @"shadowColor", @"surfaceTintColor", @"elevation", @"shape",
    ]];
    NSArray *materialProperties =
        [materialNode[@"properties"] isKindOfClass:NSArray.class]
            ? materialNode[@"properties"]
            : @[];
    NSMutableArray *result = [NSMutableArray array];
    for (id value in materialProperties) {
        if ([value isKindOfClass:NSDictionary.class] &&
            [materialPropertyNames containsObject:value[@"name"]]) {
            [result addObject:value];
        }
    }
    return result.copy;
}

- (NSDictionary *)firstInspectorNodeWithWidgetType:(NSString *)widgetType
                                            inValue:(id)value {
    if (![value isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    NSDictionary *node = value;
    NSString *candidate = [node[@"widgetRuntimeType"] isKindOfClass:NSString.class]
        ? node[@"widgetRuntimeType"]
        : ([node[@"description"] isKindOfClass:NSString.class]
               ? node[@"description"]
               : nil);
    if ([candidate isEqualToString:widgetType]) {
        return node;
    }
    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        NSDictionary *match = [self firstInspectorNodeWithWidgetType:widgetType
                                                              inValue:child];
        if (match != nil) {
            return match;
        }
    }
    return nil;
}


@end

