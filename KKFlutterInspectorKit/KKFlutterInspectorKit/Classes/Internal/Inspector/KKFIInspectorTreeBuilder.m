#import "KKFIInspectorTreeBuilder.h"

#import <math.h>

#import "KKFIInspectorJSON.h"
#import "../Model/KKFIInspectorModels.h"

static NSString *const KKFIInspectorTreeBuilderErrorDomain =
    @"KKFIInspectorTreeBuilderErrorDomain";

@implementation KKFIInspectorTreeBuilder

+ (KKFIHierarchySnapshot *)
    snapshotFromLayoutPayload:(NSDictionary *)layoutPayload
                widgetPayload:(id)widgetPayload
         widgetPropertiesByID:(NSDictionary<NSString *, NSArray *> *)widgetPropertiesByID
          resolvedOffsetsByID:(NSDictionary<NSString *, NSValue *> *)resolvedOffsetsByID
                 rootObjectID:(NSString *)rootObjectID
             fallbackRootSize:(CGSize)fallbackRootSize
                    isolateID:(NSString *)isolateID
                  objectGroup:(NSString *)objectGroup
                   snapshotID:(NSString *)snapshotID
          excludedWidgetTypes:(NSSet<NSString *> *)excludedWidgetTypes
                        error:(NSError **)error {
    if (rootObjectID.length == 0 || layoutPayload.count == 0) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:KKFIInspectorTreeBuilderErrorDomain
                           code:1
                       userInfo:@{NSLocalizedDescriptionKey :
                                      @"The Flutter hierarchy payload has no root object."}];
        }
        return nil;
    }

    NSMutableDictionary<NSString *, NSDictionary *> *metadata =
        [NSMutableDictionary dictionary];
    [self collectMetadataFromValue:widgetPayload into:metadata];
    NSMutableArray<NSDictionary *> *rootChildrenLayouts =
        [NSMutableArray array];

    NSArray<KKFIInspectorElement *> *roots =
        [self elementsFromLayoutNode:layoutPayload
                        metadataByID:metadata
                widgetPropertiesByID:widgetPropertiesByID
                resolvedOffsetsByID:resolvedOffsetsByID
            appliedRenderObjectOffsetIDs:[NSSet set]
                   accumulatedOffset:CGPointZero
                        geometryScale:CGSizeMake(1.0, 1.0)
             hasResolvedAncestorOffset:NO
                       inferredOffset:CGPointZero
                     hasInferredOffset:NO
                    visualParentSize:CGSizeZero
                  hasVisualParentSize:NO
                       forcedObjectID:rootObjectID
                           isolateID:isolateID
                         objectGroup:objectGroup
                          snapshotID:snapshotID
                 excludedWidgetTypes:excludedWidgetTypes
       childrenLayoutsForVisualParent:rootChildrenLayouts
                     layoutModifiers:@[]
                         interactions:@[]
                             semantics:@[]
                    fallbackRootSize:fallbackRootSize];
    KKFIInspectorElement *root = roots.firstObject;
    if (root == nil) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:KKFIInspectorTreeBuilderErrorDomain
                           code:2
                       userInfo:@{NSLocalizedDescriptionKey :
                                      @"The Flutter hierarchy did not contain an inspectable root."}];
        }
        return nil;
    }

    return [[KKFIHierarchySnapshot alloc] initWithSnapshotID:snapshotID
                                                  objectGroup:objectGroup
                                                    isolateID:isolateID
                                                  rootElement:root];
}

