// 卡密平台配置（默认值）。CI 会根据工作流输入用同名文件覆盖本文件里的值。
// 若在本地手动编译，可直接改这里的值。
#import <Foundation/Foundation.h>

NSString *const XBSoft = @"A5oK9TdIScwJ7YVhKa";
NSString *const XBSkey = @"spsDHBCg8SeoPuOcCMpiWX6hJ9WQ3atN";
NSString *const XBAesKey = @"pB1q7K9aR60lmP7HgpkNZ2dywAQmCHXg"; // 自动取前 16 字节做 AES-128
NSString *const XBAesIv = @"eBYRj7Hcz4nCrw9l";
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
