// 卡密平台配置（默认值）。CI 会根据工作流输入用同名文件覆盖本文件里的值。
// 若在本地手动编译，可直接改这里的值。
#import <Foundation/Foundation.h>

NSString *const XBSoft = @"1vH40i6QFSehwqsn8O";
NSString *const XBSkey = @"NKCZzdLiikYjiE78k2V6nncRfjVB57GZ";
NSString *const XBAesKey = @"HL1MAZDPXijHJqkaayNHbW1OYEHL0bqa"; // 自动取前 16 字节做 AES-128
NSString *const XBAesIv = @"MyOuMMvnvSQsjOsN";
NSString *const XBSignTpl = @"123[data]456[key]789";

NSArray *XBEndpoints(void) {
    return @[
        @"https://api2.xbzhan.com/api/login",
        @"https://api3.xbzhan.com/api/login",
        @"https://api4.xbzhan.com/api/login"
    ];
}

NSInteger const XBHeartSeconds = 150; // 应小于后台心跳周期(如 180)
BOOL const XBHeartEnabled = YES;       // 校验失败/超时自动退出
