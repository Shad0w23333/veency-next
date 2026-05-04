/* Veency - VNC Remote Access Server for iPhoneOS
 * Copyright (C) 2008-2012  Jay Freeman (saurik)
*/

/* GNU Affero General Public License, Version 3 {{{ */
/*
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.

 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.

 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
**/
/* }}} */

#define _trace() \
    fprintf(stderr, "_trace()@%s:%u[%s]\n", __FILE__, __LINE__, __FUNCTION__)
#define _likely(expr) \
    __builtin_expect(expr, 1)
#define _unlikely(expr) \
    __builtin_expect(expr, 0)

#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v)  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)

#include <CydiaSubstrate.h>

#include <rfb/rfb.h>
#include <rfb/rfbregion.h>
#include <rfb/keysym.h>

#include <mach/mach_port.h>
#include <mach/mach_time.h>
#include <sys/mman.h>
#include <sys/sysctl.h>

#import <QuartzCore/CAWindowServer.h>
#import <QuartzCore/CAWindowServerDisplay.h>

#import <CoreSurface/CoreSurface.h>
#import <CoreGraphics/CGGeometry.h>
#import <GraphicsServices/GraphicsServices.h>
#import <Foundation/Foundation.h>
#import <IOMobileFramebuffer/IOMobileFramebuffer.h>
#import <IOKit/IOKitLib.h>
#import <UIKit/UIApplication2.h>
#import <UIKit/UIKit.h>
#import <IOKit/hid/IOHIDEvent.h>

#import <SpringBoard/SBAlertItemsController.h>
#import <SpringBoard/SBDismissOnlyAlertItem.h>
#import <SpringBoard/SBStatusBarController.h>

#include "SimulateKeyboard.h"
#include "SpringBoardAccess.h"
#include "SpringBoardAccess.c"
#include "SimulateTouch/SimulateTouch.h"

#define MSHake2(name) \
    (void *)&$ ## name, (void **)&_ ## name


extern "C" void CoreSurfaceBufferFlushProcessorCaches(CoreSurfaceBufferRef buffer);
extern "C" int CoreSurfaceAcceleratorTransferSurface(CoreSurfaceAcceleratorRef accel, CoreSurfaceBufferRef src, CoreSurfaceBufferRef dst, CFDictionaryRef dict);
extern "C" int BKSHIDEventSendToApplicationWithBundleID(IOHIDEventRef event,NSString* str );
static void OnLayer(IOMobileFramebufferRef fb, CoreSurfaceBufferRef layer);
static void ApplyCaptureMethod();
static void StartCARenderServerCapture();
static void StopCARenderServerCapture();

// CV / CM 类型(避开 SDK 重声明)
typedef CFTypeRef CVImageBufferRef;
typedef CFTypeRef CVPixelBufferRef;
typedef struct OpaqueCMBlockBuffer *CMBlockBufferRef;
typedef struct opaqueCMSampleBuffer *CMSampleBufferRef;
typedef CFTypeRef CMVideoFormatDescriptionRef;

// VT/CM/CV 函数前向声明
static void SetupVTEncoder();
static void TeardownVTEncoder();
static void EncodeFrameViaVT(void *iosurface, int width, int height);
static void H264OutputCallback(void *outputCallbackRefCon, void *sourceFrameRefCon,
                                OSStatus status, uint32_t infoFlags, CMSampleBufferRef sampleBuffer);
static void SendH264NALUToClients(const uint8_t *naluStream, size_t length, bool isKeyframe,
                                   int width, int height);

static IOMobileFramebufferRef main_=NULL;
static CoreSurfaceBufferRef layer_=NULL;

static size_t width_;
static size_t height_;
static size_t destwidth_;
static size_t destheight_;
static NSUInteger ratio_ = 0;

static const size_t BytesPerPixel = 4;
static const size_t BitsPerSample = 8;

static CoreSurfaceAcceleratorRef accelerator_;
static CoreSurfaceBufferRef buffer_;
static CFDictionaryRef options_;
static CFDictionaryRef options2_=CFDictionaryCreate(NULL,NULL,NULL,0,NULL,NULL);

static NSMutableSet *handlers_;
static rfbScreenInfoPtr screen_=NULL;
static bool running_;
static int buttons_;
static int x_, y_;

static unsigned clients_;

static CFMessagePortRef ashikase_;
static bool cursor_;
static int skipBlack_;
static int divideScreenBy_=1;
static int maxFPS_=30;

static const int kTileSize = 64;
static uint32_t *tileChecksums_ = NULL;
static int tilesX_ = 0;
static int tilesY_ = 0;
static int forceFullFrameCounter_ = 0;
static uint64_t lastFrameSig_ = 0;

// ===== H.264 / CARenderServer 阶段 2-4 设置 =====
static bool h264Enabled_ = false;
static int h264Bitrate_ = 4000;            // kbps
static int h264KeyframeInterval_ = 60;     // frames
static NSString *h264Profile_ = nil;       // baseline/main/high
static bool useCARenderServer_ = false;    // CaptureMethod
static bool verboseLogging_ = false;

// CARenderServer / IOSurface 解析后的函数指针(MSInitialize 时填好)
typedef int (*CARenderServerRenderDisplay_t)(kern_return_t a, CFStringRef name, void *surface, int x, int y);
static CARenderServerRenderDisplay_t fnCARenderServerRenderDisplay = NULL;
typedef CFTypeRef (*IOSurfaceCreate_t)(CFDictionaryRef);
static IOSurfaceCreate_t fnIOSurfaceCreate = NULL;
typedef int (*IOSurfaceLock_t)(CFTypeRef, uint32_t, void *);
static IOSurfaceLock_t fnIOSurfaceLock = NULL;
typedef int (*IOSurfaceUnlock_t)(CFTypeRef, uint32_t, void *);
static IOSurfaceUnlock_t fnIOSurfaceUnlock = NULL;
typedef void *(*IOSurfaceGetBaseAddress_t)(CFTypeRef);
static IOSurfaceGetBaseAddress_t fnIOSurfaceGetBaseAddress = NULL;

// CARenderServer 捕获状态
static CFTypeRef carsSurface_ = NULL;
static dispatch_source_t carsTimer_ = NULL;
static dispatch_queue_t carsQueue_ = NULL;
static volatile bool carsRunning_ = false;

// ============== 阶段 3: VT 硬件 H.264 编码 SPI 声明 ==============
// (CMBlockBufferRef / CMSampleBufferRef / CMVideoFormatDescriptionRef 已在前面声明,OSStatus 由系统头)
typedef struct OpaqueVTCompressionSession *VTCompressionSessionRef;
extern "C" CFStringRef kCVPixelBufferPixelFormatTypeKey;
extern "C" CFStringRef kCVPixelBufferIOSurfacePropertiesKey;

typedef struct {
    int64_t value;
    int32_t timescale;
    uint32_t flags;
    int64_t epoch;
} CMTimeVL;  // local copy to avoid SDK header conflict

typedef void (*VTCompressionOutputCallback_t)(
    void *outputCallbackRefCon, void *sourceFrameRefCon,
    OSStatus status, uint32_t infoFlags, CMSampleBufferRef sampleBuffer);

typedef OSStatus (*VTCompressionSessionCreate_t)(
    CFAllocatorRef, int32_t, int32_t, uint32_t,
    CFDictionaryRef, CFDictionaryRef, CFAllocatorRef,
    VTCompressionOutputCallback_t, void *, VTCompressionSessionRef *);
typedef OSStatus (*VTCompressionSessionEncodeFrame_t)(
    VTCompressionSessionRef, CVImageBufferRef, CMTimeVL, CMTimeVL,
    CFDictionaryRef, void *, uint32_t *);
typedef OSStatus (*VTCompressionSessionSetProperty_t)(
    VTCompressionSessionRef, CFStringRef, CFTypeRef);
typedef OSStatus (*VTCompressionSessionInvalidate_t)(VTCompressionSessionRef);

typedef CMBlockBufferRef (*CMSampleBufferGetDataBuffer_t)(CMSampleBufferRef);
typedef CMVideoFormatDescriptionRef (*CMSampleBufferGetFormatDescription_t)(CMSampleBufferRef);
typedef CFArrayRef (*CMSampleBufferGetSampleAttachmentsArray_t)(CMSampleBufferRef, Boolean);
typedef OSStatus (*CMBlockBufferGetDataPointer_t)(CMBlockBufferRef, size_t, size_t *, size_t *, char **);
typedef CFTypeRef (*CMFormatDescriptionGetExtension_t)(CMVideoFormatDescriptionRef, CFStringRef);
typedef OSStatus (*CVPixelBufferCreateWithIOSurface_t)(CFAllocatorRef, void *, CFDictionaryRef, CVPixelBufferRef *);

static VTCompressionSessionCreate_t fnVTCompressionSessionCreate = NULL;
static VTCompressionSessionEncodeFrame_t fnVTCompressionSessionEncodeFrame = NULL;
static VTCompressionSessionSetProperty_t fnVTCompressionSessionSetProperty = NULL;
static VTCompressionSessionInvalidate_t fnVTCompressionSessionInvalidate = NULL;
static CMSampleBufferGetDataBuffer_t fnCMSampleBufferGetDataBuffer = NULL;
static CMSampleBufferGetFormatDescription_t fnCMSampleBufferGetFormatDescription = NULL;
static CMSampleBufferGetSampleAttachmentsArray_t fnCMSampleBufferGetSampleAttachmentsArray = NULL;
static CMBlockBufferGetDataPointer_t fnCMBlockBufferGetDataPointer = NULL;
static CMFormatDescriptionGetExtension_t fnCMFormatDescriptionGetExtension = NULL;
static CVPixelBufferCreateWithIOSurface_t fnCVPixelBufferCreateWithIOSurface = NULL;

