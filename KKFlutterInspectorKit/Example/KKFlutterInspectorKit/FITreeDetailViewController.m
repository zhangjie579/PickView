//
//  FITreeDetailViewController.m
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/14.
//

#import "FITreeDetailViewController.h"

#import <KKFlutterInspectorKit/KKFlutterInspector.h>

@interface FITreeRow : NSObject

@property(nonatomic, strong) KKFIInspectorElement *element;
@property(nonatomic) NSUInteger depth;

@end


@implementation FITreeRow
@end


@interface FIElementDetailRow : NSObject

@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *value;

@end


@implementation FIElementDetailRow
@end


@interface FIElementDetailSection : NSObject

@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSArray<FIElementDetailRow *> *rows;

@end


@implementation FIElementDetailSection
@end


@interface FIElementDetailViewController : UITableViewController

- (instancetype)initWithElement:(KKFIInspectorElement *)element
                       inspector:(nullable KKFlutterInspector *)inspector;

@end


@interface FIElementDetailViewController ()

@property(nonatomic, strong) KKFIInspectorElement *element;
@property(nonatomic, weak) KKFlutterInspector *inspector;
@property(nonatomic, copy) NSArray<FIElementDetailSection *> *sections;
@property(nonatomic, copy, nullable) NSArray<NSDictionary *> *diagnosticProperties;
@property(nonatomic, strong, nullable) NSError *propertiesError;
@property(nonatomic) BOOL propertiesLoading;
@property(nonatomic, strong, nullable) KKFIScreenshotResult *screenshotResult;
@property(nonatomic, strong, nullable) NSError *screenshotError;
@property(nonatomic, strong) UIImageView *screenshotView;
@property(nonatomic, strong) UILabel *screenshotStatusLabel;
@property(nonatomic, strong) UIActivityIndicatorView *screenshotIndicator;

@end


@implementation FIElementDetailViewController

- (instancetype)initWithElement:(KKFIInspectorElement *)element
                       inspector:(nullable KKFlutterInspector *)inspector {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _element = element;
        _inspector = inspector;
        _propertiesLoading = inspector != nil;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.element.widgetType;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 88;
    [self configureScreenshotHeader];
    [self rebuildSections];
    [self loadInspectorDetails];
}

- (void)configureScreenshotHeader {
    CGFloat width = CGRectGetWidth(UIScreen.mainScreen.bounds);
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 220)];
    header.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;

    self.screenshotView = [[UIImageView alloc]
        initWithFrame:CGRectInset(header.bounds, 16, 16)];
    self.screenshotView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.screenshotView.contentMode = UIViewContentModeScaleAspectFit;
    self.screenshotView.clipsToBounds = YES;
    [header addSubview:self.screenshotView];

    self.screenshotStatusLabel = [[UILabel alloc] initWithFrame:header.bounds];
    self.screenshotStatusLabel.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.screenshotStatusLabel.text = @"Loading screenshot…";
    self.screenshotStatusLabel.textColor = UIColor.secondaryLabelColor;
    self.screenshotStatusLabel.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.screenshotStatusLabel.textAlignment = NSTextAlignmentCenter;
    self.screenshotStatusLabel.numberOfLines = 0;
    [header addSubview:self.screenshotStatusLabel];

    self.screenshotIndicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.screenshotIndicator.center = CGPointMake(CGRectGetMidX(header.bounds),
                                                   CGRectGetMidY(header.bounds) - 24);
    self.screenshotIndicator.autoresizingMask =
        UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleRightMargin |
        UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleBottomMargin;
    [self.screenshotIndicator startAnimating];
    [header addSubview:self.screenshotIndicator];
    self.tableView.tableHeaderView = header;
}

- (void)loadInspectorDetails {
    KKFlutterInspector *inspector = self.inspector;
    if (inspector == nil) {
        self.propertiesLoading = NO;
        self.screenshotStatusLabel.text = @"Inspector is unavailable.";
        [self.screenshotIndicator stopAnimating];
        [self rebuildSections];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [inspector fetchPropertiesForElement:self.element.reference
                              completion:^(NSArray<NSDictionary *> *properties,
                                           NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self == nil) {
                return;
            }
            self.propertiesLoading = NO;
            self.diagnosticProperties = properties;
            self.propertiesError = error;
            [self rebuildSections];
        });
    }];

    CGSize logicalSize = self.element.frame.size;
    if (!self.element.hasFrame || logicalSize.width <= 0 ||
        logicalSize.height <= 0) {
        self.screenshotStatusLabel.text = @"Screenshot unavailable: no geometry.";
        [self.screenshotIndicator stopAnimating];
        return;
    }
    KKFIScreenshotOptions *options =
        [[KKFIScreenshotOptions alloc] initWithLogicalSize:logicalSize];
    options.maxPixelRatio = MIN(UIScreen.mainScreen.scale, 3.0);
    [inspector captureScreenshotForElement:self.element.reference
                                   options:options
                                completion:^(KKFIScreenshotResult *result,
                                             NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self == nil) {
                return;
            }
            self.screenshotResult = result;
            self.screenshotError = error;
            [self.screenshotIndicator stopAnimating];
            if (result.image != nil) {
                self.screenshotView.image = result.image;
                self.screenshotStatusLabel.hidden = YES;
            } else {
                self.screenshotStatusLabel.text =
                    error.localizedDescription ?: @"Screenshot unavailable.";
            }
            [self rebuildSections];
        });
    }];
}

