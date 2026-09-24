//
//  KKFIInspectorModels.h
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/14.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Identifies an Inspector object within one hierarchy snapshot.
@interface KKFIElementReference : NSObject

@property(nonatomic, copy, readonly) NSString *objectID;
@property(nonatomic, copy, readonly) NSString *objectGroup;
@property(nonatomic, copy, readonly) NSString *isolateID;
@property(nonatomic, copy, readonly) NSString *snapshotID;

- (instancetype)initWithObjectID:(NSString *)objectID
                      objectGroup:(NSString *)objectGroup
                        isolateID:(NSString *)isolateID
                       snapshotID:(NSString *)snapshotID
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

/// A visual Flutter hierarchy node. Nonvisual Flutter wrappers are retained as
/// typed relations so a client can present them as Inspector properties.
@interface KKFIInspectorElement : NSObject

@property(nonatomic, strong, readonly) KKFIElementReference *reference;
@property(nonatomic, copy, readonly) NSString *widgetType;
@property(nonatomic, copy, readonly) NSString *elementDescription;
@property(nonatomic, copy, readonly) NSString *renderObjectType;
/// Broad presentation category such as text, layout, box, image, or control.
@property(nonatomic, copy, readonly) NSString *nodeKind;
/// Whether the node paints content, applies a paint effect, or is layout-only.
@property(nonatomic, copy, readonly) NSString *paintRole;
/// Suggested preview strategy derived from the node and its visible children.
@property(nonatomic, copy, readonly) NSString *renderStrategy;
/// Whether automatic preview generation should request an Inspector screenshot.
/// Manual screenshots may still be requested through KKFlutterInspector.
@property(nonatomic, readonly) BOOL captureEligible;
@property(nonatomic, copy, readonly, nullable) NSString *textPreview;
/// A conservatively parsed solid/box/physical decoration that a client can
/// render without flattening the node's visible children into a screenshot.
@property(nonatomic, copy, readonly, nullable) NSDictionary *nativeDecoration;
/// Feature tags such as layout, paint, clip, transform, and scroll.
@property(nonatomic, copy, readonly) NSArray<NSString *> *capabilities;
@property(nonatomic, readonly) CGRect frame;
@property(nonatomic, readonly) BOOL hasFrame;
@property(nonatomic, copy, readonly) NSDictionary *rawJSON;
/// Multi-child layout policies, such as Column and Stack, that manage this
/// element's visible children without occupying their own hierarchy row.
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *childrenLayouts;
/// Single-child layout wrappers, such as Padding and Align, folded into this
/// visible element.
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *layoutModifiers;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *interactions;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *semantics;
@property(nonatomic, copy, readonly) NSArray<KKFIInspectorElement *> *children;

- (instancetype)initWithReference:(KKFIElementReference *)reference
                        widgetType:(NSString *)widgetType
                 elementDescription:(NSString *)elementDescription
                  renderObjectType:(NSString *)renderObjectType
                           nodeKind:(NSString *)nodeKind
                          paintRole:(NSString *)paintRole
                     renderStrategy:(NSString *)renderStrategy
                    captureEligible:(BOOL)captureEligible
                        textPreview:(nullable NSString *)textPreview
                   nativeDecoration:(nullable NSDictionary *)nativeDecoration
                      capabilities:(NSArray<NSString *> *)capabilities
                             frame:(CGRect)frame
                          hasFrame:(BOOL)hasFrame
                           rawJSON:(NSDictionary *)rawJSON
                   childrenLayouts:(NSArray<NSDictionary *> *)childrenLayouts
                   layoutModifiers:(NSArray<NSDictionary *> *)layoutModifiers
                      interactions:(NSArray<NSDictionary *> *)interactions
                          semantics:(NSArray<NSDictionary *> *)semantics
                          children:(NSArray<KKFIInspectorElement *> *)children
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface KKFIHierarchySnapshot : NSObject

@property(nonatomic, copy, readonly) NSString *snapshotID;
@property(nonatomic, copy, readonly) NSString *objectGroup;
@property(nonatomic, copy, readonly) NSString *isolateID;
@property(nonatomic, strong, readonly) KKFIInspectorElement *rootElement;

- (instancetype)initWithSnapshotID:(NSString *)snapshotID
                        objectGroup:(NSString *)objectGroup
                          isolateID:(NSString *)isolateID
                        rootElement:(KKFIInspectorElement *)rootElement
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface KKFIScreenshotOptions : NSObject <NSCopying>

@property(nonatomic) CGSize logicalSize;
@property(nonatomic) CGFloat margin;
@property(nonatomic) CGFloat maxPixelRatio;
@property(nonatomic) BOOL debugPaint;

- (instancetype)initWithLogicalSize:(CGSize)logicalSize
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end


@interface KKFIScreenshotResult : NSObject

@property(nonatomic, strong, readonly) UIImage *image;
@property(nonatomic, copy, readonly) NSData *pngData;
@property(nonatomic, readonly) CGSize pixelSize;

- (instancetype)initWithImage:(UIImage *)image pngData:(NSData *)pngData
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