// VT 编码状态
static VTCompressionSessionRef vtSession_ = NULL;
static dispatch_queue_t vtQueue_ = NULL;
static int64_t vtFrameNo_ = 0;
static NSData *cachedSPS_ = nil;
static NSData *cachedPPS_ = nil;
static volatile bool forceNextKeyframe_ = false;  // 新客户端连接 → 下一帧强制 IDR
static NSLock *h264WriteLock_ = nil;             // 串行化 H.264 socket 写入,避免回调多线程穿插

// 自定义 RFB 编码 ID
#define rfbEncodingVeencyH264 0x48323634  // 'H264'

static rfbPixel *black_;
static rfbPixel *mainFrameBuffer_=NULL;
static rfbPixel *correctedBlocksBuffer_=NULL;
static char *bufferData_;

#if 0
// Logging is costly.  Takes 3-6ms
static void Log(const char *str,...) {
FILE *out;
va_list args;


va_start(args,str);
out=fopen("/tmp/veency.log","a");
vfprintf(out,str,args);
fflush(out);
fclose(out);
va_end(args);
}
#endif


static void VNCBlack() {
    if (_unlikely(black_ == NULL))
        black_ = reinterpret_cast<rfbPixel *>(mmap(NULL, sizeof(rfbPixel) * width_ * height_, PROT_READ, MAP_ANON | MAP_PRIVATE | MAP_NOCACHE, VM_FLAGS_PURGABLE, 0));
    screen_->frameBuffer = reinterpret_cast<char *>(black_);
}

static bool Ashikase(bool always) {
    if (!always && !cursor_)
        return false;

    if (ashikase_ == NULL)
        ashikase_ = CFMessagePortCreateRemote(kCFAllocatorDefault, CFSTR("jp.ashikase.mousesupport"));
    if (ashikase_ != NULL)
        return true;

    cursor_ = false;
    return false;
}

static CFDataRef cfTrue_;
static CFDataRef cfFalse_;

typedef struct {
    float x, y;
    int buttons;
    BOOL absolute;
} MouseEvent;

static MouseEvent event_;
static CFDataRef cfEvent_;

typedef enum {
    MouseMessageTypeEvent,
    MouseMessageTypeSetEnabled
} MouseMessageType;

static void AshikaseSendEvent(float x, float y, int buttons = 0) {
    event_.x = x;
    event_.y = y;
    event_.buttons = buttons;
    event_.absolute = true;

    CFMessagePortSendRequest(ashikase_, MouseMessageTypeEvent, cfEvent_, 0, 0, NULL, NULL);
}

static void AshikaseSetEnabled(bool enabled, bool always) {
    if (!Ashikase(always))
        return;

    CFMessagePortSendRequest(ashikase_, MouseMessageTypeSetEnabled, enabled ? cfTrue_ : cfFalse_, 0, 0, NULL, NULL);

    if (enabled)
        AshikaseSendEvent(x_, y_);
}

MSClassHook(SBAlertItem)
MSClassHook(SBAlertItemsController)
MSClassHook(SBStatusBarController)

//@class VNCAlertItem;
@interface VNCAlertItem : SBAlertItem {

}
@end
static Class $VNCAlertItem;

static NSString *DialogTitle(@"Remote Access Request");
static NSString *DialogFormat(@"Accept connection from\n%s?\n\nVeency VNC Server\nby Jay Freeman (saurik)\nsaurik@saurik.com\nhttp://www.saurik.com/\n\nSet a VNC password in Settings!");
static NSString *DialogAccept(@"Accept");
static NSString *DialogReject(@"Reject");

static volatile rfbNewClientAction action_ = RFB_CLIENT_ON_HOLD;
static NSCondition *condition_;
static NSLock *lock_;

static rfbClientPtr client_;
static int downFinger_=0;

static void VNCSetup();
static void VNCEnabled();
static void VNCShutDown();

static void OnUserNotification(CFUserNotificationRef notification, CFOptionFlags flags) {
    [condition_ lock];

    if ((flags & 0x3) == 1)
        action_ = RFB_CLIENT_ACCEPT;
    else
        action_ = RFB_CLIENT_REFUSE;

    [condition_ signal];
    [condition_ unlock];

    CFRelease(notification);
}

@interface VNCBridge : NSObject {
}

+ (void) askForConnection;
+ (void) removeStatusBarItem;
+ (void) registerClient;

@end

@implementation VNCBridge

+ (void) askForConnection {
    if ($VNCAlertItem != nil) {
        [[$SBAlertItemsController sharedInstance] activateAlertItem:[[[$VNCAlertItem alloc] init] autorelease]];
        return;
    }

    SInt32 error;
    CFUserNotificationRef notification(CFUserNotificationCreate(kCFAllocatorDefault, 0, kCFUserNotificationPlainAlertLevel, &error, (CFDictionaryRef) [NSDictionary dictionaryWithObjectsAndKeys:
        DialogTitle, kCFUserNotificationAlertHeaderKey,
        [NSString stringWithFormat:DialogFormat, client_->host], kCFUserNotificationAlertMessageKey,
        DialogAccept, kCFUserNotificationAlternateButtonTitleKey,
        DialogReject, kCFUserNotificationDefaultButtonTitleKey,
    nil]));

    if (error != 0) {
        CFRelease(notification);
        notification = NULL;
    }

    if (notification == NULL) {
        [condition_ lock];
        action_ = RFB_CLIENT_REFUSE;
        [condition_ signal];
        [condition_ unlock];
        return;
    }

    CFRunLoopSourceRef source(CFUserNotificationCreateRunLoopSource(kCFAllocatorDefault, notification, &OnUserNotification, 0));
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
}

+ (void) removeStatusBarItem {
    AshikaseSetEnabled(false, false);

    if (SBA_available())
        SBA_removeStatusBarImage(const_cast<char *>("Veency"));
    else if ($SBStatusBarController != nil)
        [[$SBStatusBarController sharedStatusBarController] removeStatusBarItem:@"Veency"];
    else if (UIApplication *app = [UIApplication sharedApplication])
        [app removeStatusBarImageNamed:@"Veency"];
}

+ (void) registerClient {
    // XXX: this could find a better home
    if (ratio_ == 0) {
        UIScreen *screen([UIScreen mainScreen]);
        if ([screen respondsToSelector:@selector(scale)])
            ratio_ = [screen scale];
        else
            ratio_ = 1;
    }

    ++clients_;
    AshikaseSetEnabled(true, false);

    if (SBA_available())
        SBA_addStatusBarImage(const_cast<char *>("Veency"));
    else if ($SBStatusBarController != nil)
        [[$SBStatusBarController sharedStatusBarController] addStatusBarItem:@"Veency"];
    else if (UIApplication *app = [UIApplication sharedApplication])
        [app addStatusBarImageNamed:@"Veency"];
}

+ (void) performSetup:(NSThread *)thread {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);
    [thread autorelease];
    VNCSetup();
    VNCEnabled();
    [pool release];
}

@end

MSInstanceMessage2(void, VNCAlertItem, alertSheet,buttonClicked, id, sheet, int, button) {
    [condition_ lock];

    switch (button) {
        case 1:
            action_ = RFB_CLIENT_ACCEPT;

            @synchronized (condition_) {
                [VNCBridge registerClient];
            }
        break;

        case 2:
            action_ = RFB_CLIENT_REFUSE;
        break;
    }

    [condition_ signal];
    [condition_ unlock];
    [self dismiss];
}

MSInstanceMessage2(void, VNCAlertItem, configure,requirePasscodeForActions, BOOL, configure, BOOL, require) {
    UIModalView *sheet([self alertSheet]);
    [sheet setDelegate:self];
    [sheet setTitle:DialogTitle];
    [sheet setBodyText:[NSString stringWithFormat:DialogFormat, client_->host]];
    [sheet addButtonWithTitle:DialogAccept];
    [sheet addButtonWithTitle:DialogReject];
}

MSInstanceMessage0(void, VNCAlertItem, performUnlockAction) {
    [[$SBAlertItemsController sharedInstance] activateAlertItem:self];
}

static mach_port_t (*GSTakePurpleSystemEventPort)(void);
static bool PurpleAllocated;
static int Level_;

static void FixRecord(GSEventRecord *record) {
    if (Level_ < 1)
        memmove(&record->windowContextId, &record->windowContextId + 1, sizeof(*record) - (reinterpret_cast<uint8_t *>(&record->windowContextId + 1) - reinterpret_cast<uint8_t *>(record)) + record->size);
}