- (void)rebuildSections {
    NSMutableArray<FIElementDetailSection *> *sections = [NSMutableArray array];
    [sections addObject:[self sectionWithTitle:@"Element"
                                          rows:@[
        [self rowWithTitle:@"Widget type" value:self.element.widgetType],
        [self rowWithTitle:@"Description" value:self.element.elementDescription],
        [self rowWithTitle:@"RenderObject" value:self.element.renderObjectType],
    ]]];

    [sections addObject:[self sectionWithTitle:@"Geometry"
                                          rows:@[
        [self rowWithTitle:@"Frame" value:NSStringFromCGRect(self.element.frame)],
        [self rowWithTitle:@"Has frame"
                     value:self.element.hasFrame ? @"YES" : @"NO"],
        [self rowWithTitle:@"Visible children"
                     value:[NSString stringWithFormat:@"%@",
                                                      @(self.element.children.count)]],
    ]]];

    NSMutableArray<FIElementDetailRow *> *renderingRows =
        [NSMutableArray arrayWithArray:@[
        [self rowWithTitle:@"Node kind" value:self.element.nodeKind],
        [self rowWithTitle:@"Paint role" value:self.element.paintRole],
        [self rowWithTitle:@"Render strategy" value:self.element.renderStrategy],
        [self rowWithTitle:@"Screenshot eligible"
                     value:self.element.captureEligible ? @"YES" : @"NO"],
        [self rowWithTitle:@"Capabilities"
                     value:self.element.capabilities.count > 0
                         ? [self.element.capabilities componentsJoinedByString:@", "]
                         : @"None"],
    ]];
    if (self.element.textPreview.length > 0) {
        [renderingRows addObject:[self rowWithTitle:@"Text preview"
                                             value:self.element.textPreview]];
    }
    [sections addObject:[self sectionWithTitle:@"Rendering"
                                          rows:renderingRows]];
    if (self.element.nativeDecoration != nil) {
        [sections addObject:[self sectionWithTitle:@"Native decoration"
                                              rows:@[
            [self rowWithTitle:@"Decoration"
                         value:[self prettyJSONStringForObject:
                             self.element.nativeDecoration]],
        ]]];
    }

    KKFIElementReference *reference = self.element.reference;
    [sections addObject:[self sectionWithTitle:@"Reference"
                                          rows:@[
        [self rowWithTitle:@"Object ID" value:reference.objectID],
        [self rowWithTitle:@"Object group" value:reference.objectGroup],
        [self rowWithTitle:@"Isolate ID" value:reference.isolateID],
        [self rowWithTitle:@"Snapshot ID" value:reference.snapshotID],
    ]]];

    [self appendDiagnosticsToSections:sections];
    [self appendRelations:self.element.childrenLayouts
                    title:@"Children layouts"
               toSections:sections];
    [self appendRelations:self.element.layoutModifiers
                    title:@"Layout modifiers"
               toSections:sections];
    [self appendRelations:self.element.interactions
                    title:@"Interactions"
               toSections:sections];
    [self appendRelations:self.element.semantics
                    title:@"Semantics"
               toSections:sections];
    [self appendChildrenToSections:sections];
    [self appendScreenshotToSections:sections];
    [sections addObject:[self sectionWithTitle:@"Raw layout JSON"
                                          rows:@[
        [self rowWithTitle:@"Payload"
                     value:[self prettyJSONStringForObject:self.element.rawJSON]],
    ]]];
    self.sections = sections.copy;
    if (self.isViewLoaded) {
        [self.tableView reloadData];
    }
}