+ (NSArray<KKFIInspectorElement *> *)elementsFromLayoutNode:(NSDictionary *)layoutNode
                                               metadataByID:(NSDictionary<NSString *, NSDictionary *> *)metadataByID
                                       widgetPropertiesByID:(NSDictionary<NSString *, NSArray *> *)widgetPropertiesByID
                                        resolvedOffsetsByID:(NSDictionary<NSString *, NSValue *> *)resolvedOffsetsByID
                               appliedRenderObjectOffsetIDs:(NSSet<NSString *> *)appliedRenderObjectOffsetIDs
                                          accumulatedOffset:(CGPoint)accumulatedOffset
                                               geometryScale:(CGSize)geometryScale
                                hasResolvedAncestorOffset:(BOOL)hasResolvedAncestorOffset
                                              inferredOffset:(CGPoint)inferredOffset
                                            hasInferredOffset:(BOOL)hasInferredOffset
                                           visualParentSize:(CGSize)visualParentSize
                                         hasVisualParentSize:(BOOL)hasVisualParentSize
                                             forcedObjectID:(NSString *)forcedObjectID
                                                  isolateID:(NSString *)isolateID
                                                objectGroup:(NSString *)objectGroup
                                                 snapshotID:(NSString *)snapshotID
                                        excludedWidgetTypes:(NSSet<NSString *> *)excludedWidgetTypes
                             childrenLayoutsForVisualParent:(NSMutableArray<NSDictionary *> *)childrenLayoutsForVisualParent
                                            layoutModifiers:(NSArray<NSDictionary *> *)layoutModifiers interactions:(NSArray<NSDictionary *> *)interactions
                                                  semantics:(NSArray<NSDictionary *> *)semantics
                                           fallbackRootSize:(CGSize)fallbackRootSize {
    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:layoutNode];
    if (objectID.length == 0) {
        objectID = forcedObjectID;
    }

    NSDictionary *metadata = objectID.length > 0 ? metadataByID[objectID] : nil;
    NSString *widgetType =
        [self widgetTypeFromNode:layoutNode metadata:metadata] ?: @"Unknown";
    NSString *baseWidgetType =
        [[widgetType componentsSeparatedByString:@"<"] firstObject] ?: widgetType;
    NSString *renderObjectType = [self renderObjectTypeFromNode:layoutNode];
    BOOL excluded = [excludedWidgetTypes containsObject:widgetType] ||
        [excludedWidgetTypes containsObject:baseWidgetType];
    NSString *hierarchyRole = excluded
        ? @"transparent"
        : [self hierarchyRoleForWidgetType:baseWidgetType
                          renderObjectType:renderObjectType];

    NSString *renderObjectID = [self renderObjectIDFromNode:layoutNode];
    BOOL renderObjectOffsetAlreadyApplied = renderObjectID.length > 0 &&
        [appliedRenderObjectOffsetIDs containsObject:renderObjectID];
    NSMutableSet<NSString *> *nextAppliedRenderObjectOffsetIDs =
        [appliedRenderObjectOffsetIDs mutableCopy];

    BOOL foundOffset = NO;
    NSValue *resolvedOffsetValue = objectID.length > 0
        ? resolvedOffsetsByID[objectID]
        : nil;
    CGPoint localOffset = CGPointZero;
    if (renderObjectOffsetAlreadyApplied) {
        // ParentDataWidget nodes such as LayoutId and their visible child can
        // reference the exact same RenderObject. Its parentData offset belongs
        // to that RenderObject and must only be applied once along the path.
        foundOffset = YES;
    } else if (resolvedOffsetValue != nil) {
        localOffset = resolvedOffsetValue.CGPointValue;
        foundOffset = YES;
    } else {
        NSDictionary *parentRenderElement =
            [layoutNode[@"parentRenderElement"] isKindOfClass:NSDictionary.class]
                ? layoutNode[@"parentRenderElement"]
                : nil;
        NSString *parentRenderObjectID =
            [self renderObjectIDFromNode:parentRenderElement];
        BOOL parentRenderObjectOffsetAlreadyApplied =
            parentRenderObjectID.length > 0 &&
            [appliedRenderObjectOffsetIDs containsObject:parentRenderObjectID];
        localOffset = [self offsetFromNode:layoutNode
              useParentRenderElementOffset:
                  [hierarchyRole isEqualToString:@"visual"] &&
                  !parentRenderObjectOffsetAlreadyApplied
                                     found:&foundOffset];
    }
    if (!renderObjectOffsetAlreadyApplied && resolvedOffsetValue == nil &&
        !foundOffset && hasInferredOffset) {
        localOffset = inferredOffset;
        foundOffset = YES;
    }
    if (foundOffset && !renderObjectOffsetAlreadyApplied &&
        renderObjectID.length > 0) {
        [nextAppliedRenderObjectOffsetIDs addObject:renderObjectID];
    }
    CGPoint combinedOffset = CGPointMake(
        accumulatedOffset.x + localOffset.x * geometryScale.width,
        accumulatedOffset.y + localOffset.y * geometryScale.height);

    BOOL foundSize = NO;
    CGSize size = [self sizeFromNode:layoutNode found:&foundSize];
    if (!foundSize && forcedObjectID.length > 0 &&
        fallbackRootSize.width > 0 && fallbackRootSize.height > 0) {
        size = fallbackRootSize;
        foundSize = YES;
    }
    CGSize displayedSize = CGSizeMake(size.width * geometryScale.width,
                                      size.height * geometryScale.height);

    BOOL isSpacingContent = [baseWidgetType isEqualToString:@"SizedBox"] ||
        [baseWidgetType isEqualToString:@"Spacer"];
    // A spacing widget is intentional layout content even when one dimension
    // is zero (for example SizedBox(height: 8) inside a Column). Keep it in the
    // hierarchy so clients can display the constraint instead of silently
    // dropping the node because it has no drawable area.
    BOOL hasGeometry = objectID.length > 0 && foundSize &&
        (isSpacingContent || (size.width > 0 && size.height > 0));
    BOOL isVisual = hasGeometry && [hierarchyRole isEqualToString:@"visual"];
    BOOL isRoot = forcedObjectID.length > 0;
    BOOL fillsVisualParent = hasVisualParentSize && foundSize &&
        fabs(size.width - visualParentSize.width) < 0.01 &&
        fabs(size.height - visualParentSize.height) < 0.01 &&
        fabs(accumulatedOffset.x) < 0.01 &&
        fabs(accumulatedOffset.y) < 0.01;
    BOOL inheritsResolvedAncestorOffset = !foundOffset &&
        hasResolvedAncestorOffset &&
        [self nodeMatchesParentRenderElementSize:layoutNode];
    BOOL hasResolvedFrame = foundSize &&
        (foundOffset || isRoot || fillsVisualParent ||
         inheritsResolvedAncestorOffset);

    NSDictionary *relation = [self relationForLayoutNode:layoutNode
                                                      type:baseWidgetType
                                          renderObjectType:renderObjectType];
    NSArray<NSDictionary *> *nextLayoutModifiers = layoutModifiers;
    NSArray<NSDictionary *> *nextInteractions = interactions;
    NSArray<NSDictionary *> *nextSemantics = semantics;
    if ([hierarchyRole isEqualToString:@"childrenLayout"]) {
        [childrenLayoutsForVisualParent addObject:relation];
    } else if ([hierarchyRole isEqualToString:@"layoutModifier"]) {
        nextLayoutModifiers =
            [layoutModifiers arrayByAddingObject:relation];
    } else if ([hierarchyRole isEqualToString:@"interaction"]) {
        nextInteractions = [interactions arrayByAddingObject:relation];
    } else if ([hierarchyRole isEqualToString:@"semantics"]) {
        nextSemantics = [semantics arrayByAddingObject:relation];
    }

    NSArray *childrenJSON = [layoutNode[@"children"] isKindOfClass:NSArray.class]
        ? layoutNode[@"children"]
        : @[];
    NSArray<NSValue *> *inferredChildOffsets =
        [self inferredOffsetsForNode:layoutNode
                          widgetType:baseWidgetType
                          properties:widgetPropertiesByID[objectID]
                            children:childrenJSON];
    NSMutableArray<KKFIInspectorElement *> *children = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *childLayouts = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *nextChildrenLayouts =
        isVisual ? childLayouts : childrenLayoutsForVisualParent;
    CGPoint nextAccumulatedOffset = isVisual ? CGPointZero : combinedOffset;
    CGSize nextGeometryScale = geometryScale;
    CGPoint fittedChildOffset = CGPointZero;
    CGSize fittedChildScale = CGSizeMake(1.0, 1.0);
    BOOL appliesFittedBoxTransform = !isVisual && childrenJSON.count == 1 &&
        [baseWidgetType isEqualToString:@"FittedBox"] &&
        [childrenJSON.firstObject isKindOfClass:NSDictionary.class] &&
        [self fittedBoxTransformFromNode:layoutNode
                              childNode:childrenJSON.firstObject
                                 offset:&fittedChildOffset
                                  scale:&fittedChildScale];
    if (appliesFittedBoxTransform) {
        nextAccumulatedOffset = CGPointMake(
            combinedOffset.x + fittedChildOffset.x * geometryScale.width,
            combinedOffset.y + fittedChildOffset.y * geometryScale.height);
        nextGeometryScale = CGSizeMake(
            geometryScale.width * fittedChildScale.width,
            geometryScale.height * fittedChildScale.height);
    }
    BOOL nextHasResolvedAncestorOffset = isVisual
        ? NO
        : (hasResolvedAncestorOffset || foundOffset);
    NSArray<NSDictionary *> *childLayoutModifiers =
        isVisual ? @[] : nextLayoutModifiers;
    NSArray<NSDictionary *> *childInteractions =
        isVisual ? @[] : nextInteractions;
    NSArray<NSDictionary *> *childSemantics = isVisual ? @[] : nextSemantics;
    [childrenJSON enumerateObjectsUsingBlock:^(id value,
                                                NSUInteger index,
                                                BOOL *stop) {
        if (![value isKindOfClass:NSDictionary.class]) {
            return;
        }
        NSValue *inferredChildOffset =
            index < inferredChildOffsets.count ? inferredChildOffsets[index] : nil;
        if (inferredChildOffset == nil && appliesFittedBoxTransform && index == 0) {
            // RenderFittedBox positions its child through a paint transform,
            // so the child normally has no BoxParentData offset. The transform
            // above fully resolves its origin; zero is authoritative here.
            inferredChildOffset = [NSValue valueWithCGPoint:CGPointZero];
        }
        [children addObjectsFromArray:
            [self elementsFromLayoutNode:value
                            metadataByID:metadataByID
                    widgetPropertiesByID:widgetPropertiesByID
                    resolvedOffsetsByID:resolvedOffsetsByID
            appliedRenderObjectOffsetIDs:nextAppliedRenderObjectOffsetIDs
                       accumulatedOffset:nextAccumulatedOffset
                            geometryScale:nextGeometryScale
                 hasResolvedAncestorOffset:nextHasResolvedAncestorOffset
                           inferredOffset:inferredChildOffset.CGPointValue
                         hasInferredOffset:inferredChildOffset != nil
                        visualParentSize:isVisual ? size : visualParentSize
                      hasVisualParentSize:isVisual ? foundSize : hasVisualParentSize
                           forcedObjectID:nil
                               isolateID:isolateID
                              objectGroup:objectGroup
                             snapshotID:snapshotID
                    excludedWidgetTypes:excludedWidgetTypes
          childrenLayoutsForVisualParent:nextChildrenLayouts
                        layoutModifiers:childLayoutModifiers
                            interactions:childInteractions
                                semantics:childSemantics
                        fallbackRootSize:CGSizeZero]];
    }];

    if (!isVisual) {
        return children.copy;
    }

    NSString *description =
        [layoutNode[@"description"] isKindOfClass:NSString.class]
            ? layoutNode[@"description"]
            : ([metadata[@"description"] isKindOfClass:NSString.class]
                   ? metadata[@"description"]
                   : widgetType);
    description = description ?: @"";
    NSString *nodeKind = [self kindForVisualType:baseWidgetType];
    NSString *paintRole = [self paintRoleForWidgetType:baseWidgetType
                                      renderObjectType:renderObjectType];
    NSDictionary *nativeDecoration =
        [self nativeDecorationFromLayoutNode:layoutNode
                            renderObjectType:renderObjectType
                                  widgetType:baseWidgetType
                                  properties:widgetPropertiesByID[objectID]];
    NSString *textPreview =
        [metadata[@"textPreview"] isKindOfClass:NSString.class]
            ? metadata[@"textPreview"]
            : ([layoutNode[@"textPreview"] isKindOfClass:NSString.class]
                   ? layoutNode[@"textPreview"]
                   : nil);
    BOOL captureEligible = YES;
    NSString *renderStrategy = children.count == 0
        ? @"flutterLeafScreenshot"
        : @"flutterSubtreeScreenshot";
    if ([paintRole isEqualToString:@"layoutOnly"]) {
        renderStrategy = @"layoutOnly";
        captureEligible = NO;
    } else if (nativeDecoration != nil) {
        renderStrategy = @"nativeViewDecoration";
        captureEligible = NO;
    } else if (children.count > 0 &&
               ([paintRole isEqualToString:@"selfPaint"] ||
                [paintRole isEqualToString:@"paintEffect"])) {
        // Inspector screenshots include the complete render subtree. If this
        // node paints but its own pixels cannot be reconstructed from a
        // conservative nativeDecoration, keep the subtree atomic in preview.
        renderStrategy = @"atomicSubtreeScreenshot";
    }
    NSArray<NSString *> *capabilities =
        [self capabilitiesForWidgetType:baseWidgetType
                       renderObjectType:renderObjectType
                              paintRole:paintRole
                       nativeDecoration:nativeDecoration];
    KKFIElementReference *reference = [[KKFIElementReference alloc]
        initWithObjectID:objectID
             objectGroup:objectGroup
               isolateID:isolateID
              snapshotID:snapshotID];
    KKFIInspectorElement *element = [[KKFIInspectorElement alloc]
        initWithReference:reference
               widgetType:widgetType
       elementDescription:description
         renderObjectType:renderObjectType
                  nodeKind:nodeKind
                 paintRole:paintRole
            renderStrategy:renderStrategy
           captureEligible:captureEligible
               textPreview:textPreview
          nativeDecoration:nativeDecoration
             capabilities:capabilities
                    frame:CGRectMake(combinedOffset.x, combinedOffset.y,
                                     displayedSize.width, displayedSize.height)
                 hasFrame:hasResolvedFrame
                  rawJSON:layoutNode
           childrenLayouts:childLayouts
           layoutModifiers:nextLayoutModifiers
              interactions:nextInteractions
                  semantics:nextSemantics
                 children:children];
    return @[ element ];
}

+ (void)collectMetadataFromValue:(id)value
                            into:(NSMutableDictionary<NSString *, NSDictionary *> *)metadata {
    if ([value isKindOfClass:NSArray.class]) {
        for (id child in value) {
            [self collectMetadataFromValue:child into:metadata];
        }
        return;
    }
    if (![value isKindOfClass:NSDictionary.class]) {
        return;
    }

    NSDictionary *node = value;
    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:node];
    if (objectID.length > 0) {
        NSMutableDictionary *merged =
            [metadata[objectID] mutableCopy] ?: [NSMutableDictionary dictionary];
        for (NSString *key in @[
                 @"widgetRuntimeType", @"runtimeType", @"type", @"description",
                 @"textPreview", @"createdByLocalProject"
             ]) {
            if (node[key] != nil && node[key] != NSNull.null) {
                merged[key] = node[key];
            }
        }
        metadata[objectID] = merged;
    }

    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        [self collectMetadataFromValue:child into:metadata];
    }
}