static void VNCSettingsScreenSize() {
    NSDictionary *settings([NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Library/Preferences/com.saurik.Veency.plist", NSHomeDirectory()]]);

    NSNumber *divideScreenBy = [settings objectForKey:@"DivideScreenBy"];
    int divideScreenByOld=divideScreenBy_;
    divideScreenBy_ = [divideScreenBy intValue];
    if(divideScreenBy_<1 || divideScreenBy_>320) divideScreenBy_=1;
    destwidth_ = width_/divideScreenBy_;
    destheight_ = height_/divideScreenBy_;

    if(running_ && divideScreenBy_ != divideScreenByOld) {
        VNCShutDown();
        VNCSetup();
        VNCEnabled();
    }
}

static void VNCSettings() {
    NSDictionary *settings([NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Library/Preferences/com.saurik.Veency.plist", NSHomeDirectory()]]);

    @synchronized (lock_) {
        for (NSValue *handler in handlers_)
            rfbUnregisterSecurityHandler(reinterpret_cast<rfbSecurityHandler *>([handler pointerValue]));
        [handlers_ removeAllObjects];
    }

    @synchronized (condition_) {
        if (screen_ == NULL)
            return;

        [reinterpret_cast<NSString *>(screen_->authPasswdData) release];
        screen_->authPasswdData = NULL;

        if (settings != nil)
            if (NSString *password = [settings objectForKey:@"Password"])
                if ([password length] != 0)
                    screen_->authPasswdData = [password retain];

        NSNumber *cursor = [settings objectForKey:@"ShowCursor"];
        cursor_ = cursor == nil ? true : [cursor boolValue];
        if(SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"7.0")) { 
            // iOS7 crashes with the mouse cursor
            cursor_=false; 
        }

        NSNumber *skipBlack = [settings objectForKey:@"SkipBlack"];
        skipBlack_ = skipBlack == nil ? 0 : [skipBlack intValue];

        NSNumber *maxFPS = [settings objectForKey:@"MaxFPS"];
        maxFPS_ = maxFPS == nil ? 30 : [maxFPS intValue];
        if (maxFPS_ < 5 || maxFPS_ > 60) maxFPS_ = 30;
        screen_->deferUpdateTime = 1000 / maxFPS_;

        // H.264 / 捕获方式 / 调试
        NSNumber *h264On = [settings objectForKey:@"H264Enabled"];
        h264Enabled_ = h264On == nil ? false : [h264On boolValue];
        NSNumber *h264Br = [settings objectForKey:@"H264Bitrate"];
        h264Bitrate_ = h264Br == nil ? 4000 : [h264Br intValue];
        if (h264Bitrate_ < 100 || h264Bitrate_ > 50000) h264Bitrate_ = 4000;
        NSNumber *h264Kf = [settings objectForKey:@"H264KeyframeInterval"];
        h264KeyframeInterval_ = h264Kf == nil ? 60 : [h264Kf intValue];
        if (h264KeyframeInterval_ < 1 || h264KeyframeInterval_ > 600) h264KeyframeInterval_ = 60;
        [h264Profile_ release];
        h264Profile_ = [[settings objectForKey:@"H264Profile"] retain] ?: [@"main" retain];

        // 兼容老 key (CaptureMethod=carenderserver) 与新 key (UseCARenderServer=true)
        NSNumber *useCars = [settings objectForKey:@"UseCARenderServer"];
        NSString *captureMethod = [settings objectForKey:@"CaptureMethod"];
        useCARenderServer_ = (useCars != nil && [useCars boolValue])
            || [captureMethod isEqualToString:@"carenderserver"];

        NSNumber *verbose = [settings objectForKey:@"VerboseLogging"];
        verboseLogging_ = verbose == nil ? false : [verbose boolValue];

        VNCSettingsScreenSize();

        if (clients_ != 0)
            AshikaseSetEnabled(cursor_, true);
    }

    // 设置加载完成后,根据 CaptureMethod 切换捕获方式
    ApplyCaptureMethod();

    // H.264:开关变化时 Setup / Teardown
    static bool prevH264_ = false;
    if (h264Enabled_ && !prevH264_) SetupVTEncoder();
    else if (!h264Enabled_ && prevH264_) TeardownVTEncoder();
    prevH264_ = h264Enabled_;
}

static void VNCNotifySettings(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef info
) {
    VNCSettings();
}

static rfbBool VNCCheck(rfbClientPtr client, const char *data, int size) {
    @synchronized (condition_) {
        if (NSString *password = reinterpret_cast<NSString *>(screen_->authPasswdData)) {
            NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);
            rfbEncryptBytes(client->authChallenge, const_cast<char *>([password UTF8String]));
            bool good(memcmp(client->authChallenge, data, size) == 0);
            [pool release];
            return good;
        } return TRUE;
    }
}

static bool iPad1_;

struct VeencyEvent {
    struct GSEventRecord record;
    struct {
        struct GSEventRecordInfo info;
        struct GSPathInfo path;
    } data;
};

static void VNCPointer(int buttons, int x, int y, rfbClientPtr client) {
//Log("pointer event, x,y: %i,%i b:%i\n",x,y,buttons);
    if (ratio_ == 0)
        return;


    if (width_ > height_) {
        int t(x);
        x = height_ - 1 - y;
        y = t;

        if (!iPad1_) {
            x = height_ - 1 - x;
            y = width_ - 1 - y;
        }
    }

    x /= ratio_;
    y /= ratio_;
    x*=divideScreenBy_;
    y*=divideScreenBy_;

    x_ = x; y_ = y;
    int diff = buttons_ ^ buttons;
    bool twas((buttons_ & 0x1) != 0);
    bool tis((buttons & 0x1) != 0);
    buttons_ = buttons;

    rfbDefaultPtrAddEvent(buttons, x, y, client);

    // *** not working in iOS7
    if(!SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"7.0")) { 
        if (Ashikase(false)) {
            AshikaseSendEvent(x, y, buttons);
            return;
        }
    }


    if ((diff & 0x10) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x10) != 0 ?
            GSEventTypeHeadsetButtonDown :
            GSEventTypeHeadsetButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        FixRecord(&record);
        GSSendSystemEvent(&record);
    }

    if ((diff & 0x04) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x04) != 0 ?
            GSEventTypeMenuButtonDown :
            GSEventTypeMenuButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        FixRecord(&record);
        GSSendSystemEvent(&record);
    }

    if ((diff & 0x02) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x02) != 0 ?
            GSEventTypeLockButtonDown :
            GSEventTypeLockButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        FixRecord(&record);
        GSSendSystemEvent(&record);
    }

    if (twas != tis) {
        if(tis) {
            downFinger_=[SimulateTouch simulateTouch:0 atPoint:CGPointMake(x,y) withType:(tis?STTouchDown:STTouchUp)];
        } else {
            [SimulateTouch simulateTouch:downFinger_ atPoint:CGPointMake(x,y) withType:(tis?STTouchDown:STTouchUp)];
        }
    } else if(tis) {
        if(downFinger_>=0)
            [SimulateTouch simulateTouch:downFinger_ atPoint:CGPointMake(x,y) withType:STTouchMove];
    }
/*
    // Old version using SendEvent, SimluateTouch can do SendEvent if detected.
    CGPoint location = {x, y};
    mach_port_t purple(0);

    if (twas != tis || tis) {
        struct VeencyEvent event;

        memset(&event, 0, sizeof(event));

        event.record.type = GSEventTypeMouse;
        event.record.locationInWindow.x = x;
        event.record.locationInWindow.y = y;
        event.record.timestamp = GSCurrentEventTimestamp();
        event.record.size = sizeof(event.data);

        event.data.info.handInfo.type = twas == tis ?
            GSMouseEventTypeDragged :
        tis ?
            GSMouseEventTypeDown :
            GSMouseEventTypeUp;

        event.data.info.handInfo.x34 = 0x1;
        event.data.info.handInfo.x38 = tis ? 0x1 : 0x0;

        if (Level_ < 3)
            event.data.info.pathPositions = 1;
        else
            event.data.info.x52 = 1;

        event.data.path.x00 = 0x01;
        event.data.path.x01 = 0x02;
        event.data.path.x02 = tis ? 0x03 : 0x00;
        event.data.path.position = event.record.locationInWindow;

        mach_port_t port(0);

        if (CAWindowServer *server = [CAWindowServer serverIfRunning]) {
            NSArray *displays([server displays]);
            if (displays != nil && [displays count] != 0)
                if (CAWindowServerDisplay *display = [displays objectAtIndex:0])
                    port = [display clientPortAtPosition:location];
        }

        if (port == 0) {
            if (purple == 0)
                purple = (*GSTakePurpleSystemEventPort)();
            port = purple;
        }

        FixRecord(&event.record);
        GSSendEvent(&event.record, port);
    }
    if (purple != 0 && PurpleAllocated) {
        mach_port_deallocate(mach_task_self(), purple);
    }
*/
}

GSEventRef (*$GSEventCreateKeyEvent)(int, CGPoint, CFStringRef, CFStringRef, id, UniChar, short, short);
GSEventRef (*$GSCreateSyntheticKeyEvent)(UniChar, BOOL, BOOL);

static void VNCKeyboard(rfbBool down, rfbKeySym key, rfbClientPtr client) {
    if (!down)
        return;


    switch (key) {
        case XK_Return: key = '\r'; break;
        case XK_BackSpace: key = 0x7f; break;
    }

    if (key > 0xfff)
        return;

    CGPoint point(CGPointMake(x_, y_));

    UniChar unicode(key);
    CFStringRef string(NULL);

    GSEventRef event0, event1(NULL);
    if ($GSEventCreateKeyEvent != NULL) {
        string = CFStringCreateWithCharacters(kCFAllocatorDefault, &unicode, 1);
        event0 = (*$GSEventCreateKeyEvent)(10, point, string, string, nil, 0, 0, 1);
        event1 = (*$GSEventCreateKeyEvent)(11, point, string, string, nil, 0, 0, 1);
    } else if ($GSCreateSyntheticKeyEvent != NULL) {
        event0 = (*$GSCreateSyntheticKeyEvent)(unicode, YES, YES);
        GSEventRecord *record(_GSEventGetGSEventRecord(event0));
        record->type = GSEventTypeKeyDown;
    } else return;

    mach_port_t port(0);

    if (CAWindowServer *server = [CAWindowServer serverIfRunning]) {
        NSArray *displays([server displays]);
        if (displays != nil && [displays count] != 0)
            if (CAWindowServerDisplay *display = [displays objectAtIndex:0])
                port = [display clientPortAtPosition:point];
    }

    mach_port_t purple(0);

    if (port == 0) {
        if (purple == 0)
            purple = (*GSTakePurpleSystemEventPort)();
        port = purple;
    }

    if (port != 0) {
        GSSendEvent(_GSEventGetGSEventRecord(event0), port);
        if (event1 != NULL)
            GSSendEvent(_GSEventGetGSEventRecord(event1), port);
    }

    if (purple != 0 && PurpleAllocated)
        mach_port_deallocate(mach_task_self(), purple);

    CFRelease(event0);
    if (event1 != NULL)
        CFRelease(event1);
    if (string != NULL)
        CFRelease(string);
}

static void VNCDisconnect(rfbClientPtr client) {
    @synchronized (condition_) {
        if (--clients_ == 0)
            [VNCBridge performSelectorOnMainThread:@selector(removeStatusBarItem) withObject:nil waitUntilDone:YES];
    }
}

