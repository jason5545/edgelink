#import "PrivateVerificationCodeBridge.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static id ELMessageSendId(id target, SEL selector) {
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static id ELMessageSendIdWithObject(id target, SEL selector, id object) {
    return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, object);
}

static void ELMessageSendVoid(id target, SEL selector) {
    ((void (*)(id, SEL))objc_msgSend)(target, selector);
}

static void ELMessageSendVoidObjectInteger(id target, SEL selector, id object, NSInteger value) {
    ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(target, selector, object, value);
}

static id ELMessageSendCurrentCodes(id target, SEL selector, id appIdentifier, id website, id usernameHint, NSInteger fieldClassification) {
    return ((id (*)(id, SEL, id, id, id, NSInteger))objc_msgSend)(target, selector, appIdentifier, website, usernameHint, fieldClassification);
}

static NSString *ELStringSymbol(void *handle, const char *symbolName, NSString *fallback) {
    if (!handle) {
        return fallback;
    }
    void *rawSymbol = dlsym(handle, symbolName);
    if (!rawSymbol) {
        return fallback;
    }
    NSString * __unsafe_unretained *symbol = (NSString * __unsafe_unretained *)rawSymbol;
    return *symbol ?: fallback;
}

static void ELSafeSet(NSMutableDictionary *dictionary, id<NSCopying> key, id _Nullable value) {
    if (key && value && value != [NSNull null]) {
        dictionary[key] = value;
    }
}

static NSDictionary<NSString *, id> *ELExceptionResult(NSString *stage, NSException *exception) {
    return @{
        @"ok": @NO,
        @"stage": stage,
        @"exception": exception.name ?: @"NSException",
        @"reason": exception.reason ?: @""
    };
}

static NSString *ELDLErrorString(void) {
    const char *error = dlerror();
    return error ? [NSString stringWithUTF8String:error] : @"unknown";
}

static NSMutableDictionary *ELIMCorePayload(NSDictionary<NSString *, id> *payload, void *imCoreHandle) {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    NSString *code = [payload[@"code"] isKindOfClass:NSString.class] ? payload[@"code"] : nil;
    NSString *displayCode = [payload[@"displayCode"] isKindOfClass:NSString.class] ? payload[@"displayCode"] : code;
    NSString *machineReadableCode = [payload[@"machineReadableCode"] isKindOfClass:NSString.class] ? payload[@"machineReadableCode"] : nil;
    NSString *guid = [payload[@"guid"] isKindOfClass:NSString.class] ? payload[@"guid"] : [[NSUUID UUID] UUIDString];
    NSString *handle = [payload[@"handle"] isKindOfClass:NSString.class] ? payload[@"handle"] : @"EdgeLink";
    NSString *domain = [payload[@"domain"] isKindOfClass:NSString.class] ? payload[@"domain"] : nil;
    NSString *embeddedDomain = [payload[@"embeddedDomain"] isKindOfClass:NSString.class] ? payload[@"embeddedDomain"] : nil;
    NSNumber *timestamp = [payload[@"timestamp"] isKindOfClass:NSNumber.class] ? payload[@"timestamp"] : @([[NSDate date] timeIntervalSince1970]);

    ELSafeSet(dictionary, ELStringSymbol(imCoreHandle, "IMOneTimeCodeKey", @"code"), code);
    ELSafeSet(dictionary, ELStringSymbol(imCoreHandle, "IMOneTimeCodeDisplayKey", @"displayCode"), displayCode);
    ELSafeSet(dictionary, ELStringSymbol(imCoreHandle, "IMOneTimeCodeMachineReadableCodeKey", @"machineReadableCode"), machineReadableCode);
    ELSafeSet(dictionary, ELStringSymbol(imCoreHandle, "IMOneTimeCodeGuidKey", @"guid"), guid);
    ELSafeSet(dictionary, ELStringSymbol(imCoreHandle, "IMOneTimeCodeHandleKey", @"handle"), handle);
    ELSafeSet(dictionary, ELStringSymbol(imCoreHandle, "IMOneTimeCodeTimeStampKey", @"timeStamp"), [NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue]);
    ELSafeSet(dictionary, ELStringSymbol(imCoreHandle, "IMOneTimeCodeDomainKey", @"domain"), domain);
    ELSafeSet(dictionary, ELStringSymbol(imCoreHandle, "IMOneTimeCodeDomainStrictMatchKey", @"domainStrict"), domain ? @YES : nil);
    ELSafeSet(dictionary, ELStringSymbol(imCoreHandle, "IMOneTimeCodeEmbeddedDomainKey", @"embeddedDomain"), embeddedDomain);
    if (embeddedDomain) {
        ELSafeSet(dictionary, ELStringSymbol(imCoreHandle, "IMOneTimeCodeEmbeddedDomainsKey", @"embeddedDomains"), @[embeddedDomain]);
    }
    return dictionary;
}