+ (NSString *)widgetTypeFromNode:(NSDictionary *)node
                         metadata:(NSDictionary *)metadata {
    for (id value in @[
             metadata[@"widgetRuntimeType"] ?: NSNull.null,
             metadata[@"runtimeType"] ?: NSNull.null,
             node[@"widgetRuntimeType"] ?: NSNull.null,
             node[@"runtimeType"] ?: NSNull.null,
             node[@"type"] ?: NSNull.null
         ]) {
        if ([value isKindOfClass:NSString.class] && [value length] > 0) {
            return value;
        }
    }
    return @"Unknown";
}

+ (NSString *)hierarchyRoleForWidgetType:(NSString *)widgetType
                         renderObjectType:(NSString *)renderObjectType {
    static NSSet<NSString *> *childrenLayouts;
    static NSSet<NSString *> *layoutModifiers;
    static NSSet<NSString *> *spacingWidgets;
    static NSSet<NSString *> *interactionWrappers;
    static NSSet<NSString *> *semanticWrappers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        childrenLayouts = [NSSet setWithArray:@[
            @"Column", @"Row", @"Flex", @"Stack", @"IndexedStack", @"Wrap",
            @"Flow", @"Table", @"ListBody", @"CustomMultiChildLayout",
        ]];
        layoutModifiers = [NSSet setWithArray:@[
            @"Align", @"Center", @"Padding", @"SafeArea", @"Expanded",
            @"Flexible", @"Positioned", @"PositionedDirectional", @"FittedBox",
            @"FractionallySizedBox", @"FractionalTranslation",
            @"SlideTransition", @"AspectRatio", @"ConstrainedBox",
            @"UnconstrainedBox", @"LimitedBox", @"OverflowBox",
            @"Baseline", @"IntrinsicWidth", @"IntrinsicHeight",
            @"SliverPadding", @"SliverToBoxAdapter", @"LayoutId",
        ]];
        spacingWidgets = [NSSet setWithArray:@[
            @"SizedBox", @"Spacer",
        ]];
        interactionWrappers = [NSSet setWithArray:@[
            @"GestureDetector", @"RawGestureDetector", @"Listener", @"MouseRegion",
            @"Focus", @"FocusScope", @"FocusableActionDetector", @"Actions",
            @"Shortcuts", @"CallbackShortcuts", @"TapRegion", @"IgnorePointer",
            @"AbsorbPointer", @"ModalBarrier",
        ]];
        semanticWrappers = [NSSet setWithArray:@[
            @"Semantics", @"MergeSemantics", @"ExcludeSemantics", @"BlockSemantics",
        ]];
    });

    if ([spacingWidgets containsObject:widgetType]) {
        return @"visual";
    }
    if ([childrenLayouts containsObject:widgetType]) {
        return @"childrenLayout";
    }
    if ([layoutModifiers containsObject:widgetType]) {
        return @"layoutModifier";
    }
    if ([interactionWrappers containsObject:widgetType]) {
        return @"interaction";
    }
    if ([semanticWrappers containsObject:widgetType]) {
        return @"semantics";
    }
    if (renderObjectType.length > 0 &&
        ![renderObjectType isEqualToString:@"Unknown"]) {
        return @"visual";
    }
    return @"transparent";
}

+ (NSString *)kindForVisualType:(NSString *)type {
    static NSSet<NSString *> *textTypes;
    static NSSet<NSString *> *layoutTypes;
    static NSSet<NSString *> *boxTypes;
    static NSSet<NSString *> *imageTypes;
    static NSSet<NSString *> *controlTypes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        textTypes = [NSSet setWithArray:@[
            @"Text", @"RichText", @"SelectableText", @"EditableText",
        ]];
        layoutTypes = [NSSet setWithArray:@[
            @"Align", @"AspectRatio", @"Center", @"Column",
            @"ConstrainedBox", @"CustomScrollView", @"Expanded", @"FittedBox",
            @"Flex", @"Flexible", @"GridView", @"IntrinsicHeight",
            @"IntrinsicWidth", @"LimitedBox", @"ListView", @"NestedScrollView",
            @"OverflowBox", @"Padding", @"Positioned", @"Row", @"SafeArea",
            @"SingleChildScrollView", @"SizedBox", @"Spacer", @"Stack", @"Wrap",
            @"SliverAppBar", @"SliverFillRemaining", @"SliverGrid",
            @"SliverList", @"SliverPadding", @"SliverPersistentHeader",
            @"SliverToBoxAdapter",
        ]];
        boxTypes = [NSSet setWithArray:@[
            @"AppBar", @"Card", @"ColoredBox", @"Container",
            @"CupertinoNavigationBar", @"DecoratedBox", @"Material",
            @"PhysicalModel", @"Scaffold", @"ClipOval", @"ClipPath",
            @"ClipRect", @"ClipRRect", @"Opacity", @"Transform",
        ]];
        imageTypes = [NSSet setWithArray:@[
            @"CircleAvatar", @"FadeInImage", @"FlutterLogo", @"Image",
            @"RawImage",
        ]];
        controlTypes = [NSSet setWithArray:@[
            @"Checkbox", @"CheckboxListTile", @"CupertinoButton",
            @"ElevatedButton", @"FilledButton", @"FloatingActionButton",
            @"GestureDetector", @"IconButton", @"InkWell",
            @"OutlinedButton", @"Radio", @"Slider", @"Switch",
            @"SwitchListTile", @"TextButton",
        ]];
    });

    if ([textTypes containsObject:type]) {
        return @"text";
    }
    if ([layoutTypes containsObject:type]) {
        return @"layout";
    }
    if ([boxTypes containsObject:type]) {
        return @"box";
    }
    if ([imageTypes containsObject:type]) {
        return @"image";
    }
    if ([type isEqualToString:@"Icon"]) {
        return @"icon";
    }
    if ([controlTypes containsObject:type] || [type hasSuffix:@"Button"]) {
        return @"control";
    }
    if ([type isEqualToString:@"CustomPaint"]) {
        return @"canvas";
    }
    return @"custom";
}

+ (NSArray<NSString *> *)capabilitiesForWidgetType:(NSString *)widgetType
                                  renderObjectType:(NSString *)renderObjectType
                                         paintRole:(NSString *)paintRole
                                  nativeDecoration:(NSDictionary *)decoration {
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    if (renderObjectType.length > 0 &&
        ![renderObjectType isEqualToString:@"Unknown"]) {
        [result addObject:@"layout"];
    }
    if ([paintRole isEqualToString:@"selfPaint"]) {
        [result addObject:@"paint"];
    }
    if ([paintRole isEqualToString:@"paintEffect"]) {
        [result addObject:@"effect"];
    }
    if (decoration != nil) {
        [result addObject:@"decoration"];
    }
    if ([widgetType containsString:@"Clip"] ||
        [renderObjectType containsString:@"Clip"]) {
        [result addObject:@"clip"];
    }
    if ([widgetType containsString:@"Opacity"] ||
        [widgetType containsString:@"Filter"] ||
        [renderObjectType containsString:@"Opacity"] ||
        [renderObjectType containsString:@"Filter"]) {
        [result addObject:@"compositing"];
    }
    if ([widgetType containsString:@"Transform"] ||
        [renderObjectType containsString:@"Transform"]) {
        [result addObject:@"transform"];
    }
    if ([widgetType containsString:@"Scroll"] ||
        [widgetType containsString:@"ListView"] ||
        [widgetType containsString:@"GridView"] ||
        [widgetType containsString:@"PageView"] ||
        [renderObjectType containsString:@"Viewport"] ||
        [renderObjectType containsString:@"Sliver"]) {
        [result addObject:@"scroll"];
    }
    if ([widgetType containsString:@"PlatformView"] ||
        [widgetType isEqualToString:@"UiKitView"] ||
        [renderObjectType containsString:@"UiKitView"] ||
        [renderObjectType containsString:@"PlatformView"]) {
        [result addObject:@"platformView"];
    }
    return result.array;
}