static rfbNewClientAction VNCClient(rfbClientPtr client) {
    @synchronized (condition_) {
        if (h264Enabled_) {
            forceNextKeyframe_ = true;
            // 注:任何对 client->modifiedRegion 的修改(sraRgnSubtract / Destroy)
            // 都会让 backboardd SIGSEGV — libvncserver 内部状态依赖。
            // 不动它。改用 client side 容错处理首帧 Raw。
            if (verboseLogging_) NSLog(@"[Veency-VT] 新客户端连接 → 强制下一帧 IDR");
        }
        if (screen_->authPasswdData != NULL) {
            [VNCBridge performSelectorOnMainThread:@selector(registerClient) withObject:nil waitUntilDone:YES];
            client->clientGoneHook = &VNCDisconnect;
            return RFB_CLIENT_ACCEPT;
        }
    }

    [condition_ lock];
    client_ = client;
    [VNCBridge performSelectorOnMainThread:@selector(askForConnection) withObject:nil waitUntilDone:NO];
    while (action_ == RFB_CLIENT_ON_HOLD)
        [condition_ wait];
    rfbNewClientAction action(action_);
    action_ = RFB_CLIENT_ON_HOLD;
    [condition_ unlock];

    if (action == RFB_CLIENT_ACCEPT)
        client->clientGoneHook = &VNCDisconnect;
    return action;
}

//extern "C" bool GSSystemHasCapability(NSString *);

static CFTypeRef (*$GSSystemCopyCapability)(CFStringRef);
static CFTypeRef (*$GSSystemGetCapability)(CFStringRef);

static void VNCSetup() {
    rfbLogEnable(false);

    @synchronized (condition_) {
        int argc(1);
        char *arg0(strdup("VNCServer"));
        char *argv[] = {arg0, NULL};
/* *** -geometry does not scale the picture
        char a1[]="-geometry";
        char a2[]="300x300";
        char *argv[] = {arg0,a1,a2, NULL};
*/

        VNCSettingsScreenSize();

        screen_ = rfbGetScreen(&argc, argv, destwidth_, destheight_, BitsPerSample, 3, BytesPerPixel);
        free(arg0);

        VNCSettings();
    }

    screen_->desktopName = strdup([[[NSProcessInfo processInfo] hostName] UTF8String]);

    screen_->alwaysShared = TRUE;
    screen_->handleEventsEagerly = TRUE;
    screen_->deferUpdateTime = 1000 / maxFPS_;

    screen_->serverFormat.redShift = BitsPerSample * 2;
    screen_->serverFormat.greenShift = BitsPerSample * 1;
    screen_->serverFormat.blueShift = BitsPerSample * 0;

    $GSSystemCopyCapability = reinterpret_cast<CFTypeRef (*)(CFStringRef)>(dlsym(RTLD_DEFAULT, "GSSystemCopyCapability"));
    $GSSystemGetCapability = reinterpret_cast<CFTypeRef (*)(CFStringRef)>(dlsym(RTLD_DEFAULT, "GSSystemGetCapability"));

    CFTypeRef opengles2;

    if ($GSSystemCopyCapability != NULL) {
        opengles2 = (*$GSSystemCopyCapability)(CFSTR("opengles-2"));
    } else if ($GSSystemGetCapability != NULL) {
        opengles2 = (*$GSSystemGetCapability)(CFSTR("opengles-2"));
        if (opengles2 != NULL)
            CFRetain(opengles2);
    } else
        opengles2 = NULL;

    bool accelerated(opengles2 != NULL && [(NSNumber *)opengles2 boolValue]);
    if(SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"7.0")) { 
        // accelerated is supported in iOS7 but is not detected here.
        accelerated=true;
    }

    if (accelerated)
        CoreSurfaceAcceleratorCreate(NULL, NULL, &accelerator_);

    if (opengles2 != NULL)
        CFRelease(opengles2);

    if (accelerator_ != NULL)
        buffer_ = CoreSurfaceBufferCreate((CFDictionaryRef) [NSDictionary dictionaryWithObjectsAndKeys:
            @"PurpleEDRAM", kCoreSurfaceBufferMemoryRegion,
            [NSNumber numberWithBool:YES], kCoreSurfaceBufferGlobal,
            [NSNumber numberWithInt:(width_ * BytesPerPixel)], kCoreSurfaceBufferPitch,
            [NSNumber numberWithInt:width_], kCoreSurfaceBufferWidth,
            [NSNumber numberWithInt:height_], kCoreSurfaceBufferHeight,
            [NSNumber numberWithInt:'BGRA'], kCoreSurfaceBufferPixelFormat,
            [NSNumber numberWithInt:(width_ * height_ * BytesPerPixel)], kCoreSurfaceBufferAllocSize,
        nil]);
    else
        VNCBlack();

    //screen_->frameBuffer = reinterpret_cast<char *>(mmap(NULL, sizeof(rfbPixel) * width_ * height_, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NOCACHE, VM_FLAGS_PURGABLE, 0));

    CoreSurfaceBufferLock(buffer_, 3);
    bufferData_ = reinterpret_cast<char *>(CoreSurfaceBufferGetBaseAddress(buffer_));
    CoreSurfaceBufferUnlock(buffer_);
    // let's alloc the maximum memory needed for the full screen
    if(mainFrameBuffer_==NULL)
        mainFrameBuffer_ = reinterpret_cast<rfbPixel *>(mmap(NULL, sizeof(rfbPixel) * width_ * height_, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NOCACHE, VM_FLAGS_PURGABLE, 0));
    screen_->frameBuffer=(char *)mainFrameBuffer_;

    screen_->kbdAddEvent = &VNCKeyboard;
    screen_->ptrAddEvent = &VNCPointer;

    screen_->newClientHook = &VNCClient;
    screen_->passwordCheck = &VNCCheck;

    screen_->cursor = NULL;

    // VNCSetup 完成,所有资源就绪;此时再决定是否切到 CARenderServer 模式
    ApplyCaptureMethod();

    // H.264 编码器(若开启)
    if (h264Enabled_) SetupVTEncoder();
}

