// Geometry-only regression against the actual InspectorKit sources. The small
// UIKit adapter in run.py maps value types to AppKit; no UI/image APIs are used.
#import <UIKit/UIKit.h>
#import "KKFIHierarchyEnricher.h"
#import "KKFIInspectorTreeBuilder.h"
#import "KKFIInspectorModels.h"

@implementation NSImage (PVGeometryTest)
- (CGImageRef)CGImage { return [self CGImageForProposedRect:NULL context:nil hints:nil]; }
@end
@implementation NSValue (PVGeometryTest)
+ (NSValue *)valueWithCGPoint:(CGPoint)value { return [self valueWithPoint:value]; }
+ (NSValue *)valueWithCGSize:(CGSize)value { return [self valueWithSize:value]; }
- (CGPoint)CGPointValue { return self.pointValue; }
- (CGSize)CGSizeValue { return self.sizeValue; }
@end

static NSDictionary *Render(NSString *identity, CGPoint offset) {
    return @{@"valueId": identity, @"description": @"RenderBox#test", @"properties": @[
        @{@"name": @"parentData", @"description": [NSString stringWithFormat:@"offset=Offset(%g, %g)", offset.x, offset.y]}
    ]};
}
static NSDictionary *Node(NSString *identity, NSString *type, NSString *renderID, CGPoint offset, NSArray *children) {
    return @{@"valueId": identity, @"widgetRuntimeType": type, @"description": type,
             @"size": @{@"width": @300, @"height": @600},
             @"parentData": @{@"offsetX": @(offset.x), @"offsetY": @(offset.y)},
             @"renderObject": Render(renderID, offset), @"children": children};
}

@interface ScrollFixtureClient : NSObject
@property(nonatomic, copy) NSDictionary *details;
@end
@implementation ScrollFixtureClient
- (void)callMethod:(NSString *)method params:(NSDictionary *)params completion:(void (^)(NSDictionary *, NSError *))completion {
    id value = [method hasSuffix:@"getDetailsSubtree"] ? self.details : @[];
    completion(@{@"result": @{@"result": value}}, nil);
}
@end

static NSValue *Position(KKFIInspectorElement *item, NSString *identity, CGPoint parent) {
    CGPoint point = CGPointMake(parent.x + item.frame.origin.x, parent.y + item.frame.origin.y);
    if ([item.reference.objectID isEqual:identity]) return [NSValue valueWithCGPoint:point];
    for (KKFIInspectorElement *child in item.children) {
        NSValue *found = Position(child, identity, point);
        if (found) return found;
    }
    return nil;
}

static void CheckCase(CGPoint paintOffset, CGFloat padding, BOOL sharedWrapper, BOOL detailsHasRootRenderObject) {
    CGPoint viewportOrigin = CGPointMake(23, 94);
    CGPoint localPadding = CGPointMake(padding, padding);
    NSDictionary *leaf = Node(@"leaf", @"Text", @"render-leaf", CGPointMake(15, 40), @[]);
    NSDictionary *column = Node(@"column", @"Column", @"render-column", localPadding, @[leaf]);
    NSDictionary *target = sharedWrapper ? Node(@"wrapper", @"ScrollContent", @"render-column", localPadding, @[column]) : column;
    NSDictionary *scroll = Node(@"scroll", @"SingleChildScrollView", @"render-scroll", viewportOrigin, @[target]);
    NSDictionary *layout = Node(@"page", @"Column", @"render-page", CGPointZero, @[scroll]);

    NSDictionary *detailsTarget = @{@"valueId": sharedWrapper ? @"wrapper" : @"column",
        @"renderObject": Render(@"render-column", localPadding)};
    NSDictionary *viewport = @{@"valueId": @"internal-viewport", @"renderObject": @{
        @"valueId": @"render-viewport", @"description": @"_RenderSingleChildViewport#test",
        @"properties": @[@{@"name": @"offset", @"description": [NSString stringWithFormat:@"Offset(%g, %g)", paintOffset.x, paintOffset.y]}]
    }, @"children": @[detailsTarget]};
    // Flutter's details tree can omit renderObject on SingleChildScrollView
    // while an internal RepaintBoundary exposes the SAME RenderObject and its
    // offset in the outer page. That offset is not a content-local bridge.
    NSDictionary *repaint = @{@"valueId": @"internal-repaint", @"renderObject": Render(@"render-scroll", viewportOrigin), @"children": @[viewport]};
    NSMutableDictionary *details = [@{@"valueId": @"scroll", @"children": @[repaint]} mutableCopy];
    if (detailsHasRootRenderObject) details[@"renderObject"] = Render(@"render-scroll", viewportOrigin);
    ScrollFixtureClient *client = [ScrollFixtureClient new]; client.details = details;
    __block BOOL completed = NO;
    [[KKFIHierarchyEnricher new] enrichLayoutPayload:layout client:(id)client isolateID:@"isolate" objectGroup:@"group" completion:^(NSDictionary *properties, NSDictionary *offsets) {
        completed = YES;
        KKFIHierarchySnapshot *snapshot = [KKFIInspectorTreeBuilder snapshotFromLayoutPayload:layout widgetPayload:layout
            widgetPropertiesByID:properties resolvedOffsetsByID:offsets rootObjectID:@"page"
            fallbackRootSize:CGSizeMake(300, 600) isolateID:@"isolate" objectGroup:@"group"
            snapshotID:@"snapshot" excludedWidgetTypes:[NSSet set] error:nil];
        NSCAssert(snapshot, @"Snapshot builds");
        CGPoint expected = CGPointMake(viewportOrigin.x + paintOffset.x + padding, viewportOrigin.y + paintOffset.y + padding);
        NSValue *columnPosition = Position(snapshot.rootElement, @"column", CGPointZero);
        NSValue *leafPosition = Position(snapshot.rootElement, @"leaf", CGPointZero);
        NSCAssert(columnPosition && leafPosition, @"Column and descendants remain in the hierarchy");
        CGPoint actual = columnPosition.CGPointValue;
        NSCAssert(fabs(actual.x - expected.x) < 0.01 && fabs(actual.y - expected.y) < 0.01,
                  @"Viewport origin must be counted once: expected %@, actual %@", NSStringFromPoint(expected), NSStringFromPoint(actual));
        CGPoint leafActual = leafPosition.CGPointValue;
        NSCAssert(fabs(leafActual.x - expected.x - 15) < 0.01 && fabs(leafActual.y - expected.y - 40) < 0.01,
                  @"Descendants must inherit the corrected Column position once");
    }];
    NSCAssert(completed, @"Enrichment callback completed");
}
@interface RecordedScrollClient : NSObject
@property(nonatomic, strong) NSDictionary *fixture;
@end
@implementation RecordedScrollClient
- (void)callMethod:(NSString *)method params:(NSDictionary *)params completion:(void (^)(NSDictionary *, NSError *))completion {
    NSDictionary *values = [method hasSuffix:@"getDetailsSubtree"] ? self.fixture[@"details"] : self.fixture[@"properties"];
    completion(@{@"result": @{@"result": values[params[@"arg"]] ?: @[]}}, nil);
}
@end

