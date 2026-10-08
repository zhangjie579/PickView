//
//  PVRequestType.h
//  PickView
//
//  Created by kris cheng on 2026/7/6.
//

#ifndef PVRequestType_h
#define PVRequestType_h

typedef NS_ENUM(uint32_t, PVRequestType) {
    PVRequestTypeConnectionAuthorization = 199,
    PVRequestTypePing = 200,
    PVRequestTypeAppInfo = 201,
    PVRequestTypeHierarchy = 202,
    PVRequestTypeHierarchyDetails = 203,
    PVRequestTypeModifyAttribute = 204,
    PVRequestTypeAttrModificationPatch = 205,
    PVRequestTypeInvokeMethod = 206,
    PVRequestTypeFetchObject = 207,
    PVRequestTypeFetchImageViewImage = 208,
    PVRequestTypeModifyRecognizerEnable = 209,
    PVRequestTypeAllAttrGroups = 210,
    PVRequestTypeAllSelectorNames = 213,
    PVRequestTypeCustomAttrModification = 214,

    PVRequestTypeMessage = 230,
    PVRequestTypeHeartbeat = 231,
    PVRequestTypeWindowList = 232,
    /// Inspector 偏好设置由 Mac 端下发给被调试 app，例如 Flutter 层级过滤开关
    PVRequestTypeInspectorSettings = 233,

    PVRequestTypeCancelHierarchyDetails = 304
};

/// PVRequestTypeInspectorSettings 的设置项 key。Mac 端与被调试 app 共用同一个 header，
/// 这里用宏定义以避免为了一个常量再新增一个编译单元。
#define PVInspectorSettingsKey_HideFlutterBlocWidgets @"hideFlutterBlocWidgets"

#endif /* PVRequestType_h */
