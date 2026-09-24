#import "KKFIInspectorJSON.h"

#import <math.h>

@implementation KKFIInspectorJSON

+ (id)normalizedPayloadFromResponse:(NSDictionary *)response {
    NSDictionary *result = [response[@"result"] isKindOfClass:NSDictionary.class]
        ? response[@"result"]
        : nil;
    if (result == nil) {
        return response;
    }

    id serviceResponse = result[@"response"];
    if (serviceResponse != nil) {
        return [self unwrapInspectorValue:serviceResponse];
    }

    id nestedResult = result[@"result"];
    if (nestedResult != nil) {
        return [self unwrapInspectorValue:nestedResult];
    }
    return response;
}

+ (NSString *)nodeIDFromDictionary:(NSDictionary *)dictionary {
    NSString *valueID = [dictionary[@"valueId"] isKindOfClass:NSString.class]
        ? dictionary[@"valueId"]
        : nil;
    if (valueID.length > 0) {
        return valueID;
    }
    NSString *objectID = [dictionary[@"objectId"] isKindOfClass:NSString.class]
        ? dictionary[@"objectId"]
        : nil;
    return objectID.length > 0 ? objectID : nil;
}

+ (NSNumber *)numberFromValue:(id)value {
    if ([value isKindOfClass:NSNumber.class]) {
        return isfinite([value doubleValue]) ? value : nil;
    }
    if ([value isKindOfClass:NSString.class]) {
        double number = [value doubleValue];
        return isfinite(number) ? @(number) : nil;
    }
    return nil;
}

+ (id)unwrapInspectorValue:(id)value {
    if ([value isKindOfClass:NSString.class]) {
        NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
        id decoded = data == nil
            ? nil
            : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (decoded != nil) {
            return [self unwrapInspectorValue:decoded];
        }
    }

    if ([value isKindOfClass:NSDictionary.class]) {
        id nestedResult = value[@"result"];
        if (nestedResult != nil) {
            return [self unwrapInspectorValue:nestedResult];
        }
    }
    return value;
}

@end