static void VNCShutDown() {
    rfbShutdownServer(screen_, true);
    running_ = false;
}
static void VNCEnabled() {
    [lock_ lock];

    bool enabled(true);
    if (NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Library/Preferences/com.saurik.Veency.plist", NSHomeDirectory()]])
        if (NSNumber *number = [settings objectForKey:@"Enabled"])
            enabled = [number boolValue];

    if (enabled != running_)
        if (enabled) {
            running_ = true;
            screen_->socketState = RFB_SOCKET_INIT;
            rfbInitServer(screen_);
            rfbRunEventLoop(screen_, -1, true);
        } else {
            VNCShutDown();
        }

    [lock_ unlock];
}

static void VNCNotifyEnabled(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef info
) {
    VNCEnabled();
}

void (*$IOMobileFramebufferIsMainDisplay)(IOMobileFramebufferRef, int *);



static void Copy64x16BlockedImage(char *dest,const char *fromStart) {
    const char *fromEnd;
    char *to,*toLine,*toEnd,*toPtr;
    fromEnd=fromStart+(4*width_*height_);
    toEnd=dest+(4*width_*height_);
    to=dest;
    int toLineOffset=0;
    unsigned int toXOffset=0;

    toLine=to;
    const char *from=fromStart;

    while(from<fromEnd) {
        toXOffset=0;
        while(toXOffset<(width_*4)) {
            // one 16x line from image
            toLineOffset=0;
            while(toLineOffset<16) {
                toPtr=toLine+toXOffset+(4*width_*toLineOffset);
                if((toPtr+(64*4))<toEnd  && (from+(64*4))<fromEnd)
                    memcpy(toPtr,from,64*4);
                toLineOffset++;
                from+=64*4;
            }
            toXOffset+=64*4;
        }
        toLine+=16*4*width_;
    }

}

static void CopyToFrameBuffer(rfbPixel *dest,rfbPixel *from,int divideBy) {
    int size;
    int skipDots;
    rfbPixel zero[16];
    rfbPixel *fromEnd,*destUpto,*fromNextLine,*fromUpto,*fromLine,*destEnd,*destLine;

    memset(zero,0,sizeof(zero));
    destEnd=dest+(destwidth_*destheight_);

    size=width_*height_;
    skipDots=divideBy;
    if(skipDots<=0) skipDots=1;
    destUpto=dest;
    fromEnd=from+size;

    fromUpto=from;
    while(fromUpto<fromEnd && destUpto<destEnd) {
        destLine=destUpto;
        fromLine=fromUpto;
        fromNextLine=fromUpto+width_;

#if 0
//*** check for black bits line by line, makes no difference to speed
        int hasZeros=0;
        if(skipBlack_) {
            const rfbPixel *fromTest=fromUpto;
            while(fromTest<fromNextLine) {
                if(memcmp(fromTest,zero,sizeof(zero))==0) {
                    hasZeros=1;
                    break;
                }
                fromTest+=sizeof(zero)/sizeof(zero[0]);
            }
        }

        if(!hasZeros) {
#endif
            while(fromUpto<fromNextLine) {
                *destUpto=*fromUpto;
                ++destUpto;
                fromUpto+=skipDots;
            }
//        }
        fromUpto=fromLine+(width_*skipDots);
        destUpto=destLine+destwidth_;
    }
}
static int isBottomScreenBlack(const char *data) {
    const char *dataEnd=data+(width_*height_*sizeof(rfbPixel));
    int hasNonZero=0;
    int hasZero=0;
//    int width4=(width_/4)+width_;
    int width4=96;

    for(int *d=(int *)(data+(width_*(height_/8)*7)); d<(int *)dataEnd; d+=width4) { 
        if(d[0]) { ++hasNonZero;  }
        else ++hasZero;
    } 
    if((hasNonZero/2)>hasZero) { return 0; }
    return 1;
}


static inline uint64_t QuickFrameSignature(const uint32_t *fb, int width, int height) {
    if (width <= 0 || height <= 0) return 0;
    uint64_t h = 0;
    int dx = width / 5; if (dx < 1) dx = 1;
    int dy = height / 5; if (dy < 1) dy = 1;
    for (int y = dy; y < height; y += dy)
        for (int x = dx; x < width; x += dx)
            h = h * 31 + fb[y * width + x];
    h = h * 31 + fb[0];
    h = h * 31 + fb[width - 1];
    h = h * 31 + fb[(height - 1) * width];
    h = h * 31 + fb[height * width - 1];
    return h;
}

static inline uint32_t TileChecksum(const uint32_t *fb, int tx, int ty, int width, int height) {
    int x0 = tx * kTileSize, y0 = ty * kTileSize;
    int x1 = x0 + kTileSize; if (x1 > width) x1 = width;
    int y1 = y0 + kTileSize; if (y1 > height) y1 = height;
    uint32_t h = 0x811c9dc5u;
    for (int y = y0; y < y1; ++y) {
        const uint32_t *row = fb + y * width + x0;
        for (int x = x0; x < x1; ++x) {
            h ^= *row++;
            h *= 0x01000193u;
        }
    }
    return h;
}

static void MarkDirtyTiles(const uint32_t *fb, int width, int height) {
    int newTilesX = (width + kTileSize - 1) / kTileSize;
    int newTilesY = (height + kTileSize - 1) / kTileSize;
    bool needFullRefresh = false;

    if (tileChecksums_ == NULL || newTilesX != tilesX_ || newTilesY != tilesY_) {
        free(tileChecksums_);
        tilesX_ = newTilesX;
        tilesY_ = newTilesY;
        tileChecksums_ = (uint32_t *)calloc(tilesX_ * tilesY_, sizeof(uint32_t));
        forceFullFrameCounter_ = 0;
        needFullRefresh = true;
    } else if (++forceFullFrameCounter_ >= 30) {
        forceFullFrameCounter_ = 0;
        needFullRefresh = true;
    }

    if (needFullRefresh) {
        rfbMarkRectAsModified(screen_, 0, 0, width, height);
        for (int ty = 0; ty < tilesY_; ++ty)
            for (int tx = 0; tx < tilesX_; ++tx)
                tileChecksums_[ty * tilesX_ + tx] = TileChecksum(fb, tx, ty, width, height);
        return;
    }

    for (int ty = 0; ty < tilesY_; ++ty) {
        for (int tx = 0; tx < tilesX_; ++tx) {
            uint32_t c = TileChecksum(fb, tx, ty, width, height);
            int idx = ty * tilesX_ + tx;
            if (c != tileChecksums_[idx]) {
                tileChecksums_[idx] = c;
                int x0 = tx * kTileSize, y0 = ty * kTileSize;
                int x1 = x0 + kTileSize; if (x1 > width) x1 = width;
                int y1 = y0 + kTileSize; if (y1 > height) y1 = height;
                rfbMarkRectAsModified(screen_, x0, y0, x1, y1);
            }
        }
    }
}

// ============== 阶段 2:CARenderServer 主动捕获路径 ==============
// 与 IOMobileFramebufferSwapSetLayer 钩注互斥;由 CaptureMethod 设置切换。
// 这条路 RecordMyScreen / iOS 6 时代 Apple 录屏标准 SPI(CARenderServerRenderDisplay)。

static void StopCARenderServerCapture() {
    if (carsTimer_) {
        dispatch_source_cancel(carsTimer_);
        carsTimer_ = NULL;
    }
    if (carsSurface_) {
        CFRelease(carsSurface_);
        carsSurface_ = NULL;
    }
    carsRunning_ = false;
    if (verboseLogging_) NSLog(@"[Veency] CARenderServer 捕获已停止");
}

static void StartCARenderServerCapture() {
    if (carsRunning_) return;
    if (!fnCARenderServerRenderDisplay || !fnIOSurfaceCreate || !fnIOSurfaceLock) {
        NSLog(@"[Veency] CARenderServer SPI 不可用,放弃主动 pull 模式");
        return;
    }
    if (width_ == 0 || height_ == 0 || screen_ == NULL || mainFrameBuffer_ == NULL) {
        NSLog(@"[Veency] CARenderServer 启动延迟:width=%zu height=%zu screen=%p mainFB=%p",
              width_, height_, screen_, mainFrameBuffer_);
        return;
    }

    int w = (int)destwidth_;
    int h = (int)destheight_;
    int bpr = w * 4;
    NSDictionary *props = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:YES], (id)kIOSurfaceIsGlobal,
        [NSNumber numberWithInt:4], (id)kIOSurfaceBytesPerElement,
        [NSNumber numberWithInt:bpr], (id)kIOSurfaceBytesPerRow,
        [NSNumber numberWithInt:w], (id)kIOSurfaceWidth,
        [NSNumber numberWithInt:h], (id)kIOSurfaceHeight,
        [NSNumber numberWithUnsignedInt:'BGRA'], (id)kIOSurfacePixelFormat,
        [NSNumber numberWithInt:bpr * h], (id)kIOSurfaceAllocSize,
        nil];
    carsSurface_ = fnIOSurfaceCreate((CFDictionaryRef)props);
    if (!carsSurface_) {
        NSLog(@"[Veency] IOSurfaceCreate 失败");
        return;
    }

    if (carsQueue_ == NULL)
        carsQueue_ = dispatch_queue_create("com.saurik.veency.cars", DISPATCH_QUEUE_SERIAL);
    carsTimer_ = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, carsQueue_);
    uint64_t interval = NSEC_PER_SEC / maxFPS_;
    dispatch_source_set_timer(carsTimer_, dispatch_time(DISPATCH_TIME_NOW, 0),
                              interval, NSEC_PER_MSEC);
    static int diagFrameCount_ = 0;
    static int carsFailCount_ = 0;
    dispatch_source_set_event_handler(carsTimer_, ^{
        if (clients_ == 0) return;
        @synchronized (condition_) {
            if (screen_ == NULL || mainFrameBuffer_ == NULL) return;

            // 1) 拉一帧到 user IOSurface
            fnIOSurfaceLock(carsSurface_, 0, NULL);
            int rc = fnCARenderServerRenderDisplay(0, CFSTR("LCD"), (void *)carsSurface_, 0, 0);
            fnIOSurfaceUnlock(carsSurface_, 0, NULL);

            void *src = fnIOSurfaceGetBaseAddress(carsSurface_);
            if (rc != 0) {
                if (++carsFailCount_ <= 3 || carsFailCount_ % 60 == 0) {
                    NSLog(@"[Veency] CARenderServer rc=%d (#%d 次失败) — 该 SPI 在 backboardd 内不可用,自动停止 CARS 模式回退到 hook",
                          rc, carsFailCount_);
                }
                if (carsFailCount_ >= 3) {
                    // 自动停止 CARS,回退 hook
                    dispatch_async(dispatch_get_main_queue(), ^{ StopCARenderServerCapture(); });
                }
                return;
            }
            // 每 30 帧打一次像素值用于诊断
            if (++diagFrameCount_ % 30 == 1) {
                uint32_t *px = (uint32_t *)src;
                NSLog(@"[Veency-CARS] frame=%d rc=%d px[0,1,100,10000]=%08x %08x %08x %08x",
                      diagFrameCount_, rc, px ? px[0] : 0, px ? px[1] : 0,
                      px ? px[100] : 0, px ? px[10000] : 0);
            }

            // 2) 拷到 mainFrameBuffer_(libvncserver 路径)
            if (!src) return;
            memcpy(mainFrameBuffer_, src, w * h * 4);
            screen_->frameBuffer = (char *)mainFrameBuffer_;

            // 3) 复用 M2 dirty-tile 路径
            const uint32_t *fb = (const uint32_t *)mainFrameBuffer_;
            uint64_t sig = QuickFrameSignature(fb, destwidth_, destheight_);
            if (sig != lastFrameSig_) {
                lastFrameSig_ = sig;
                MarkDirtyTiles(fb, destwidth_, destheight_);
            }
        }
    });
    dispatch_resume(carsTimer_);
    carsRunning_ = true;
    NSLog(@"[Veency] CARenderServer 捕获已启动: %d×%d @ %d FPS", w, h, maxFPS_);
}

// 由 VNCSettings 调用:根据 useCARenderServer_ 切换捕获方式
static void ApplyCaptureMethod() {
    if (useCARenderServer_) {
        StartCARenderServerCapture();
    } else {
        StopCARenderServerCapture();
    }
}

// ============== 阶段 3: VT 硬件 H.264 编码实现 ==============

static void TeardownVTEncoder() {
    if (vtSession_ && fnVTCompressionSessionInvalidate) {
        fnVTCompressionSessionInvalidate(vtSession_);
        CFRelease(vtSession_);
        vtSession_ = NULL;
    }
    [cachedSPS_ release]; cachedSPS_ = nil;
    [cachedPPS_ release]; cachedPPS_ = nil;
    vtFrameNo_ = 0;
    NSLog(@"[Veency-VT] 编码器已停");
}