+ (NSString *)paintRoleForWidgetType:(NSString *)widgetType
                    renderObjectType:(NSString *)renderObjectType {
    static NSSet<NSString *> *selfPaintingRenderObjects;
    static NSSet<NSString *> *effectRenderObjects;
    static NSSet<NSString *> *layoutOnlyRenderObjects;
    static NSSet<NSString *> *selfPaintingWidgets;
    static NSSet<NSString *> *effectWidgets;
    static NSSet<NSString *> *layoutOnlyWidgets;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        selfPaintingRenderObjects = [NSSet setWithArray:@[
            @"RenderParagraph", @"RenderEditable", @"RenderImage",
            @"RenderDecoratedBox", @"_RenderColoredBox", @"RenderPhysicalModel",
            @"RenderPhysicalShape", @"RenderCustomPaint", @"RenderFlutterLogo",
            @"RenderErrorBox", @"RenderPerformanceOverlay", @"RenderTextureBox",
            @"RenderAndroidView", @"RenderUiKitView", @"RenderPlatformView",
        ]];
        effectRenderObjects = [NSSet setWithArray:@[
            @"RenderOpacity", @"RenderAnimatedOpacity", @"RenderTransform",
            @"RenderClipRect", @"RenderClipRRect", @"RenderClipOval",
            @"RenderClipPath", @"RenderBackdropFilter", @"RenderShaderMask",
            @"RenderColorFiltered", @"RenderImageFiltered", @"RenderFittedBox",
            @"RenderFractionalTranslation", @"RenderRotatedBox",
            @"RenderLeaderLayer", @"RenderFollowerLayer", @"RenderOffstage",
            @"RenderAnimatedSize",
        ]];
        layoutOnlyRenderObjects = [NSSet setWithArray:@[
            @"RenderPadding", @"RenderPositionedBox", @"RenderFlex",
            @"RenderConstrainedBox", @"RenderAspectRatio",
            @"RenderIntrinsicWidth", @"RenderIntrinsicHeight",
            @"RenderLimitedBox", @"RenderSizedOverflowBox",
            @"RenderUnconstrainedBox", @"RenderBaseline", @"RenderStack",
            @"RenderIndexedStack", @"RenderWrap", @"RenderListBody",
            @"RenderSemanticsAnnotations", @"RenderExcludeSemantics",
            @"RenderMergeSemantics", @"RenderBlockSemantics",
            @"RenderIgnorePointer", @"RenderAbsorbPointer",
            @"RenderMouseRegion", @"RenderPointerListener", @"RenderTapRegion",
            @"RenderSliverPadding", @"RenderSliverToBoxAdapter",
            @"RenderProxyBox", @"RenderProxySliver", @"RenderRepaintBoundary",
        ]];
        selfPaintingWidgets = [NSSet setWithArray:@[
            @"AppBar", @"Text", @"RichText", @"SelectableText",
            @"EditableText", @"Image", @"RawImage", @"Icon", @"FlutterLogo",
            @"CustomPaint", @"Scaffold", @"Material", @"Card",
            @"PhysicalModel", @"ColoredBox", @"DecoratedBox", @"Checkbox",
            @"CupertinoButton", @"CupertinoNavigationBar", @"ElevatedButton",
            @"FilledButton", @"FloatingActionButton", @"IconButton",
            @"OutlinedButton", @"Radio", @"Slider", @"Switch", @"TextButton",
            @"CheckboxListTile", @"SwitchListTile",
        ]];
        effectWidgets = [NSSet setWithArray:@[
            @"Opacity", @"Transform", @"ClipOval", @"ClipPath", @"ClipRect",
            @"ClipRRect", @"FittedBox", @"BackdropFilter", @"ShaderMask",
            @"ColorFiltered", @"ImageFiltered", @"RotatedBox",
            @"FractionalTranslation", @"Offstage", @"InkWell",
        ]];
        layoutOnlyWidgets = [NSSet setWithArray:@[
            @"Align", @"AspectRatio", @"Center", @"Column", @"ConstrainedBox",
            @"Expanded", @"Flex", @"Flexible", @"GridView",
            @"IntrinsicHeight", @"IntrinsicWidth", @"LimitedBox", @"ListView",
            @"OverflowBox", @"Padding", @"Positioned", @"Row", @"SafeArea",
            @"SingleChildScrollView", @"SizedBox", @"Spacer", @"Stack",
            @"Wrap", @"GestureDetector",
        ]];
    });

    if ([selfPaintingRenderObjects containsObject:renderObjectType]) {
        return @"selfPaint";
    }
    if ([effectRenderObjects containsObject:renderObjectType] ||
        [effectWidgets containsObject:widgetType]) {
        return @"paintEffect";
    }
    if ([selfPaintingWidgets containsObject:widgetType]) {
        return @"selfPaint";
    }
    if ([layoutOnlyRenderObjects containsObject:renderObjectType] ||
        [layoutOnlyWidgets containsObject:widgetType]) {
        return @"layoutOnly";
    }
    if ([widgetType isEqualToString:@"Container"]) {
        return @"selfPaint";
    }
    return @"unknown";
}

