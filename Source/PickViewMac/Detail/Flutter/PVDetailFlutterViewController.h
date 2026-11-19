//
//  PVDetailFlutterViewController.h
//  PickViewMac
//

#import "PVDetailBaseViewController.h"

@class PVDisplayItem, PVFlutterNodeDetail, PVDetailHierarchyDataSource;

extern const CGFloat PVFlutterInspectorPanelWidth;

@interface PVDetailFlutterViewController : PVDetailBaseViewController

@property(nonatomic, weak, nullable) PVDetailHierarchyDataSource *dataSource;
@property(nonatomic, strong, nullable) PVFlutterNodeDetail *detail;
@property(nonatomic, strong, nullable) PVDisplayItem *displayItem;

@end