- (void)appendDiagnosticsToSections:
    (NSMutableArray<FIElementDetailSection *> *)sections {
    if (self.propertiesLoading) {
        [sections addObject:[self sectionWithTitle:@"Diagnostics properties"
                                              rows:@[
            [self rowWithTitle:@"Status" value:@"Loading…"],
        ]]];
        return;
    }
    if (self.propertiesError != nil) {
        [sections addObject:[self sectionWithTitle:@"Diagnostics properties"
                                              rows:@[
            [self rowWithTitle:@"Error"
                         value:self.propertiesError.localizedDescription],
        ]]];
        return;
    }
    if (self.diagnosticProperties.count == 0) {
        return;
    }
    NSMutableArray<FIElementDetailRow *> *rows = [NSMutableArray array];
    [self.diagnosticProperties
        enumerateObjectsUsingBlock:^(NSDictionary *property,
                                      NSUInteger index,
                                      BOOL *stop) {
        NSString *name = [property[@"name"] isKindOfClass:NSString.class]
            ? property[@"name"]
            : [NSString stringWithFormat:@"Property %@", @(index + 1)];
        [rows addObject:[self rowWithTitle:name
                                     value:[self prettyJSONStringForObject:property]]];
    }];
    [sections addObject:[self sectionWithTitle:@"Diagnostics properties"
                                          rows:rows]];
}

- (void)appendRelations:(NSArray<NSDictionary *> *)relations
                   title:(NSString *)title
              toSections:(NSMutableArray<FIElementDetailSection *> *)sections {
    if (relations.count == 0) {
        return;
    }
    NSMutableArray<FIElementDetailRow *> *rows = [NSMutableArray array];
    [relations enumerateObjectsUsingBlock:^(NSDictionary *relation,
                                             NSUInteger index,
                                             BOOL *stop) {
        NSString *type = [relation[@"type"] isKindOfClass:NSString.class]
            ? relation[@"type"]
            : [NSString stringWithFormat:@"Relation %@", @(index + 1)];
        [rows addObject:[self rowWithTitle:type
                                     value:[self prettyJSONStringForObject:relation]]];
    }];
    [sections addObject:[self sectionWithTitle:title rows:rows]];
}

- (void)appendChildrenToSections:
    (NSMutableArray<FIElementDetailSection *> *)sections {
    if (self.element.children.count == 0) {
        return;
    }
    NSMutableArray<FIElementDetailRow *> *rows = [NSMutableArray array];
    for (KKFIInspectorElement *child in self.element.children) {
        NSString *value = [NSString stringWithFormat:
            @"RenderObject: %@\nObject ID: %@\nFrame: %@",
            child.renderObjectType, child.reference.objectID,
            NSStringFromCGRect(child.frame)];
        [rows addObject:[self rowWithTitle:child.widgetType value:value]];
    }
    [sections addObject:[self sectionWithTitle:@"Visible children" rows:rows]];
}

- (void)appendScreenshotToSections:
    (NSMutableArray<FIElementDetailSection *> *)sections {
    if (self.screenshotResult != nil) {
        NSString *pixelSize = NSStringFromCGSize(self.screenshotResult.pixelSize);
        NSString *byteCount = [NSByteCountFormatter
            stringFromByteCount:(long long)self.screenshotResult.pngData.length
                      countStyle:NSByteCountFormatterCountStyleFile];
        [sections addObject:[self sectionWithTitle:@"Screenshot"
                                              rows:@[
            [self rowWithTitle:@"Pixel size" value:pixelSize],
            [self rowWithTitle:@"PNG data" value:byteCount],
        ]]];
    } else if (self.screenshotError != nil) {
        [sections addObject:[self sectionWithTitle:@"Screenshot"
                                              rows:@[
            [self rowWithTitle:@"Error"
                         value:self.screenshotError.localizedDescription],
        ]]];
    }
}

- (FIElementDetailRow *)rowWithTitle:(NSString *)title value:(NSString *)value {
    FIElementDetailRow *row = [[FIElementDetailRow alloc] init];
    row.title = title ?: @"";
    row.value = value ?: @"";
    return row;
}

- (FIElementDetailSection *)sectionWithTitle:(NSString *)title
                                         rows:(NSArray<FIElementDetailRow *> *)rows {
    FIElementDetailSection *section = [[FIElementDetailSection alloc] init];
    section.title = title ?: @"";
    section.rows = rows ?: @[];
    return section;
}

- (NSString *)prettyJSONStringForObject:(id)object {
    if (object == nil || ![NSJSONSerialization isValidJSONObject:object]) {
        return [object description] ?: @"";
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingPrettyPrinted |
                                                           NSJSONWritingSortedKeys
                                                     error:nil];
    return data == nil
        ? ([object description] ?: @"")
        : ([[NSString alloc] initWithData:data
                                  encoding:NSUTF8StringEncoding] ?: @"");
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].rows.count;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    return self.sections[section].title;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const reuseIdentifier = @"FlutterElementDetail";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:reuseIdentifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:12
                                                               weight:UIFontWeightRegular];
        cell.detailTextLabel.numberOfLines = 0;
    }
    FIElementDetailRow *row = self.sections[indexPath.section].rows[indexPath.row];
    cell.textLabel.text = row.title;
    cell.detailTextLabel.text = row.value;
    return cell;
}