static void SetupVTEncoder() {
    TeardownVTEncoder();
    if (!fnVTCompressionSessionCreate || !fnVTCompressionSessionSetProperty) {
        NSLog(@"[Veency-VT] VT SPI 不可用");
        return;
    }
    if (width_ == 0 || height_ == 0) {
        NSLog(@"[Veency-VT] 屏幕尺寸 0,延迟创建");
        return;
    }
    if (vtQueue_ == NULL)
        vtQueue_ = dispatch_queue_create("com.saurik.veency.vt", DISPATCH_QUEUE_SERIAL);
    if (h264WriteLock_ == nil)
        h264WriteLock_ = [[NSLock alloc] init];

    NSDictionary *srcAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithUnsignedInt:'BGRA'], (id)kCVPixelBufferPixelFormatTypeKey,
        [NSDictionary dictionary], (id)kCVPixelBufferIOSurfacePropertiesKey,
        nil];

    OSStatus s = fnVTCompressionSessionCreate(
        kCFAllocatorDefault,
        (int32_t)destwidth_, (int32_t)destheight_,
        'avc1',  // kCMVideoCodecType_H264
        NULL, (CFDictionaryRef)srcAttrs,
        kCFAllocatorDefault,
        H264OutputCallback, NULL,
        &vtSession_);

    if (s != 0 || !vtSession_) {
        NSLog(@"[Veency-VT] VTCompressionSessionCreate 失败: %d", (int)s);
        vtSession_ = NULL;
        return;
    }

    fnVTCompressionSessionSetProperty(vtSession_, CFSTR("RealTime"), kCFBooleanTrue);

    int bps = h264Bitrate_ * 1000;
    CFNumberRef bpsNum = CFNumberCreate(NULL, kCFNumberIntType, &bps);
    fnVTCompressionSessionSetProperty(vtSession_, CFSTR("AverageBitRate"), bpsNum);
    CFRelease(bpsNum);

    CFNumberRef kfNum = CFNumberCreate(NULL, kCFNumberIntType, &h264KeyframeInterval_);
    fnVTCompressionSessionSetProperty(vtSession_, CFSTR("MaxKeyFrameInterval"), kfNum);
    CFRelease(kfNum);

    fnVTCompressionSessionSetProperty(vtSession_, CFSTR("AllowFrameReordering"), kCFBooleanFalse);

    CFStringRef profile = CFSTR("H264_Main_AutoLevel");
    if ([h264Profile_ isEqualToString:@"baseline"]) profile = CFSTR("H264_Baseline_AutoLevel");
    else if ([h264Profile_ isEqualToString:@"high"]) profile = CFSTR("H264_High_AutoLevel");
    fnVTCompressionSessionSetProperty(vtSession_, CFSTR("ProfileLevel"), profile);

    NSLog(@"[Veency-VT] 编码器创建 %d×%d @ %d kbps, KFI=%d, profile=%@",
          (int)destwidth_, (int)destheight_, h264Bitrate_, h264KeyframeInterval_, h264Profile_);
}

// AVCC (4-byte BE length prefix) → Annex B (00 00 00 01 start code)
static NSMutableData *AVCCtoAnnexB(const uint8_t *avcc, size_t len) {
    NSMutableData *out = [NSMutableData dataWithCapacity:len + 64];
    static const uint8_t sc[4] = {0,0,0,1};
    size_t pos = 0;
    while (pos + 4 <= len) {
        uint32_t naluLen = ((uint32_t)avcc[pos]<<24) | ((uint32_t)avcc[pos+1]<<16)
                         | ((uint32_t)avcc[pos+2]<<8) | (uint32_t)avcc[pos+3];
        pos += 4;
        if (pos + naluLen > len) break;
        [out appendBytes:sc length:4];
        [out appendBytes:avcc + pos length:naluLen];
        pos += naluLen;
    }
    return out;
}

// 从 formatDescription 抽 SPS/PPS(避开缺失的 GetH264ParameterSetAtIndex)
static void ExtractSPSPPSFromFormat(CMVideoFormatDescriptionRef fmt) {
    if (!fnCMFormatDescriptionGetExtension) return;
    CFTypeRef ext = fnCMFormatDescriptionGetExtension(fmt, CFSTR("SampleDescriptionExtensionAtoms"));
    if (!ext || CFGetTypeID(ext) != CFDictionaryGetTypeID()) return;
    CFDataRef avcC = (CFDataRef)CFDictionaryGetValue((CFDictionaryRef)ext, CFSTR("avcC"));
    if (!avcC || CFGetTypeID(avcC) != CFDataGetTypeID()) return;
    const uint8_t *p = CFDataGetBytePtr(avcC);
    CFIndex n = CFDataGetLength(avcC);
    if (n < 7) return;
    int numSPS = p[5] & 0x1F;
    int offset = 6;
    [cachedSPS_ release]; cachedSPS_ = nil;
    if (numSPS >= 1 && offset + 2 <= n) {
        int spsLen = (p[offset] << 8) | p[offset+1]; offset += 2;
        if (offset + spsLen <= n) {
            cachedSPS_ = [[NSData alloc] initWithBytes:p+offset length:spsLen];
            offset += spsLen;
        }
    }
    if (offset >= n) return;
    int numPPS = p[offset++];
    [cachedPPS_ release]; cachedPPS_ = nil;
    if (numPPS >= 1 && offset + 2 <= n) {
        int ppsLen = (p[offset] << 8) | p[offset+1]; offset += 2;
        if (offset + ppsLen <= n) {
            cachedPPS_ = [[NSData alloc] initWithBytes:p+offset length:ppsLen];
        }
    }
    NSLog(@"[Veency-VT] SPS=%lu bytes PPS=%lu bytes",
          (unsigned long)cachedSPS_.length, (unsigned long)cachedPPS_.length);
}

// 自定义伪编码协议:发送 H.264 Annex B NALU 流到所有客户端
// 帧格式:
//   FramebufferUpdate header (4): type=0, pad=0, nrects=1
//   Rect header (12): x, y, w, h, encoding=0x48323634
//   Payload: 4 字节 BE 总长度 + Annex B 流(关键帧前会附 SPS/PPS)
static void SendH264NALUToClients(const uint8_t *nalu, size_t length, bool isKeyframe,
                                    int width, int height) {
    if (!screen_ || length == 0) return;
    static int sendCount_ = 0;
    int matchedClients = 0;
    int totalClients = 0;

    // 全局串行化:避免多个 VT 回调同时写 socket 造成字节穿插
    [h264WriteLock_ lock];

    rfbClientIteratorPtr it = rfbGetClientIterator(screen_);
    rfbClientPtr cl;
    while ((cl = rfbClientIteratorNext(it)) != NULL) {
        totalClients++;
        // 只发给已完成握手 + 鉴权 + ClientInit 的客户端(state == RFB_NORMAL == 4)
        if ((int)cl->state != 4) {
            if (verboseLogging_ && sendCount_ < 3)
                NSLog(@"[Veency-VT] 跳过客户端 fd=%d (state=%d != 4)", cl->sock, (int)cl->state);
            continue;
        }
        matchedClients++;

        NSMutableData *full = [NSMutableData dataWithCapacity:length + 64];
        // 仅在关键帧前注入 SPS/PPS。客户端解码 P 帧前需要先有过 SPS/PPS,
        // 因此连接后第一个关键帧到来前的所有 P 帧客户端会丢弃 — 等 1 秒后即正常解码。
        if (isKeyframe && cachedSPS_ && cachedPPS_) {
            static const uint8_t sc[4] = {0,0,0,1};
            [full appendBytes:sc length:4];
            [full appendData:cachedSPS_];
            [full appendBytes:sc length:4];
            [full appendData:cachedPPS_];
        }
        [full appendBytes:nalu length:length];

        // 注:libvncserver 编译时未启用 pthread(MUTEX 宏为 no-op,
        // cl->outputMutex 字段并不真实存在),所以 LOCK 会访问不存在的内存崩溃。
        // 我们只写 H.264 帧,libvncserver 主线程在 h264 模式下不会发任何更新
        // (modifiedRegion 为空),所以单写者无竞争。

        rfbFramebufferUpdateMsg fum;
        fum.type = rfbFramebufferUpdate;
        fum.pad = 0;
        fum.nRects = Swap16IfLE(1);
        rfbWriteExact(cl, (char *)&fum, sz_rfbFramebufferUpdateMsg);

        rfbFramebufferUpdateRectHeader rh;
        rh.r.x = Swap16IfLE(0);
        rh.r.y = Swap16IfLE(0);
        rh.r.w = Swap16IfLE(width);
        rh.r.h = Swap16IfLE(height);
        rh.encoding = Swap32IfLE(rfbEncodingVeencyH264);
        rfbWriteExact(cl, (char *)&rh, sz_rfbFramebufferUpdateRectHeader);

        uint32_t lenBE = Swap32IfLE((uint32_t)full.length);
        rfbWriteExact(cl, (char *)&lenBE, 4);
        rfbWriteExact(cl, (char *)full.bytes, full.length);
    }
    rfbReleaseClientIterator(it);

    [h264WriteLock_ unlock];

    if (verboseLogging_ && (++sendCount_ <= 5 || sendCount_ % 60 == 0)) {
        NSLog(@"[Veency-VT] SendH264 #%d: %d/%d clients %luB %s",
              sendCount_, matchedClients, totalClients, (unsigned long)length,
              isKeyframe ? "[KEY]" : "");
    }
}