static void CheckRecordedFixtures(NSString *path) {
    NSArray *fixtures = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
    NSCAssert(fixtures.count > 0, @"Runtime fixtures must load");
    for (NSDictionary *fixture in fixtures) {
        RecordedScrollClient *client = [RecordedScrollClient new];
        client.fixture = fixture;
        __block BOOL completed = NO;
        [[KKFIHierarchyEnricher new] enrichLayoutPayload:fixture[@"layout"] client:(id)client isolateID:@"isolate" objectGroup:@"group"
            completion:^(NSDictionary *properties, NSDictionary *offsets) {
            completed = YES;
            KKFIHierarchySnapshot *snapshot = [KKFIInspectorTreeBuilder snapshotFromLayoutPayload:fixture[@"layout"] widgetPayload:fixture[@"layout"]
                widgetPropertiesByID:properties resolvedOffsetsByID:offsets rootObjectID:fixture[@"rootId"]
                fallbackRootSize:CGSizeMake(800, 600) isolateID:@"isolate" objectGroup:@"group" snapshotID:@"snapshot" excludedWidgetTypes:[NSSet set] error:nil];
            NSCAssert(snapshot, @"%@ snapshot builds", fixture[@"name"]);
            NSDictionary *expected = fixture[@"expected"];
            NSCAssert(expected.count > 0, @"%@ must contain known positions", fixture[@"name"]);
            for (NSString *objectID in expected) {
                NSValue *position = Position(snapshot.rootElement, objectID, CGPointZero);
                NSCAssert(position, @"%@ missing %@", fixture[@"name"], expected[objectID][@"name"]);
                CGPoint actual = position.CGPointValue;
                CGPoint desired = CGPointMake([expected[objectID][@"x"] doubleValue], [expected[objectID][@"y"] doubleValue]);
                NSCAssert(fabs(actual.x - desired.x) < 0.01 && fabs(actual.y - desired.y) < 0.01,
                    @"%@ %@ expected=%@ actual=%@", fixture[@"name"], expected[objectID][@"name"], NSStringFromPoint(desired), NSStringFromPoint(actual));
            }
        }];
        NSCAssert(completed, @"%@ enrichment completed", fixture[@"name"]);
    }
    NSLog(@"PASS: %@ real Flutter scroll geometry cases", @(fixtures.count));
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray<NSValue *> *offsets = @[[NSValue valueWithCGPoint:CGPointZero],
            [NSValue valueWithCGPoint:CGPointMake(0, -80)],
            [NSValue valueWithCGPoint:CGPointMake(0, 80)],
            [NSValue valueWithCGPoint:CGPointMake(-80, 0)]];
        for (NSValue *offset in offsets) for (NSNumber *padding in @[@0, @12])
            for (NSNumber *wrapper in @[@NO, @YES]) for (NSNumber *root in @[@NO, @YES])
                CheckCase(offset.CGPointValue, padding.doubleValue, wrapper.boolValue, root.boolValue);
        NSLog(@"PASS: 32 scroll/Column geometry cases (offset, padding, shared renderer, details root)");
        if (argc > 1) CheckRecordedFixtures([NSString stringWithUTF8String:argv[1]]);
    }
    return 0;
}
