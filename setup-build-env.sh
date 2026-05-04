#!/bin/bash
# Veency 一键搭建本地构建环境
# 适用于 macOS + 现代 Xcode (无需 iPhoneOS 6.1 SDK)
# 使用: ./setup-build-env.sh
set -e
cd "$(dirname "$0")"

step() { echo ""; echo "==> [$1/6] $2"; }

step 1 "检查 Homebrew"
command -v brew >/dev/null || {
    echo "请先安装 Homebrew: https://brew.sh/"; exit 1;
}
echo "    ✅ brew $(brew --version | head -1)"

step 2 "安装 ldid 与 dpkg (打包/签名工具)"
command -v ldid >/dev/null || brew install ldid
command -v dpkg-deb >/dev/null || brew install dpkg
echo "    ✅ ldid $(ldid -h 2>&1 | head -1 | awk '{print $2}' || echo installed)"
echo "    ✅ dpkg-deb $(dpkg-deb --version | head -1 | awk '{print $NF}')"

step 3 "解压 theos_includes.zip → theos/include/"
if [ ! -d theos/include ]; then
    [ -f theos_includes.zip ] || { echo "缺少 theos_includes.zip"; exit 1; }
    unzip -q theos_includes.zip
    mkdir -p theos
    [ -d include ] && mv include theos/include
fi
echo "    ✅ theos/include ($(find theos/include -type f -name '*.h' | wc -l | tr -d ' ') 个 .h)"

step 4 "克隆 SimulateTouch (输入注入头文件)"
if [ ! -f SimulateTouch/SimulateTouch.h ]; then
    rm -rf SimulateTouch
    git clone --depth 1 --quiet https://github.com/iolate/SimulateTouch.git
fi
echo "    ✅ SimulateTouch/SimulateTouch.h"

step 5 "批量 stub 现代 SDK 的 UIKit 头 (规避 iOS 13+ API 级联)"
SDK="$(xcrun -sdk iphoneos --show-sdk-path)"
created=0
for f in "$SDK/System/Library/Frameworks/UIKit.framework/Headers/"*.h; do
    name=$(basename "$f")
    if [ ! -f "theos/include/UIKit/$name" ]; then
        printf "#pragma once\n#import <UIKit/UIKit.h>\n" > "theos/include/UIKit/$name"
        created=$((created+1))
    fi
done
# 大型私有框架空 stub (Tweak.mm 不直接使用,但 SpringBoard 头会传递引入)
# 对整个目录下的所有 .h 都覆写成空 stub,避免 class-dump-z 生成的旧代码引用未声明类型
for fw in ChatKit DataAccess MIME Celestial MediaPlayer AppSupport ActorKit \
          AccountSettings MessageUI WebKit MobileMail MobileSMS ApplePushService \
          AppleAccount Marco MailComposer ContentIndex StoreServices Bluetooth; do
    if [ -d "theos/include/$fw" ]; then
        for f in theos/include/$fw/*.h; do
            [ -f "$f" ] && printf "#pragma once\n" > "$f"
        done
    fi
    mkdir -p "theos/include/$fw"
    [ -f "theos/include/$fw/$fw.h" ] || printf "#pragma once\n" > "theos/include/$fw/$fw.h"
done
echo "    ✅ 新建 UIKit stub: $created 个"

step 6 "写入核心 UIKit / WebCore stub"
# 这些 stub 必须有内容,定义 Tweak.mm 使用的最小 API
mkdir -p theos/include/UIKit theos/include/WebCore
cat > theos/include/UIKit/UIKit.h <<'EOF'
// 最小 UIKit 头 stub —— 用于在没有 iPhoneOS 6.1 SDK 时阻断对现代 SDK UIKit 的级联
#pragma once
#ifndef _VEENCY_UIKIT_STUB_H_
#define _VEENCY_UIKIT_STUB_H_
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#define UIKIT_EXTERN extern "C"
#define UIKIT_EXTERN_C_BEGIN
#define UIKIT_EXTERN_C_END
@class UIWindow, UIView, UIImage, UIColor, UIEvent, UITouch, UIFont;
@protocol UIApplicationDelegate;
@interface UIResponder : NSObject @end
@interface UIApplication : UIResponder
+ (UIApplication *)sharedApplication;
@end
@interface UIScreen : NSObject
+ (UIScreen *)mainScreen;
- (CGFloat)scale;
- (CGRect)bounds;
@end
@interface UIDevice : NSObject
+ (UIDevice *)currentDevice;
- (NSString *)systemVersion;
@end
@interface UIView : UIResponder @end
@interface UIModalView : UIView
- (void)setDelegate:(id)delegate;
- (void)setTitle:(NSString *)title;
- (void)setBodyText:(NSString *)body;
- (void)addButtonWithTitle:(NSString *)title;
@end
@interface UIAlertItem : NSObject
- (UIModalView *)alertSheet;
- (void)dismiss;
@end
#endif
EOF
cat > theos/include/WebCore/WKTypes.h <<'EOF'
#pragma once
// WebCore 内部不透明类型 stub —— 让 UIKit-Structs.h / WKUtilities.h 引用通过
typedef void *WKObject;
typedef void *WKObjectRef;
typedef void *WKViewRef;
typedef void *WKWindowRef;
typedef void *WKEventRef;
typedef void *WKTypeRef;
typedef void *WKContextRef;
typedef void *WKMutableArrayRef;
typedef void *WKArrayRef;
EOF
echo "    ✅ UIKit.h + WebCore/WKTypes.h 写入"

# SimulateKeyboard.h 是历史遗留 include,Tweak.mm 没用其符号,提供空 stub
[ -f SimulateKeyboard.h ] || printf '#pragma once\n' > SimulateKeyboard.h

echo ""
echo "✅ 环境就绪。运行 ./build.sh package 进行打包。"