+ (NSDictionary *)relationForLayoutNode:(NSDictionary *)layoutNode
                                    type:(NSString *)type
                        renderObjectType:(NSString *)renderObjectType {
    NSMutableDictionary *relation = [@{
        @"type" : type ?: @"Unknown",
        @"renderObjectType" : renderObjectType ?: @"Unknown",
    } mutableCopy];
    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:layoutNode];
    if (objectID.length > 0) {
        relation[@"objectId"] = objectID;
    }
    if ([layoutNode[@"description"] isKindOfClass:NSString.class]) {
        relation[@"description"] = layoutNode[@"description"];
    }

    NSDictionary *renderObject =
        [layoutNode[@"renderObject"] isKindOfClass:NSDictionary.class]
            ? layoutNode[@"renderObject"]
            : nil;
    if ([renderObject[@"properties"] isKindOfClass:NSArray.class]) {
        relation[@"properties"] = renderObject[@"properties"];
    }

    NSArray *children = [layoutNode[@"children"] isKindOfClass:NSArray.class]
        ? layoutNode[@"children"]
        : @[];
    NSMutableArray<NSDictionary *> *managedChildren = [NSMutableArray array];
    for (id value in children) {
        if (![value isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSDictionary *child = value;
        NSMutableDictionary *managedChild = [NSMutableDictionary dictionary];
        NSString *childID = [KKFIInspectorJSON nodeIDFromDictionary:child];
        if (childID.length > 0) {
            managedChild[@"objectId"] = childID;
        }
        NSString *childType = [self widgetTypeFromNode:child metadata:nil];
        if (childType.length > 0) {
            managedChild[@"type"] = childType;
        }
        if (managedChild.count > 0) {
            [managedChildren addObject:managedChild];
        }
    }
    relation[@"managedChildren"] = managedChildren.copy;

    BOOL foundSize = NO;
    CGSize size = [self sizeFromNode:layoutNode found:&foundSize];
    if (foundSize) {
        relation[@"size"] = @{
            @"width" : @(size.width),
            @"height" : @(size.height),
        };
    }
    return relation.copy;
}

+ (NSDictionary *)nativeDecorationFromLayoutNode:(NSDictionary *)layoutNode
                                 renderObjectType:(NSString *)renderObjectType
                                       widgetType:(NSString *)widgetType
                                       properties:(NSArray *)widgetProperties {
    NSDictionary *renderObject =
        [layoutNode[@"renderObject"] isKindOfClass:NSDictionary.class]
            ? layoutNode[@"renderObject"]
            : nil;
    NSArray *properties =
        [renderObject[@"properties"] isKindOfClass:NSArray.class]
            ? renderObject[@"properties"]
            : @[];

    static NSSet<NSString *> *materialButtonTypes;
    static dispatch_once_t buttonTypesOnceToken;
    dispatch_once(&buttonTypesOnceToken, ^{
        materialButtonTypes = [NSSet setWithArray:@[
            @"CupertinoButton", @"ElevatedButton", @"FilledButton",
            @"FloatingActionButton", @"IconButton", @"OutlinedButton",
            @"TextButton",
        ]];
    });
    if ([materialButtonTypes containsObject:widgetType]) {
        NSString *shapeDescription = [self diagnosticDescription:
            [self diagnosticPropertyNamed:@"shape"
                              inProperties:widgetProperties]];
        if (shapeDescription.length == 0) {
            return nil;
        }

        NSDictionary *color = [self colorDictionaryFromProperty:
            [self diagnosticPropertyNamed:@"color"
                              inProperties:widgetProperties]];
        NSMutableDictionary *result = [@{
            @"kind" : @"materialButton",
            @"shape" : @"rectangle",
            @"backgroundColor" : color ?: @{
                @"red" : @0, @"green" : @0, @"blue" : @0, @"alpha" : @0,
            },
        } mutableCopy];
        if ([shapeDescription containsString:@"CircleBorder"]) {
            result[@"shape"] = @"circle";
        } else if ([shapeDescription containsString:@"StadiumBorder"]) {
            BOOL foundSize = NO;
            CGSize size = [self sizeFromNode:layoutNode found:&foundSize];
            if (!foundSize || size.width <= 0 || size.height <= 0) {
                return nil;
            }
            result[@"cornerRadius"] = @(MIN(size.width, size.height) * 0.5);
        } else {
            NSNumber *radius =
                [self uniformRadiusFromDescription:shapeDescription];
            if (radius == nil) {
                return nil;
            }
            result[@"cornerRadius"] = radius;
        }

        NSDictionary *border =
            [self borderDictionaryFromDescription:shapeDescription];
        if ([border[@"width"] doubleValue] > 0) {
            result[@"border"] = border;
        }
        NSNumber *elevation = [self numberFromDiagnosticProperty:
            [self diagnosticPropertyNamed:@"elevation"
                              inProperties:widgetProperties]];
        if (elevation.doubleValue > 0) {
            NSDictionary *shadowColor = [self colorDictionaryFromProperty:
                [self diagnosticPropertyNamed:@"shadowColor"
                                  inProperties:widgetProperties]];
            if (shadowColor != nil) {
                result[@"shadows"] = @[@{
                    @"color" : shadowColor,
                    @"offsetX" : @0,
                    @"offsetY" : @(MAX(0.5, elevation.doubleValue * 0.5)),
                    @"blurRadius" : @(MAX(1.0, elevation.doubleValue * 2.0)),
                }];
            }
        }
        return result.copy;
    }

    if ([widgetType isEqualToString:@"Container"]) {
        NSDictionary *decoration =
            [self diagnosticPropertyNamed:@"bg"
                              inProperties:widgetProperties];
        NSDictionary *result =
            [self boxDecorationFromDiagnosticProperty:decoration];
        if (result != nil) {
            return result;
        }
    }

    if ([widgetType isEqualToString:@"Card"]) {
        NSDictionary *color = [self colorDictionaryFromProperty:
            [self diagnosticPropertyNamed:@"color"
                              inProperties:widgetProperties]];
        NSString *shapeDescription = [self diagnosticDescription:
            [self diagnosticPropertyNamed:@"shape"
                              inProperties:widgetProperties]];
        if (color == nil || shapeDescription.length == 0) {
            return nil;
        }

        NSMutableDictionary *result = [@{
            @"kind" : @"materialCard",
            @"shape" : @"rectangle",
            @"backgroundColor" : color,
        } mutableCopy];
        if ([shapeDescription containsString:@"CircleBorder"]) {
            result[@"shape"] = @"circle";
        } else {
            NSNumber *radius =
                [self uniformRadiusFromDescription:shapeDescription];
            if (radius == nil) {
                return nil;
            }
            result[@"cornerRadius"] = radius;
        }

        UIEdgeInsets margin = UIEdgeInsetsZero;
        if ([self edgeInsetsFromDiagnosticProperty:
                [self diagnosticPropertyNamed:@"margin"
                                  inProperties:widgetProperties]
                                          value:&margin]) {
            result[@"contentInsets"] = @{
                @"top" : @(margin.top),
                @"left" : @(margin.left),
                @"bottom" : @(margin.bottom),
                @"right" : @(margin.right),
            };
        }

        NSNumber *elevation = [self numberFromDiagnosticProperty:
            [self diagnosticPropertyNamed:@"elevation"
                              inProperties:widgetProperties]];
        if (elevation.doubleValue > 0) {
            result[@"elevation"] = elevation;
            NSDictionary *shadowColor = [self colorDictionaryFromProperty:
                [self diagnosticPropertyNamed:@"shadowColor"
                                  inProperties:widgetProperties]];
            if (shadowColor != nil) {
                NSMutableDictionary *softShadowColor = shadowColor.mutableCopy;
                softShadowColor[@"alpha"] =
                    @(MIN([shadowColor[@"alpha"] doubleValue], 64.0));
                result[@"shadowColor"] = shadowColor;
                result[@"shadows"] = @[@{
                    @"color" : softShadowColor.copy,
                    @"offsetX" : @0,
                    @"offsetY" : @(MAX(0.5, elevation.doubleValue * 0.5)),
                    @"blurRadius" : @(MAX(1.0, elevation.doubleValue * 2.0)),
                }];
            }
        }
        return result.copy;
    }

    if ([renderObjectType isEqualToString:@"RenderDecoratedBox"]) {
        NSDictionary *decoration =
            [self diagnosticPropertyNamed:@"decoration" inProperties:properties];
        return [self boxDecorationFromDiagnosticProperty:decoration];
    }

    if ([renderObjectType isEqualToString:@"_RenderColoredBox"]) {
        NSDictionary *color = [self colorDictionaryFromProperty:
            [self diagnosticPropertyNamed:@"color" inProperties:properties]];
        return color == nil ? nil : @{
            @"kind" : @"solidColor",
            @"shape" : @"rectangle",
            @"backgroundColor" : color,
        };
    }

    if ([renderObjectType isEqualToString:@"RenderPhysicalModel"]) {
        NSDictionary *color = [self colorDictionaryFromProperty:
            [self diagnosticPropertyNamed:@"color" inProperties:properties]];
        if (color == nil) {
            return nil;
        }
        NSMutableDictionary *result = [@{
            @"kind" : @"physicalModel",
            @"shape" : @"rectangle",
            @"backgroundColor" : color,
        } mutableCopy];
        NSString *shapeDescription = [self diagnosticDescription:
            [self diagnosticPropertyNamed:@"shape" inProperties:properties]];
        if ([shapeDescription containsString:@"circle"]) {
            result[@"shape"] = @"circle";
        }
        NSDictionary *radiusProperty =
            [self diagnosticPropertyNamed:@"borderRadius"
                              inProperties:properties];
        if ([self diagnosticPropertyHasValue:radiusProperty]) {
            NSNumber *radius = [self uniformRadiusFromDescription:
                [self diagnosticDescription:radiusProperty]];
            if (radius == nil) {
                return nil;
            }
            result[@"cornerRadius"] = radius;
        }
        NSNumber *elevation = [self numberFromDiagnosticProperty:
            [self diagnosticPropertyNamed:@"elevation"
                              inProperties:properties]];
        if (elevation.doubleValue > 0) {
            result[@"elevation"] = elevation;
            NSDictionary *shadowColor = [self colorDictionaryFromProperty:
                [self diagnosticPropertyNamed:@"shadowColor"
                                  inProperties:properties]];
            if (shadowColor != nil) {
                result[@"shadowColor"] = shadowColor;
            }
        }
        return result.copy;
    }
    return nil;
}

+ (NSDictionary *)boxDecorationFromDiagnosticProperty:(NSDictionary *)decoration {
    NSArray *properties =
        [decoration[@"properties"] isKindOfClass:NSArray.class]
            ? decoration[@"properties"]
            : @[];
    if (properties.count == 0) {
        return nil;
    }

    NSDictionary *image =
        [self diagnosticPropertyNamed:@"image" inProperties:properties];
    if ([self diagnosticPropertyHasValue:image]) {
        return nil;
    }

    NSMutableDictionary *result = [@{
        @"kind" : @"boxDecoration",
        @"shape" : @"rectangle",
    } mutableCopy];
    NSDictionary *color = [self colorDictionaryFromProperty:
        [self diagnosticPropertyNamed:@"color" inProperties:properties]];
    if (color != nil) {
        result[@"backgroundColor"] = color;
    }

    NSDictionary *gradientProperty =
        [self diagnosticPropertyNamed:@"gradient" inProperties:properties];
    if ([self diagnosticPropertyHasValue:gradientProperty]) {
        NSDictionary *gradient =
            [self linearGradientFromDiagnosticProperty:gradientProperty];
        if (gradient == nil) {
            return nil;
        }
        result[@"gradient"] = gradient;
    }

    NSString *shapeDescription = [self diagnosticDescription:
        [self diagnosticPropertyNamed:@"shape" inProperties:properties]];
    if ([shapeDescription containsString:@"circle"]) {
        result[@"shape"] = @"circle";
    }

    NSDictionary *radiusProperty =
        [self diagnosticPropertyNamed:@"borderRadius" inProperties:properties];
    if ([self diagnosticPropertyHasValue:radiusProperty]) {
        NSNumber *radius = [self uniformRadiusFromDescription:
            [self diagnosticDescription:radiusProperty]];
        if (radius == nil) {
            return nil;
        }
        result[@"cornerRadius"] = radius;
    }

    NSDictionary *borderProperty =
        [self diagnosticPropertyNamed:@"border" inProperties:properties];
    if ([self diagnosticPropertyHasValue:borderProperty]) {
        NSDictionary *border = [self borderDictionaryFromDescription:
            [self diagnosticDescription:borderProperty]];
        if (border == nil) {
            return nil;
        }
        result[@"border"] = border;
    }

    NSDictionary *shadowProperty =
        [self diagnosticPropertyNamed:@"boxShadow" inProperties:properties];
    if ([self diagnosticPropertyHasValue:shadowProperty]) {
        NSArray *shadows = [self shadowDictionariesFromProperty:shadowProperty];
        if (shadows == nil) {
            return nil;
        }
        result[@"shadows"] = shadows;
    }
    return result.count > 2 ? result.copy : nil;
}

+ (NSDictionary *)linearGradientFromDiagnosticProperty:(NSDictionary *)property {
    NSString *description = [self diagnosticDescription:property];
    if (![description containsString:@"LinearGradient("] ||
        ([description containsString:@"tileMode:"] &&
         ![description containsString:@"tileMode: TileMode.clamp"]) ||
        [description containsString:@"transform:"]) {
        return nil;
    }

    NSRegularExpression *colorRegex = [NSRegularExpression
        regularExpressionWithPattern:@"Color\\([^\\)]*\\)"
                             options:0
                               error:nil];
    NSArray<NSTextCheckingResult *> *colorMatches =
        [colorRegex matchesInString:description
                           options:0
                             range:NSMakeRange(0, description.length)];
    NSMutableArray<NSDictionary *> *colors = [NSMutableArray array];
    for (NSTextCheckingResult *match in colorMatches) {
        NSDictionary *color = [self colorDictionaryFromDescription:
            [description substringWithRange:match.range]];
        if (color != nil) {
            [colors addObject:color];
        }
    }
    if (colors.count < 2) {
        return nil;
    }

    NSString *beginDescription = @"Alignment.centerLeft";
    NSString *endDescription = @"Alignment.centerRight";
    NSRange beginMarker = [description rangeOfString:@"begin:"];
    NSRange endMarker = [description rangeOfString:@", end:"];
    NSRange colorsMarker = [description rangeOfString:@", colors:"];
    if (beginMarker.location != NSNotFound &&
        endMarker.location != NSNotFound &&
        endMarker.location > NSMaxRange(beginMarker)) {
        NSRange range = NSMakeRange(
            NSMaxRange(beginMarker),
            endMarker.location - NSMaxRange(beginMarker));
        beginDescription =
            [[description substringWithRange:range]
                stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if (endMarker.location != NSNotFound &&
        colorsMarker.location != NSNotFound &&
        colorsMarker.location > NSMaxRange(endMarker)) {
        NSRange range = NSMakeRange(
            NSMaxRange(endMarker),
            colorsMarker.location - NSMaxRange(endMarker));
        endDescription =
            [[description substringWithRange:range]
                stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }

    NSDictionary *startPoint =
        [self unitPointFromAlignmentDescription:beginDescription];
    NSDictionary *endPoint =
        [self unitPointFromAlignmentDescription:endDescription];
    if (startPoint == nil || endPoint == nil) {
        return nil;
    }

    NSMutableDictionary *result = [@{
        @"type" : @"linear",
        @"colors" : colors.copy,
        @"startX" : startPoint[@"x"],
        @"startY" : startPoint[@"y"],
        @"endX" : endPoint[@"x"],
        @"endY" : endPoint[@"y"],
    } mutableCopy];

    NSRegularExpression *stopsRegex = [NSRegularExpression
        regularExpressionWithPattern:@"stops:\\s*\\[([^\\]]+)\\]"
                             options:0
                               error:nil];
    NSTextCheckingResult *stopsMatch =
        [stopsRegex firstMatchInString:description
                               options:0
                                 range:NSMakeRange(0, description.length)];
    if (stopsMatch.numberOfRanges == 2) {
        NSString *stopsText =
            [description substringWithRange:[stopsMatch rangeAtIndex:1]];
        NSMutableArray<NSNumber *> *stops = [NSMutableArray array];
        for (NSString *component in
             [stopsText componentsSeparatedByString:@","]) {
            NSString *trimmed =
                [component stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSNumber *number = [KKFIInspectorJSON numberFromValue:trimmed];
            if (number != nil) {
                [stops addObject:number];
            }
        }
        if (stops.count == colors.count) {
            result[@"stops"] = stops.copy;
        }
    }
    return result.copy;
}

+ (NSDictionary *)unitPointFromAlignmentDescription:(NSString *)description {
    static NSDictionary<NSString *, NSDictionary *> *namedPoints;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        namedPoints = @{
            @"Alignment.topLeft" : @{ @"x" : @0, @"y" : @0 },
            @"Alignment.topCenter" : @{ @"x" : @0.5, @"y" : @0 },
            @"Alignment.topRight" : @{ @"x" : @1, @"y" : @0 },
            @"Alignment.centerLeft" : @{ @"x" : @0, @"y" : @0.5 },
            @"Alignment.center" : @{ @"x" : @0.5, @"y" : @0.5 },
            @"Alignment.centerRight" : @{ @"x" : @1, @"y" : @0.5 },
            @"Alignment.bottomLeft" : @{ @"x" : @0, @"y" : @1 },
            @"Alignment.bottomCenter" : @{ @"x" : @0.5, @"y" : @1 },
            @"Alignment.bottomRight" : @{ @"x" : @1, @"y" : @1 },
        };
    });
    NSDictionary *namedPoint = namedPoints[description];
    if (namedPoint != nil) {
        return namedPoint;
    }

    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:
            @"Alignment\\(\\s*([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)\\s*\\)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match =
        [regex firstMatchInString:description
                          options:0
                            range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges != 3) {
        return nil;
    }
    CGFloat x = [[description substringWithRange:[match rangeAtIndex:1]]
        doubleValue];
    CGFloat y = [[description substringWithRange:[match rangeAtIndex:2]]
        doubleValue];
    return @{
        @"x" : @(MIN(MAX((x + 1.0) / 2.0, 0.0), 1.0)),
        @"y" : @(MIN(MAX((y + 1.0) / 2.0, 0.0), 1.0)),
    };
}

+ (NSDictionary *)diagnosticPropertyNamed:(NSString *)name
                              inProperties:(NSArray *)properties {
    for (id value in properties) {
        if ([value isKindOfClass:NSDictionary.class] &&
            [value[@"name"] isEqual:name]) {
            return value;
        }
    }
    return nil;
}

+ (NSString *)diagnosticDescription:(NSDictionary *)property {
    return [property[@"description"] isKindOfClass:NSString.class]
        ? property[@"description"]
        : @"";
}

+ (BOOL)diagnosticPropertyHasValue:(NSDictionary *)property {
    if (property == nil || property[@"value"] == NSNull.null) {
        return NO;
    }
    NSString *description = [self diagnosticDescription:property];
    return description.length > 0 &&
        ![description isEqualToString:@"null"];
}

+ (NSNumber *)numberFromDiagnosticProperty:(NSDictionary *)property {
    NSNumber *value =
        [KKFIInspectorJSON numberFromValue:property[@"value"]];
    if (value != nil) {
        return value;
    }
    return [KKFIInspectorJSON
        numberFromValue:property[@"numberToString"] ?:
            [self diagnosticDescription:property]];
}

+ (NSDictionary *)colorDictionaryFromProperty:(NSDictionary *)property {
    NSDictionary *components =
        [property[@"valueProperties"] isKindOfClass:NSDictionary.class]
            ? property[@"valueProperties"]
            : nil;
    NSNumber *red = [KKFIInspectorJSON numberFromValue:components[@"red"]];
    NSNumber *green = [KKFIInspectorJSON numberFromValue:components[@"green"]];
    NSNumber *blue = [KKFIInspectorJSON numberFromValue:components[@"blue"]];
    NSNumber *alpha = [KKFIInspectorJSON numberFromValue:components[@"alpha"]];
    if (red != nil && green != nil && blue != nil && alpha != nil) {
        return @{
            @"red" : red,
            @"green" : green,
            @"blue" : blue,
            @"alpha" : alpha,
        };
    }
    return [self colorDictionaryFromDescription:
        [self diagnosticDescription:property]];
}

+ (NSDictionary *)colorDictionaryFromDescription:(NSString *)description {
    if (description.length == 0) {
        return nil;
    }
    NSRegularExpression *componentsRegex = [NSRegularExpression
        regularExpressionWithPattern:
            @"Color\\(alpha:\\s*([0-9.]+),\\s*red:\\s*([0-9.]+),\\s*green:"
             @"\\s*([0-9.]+),\\s*blue:\\s*([0-9.]+)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match =
        [componentsRegex firstMatchInString:description
                                    options:0
                                      range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges == 5) {
        double alpha =
            [[description substringWithRange:[match rangeAtIndex:1]] doubleValue];
        double red =
            [[description substringWithRange:[match rangeAtIndex:2]] doubleValue];
        double green =
            [[description substringWithRange:[match rangeAtIndex:3]] doubleValue];
        double blue =
            [[description substringWithRange:[match rangeAtIndex:4]] doubleValue];
        return @{
            @"red" : @(round(red * 255.0)),
            @"green" : @(round(green * 255.0)),
            @"blue" : @(round(blue * 255.0)),
            @"alpha" : @(round(alpha * 255.0)),
        };
    }

    NSRegularExpression *hexRegex = [NSRegularExpression
        regularExpressionWithPattern:@"Color\\(0x([0-9A-Fa-f]{8})\\)"
                             options:0
                               error:nil];
    match = [hexRegex firstMatchInString:description
                                 options:0
                                   range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges == 2) {
        NSString *hex = [description substringWithRange:[match rangeAtIndex:1]];
        unsigned long long argb = 0;
        [[NSScanner scannerWithString:hex] scanHexLongLong:&argb];
        return @{
            @"alpha" : @((argb >> 24) & 0xff),
            @"red" : @((argb >> 16) & 0xff),
            @"green" : @((argb >> 8) & 0xff),
            @"blue" : @(argb & 0xff),
        };
    }
    return nil;
}

+ (NSNumber *)uniformRadiusFromDescription:(NSString *)description {
    if (description.length == 0 || [description isEqualToString:@"null"]) {
        return nil;
    }
    if ([description containsString:@"zero"]) {
        return @0;
    }
    if ([description containsString:@"topLeft"] ||
        [description containsString:@"topRight"] ||
        [description containsString:@"bottomLeft"] ||
        [description containsString:@"bottomRight"] ||
        [description containsString:@"elliptical"]) {
        return nil;
    }
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:
            @"(?:BorderRadius\\.circular|Radius\\.circular)\\(\\s*([-+0-9.eE]+)"
             @"\\s*\\)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match =
        [regex firstMatchInString:description
                          options:0
                            range:NSMakeRange(0, description.length)];
    return match.numberOfRanges == 2
        ? @([[description substringWithRange:[match rangeAtIndex:1]] doubleValue])
        : nil;
}

+ (NSDictionary *)borderDictionaryFromDescription:(NSString *)description {
    if ([description containsString:@"BorderSide.none"] ||
        [description containsString:@"BorderStyle.none"]) {
        return @{ @"width" : @0 };
    }
    if (![description containsString:@"Border.all("] &&
        ![description containsString:@"BorderSide("]) {
        return nil;
    }
    NSDictionary *color = [self colorDictionaryFromDescription:description];
    NSRegularExpression *widthRegex = [NSRegularExpression
        regularExpressionWithPattern:@"width:\\s*([-+0-9.eE]+)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match =
        [widthRegex firstMatchInString:description
                               options:0
                                 range:NSMakeRange(0, description.length)];
    if (color == nil || match.numberOfRanges != 2) {
        return nil;
    }
    return @{
        @"width" : @([[description substringWithRange:[match rangeAtIndex:1]]
            doubleValue]),
        @"color" : color,
        @"style" : @"solid",
    };
}

+ (NSArray *)shadowDictionariesFromProperty:(NSDictionary *)property {
    NSArray *values = [property[@"values"] isKindOfClass:NSArray.class]
        ? property[@"values"]
        : nil;
    if (values.count == 0) {
        NSString *description = [self diagnosticDescription:property];
        values = description.length > 0 ? @[ description ] : @[];
    }
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:values.count];
    NSRegularExpression *numbersRegex = [NSRegularExpression
        regularExpressionWithPattern:
            @"Offset\\(\\s*([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)\\s*\\)\\s*,"
             @"\\s*([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)"
                             options:0
                               error:nil];
    for (id value in values) {
        NSString *description =
            [value isKindOfClass:NSString.class] ? value : nil;
        NSDictionary *color =
            [self colorDictionaryFromDescription:description];
        NSTextCheckingResult *match =
            [numbersRegex firstMatchInString:description ?: @""
                                     options:0
                                       range:NSMakeRange(0, description.length)];
        if (color == nil || match.numberOfRanges != 5 ||
            ([description containsString:@"BlurStyle."] &&
             ![description containsString:@"BlurStyle.normal"])) {
            return nil;
        }
        [result addObject:@{
            @"color" : color,
            @"offsetX" : @([[description
                substringWithRange:[match rangeAtIndex:1]] doubleValue]),
            @"offsetY" : @([[description
                substringWithRange:[match rangeAtIndex:2]] doubleValue]),
            @"blurRadius" : @([[description
                substringWithRange:[match rangeAtIndex:3]] doubleValue]),
            @"spreadRadius" : @([[description
                substringWithRange:[match rangeAtIndex:4]] doubleValue]),
        }];
    }
    return result.copy;
}

+ (NSString *)renderObjectTypeFromNode:(NSDictionary *)node {
    NSDictionary *renderObject =
        [node[@"renderObject"] isKindOfClass:NSDictionary.class]
            ? node[@"renderObject"]
            : nil;
    NSString *description =
        [renderObject[@"description"] isKindOfClass:NSString.class]
            ? renderObject[@"description"]
            : nil;
    if (description.length == 0) {
        return @"Unknown";
    }

    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"^([_A-Za-z][_A-Za-z0-9]*)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match =
        [regex firstMatchInString:description
                          options:0
                            range:NSMakeRange(0, description.length)];
    return match.numberOfRanges == 2
        ? [description substringWithRange:[match rangeAtIndex:1]]
        : @"Unknown";
}

+ (CGSize)sizeFromNode:(NSDictionary *)node found:(BOOL *)found {
    NSDictionary *size = [node[@"size"] isKindOfClass:NSDictionary.class]
        ? node[@"size"]
        : nil;
    NSNumber *width = [KKFIInspectorJSON numberFromValue:size[@"width"]];
    NSNumber *height = [KKFIInspectorJSON numberFromValue:size[@"height"]];
    BOOL hasSize = width != nil && height != nil;
    if (found != NULL) {
        *found = hasSize;
    }
    return hasSize ? CGSizeMake(width.doubleValue, height.doubleValue)
                   : CGSizeZero;
}

+ (BOOL)fittedBoxTransformFromNode:(NSDictionary *)node
                         childNode:(NSDictionary *)childNode
                            offset:(CGPoint *)offset
                             scale:(CGSize *)scale {
    BOOL foundBoxSize = NO;
    BOOL foundChildSize = NO;
    CGSize boxSize = [self sizeFromNode:node found:&foundBoxSize];
    CGSize childSize = [self sizeFromNode:childNode found:&foundChildSize];
    if (!foundBoxSize || !foundChildSize || boxSize.width <= 0 ||
        boxSize.height <= 0 || childSize.width <= 0 || childSize.height <= 0) {
        return NO;
    }

    NSDictionary *renderObject =
        [node[@"renderObject"] isKindOfClass:NSDictionary.class]
            ? node[@"renderObject"]
            : nil;
    NSArray *properties =
        [renderObject[@"properties"] isKindOfClass:NSArray.class]
            ? renderObject[@"properties"]
            : @[];
    NSString *fit = [self diagnosticDescription:
        [self diagnosticPropertyNamed:@"fit" inProperties:properties]];
    if ([fit hasPrefix:@"BoxFit."]) {
        fit = [fit substringFromIndex:@"BoxFit.".length];
    }

    CGFloat scaleX = 1.0;
    CGFloat scaleY = 1.0;
    CGFloat widthScale = boxSize.width / childSize.width;
    CGFloat heightScale = boxSize.height / childSize.height;
    if ([fit isEqualToString:@"fill"]) {
        scaleX = widthScale;
        scaleY = heightScale;
    } else if ([fit isEqualToString:@"contain"]) {
        scaleX = scaleY = MIN(widthScale, heightScale);
    } else if ([fit isEqualToString:@"cover"]) {
        scaleX = scaleY = MAX(widthScale, heightScale);
    } else if ([fit isEqualToString:@"fitWidth"]) {
        scaleX = scaleY = widthScale;
    } else if ([fit isEqualToString:@"fitHeight"]) {
        scaleX = scaleY = heightScale;
    } else if ([fit isEqualToString:@"none"]) {
        scaleX = scaleY = 1.0;
    } else if ([fit isEqualToString:@"scaleDown"]) {
        scaleX = scaleY = MIN(1.0, MIN(widthScale, heightScale));
    } else {
        return NO;
    }

    NSString *alignmentDescription = [self diagnosticDescription:
        [self diagnosticPropertyNamed:@"alignment" inProperties:properties]];
    NSDictionary *alignment =
        [self unitPointFromAlignmentDescription:alignmentDescription];
    NSNumber *alignmentX = alignment[@"x"];
    NSNumber *alignmentY = alignment[@"y"];
    if (alignmentX == nil || alignmentY == nil || !isfinite(scaleX) ||
        !isfinite(scaleY) || scaleX <= 0 || scaleY <= 0) {
        return NO;
    }

    CGSize transformedSize = CGSizeMake(childSize.width * scaleX,
                                        childSize.height * scaleY);
    if (offset != NULL) {
        *offset = CGPointMake(
            (boxSize.width - transformedSize.width) * alignmentX.doubleValue,
            (boxSize.height - transformedSize.height) * alignmentY.doubleValue);
    }
    if (scale != NULL) {
        *scale = CGSizeMake(scaleX, scaleY);
    }
    return YES;
}

+ (NSArray<NSValue *> *)inferredOffsetsForNode:(NSDictionary *)node
                                    widgetType:(NSString *)widgetType
                                    properties:(NSArray *)properties
                                      children:(NSArray *)children {
    if ([widgetType isEqualToString:@"ListView"]) {
        return [self inferredOffsetsForLinearListNode:node
                                           properties:properties
                                             children:children];
    }
    if ([widgetType isEqualToString:@"Card"]) {
        return [self inferredOffsetsForCardNode:node
                                     properties:properties
                                       children:children];
    }
    if ([widgetType isEqualToString:@"SliverToBoxAdapter"] &&
        children.count == 1) {
        // RenderSliverToBoxAdapter positions its box child at the sliver's
        // local origin. The summary tree omits the internal RenderBox bridge,
        // so make that zero offset explicit after the sliver paintOffset has
        // been resolved by the session.
        return @[[NSValue valueWithCGPoint:CGPointZero]];
    }
    return nil;
}

+ (NSArray<NSValue *> *)inferredOffsetsForLinearListNode:(NSDictionary *)node
                                               properties:(NSArray *)properties
                                                 children:(NSArray *)children {
    // Layout Explorer does not serialize SliverLogicalParentData.layoutOffset.
    // Recover offsets only when the ListView cannot scroll: in that case its
    // leading padding plus the measured child extents fully determines every
    // child's position. Scrollable, reversed, horizontal, and unknown layouts
    // deliberately return no inference rather than inventing a frame.
    if (properties.count == 0 || children.count == 0) {
        return nil;
    }

    NSDictionary *axisProperty =
        [self diagnosticPropertyNamed:@"scrollDirection"
                          inProperties:properties];
    if (![[self diagnosticDescription:axisProperty] isEqualToString:@"vertical"]) {
        return nil;
    }

    BOOL reverseFound = NO;
    BOOL reverse = [self boolFromDiagnosticProperty:
        [self diagnosticPropertyNamed:@"reverse" inProperties:properties]
                                           found:&reverseFound];
    BOOL shrinkWrapFound = NO;
    BOOL shrinkWrap = [self boolFromDiagnosticProperty:
        [self diagnosticPropertyNamed:@"shrinkWrap" inProperties:properties]
                                              found:&shrinkWrapFound];
    if (!reverseFound || reverse || !shrinkWrapFound || shrinkWrap) {
        return nil;
    }

    UIEdgeInsets padding = UIEdgeInsetsZero;
    if (![self edgeInsetsFromDiagnosticProperty:
            [self diagnosticPropertyNamed:@"padding" inProperties:properties]
                                      value:&padding]) {
        return nil;
    }

    BOOL foundViewportSize = NO;
    CGSize viewportSize = [self sizeFromNode:node found:&foundViewportSize];
    if (!foundViewportSize || viewportSize.width <= 0 ||
        viewportSize.height <= 0) {
        return nil;
    }

    const CGFloat tolerance = 0.5;
    CGFloat expectedChildWidth =
        viewportSize.width - padding.left - padding.right;
    if (expectedChildWidth < -tolerance) {
        return nil;
    }

    CGFloat contentHeight = padding.top + padding.bottom;
    NSMutableArray<NSValue *> *offsets =
        [NSMutableArray arrayWithCapacity:children.count];
    CGFloat childY = padding.top;
    for (id value in children) {
        if (![value isKindOfClass:NSDictionary.class]) {
            return nil;
        }
        BOOL foundChildSize = NO;
        CGSize childSize = [self sizeFromNode:value found:&foundChildSize];
        if (!foundChildSize || !isfinite(childSize.width) ||
            !isfinite(childSize.height) || childSize.width < 0 ||
            childSize.height < 0 ||
            fabs(childSize.width - expectedChildWidth) > tolerance) {
            return nil;
        }
        [offsets addObject:[NSValue valueWithCGPoint:
            CGPointMake(padding.left, childY)]];
        childY += childSize.height;
        contentHeight += childSize.height;
    }

    if (contentHeight > viewportSize.height + tolerance) {
        return nil;
    }
    return offsets.copy;
}

+ (NSArray<NSValue *> *)inferredOffsetsForCardNode:(NSDictionary *)node
                                         properties:(NSArray *)properties
                                           children:(NSArray *)children {
    // A Card's margin belongs to the outer widget. The summary tree promotes
    // the Card child and omits the intermediate padding RenderObjects, so use
    // the declared margin only when it exactly explains the measured size
    // difference. Otherwise leave the child frame unresolved.
    if (properties.count == 0 || children.count != 1 ||
        ![children.firstObject isKindOfClass:NSDictionary.class]) {
        return nil;
    }

    UIEdgeInsets margin = UIEdgeInsetsZero;
    if (![self edgeInsetsFromDiagnosticProperty:
            [self diagnosticPropertyNamed:@"margin" inProperties:properties]
                                      value:&margin]) {
        return nil;
    }

    BOOL foundCardSize = NO;
    BOOL foundChildSize = NO;
    CGSize cardSize = [self sizeFromNode:node found:&foundCardSize];
    CGSize childSize = [self sizeFromNode:children.firstObject
                                    found:&foundChildSize];
    const CGFloat tolerance = 0.5;
    CGFloat expectedWidth = cardSize.width - margin.left - margin.right;
    CGFloat expectedHeight = cardSize.height - margin.top - margin.bottom;
    if (!foundCardSize || !foundChildSize || expectedWidth < -tolerance ||
        expectedHeight < -tolerance ||
        fabs(childSize.width - expectedWidth) > tolerance ||
        fabs(childSize.height - expectedHeight) > tolerance) {
        return nil;
    }

    return @[[NSValue valueWithCGPoint:
        CGPointMake(margin.left, margin.top)]];
}

+ (BOOL)boolFromDiagnosticProperty:(NSDictionary *)property
                              found:(BOOL *)found {
    id value = property[@"value"];
    if ([value isKindOfClass:NSNumber.class]) {
        if (found != NULL) {
            *found = YES;
        }
        return [value boolValue];
    }

    NSString *description = [self diagnosticDescription:property];
    if ([description isEqualToString:@"true"] ||
        [description isEqualToString:@"false"]) {
        if (found != NULL) {
            *found = YES;
        }
        return [description isEqualToString:@"true"];
    }

    if (found != NULL) {
        *found = NO;
    }
    return NO;
}

+ (BOOL)edgeInsetsFromDiagnosticProperty:(NSDictionary *)property
                                    value:(UIEdgeInsets *)value {
    if (property == nil || value == NULL) {
        return NO;
    }

    NSString *description = [self diagnosticDescription:property];
    if ([description isEqualToString:@"null"] ||
        [description containsString:@"EdgeInsets.zero"]) {
        *value = UIEdgeInsetsZero;
        return YES;
    }

    NSRegularExpression *allRegex = [NSRegularExpression
        regularExpressionWithPattern:
            @"EdgeInsets\\.all\\(\\s*([-+0-9.eE]+)\\s*\\)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match =
        [allRegex firstMatchInString:description
                             options:0
                               range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges == 2) {
        CGFloat inset = [[description substringWithRange:
            [match rangeAtIndex:1]] doubleValue];
        *value = UIEdgeInsetsMake(inset, inset, inset, inset);
        return YES;
    }

    NSRegularExpression *valuesRegex = [NSRegularExpression
        regularExpressionWithPattern:
            @"EdgeInsets(?:\\.fromLTRB)?\\(\\s*([-+0-9.eE]+)\\s*,\\s*"
             @"([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)\\s*,\\s*"
             @"([-+0-9.eE]+)\\s*\\)"
                             options:0
                               error:nil];
    match = [valuesRegex firstMatchInString:description
                                    options:0
                                      range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges == 5) {
        CGFloat left = [[description substringWithRange:
            [match rangeAtIndex:1]] doubleValue];
        CGFloat top = [[description substringWithRange:
            [match rangeAtIndex:2]] doubleValue];
        CGFloat right = [[description substringWithRange:
            [match rangeAtIndex:3]] doubleValue];
        CGFloat bottom = [[description substringWithRange:
            [match rangeAtIndex:4]] doubleValue];
        *value = UIEdgeInsetsMake(top, left, bottom, right);
        return YES;
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
        *value = UIEdgeInsetsMake(vertical, horizontal, vertical, horizontal);
        return YES;
    }

    if ([description containsString:@"EdgeInsets.only("]) {
        CGFloat left = 0;
        CGFloat top = 0;
        CGFloat right = 0;
        CGFloat bottom = 0;
        BOOL matchedEdge = NO;
        for (NSString *edge in @[@"left", @"top", @"right", @"bottom"]) {
            NSString *pattern = [NSString stringWithFormat:
                @"%@:\\s*([-+0-9.eE]+)", edge];
            NSRegularExpression *regex = [NSRegularExpression
                regularExpressionWithPattern:pattern options:0 error:nil];
            NSTextCheckingResult *edgeMatch =
                [regex firstMatchInString:description
                                  options:0
                                    range:NSMakeRange(0, description.length)];
            if (edgeMatch.numberOfRanges != 2) {
                continue;
            }
            CGFloat inset = [[description substringWithRange:
                [edgeMatch rangeAtIndex:1]] doubleValue];
            matchedEdge = YES;
            if ([edge isEqualToString:@"left"]) {
                left = inset;
            } else if ([edge isEqualToString:@"top"]) {
                top = inset;
            } else if ([edge isEqualToString:@"right"]) {
                right = inset;
            } else {
                bottom = inset;
            }
        }
        if (matchedEdge) {
            *value = UIEdgeInsetsMake(top, left, bottom, right);
            return YES;
        }
    }

    return NO;
}

+ (CGPoint)directOffsetFromNode:(NSDictionary *)node found:(BOOL *)found {
    NSDictionary *parentData =
        [node[@"parentData"] isKindOfClass:NSDictionary.class]
            ? node[@"parentData"]
            : nil;
    NSNumber *x = [KKFIInspectorJSON numberFromValue:parentData[@"offsetX"]];
    NSNumber *y = [KKFIInspectorJSON numberFromValue:parentData[@"offsetY"]];
    if (x != nil && y != nil) {
        if (found != NULL) {
            *found = YES;
        }
        return CGPointMake(x.doubleValue, y.doubleValue);
    }

    NSString *description = [self parentDataDescriptionInValue:node[@"renderObject"]];
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
            double parsedX =
                [[description substringWithRange:[match rangeAtIndex:1]] doubleValue];
            double parsedY =
                [[description substringWithRange:[match rangeAtIndex:2]] doubleValue];
            if (isfinite(parsedX) && isfinite(parsedY)) {
                if (found != NULL) {
                    *found = YES;
                }
                return CGPointMake(parsedX, parsedY);
            }
        }
    }

    if (found != NULL) {
        *found = NO;
    }
    return CGPointZero;
}

+ (CGPoint)offsetFromNode:(NSDictionary *)node
    useParentRenderElementOffset:(BOOL)useParentRenderElementOffset
                           found:(BOOL *)found {
    BOOL foundDirectOffset = NO;
    CGPoint directOffset =
        [self directOffsetFromNode:node found:&foundDirectOffset];
    if (foundDirectOffset) {
        if (found != NULL) {
            *found = YES;
        }
        return directOffset;
    }

    // Some high-level widgets expose a semantic RenderObject whose parentData
    // is intentionally empty. Their actual placement in the outer layout is
    // carried by parentRenderElement instead. AppBar is a common example: its
    // RenderSemanticsAnnotations has no offset, while the Scaffold slot's
    // ConstrainedBox contains offset=(0, 0). Reuse that offset only when both
    // nodes have the same measured size, so a structurally related but
    // geometrically different ancestor cannot move this element incorrectly.
    NSDictionary *parentRenderElement =
        [node[@"parentRenderElement"] isKindOfClass:NSDictionary.class]
            ? node[@"parentRenderElement"]
            : nil;
    if (useParentRenderElementOffset &&
        [self nodeMatchesParentRenderElementSize:node]) {
        BOOL foundCarrierOffset = NO;
        CGPoint carrierOffset =
            [self directOffsetFromNode:parentRenderElement
                                 found:&foundCarrierOffset];
        if (foundCarrierOffset) {
            if (found != NULL) {
                *found = YES;
            }
            return carrierOffset;
        }
    }

    if (found != NULL) {
        *found = NO;
    }
    return CGPointZero;
}

+ (NSString *)renderObjectIDFromNode:(NSDictionary *)node {
    NSDictionary *renderObject =
        [node[@"renderObject"] isKindOfClass:NSDictionary.class]
            ? node[@"renderObject"]
            : nil;
    return [renderObject[@"valueId"] isKindOfClass:NSString.class]
        ? renderObject[@"valueId"]
        : nil;
}

+ (BOOL)nodeMatchesParentRenderElementSize:(NSDictionary *)node {
    NSDictionary *parentRenderElement =
        [node[@"parentRenderElement"] isKindOfClass:NSDictionary.class]
            ? node[@"parentRenderElement"]
            : nil;
    BOOL foundNodeSize = NO;
    BOOL foundParentSize = NO;
    CGSize nodeSize = [self sizeFromNode:node found:&foundNodeSize];
    CGSize parentSize =
        [self sizeFromNode:parentRenderElement found:&foundParentSize];
    const CGFloat tolerance = 0.01;
    return foundNodeSize && foundParentSize &&
        fabs(nodeSize.width - parentSize.width) < tolerance &&
        fabs(nodeSize.height - parentSize.height) < tolerance;
}

+ (NSString *)parentDataDescriptionInValue:(id)value {
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        if ([dictionary[@"name"] isEqual:@"parentData"] &&
            [dictionary[@"description"] isKindOfClass:NSString.class]) {
            return dictionary[@"description"];
        }
        for (id child in dictionary.allValues) {
            NSString *result = [self parentDataDescriptionInValue:child];
            if (result.length > 0) {
                return result;
            }
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id child in value) {
            NSString *result = [self parentDataDescriptionInValue:child];
            if (result.length > 0) {
                return result;
            }
        }
    }
    return nil;
}

@end