static NSDictionary<NSString *, id> *ELDeliverToSafariFoundation(NSDictionary<NSString *, id> *payload) {
    @try {
        void *safariHandle = dlopen("/System/Library/PrivateFrameworks/SafariFoundation.framework/SafariFoundation", RTLD_LAZY | RTLD_LOCAL);
        void *imCoreHandle = dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_LAZY | RTLD_LOCAL);
        if (!safariHandle) {
            return @{
                @"ok": @NO,
                @"stage": @"safariFoundation.dlopen",
                @"error": ELDLErrorString()
            };
        }

        Class oneTimeCodeClass = NSClassFromString(@"SFAutoFillOneTimeCode");
        Class providerClass = NSClassFromString(@"SFAppAutoFillOneTimeCodeProvider");
        if (!oneTimeCodeClass || !providerClass) {
            return @{
                @"ok": @NO,
                @"stage": @"safariFoundation.class",
                @"hasCodeClass": @(oneTimeCodeClass != Nil),
                @"hasProviderClass": @(providerClass != Nil)
            };
        }

        NSDictionary *imPayload = ELIMCorePayload(payload, imCoreHandle);
        id codeObject = ELMessageSendIdWithObject([oneTimeCodeClass alloc], NSSelectorFromString(@"initWithIMCoreDictionary:"), imPayload);
        id provider = ELMessageSendId([providerClass alloc], @selector(init));
        if (!codeObject || !provider) {
            return @{
                @"ok": @NO,
                @"stage": @"safariFoundation.instantiate",
                @"hasCodeObject": @(codeObject != nil),
                @"hasProvider": @(provider != nil)
            };
        }

        if ([provider respondsToSelector:NSSelectorFromString(@"didFocusOneTimeCodeField")]) {
            ELMessageSendVoid(provider, NSSelectorFromString(@"didFocusOneTimeCodeField"));
        }
        ELMessageSendVoidObjectInteger(provider, NSSelectorFromString(@"test_deliverOneTimeCode:fromSource:"), codeObject, 0);

        id currentCodes = nil;
        if ([provider respondsToSelector:NSSelectorFromString(@"currentOneTimeCodesWithAppIdentifier:website:usernameHint:fieldClassification:")]) {
            NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"com.edgelink.mac";
            NSURL *website = nil;
            NSString *domain = [payload[@"domain"] isKindOfClass:NSString.class] ? payload[@"domain"] : nil;
            if (domain.length > 0) {
                website = [NSURL URLWithString:[@"https://" stringByAppendingString:domain]];
            }
            currentCodes = ELMessageSendCurrentCodes(
                provider,
                NSSelectorFromString(@"currentOneTimeCodesWithAppIdentifier:website:usernameHint:fieldClassification:"),
                bundleIdentifier,
                website,
                nil,
                0
            );
        }

        return @{
            @"ok": @YES,
            @"stage": @"safariFoundation.testDeliver",
            @"currentCount": @([currentCodes respondsToSelector:@selector(count)] ? [currentCodes count] : 0),
            @"payloadKeys": imPayload.allKeys
        };
    } @catch (NSException *exception) {
        return ELExceptionResult(@"safariFoundation.exception", exception);
    }
}

static NSDictionary<NSString *, id> *ELWarmIMCore(void) {
    @try {
        static id accelerator = nil;
        void *handle = dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_LAZY | RTLD_LOCAL);
        if (!handle) {
            return @{
                @"ok": @NO,
                @"stage": @"imCore.dlopen",
                @"error": ELDLErrorString()
            };
        }
        Class acceleratorClass = NSClassFromString(@"IMOneTimeCodeAccelerator");
        if (!acceleratorClass) {
            return @{ @"ok": @NO, @"stage": @"imCore.class" };
        }
        if (!accelerator) {
            id block = [^(id update) {
                NSLog(@"EdgeLink IMOneTimeCodeAccelerator update: %@", update);
            } copy];
            accelerator = ELMessageSendIdWithObject([acceleratorClass alloc], NSSelectorFromString(@"initWithBlockForUpdates:"), block);
        }
        if (accelerator && [accelerator respondsToSelector:NSSelectorFromString(@"setUpConnectionToDaemaon")]) {
            ELMessageSendVoid(accelerator, NSSelectorFromString(@"setUpConnectionToDaemaon"));
        }
        id daemonConnection = accelerator && [accelerator respondsToSelector:NSSelectorFromString(@"daemonConnection")]
            ? ELMessageSendId(accelerator, NSSelectorFromString(@"daemonConnection"))
            : nil;
        if (daemonConnection && [daemonConnection respondsToSelector:NSSelectorFromString(@"requestOneTimeCodeStatus")]) {
            ELMessageSendVoid(daemonConnection, NSSelectorFromString(@"requestOneTimeCodeStatus"));
        }
        return @{
            @"ok": @(accelerator != nil),
            @"stage": @"imCore.warm",
            @"hasDaemonConnection": @(daemonConnection != nil)
        };
    } @catch (NSException *exception) {
        return ELExceptionResult(@"imCore.exception", exception);
    }
}

static NSDictionary<NSString *, id> *ELWarmUserNotificationsOneTimeCode(void) {
    @try {
        Class connectionClass = NSClassFromString(@"UNOneTimeCodeServiceConnection");
        if (!connectionClass || ![connectionClass respondsToSelector:NSSelectorFromString(@"sharedInstance")]) {
            return @{ @"ok": @NO, @"stage": @"userNotifications.class" };
        }
        id connection = ELMessageSendId((id)connectionClass, NSSelectorFromString(@"sharedInstance"));
        if (connection && [connection respondsToSelector:NSSelectorFromString(@"registerForUpdates")]) {
            ELMessageSendVoid(connection, NSSelectorFromString(@"registerForUpdates"));
        }
        return @{
            @"ok": @(connection != nil),
            @"stage": @"userNotifications.register",
            @"hasConnection": @(connection != nil)
        };
    } @catch (NSException *exception) {
        return ELExceptionResult(@"userNotifications.exception", exception);
    }
}

NSDictionary<NSString *, id> *ELDeliverVerificationCodeToPrivateAutoFill(NSDictionary<NSString *, id> *payload) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"safariFoundation"] = ELDeliverToSafariFoundation(payload);
    result[@"imCore"] = ELWarmIMCore();
    result[@"userNotifications"] = ELWarmUserNotificationsOneTimeCode();
    return result;
}

NSDictionary<NSString *, id> *ELWarmPrivateOneTimeCodeObservers(void) {
    return @{
        @"imCore": ELWarmIMCore(),
        @"userNotifications": ELWarmUserNotificationsOneTimeCode()
    };
}
