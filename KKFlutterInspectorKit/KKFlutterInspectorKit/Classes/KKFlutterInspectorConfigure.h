//
//  KKFlutterInspectorConfigure.h
//  KKFlutterInspectorKit
//
//  Created by 张杰 on 2026/9/24.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKFlutterInspectorConfigure : NSObject

/// flutter 根节点的 widget name
@property (nonatomic, copy, nullable) NSString *flutterRootNodeWidgetName;

/// 是否在 PickView 上过滤（不显示）Bloc 相关的状态管理 widget。
///
/// 开启后 flutter_bloc 一类的容器/监听控件（BlocProvider、BlocBuilder、
/// BlocListener 等）会从层级快照中移除，它们的子节点会被提升到父级，
/// 因此不会丢失真正需要检视的内容，也不会影响子节点的位置计算。
/// 默认 NO，保持既有行为不变。
@property (nonatomic, assign, getter=isBlocWidgetFilteringEnabled)
    BOOL blocWidgetFilteringEnabled;

/// 参与过滤的 Bloc widget 类型名单。
///
/// 默认包含 flutter_bloc 的常用控件；如果项目里还有自己封装的 Bloc 基类，
/// 可以基于 `+defaultBlocWidgetTypes` 追加，或者直接整体赋值覆盖。
/// 匹配时会同时比较完整类型名和去掉泛型参数后的基础类型名，
/// 二者之一命中即过滤。
@property (nonatomic, copy, nullable) NSSet<NSString *> *blocWidgetTypes;

/// flutter_bloc 的默认过滤名单。
+ (NSSet<NSString *> *)defaultBlocWidgetTypes;

/// 结合过滤开关返回真正参与过滤的名单；开关关闭时返回 nil。
- (nullable NSSet<NSString *> *)activeBlocWidgetTypes;

+ (instancetype)sharedManager;

@end

NS_ASSUME_NONNULL_END