static void H264OutputCallback(void *refCon, void *srcRef,
                                OSStatus status, uint32_t infoFlags, CMSampleBufferRef sample) {
    static int cbCount_ = 0;
    if (++cbCount_ <= 5 || cbCount_ % 30 == 0) {
        NSLog(@"[Veency-VT] CB#%d status=%d sample=%p flags=0x%x",
              cbCount_, (int)status, sample, infoFlags);
    }
    if (status != 0 || !sample) {
        return;
    }
    if (!fnCMSampleBufferGetDataBuffer || !fnCMBlockBufferGetDataPointer) return;

    bool isKeyframe = false;
    if (fnCMSampleBufferGetSampleAttachmentsArray) {
        CFArrayRef attachs = fnCMSampleBufferGetSampleAttachmentsArray(sample, false);
        if (attachs && CFArrayGetCount(attachs) > 0) {
            CFDictionaryRef att = (CFDictionaryRef)CFArrayGetValueAtIndex(attachs, 0);
            CFBooleanRef notSync = (CFBooleanRef)CFDictionaryGetValue(att, CFSTR("NotSync"));
            isKeyframe = (notSync == NULL || !CFBooleanGetValue(notSync));
        }
    }
    if (isKeyframe && cachedSPS_ == nil) {
        CMVideoFormatDescriptionRef fmt = fnCMSampleBufferGetFormatDescription(sample);
        if (fmt) ExtractSPSPPSFromFormat(fmt);
    }

    CMBlockBufferRef bb = fnCMSampleBufferGetDataBuffer(sample);
    if (!bb) {
        if (cbCount_ <= 5) NSLog(@"[Veency-VT] CB#%d: GetDataBuffer NULL", cbCount_);
        return;
    }
    char *avccPtr = NULL; size_t avccTotal = 0;
    OSStatus rc = fnCMBlockBufferGetDataPointer(bb, 0, NULL, &avccTotal, &avccPtr);
    if (cbCount_ <= 5)
        NSLog(@"[Veency-VT] CB#%d: GetDataPointer rc=%d avccTotal=%lu avccPtr=%p",
              cbCount_, (int)rc, (unsigned long)avccTotal, avccPtr);
    if (rc != 0 || !avccPtr || avccTotal == 0) return;

    // 打印前 16 字节,排查 AVCC 长度前缀是否合理
    if (cbCount_ <= 3) {
        const uint8_t *p = (const uint8_t *)avccPtr;
        NSLog(@"[Veency-VT] CB#%d: avcc[0..15]=%02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x",
              cbCount_, p[0],p[1],p[2],p[3],p[4],p[5],p[6],p[7],
              p[8],p[9],p[10],p[11],p[12],p[13],p[14],p[15]);
    }

    @autoreleasepool {
        NSMutableData *annexB = AVCCtoAnnexB((const uint8_t *)avccPtr, avccTotal);
        if (cbCount_ <= 3) {
            NSLog(@"[Veency-VT] CB#%d: annexB.length=%lu (from avccTotal=%lu)",
                  cbCount_, (unsigned long)annexB.length, (unsigned long)avccTotal);
        }

        // Bypass 验证:写到设备 /tmp/veency_h264.bin,确认编码器端到端 OK
        // (开关:VerboseLogging 同时开 → 写文件;关 → 跳过)
        if (verboseLogging_) {
            static FILE *dumpFp = NULL;
            static int dumpedFrames = 0;
            if (!dumpFp) dumpFp = fopen("/tmp/veency_h264.bin", "wb");
            if (dumpFp && dumpedFrames < 300) {
                if (isKeyframe && cachedSPS_ && cachedPPS_ && dumpedFrames == 0) {
                    static const uint8_t sc[4] = {0,0,0,1};
                    fwrite(sc, 1, 4, dumpFp);
                    fwrite(cachedSPS_.bytes, 1, cachedSPS_.length, dumpFp);
                    fwrite(sc, 1, 4, dumpFp);
                    fwrite(cachedPPS_.bytes, 1, cachedPPS_.length, dumpFp);
                }
                fwrite(annexB.bytes, 1, annexB.length, dumpFp);
                fflush(dumpFp);
                dumpedFrames++;
                if (dumpedFrames == 30 || dumpedFrames == 100) {
                    NSLog(@"[Veency-VT] 已 dump %d 帧到 /tmp/veency_h264.bin", dumpedFrames);
                }
            }
        }

        @synchronized (condition_) {
            SendH264NALUToClients((const uint8_t *)annexB.bytes, annexB.length,
                                  isKeyframe, (int)destwidth_, (int)destheight_);
        }
    }
}

static void EncodeFrameViaVT(void *iosurface, int width, int height) {
    if (!vtSession_ || !fnCVPixelBufferCreateWithIOSurface || !fnVTCompressionSessionEncodeFrame) return;

    CVPixelBufferRef pb = NULL;
    OSStatus rc = fnCVPixelBufferCreateWithIOSurface(NULL, iosurface, NULL, &pb);
    if (rc != 0 || !pb) {
        if (verboseLogging_) NSLog(@"[Veency-VT] CVPixelBufferCreateWithIOSurface rc=%d", (int)rc);
        return;
    }

    // 注:ForceKeyFrame 路径会让 backboardd 崩溃(原因不明,可能 SPI 该字段名不同)
    // 暂时去掉,依赖 KFI=30 自然产生关键帧。客户端最多等 1 秒看到第一帧。
    forceNextKeyframe_ = false;  // 一次性消费,避免无限累积

    CMTimeVL pts = {vtFrameNo_, maxFPS_, 1, 0};
    CMTimeVL dur = {1, maxFPS_, 1, 0};
    rc = fnVTCompressionSessionEncodeFrame(vtSession_, pb, pts, dur, NULL, NULL, NULL);
    if (rc != 0 && verboseLogging_) NSLog(@"[Veency-VT] EncodeFrame rc=%d", (int)rc);
    vtFrameNo_++;
    CFRelease(pb);
}

static bool updatingScreen=false;
static void OnLayer(IOMobileFramebufferRef fb, CoreSurfaceBufferRef layer) {
    // 当 CARenderServer 主动 pull 模式启用时,Hook 路径必须让出来,否则双路冲突
    if (carsRunning_) return;

    int doUpdates=1;
    if (_unlikely(width_ == 0 || height_ == 0)) {
        CGSize size;
        IOMobileFramebufferGetDisplaySize(fb, &size);

        width_ = size.width;
        height_ = size.height;
        destwidth_ = size.width/divideScreenBy_;
        destheight_ = size.height/divideScreenBy_;

        if (width_ == 0 || height_ == 0)
            return;

        NSThread *thread([NSThread alloc]);

        [thread
            initWithTarget:[VNCBridge class]
            selector:@selector(performSetup:)
            object:thread
        ];

        [thread start];
    } else if (_unlikely(clients_ != 0)) {
        if (layer == NULL) {
/*  *** this blacking of the screen causes a mess in opengl apps.
            if (accelerator_ != NULL)
                memset(screen_->frameBuffer, 0, sizeof(rfbPixel) * width_ * height_);
            else
                VNCBlack();
*/
        } else {
//Log("Accelerator_:%x\n",accelerator_);
            if (accelerator_ != NULL) {
//                CoreSurfaceAcceleratorTransferSurface(accelerator_, layer, buffer_, options_);

                if(!skipBlack_ && divideScreenBy_ == 1) {
                    screen_->frameBuffer=(char *)bufferData_;
                    CoreSurfaceAcceleratorTransferSurface(accelerator_, layer, buffer_, options_);
                } else {
                    screen_->frameBuffer=(char *)mainFrameBuffer_;
                    int ok=1;
                    CoreSurfaceBufferLock(buffer_, 3);
                    CoreSurfaceAcceleratorTransferSurface(accelerator_, layer, buffer_, options2_);

                    if(skipBlack_) {
                        // TransferSurface 已同步等待 GPU,无需 usleep;若特定应用花屏可恢复 usleep(skipBlack_)
                        CoreSurfaceBufferFlushProcessorCaches(buffer_);
                        ok=isBottomScreenBlack(bufferData_)?0:1;
                    }
                    if(ok) {
                        if(divideScreenBy_>1) {
                            CopyToFrameBuffer(mainFrameBuffer_,(rfbPixel *)bufferData_,divideScreenBy_);
                        } else {
                            memcpy(mainFrameBuffer_,bufferData_,width_*height_*sizeof(rfbPixel));
                        }
                    } else { 
                        doUpdates=0;
                    }
                }

            } else {
                if(updatingScreen) return;
                updatingScreen=true;
                CoreSurfaceBufferLock(layer, 2);
                @try {
                    rfbPixel *data(reinterpret_cast<rfbPixel *>(CoreSurfaceBufferGetBaseAddress(layer)));
                    if(skipBlack_) {
                        if(isBottomScreenBlack((const char *)data)) {
                            return;
                        }
                    }

                    CoreSurfaceBufferFlushProcessorCaches(layer);

                    /*rfbPixel corner(data[0]);
                    data[0] = 0;
                    data[0] = corner;*/

    //                screen_->frameBuffer = const_cast<char *>(reinterpret_cast<volatile char *>(data));

                    const char *x = const_cast<char *>(reinterpret_cast<volatile char *>(data));
                    if(divideScreenBy_==1) {
                        Copy64x16BlockedImage((char *)mainFrameBuffer_,x);
                    } else {
                        if(correctedBlocksBuffer_==NULL)
                            correctedBlocksBuffer_ = reinterpret_cast<rfbPixel *>(mmap(NULL, sizeof(rfbPixel) * width_ * height_, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NOCACHE, VM_FLAGS_PURGABLE, 0));
//~~~ When using camera, opengl, etc. apps.  Any access to  the pointer returned from CoreSurfaceBufferGetBaseAddress crashes
                        Copy64x16BlockedImage((char *)correctedBlocksBuffer_,x);
                        CopyToFrameBuffer(mainFrameBuffer_,(rfbPixel *)correctedBlocksBuffer_,divideScreenBy_);
                    }
                } 
                @finally {
                    CoreSurfaceBufferUnlock(layer);
                    updatingScreen=false;
                }

//    memcpy(mainFrameBuffer_,x,(4*640*200));
            }
        }
        // H.264 路径:用硬件编码器编 buffer_(GPU 转换后的线性 BGRA),旁路 libvncserver 编码
        if (h264Enabled_ && vtSession_ != NULL && buffer_ != NULL && doUpdates) {
            EncodeFrameViaVT(buffer_, (int)destwidth_, (int)destheight_);
        } else if(doUpdates) {
            const uint32_t *fb = (const uint32_t *)screen_->frameBuffer;
            uint64_t sig = QuickFrameSignature(fb, destwidth_, destheight_);
            if (sig != lastFrameSig_) {
                lastFrameSig_ = sig;
                MarkDirtyTiles(fb, destwidth_, destheight_);
            }
        }
    }
}

static bool wait_ = false;

MSHook(kern_return_t, IOMobileFramebufferSwapSetLayer,
    IOMobileFramebufferRef fb,
    int layer,
    CoreSurfaceBufferRef buffer,
    CGRect bounds,
    CGRect frame,
    int flags
) {
    int main(false);

    if (_unlikely(buffer == NULL))
        main = fb == main_;
    else if (_unlikely(fb == NULL))
        main = false;
    else if ($IOMobileFramebufferIsMainDisplay == NULL)
        main = true;
    else
        (*$IOMobileFramebufferIsMainDisplay)(fb, &main);

    if (_likely(main)) {
        main_ = fb;
        if (wait_)
            layer_ = buffer;
        else
            OnLayer(fb, buffer);
    }

    return _IOMobileFramebufferSwapSetLayer(fb, layer, buffer, bounds, frame, flags);
}