@end


@interface FITreeDetailViewController ()

@property(nonatomic, copy) NSArray<FITreeRow *> *rows;
@property(nonatomic, strong, nullable) KKFIHierarchySnapshot *snapshot;
@property(nonatomic, strong, nullable) NSError *loadError;
@property(nonatomic, weak) KKFlutterInspector *inspector;

@end


@implementation FITreeDetailViewController

- (instancetype)initWithInspector:(KKFlutterInspector *)inspector {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _inspector = inspector;
    }
    return self;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Flutter Tree";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    [self reloadContent];
}

- (void)displaySnapshot:(KKFIHierarchySnapshot *)snapshot
                  error:(NSError *)error {
    NSAssert(NSThread.isMainThread, @"Tree UI must update on the main thread.");
    self.snapshot = snapshot;
    self.loadError = error;
    if (self.isViewLoaded) {
        [self reloadContent];
    }
}

- (void)reloadContent {
    if (self.loadError != nil) {
        self.rows = @[];
        UILabel *label = [[UILabel alloc] init];
        label.text = self.loadError.localizedDescription;
        label.textColor = UIColor.secondaryLabelColor;
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        self.tableView.backgroundView = label;
        [self.tableView reloadData];
        return;
    }

    if (self.snapshot == nil) {
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [indicator startAnimating];
        self.tableView.backgroundView = indicator;
        return;
    }

    NSMutableArray<FITreeRow *> *rows = [NSMutableArray array];
    [self appendElement:self.snapshot.rootElement depth:0 rows:rows];
    self.rows = rows.copy;
    self.title = [NSString stringWithFormat:@"Flutter Tree (%lu)",
                                            (unsigned long)rows.count];
    self.tableView.backgroundView = nil;
    [self.tableView reloadData];
}

- (void)appendElement:(KKFIInspectorElement *)element
                 depth:(NSUInteger)depth
                  rows:(NSMutableArray<FITreeRow *> *)rows {
    FITreeRow *row = [[FITreeRow alloc] init];
    row.element = element;
    row.depth = depth;
    [rows addObject:row];
    for (KKFIInspectorElement *child in element.children) {
        [self appendElement:child depth:depth + 1 rows:rows];
    }
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const reuseIdentifier = @"FlutterTreeNode";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
            reuseIdentifier:reuseIdentifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:15
                                                        weight:UIFontWeightSemibold];
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11
                                                               weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.numberOfLines = 0;
        cell.indentationWidth = 14;
    }

    FITreeRow *row = self.rows[indexPath.row];
    KKFIInspectorElement *element = row.element;
    cell.indentationLevel = MIN((NSInteger)row.depth, 15);
    cell.textLabel.text = element.widgetType;
    NSString *frame = element.hasFrame
        ? NSStringFromCGRect(element.frame)
        : @"frame unavailable";
    NSMutableArray<NSString *> *details = [NSMutableArray arrayWithObjects:
        element.renderObjectType, frame, nil];
    NSArray<NSString *> *childrenLayoutTypes =
        [self relationTypesFromValues:element.childrenLayouts];
    if (childrenLayoutTypes.count > 0) {
        [details addObject:[NSString
            stringWithFormat:@"children layout: %@",
                             [childrenLayoutTypes componentsJoinedByString:@", "]]];
    }
    NSArray<NSString *> *modifierTypes =
        [self relationTypesFromValues:element.layoutModifiers];
    if (modifierTypes.count > 0) {
        [details addObject:[NSString
            stringWithFormat:@"modifiers: %@",
                             [modifierTypes componentsJoinedByString:@", "]]];
    }
    cell.detailTextLabel.text = [details componentsJoinedByString:@"\n"];
    return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    KKFIInspectorElement *element = self.rows[indexPath.row].element;
    FIElementDetailViewController *detailViewController =
        [[FIElementDetailViewController alloc] initWithElement:element
                                                     inspector:self.inspector];
    [self.navigationController pushViewController:detailViewController animated:YES];
}

- (NSArray<NSString *> *)relationTypesFromValues:(NSArray<NSDictionary *> *)values {
    NSMutableArray<NSString *> *types = [NSMutableArray array];
    for (NSDictionary *value in values) {
        NSString *type = [value[@"type"] isKindOfClass:NSString.class]
            ? value[@"type"]
            : nil;
        if (type.length > 0) {
            [types addObject:type];
        }
    }
    return types.copy;
}

@end
