#import "KKFIInspectorModels.h"

@implementation KKFIElementReference

- (instancetype)initWithObjectID:(NSString *)objectID
                      objectGroup:(NSString *)objectGroup
                        isolateID:(NSString *)isolateID
                       snapshotID:(NSString *)snapshotID {
    self = [super init];
    if (self) {
        _objectID = [objectID copy];
        _objectGroup = [objectGroup copy];
        _isolateID = [isolateID copy];
        _snapshotID = [snapshotID copy];
    }
    return self;
}

@end

@implementation KKFIInspectorElement

- (instancetype)initWithReference:(KKFIElementReference *)reference
                        widgetType:(NSString *)widgetType
                elementDescription:(NSString *)elementDescription
                  renderObjectType:(NSString *)renderObjectType
                          nodeKind:(NSString *)nodeKind
                         paintRole:(NSString *)paintRole
                    renderStrategy:(NSString *)renderStrategy
                   captureEligible:(BOOL)captureEligible
                       textPreview:(NSString *)textPreview
                  nativeDecoration:(NSDictionary *)nativeDecoration
                     capabilities:(NSArray<NSString *> *)capabilities
                             frame:(CGRect)frame
                          hasFrame:(BOOL)hasFrame
                           rawJSON:(NSDictionary *)rawJSON
                   childrenLayouts:(NSArray<NSDictionary *> *)childrenLayouts
                   layoutModifiers:(NSArray<NSDictionary *> *)layoutModifiers
                      interactions:(NSArray<NSDictionary *> *)interactions
                          semantics:(NSArray<NSDictionary *> *)semantics
                          children:(NSArray<KKFIInspectorElement *> *)children {
    self = [super init];
    if (self) {
        _reference = reference;
        _widgetType = [widgetType copy];
        _elementDescription = [elementDescription copy];
        _renderObjectType = [renderObjectType copy];
        _nodeKind = [nodeKind copy];
        _paintRole = [paintRole copy];
        _renderStrategy = [renderStrategy copy];
        _captureEligible = captureEligible;
        _textPreview = [textPreview copy];
        _nativeDecoration = [nativeDecoration copy];
        _capabilities = [capabilities copy];
        _frame = frame;
        _hasFrame = hasFrame;
        _rawJSON = [rawJSON copy];
        _childrenLayouts = [childrenLayouts copy];
        _layoutModifiers = [layoutModifiers copy];
        _interactions = [interactions copy];
        _semantics = [semantics copy];
        _children = [children copy];
    }
    return self;
}

@end

@implementation KKFIHierarchySnapshot

- (instancetype)initWithSnapshotID:(NSString *)snapshotID
                        objectGroup:(NSString *)objectGroup
                          isolateID:(NSString *)isolateID
                        rootElement:(KKFIInspectorElement *)rootElement {
    self = [super init];
    if (self) {
        _snapshotID = [snapshotID copy];
        _objectGroup = [objectGroup copy];
        _isolateID = [isolateID copy];
        _rootElement = rootElement;
    }
    return self;
}

@end

@implementation KKFIScreenshotOptions

- (instancetype)initWithLogicalSize:(CGSize)logicalSize {
    self = [super init];
    if (self) {
        _logicalSize = logicalSize;
        _maxPixelRatio = 1;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    KKFIScreenshotOptions *copy =
        [[[self class] allocWithZone:zone] initWithLogicalSize:self.logicalSize];
    copy.margin = self.margin;
    copy.maxPixelRatio = self.maxPixelRatio;
    copy.debugPaint = self.debugPaint;
    return copy;
}

@end

@implementation KKFIScreenshotResult

- (instancetype)initWithImage:(UIImage *)image pngData:(NSData *)pngData {
    self = [super init];
    if (self) {
        _image = image;
        _pngData = [pngData copy];
        CGImageRef imageRef = image.CGImage;
        _pixelSize = imageRef == NULL
            ? CGSizeZero
            : CGSizeMake(CGImageGetWidth(imageRef), CGImageGetHeight(imageRef));
    }
    return self;
}

@end