// XXX: beg rpetrich for the type of this function
extern "C" void *IOMobileFramebufferSwapWait(IOMobileFramebufferRef, void *, unsigned);

MSHook(void *, IOMobileFramebufferSwapWait, IOMobileFramebufferRef fb, void *arg1, unsigned flags) {
    void *value(_IOMobileFramebufferSwapWait(fb, arg1, flags));
    if (fb == main_)
        OnLayer(fb, layer_);
    return value;
}

MSHook(void, rfbRegisterSecurityHandler, rfbSecurityHandler *handler) {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    @synchronized (lock_) {
        [handlers_ addObject:[NSValue valueWithPointer:handler]];
        _rfbRegisterSecurityHandler(handler);
    }

    [pool release];
}

// 当 H.264 模式启用时,拦截 libvncserver 自身的帧发送,改由我们 VT callback 直推 NALU
extern "C" rfbBool rfbSendFramebufferUpdate(rfbClientPtr cl, sraRegionPtr modRgn);
MSHook(rfbBool, rfbSendFramebufferUpdate, rfbClientPtr cl, sraRegionPtr modRgn) {
    if (h264Enabled_) {
        // 把待发区域吃掉(变空),让 libvncserver 误以为没东西要发,不会重排或重发
        sraRgnSubtract(cl->modifiedRegion, cl->modifiedRegion);
        return TRUE;
    }
    return _rfbSendFramebufferUpdate(cl, modRgn);
}

template <typename Type_>
static void dlset(Type_ &function, const char *name) {
    function = reinterpret_cast<Type_>(dlsym(RTLD_DEFAULT, name));
}

// ============== 阶段 1:VT/CARenderServer/IOSurface API 探针 ==============
// 目的:在 backboardd 与 SpringBoard 进程内 dlsym 检测 iOS 6.1.3 私下里的硬件视频 API,
// 输出到 syslog,确认设备能走方案 B(VT 硬件 H.264)。失败时回 fallback。
static void VeencyProbeAPIs() {
    static const char *symbols[] = {
        "VTCompressionSessionCreate",
        "VTCompressionSessionEncodeFrame",
        "VTCompressionSessionSetProperty",
        "VTCompressionSessionCompleteFrames",
        "VTCompressionSessionInvalidate",
        "VTCompressionSessionGetPixelBufferPool",
        "VTPixelTransferSessionCreate",
        "VTPixelTransferSessionTransferImage",
        "VTDecompressionSessionCreate",
        "CARenderServerRenderDisplay",
        "CARenderServerGetFrameCounter",
        "IOMobileFramebufferGetMainDisplay",
        "IOMobileFramebufferGetLayerDefaultSurface",
        "IOSurfaceCreate",
        "IOSurfaceLock",
        "IOSurfaceUnlock",
        "IOSurfaceGetBaseAddress",
        "IOSurfaceAcceleratorCreate",
        "IOSurfaceAcceleratorTransferSurface",
        "IOSurfaceAcceleratorTransferSurfaceWithSwap",
        "CVPixelBufferCreateWithIOSurface",
        "CMBlockBufferGetDataPointer",
        "CMSampleBufferGetDataBuffer",
        "CMSampleBufferGetFormatDescription",
        "CMVideoFormatDescriptionGetH264ParameterSetAtIndex",
        NULL
    };
    int found = 0, total = 0;
    for (int i = 0; symbols[i]; i++) {
        void *p = dlsym(RTLD_DEFAULT, symbols[i]);
        NSLog(@"[Veency-Probe] %-55s %s", symbols[i], p ? "FOUND" : "MISSING");
        if (p) found++;
        total++;
    }
    NSLog(@"[Veency-Probe] === %d/%d symbols available on this device ===", found, total);
}

MSInitialize {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    VeencyProbeAPIs();

    // 解析 CARenderServer / IOSurface 函数指针(iOS 6 SPI)
    fnCARenderServerRenderDisplay = (CARenderServerRenderDisplay_t)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    fnIOSurfaceCreate = (IOSurfaceCreate_t)dlsym(RTLD_DEFAULT, "IOSurfaceCreate");
    fnIOSurfaceLock = (IOSurfaceLock_t)dlsym(RTLD_DEFAULT, "IOSurfaceLock");
    fnIOSurfaceUnlock = (IOSurfaceUnlock_t)dlsym(RTLD_DEFAULT, "IOSurfaceUnlock");
    fnIOSurfaceGetBaseAddress = (IOSurfaceGetBaseAddress_t)dlsym(RTLD_DEFAULT, "IOSurfaceGetBaseAddress");

    // 解析 VT/CM/CV SPI(iOS 6 私下里就有)
    fnVTCompressionSessionCreate = (VTCompressionSessionCreate_t)dlsym(RTLD_DEFAULT, "VTCompressionSessionCreate");
    fnVTCompressionSessionEncodeFrame = (VTCompressionSessionEncodeFrame_t)dlsym(RTLD_DEFAULT, "VTCompressionSessionEncodeFrame");
    fnVTCompressionSessionSetProperty = (VTCompressionSessionSetProperty_t)dlsym(RTLD_DEFAULT, "VTCompressionSessionSetProperty");
    fnVTCompressionSessionInvalidate = (VTCompressionSessionInvalidate_t)dlsym(RTLD_DEFAULT, "VTCompressionSessionInvalidate");
    fnCMSampleBufferGetDataBuffer = (CMSampleBufferGetDataBuffer_t)dlsym(RTLD_DEFAULT, "CMSampleBufferGetDataBuffer");
    fnCMSampleBufferGetFormatDescription = (CMSampleBufferGetFormatDescription_t)dlsym(RTLD_DEFAULT, "CMSampleBufferGetFormatDescription");
    fnCMSampleBufferGetSampleAttachmentsArray = (CMSampleBufferGetSampleAttachmentsArray_t)dlsym(RTLD_DEFAULT, "CMSampleBufferGetSampleAttachmentsArray");
    fnCMBlockBufferGetDataPointer = (CMBlockBufferGetDataPointer_t)dlsym(RTLD_DEFAULT, "CMBlockBufferGetDataPointer");
    fnCMFormatDescriptionGetExtension = (CMFormatDescriptionGetExtension_t)dlsym(RTLD_DEFAULT, "CMFormatDescriptionGetExtension");
    fnCVPixelBufferCreateWithIOSurface = (CVPixelBufferCreateWithIOSurface_t)dlsym(RTLD_DEFAULT, "CVPixelBufferCreateWithIOSurface");

    MSHookSymbol(GSTakePurpleSystemEventPort, "_GSGetPurpleSystemEventPort");
    if (GSTakePurpleSystemEventPort == NULL) {
        MSHookSymbol(GSTakePurpleSystemEventPort, "_GSCopyPurpleSystemEventPort");
        PurpleAllocated = true;
    }

    if (dlsym(RTLD_DEFAULT, "GSLibraryCopyGenerationInfoValueForKey") != NULL)
        Level_ = 3;
    else if (dlsym(RTLD_DEFAULT, "GSKeyboardCreate") != NULL)
        Level_ = 2;
    else if (dlsym(RTLD_DEFAULT, "GSEventGetWindowContextId") != NULL)
        Level_ = 1;
    else
        Level_ = 0;

    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char machine[size];
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    iPad1_ = strcmp(machine, "iPad1,1") == 0;

    dlset($GSEventCreateKeyEvent, "GSEventCreateKeyEvent");
    dlset($GSCreateSyntheticKeyEvent, "_GSCreateSyntheticKeyEvent");
    dlset($IOMobileFramebufferIsMainDisplay, "IOMobileFramebufferIsMainDisplay");

    MSHookFunction((void *)&IOMobileFramebufferSwapSetLayer, MSHake2(IOMobileFramebufferSwapSetLayer));
    MSHookFunction(&rfbRegisterSecurityHandler, MSHake(rfbRegisterSecurityHandler));
    // 注:rfbSendFramebufferUpdate hook 导致 SIGSEGV(libvncserver 内部状态依赖),已禁用
    // 改为依赖 outputMutex + cl->state==4 过滤,客户端跳过 Raw rect

    if (wait_)
        MSHookFunction(&IOMobileFramebufferSwapWait, MSHake(IOMobileFramebufferSwapWait));

    if ($SBAlertItem != nil) {
        $VNCAlertItem = objc_allocateClassPair($SBAlertItem, "VNCAlertItem", 0);
        MSAddMessage2(VNCAlertItem, "v@:@i", alertSheet,buttonClicked);
        MSAddMessage2(VNCAlertItem, "v@:cc", configure,requirePasscodeForActions);
        MSAddMessage0(VNCAlertItem, "v@:", performUnlockAction);
        objc_registerClassPair($VNCAlertItem);
    }

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, &VNCNotifyEnabled, CFSTR("com.saurik.Veency-Enabled"), NULL, (CFNotificationSuspensionBehavior)0
    );

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, &VNCNotifySettings, CFSTR("com.saurik.Veency-Settings"), NULL, (CFNotificationSuspensionBehavior)0
    );

    condition_ = [[NSCondition alloc] init];
    lock_ = [[NSLock alloc] init];
    handlers_ = [[NSMutableSet alloc] init];

    bool value;

    value = true;
    cfTrue_ = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<UInt8 *>(&value), sizeof(value));

    value = false;
    cfFalse_ = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<UInt8 *>(&value), sizeof(value));

    cfEvent_ = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, reinterpret_cast<UInt8 *>(&event_), sizeof(event_), kCFAllocatorNull);

    options_ = (CFDictionaryRef) [[NSDictionary dictionaryWithObjectsAndKeys:
    nil] retain];

    [pool release];
}
/* vim: set ts=4 sw=4 expandtab: */
