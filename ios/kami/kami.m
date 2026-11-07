// iOS 卡密验证 dylib（小白网络验证协议，WKWebView + 可自定义 HTML）
//
// 编译：xcrun --sdk iphoneos clang -arch arm64 -dynamiclib -fobjc-arc \
//         -framework Foundation -framework UIKit -framework WebKit \
//         -mios-version-min=12.0 -o libkami.dylib kami.m xb_config.m
//
// 登录协议：AES-128-CBC(JSON) -> hex，sign = md5("123"+hex+"456"+软件秘钥+"789")
// 页面 HTML 从 App 包内的 kami/index.html 读取（没有则用内置兜底页）。
// 页面通过 window.Android.xxx 调用原生（dylib 在 documentStart 注入 shim）：
//   Android.verifyCardKey2(soft, url, card, cbName)
//   Android.writeSP(key, value) / Android.Toast(msg) / Android.close() / Android.openUrl(url)
// 不保存卡密：每次启动都必须重新输入并验证；成功只在本次运行内做心跳。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>
#import <stdlib.h>
#import <stdio.h>
#import <string.h>

// ===== 由 xb_config.m 提供 =====
extern NSString *const XBSoft;
extern NSString *const XBSkey;
extern NSString *const XBAesKey;
extern NSString *const XBAesIv;
extern NSString *const XBSignTpl;
extern NSArray  *XBEndpoints(void);
extern NSInteger const XBHeartSeconds;
extern BOOL      const XBHeartEnabled;

static NSString *const kPrefsClientId = @"xb_clientid";
// 注意：不保存卡密/会话，每次启动都必须重新输入并验证。

#pragma mark - Crypto

static NSString *XBHexFromData(NSData *data) {
    const unsigned char *b = data.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

static NSData *XBDataFromHex(NSString *hex) {
    NSInteger n = hex.length / 2;
    NSMutableData *d = [NSMutableData dataWithCapacity:n];
    for (NSInteger i = 0; i < n; i++) {
        unsigned int v = 0;
        sscanf([[hex substringWithRange:NSMakeRange(i * 2, 2)] UTF8String], "%x", &v);
        unsigned char c = (unsigned char)v;
        [d appendBytes:&c length:1];
    }
    return d;
}

static NSData *XBKeyData(void) {
    NSString *k = XBAesKey ?: @"";
    if (k.length < 16) k = @"HL1MAZDPXijHJqka";
    return [[k substringToIndex:16] dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *XBIVData(void) {
    NSString *v = XBAesIv ?: @"";
    if (v.length < 16) v = @"MyOuMMvnvSQsjOsN";
    return [[v substringToIndex:16] dataUsingEncoding:NSUTF8StringEncoding];
}

static NSString *XBAesEncryptHex(NSData *plain) {
    size_t outLen = plain.length + kCCBlockSizeAES128;
    NSMutableData *out = [NSMutableData dataWithLength:outLen];
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(kCCEncrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding,
                                 XBKeyData().bytes, kCCKeySizeAES128, XBIVData().bytes,
                                 plain.bytes, plain.length, out.mutableBytes, outLen, &moved);
    if (st != kCCSuccess) return nil;
    out.length = moved;
    return XBHexFromData(out);
}

static NSData *XBAesDecryptHex(NSString *hex) {
    NSData *in = XBDataFromHex(hex);
    size_t outLen = in.length + kCCBlockSizeAES128;
    NSMutableData *out = [NSMutableData dataWithLength:outLen];
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(kCCDecrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding,
                                 XBKeyData().bytes, kCCKeySizeAES128, XBIVData().bytes,
                                 in.bytes, in.length, out.mutableBytes, outLen, &moved);
    if (st != kCCSuccess) return nil;
    out.length = moved;
    return out;
}

static NSString *XBMD5Hex(NSString *s) {
    const char *c = [s UTF8String];
    unsigned char d[CC_MD5_DIGEST_LENGTH];
    CC_MD5(c, (CC_LONG)strlen(c), d);
    NSMutableString *out = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [out appendFormat:@"%02x", d[i]];
    return out;
}

static NSString *XBRandomHex(int len) {
    const char *hx = "0123456789abcdef";
    NSMutableString *s = [NSMutableString stringWithCapacity:len];
    for (int i = 0; i < len; i++) [s appendFormat:@"%c", hx[arc4random_uniform(16)]];
    return s;
}

// 生成一个可直接嵌入 JS 的双引号字符串
static NSString *XBJSString(NSString *s) {
    if (!s) s = @"";
    NSMutableString *o = [NSMutableString stringWithString:@"\""];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '"': [o appendString:@"\\\""]; break;
            case '\\': [o appendString:@"\\\\"]; break;
            case '\n': [o appendString:@"\\n"]; break;
            case '\r': [o appendString:@"\\r"]; break;
            case '\t': [o appendString:@"\\t"]; break;
            default: [o appendFormat:@"%C", c]; break;
        }
    }
    [o appendString:@"\""];
    return o;
}

#pragma mark - Device

static NSString *XBFeature(void) {
    NSString *idfv = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    idfv = [[idfv stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
    if (idfv.length < 8) idfv = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    return [@"A" stringByAppendingString:idfv];
}

static NSString *XBClientId(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *cid = [d stringForKey:kPrefsClientId];
    if (cid.length == 0) {
        cid = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
        [d setObject:cid forKey:kPrefsClientId];
    }
    return cid;
}

static NSString *XBDeviceMac(void) {
    NSString *md = XBMD5Hex(XBFeature());
    NSMutableString *mac = [NSMutableString string];
    for (int i = 0; i < 6; i++) {
        if (i > 0) [mac appendString:@":"];
        [mac appendString:[md substringWithRange:NSMakeRange(i * 2, 2)]];
    }
    return mac;
}

static NSString *XBClientOS(void) {
    return [@"iOS " stringByAppendingString:[[UIDevice currentDevice] systemVersion]];
}

static NSString *XBAppVersion(void) {
    NSString *v = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"];
    return v ?: @"1.0.0";
}

#pragma mark - License

@interface XbResult : NSObject
@property (nonatomic) BOOL success;
@property (nonatomic) NSInteger code;
@property (nonatomic, strong) NSString *msg;
@property (nonatomic, strong) NSString *cookie;
@end
@implementation XbResult
@end

static NSDictionary *XBBaseData(NSString *card) {
    return @{
        @"account": card ?: @"",
        @"account_pass": @"",
        @"feature": XBFeature(),
        @"mac": XBDeviceMac(),
        @"md5": @"",
        @"version": XBAppVersion(),
        @"clientid": XBClientId(),
        @"clientos": XBClientOS(),
        @"param": @"",
        @"token": XBRandomHex(32),
        @"uuid": XBRandomHex(32)
    };
}

static NSDictionary *XBPostBody(NSDictionary *data) {
    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:data options:0 error:&err];
    if (!json) return nil;
    NSString *enc = XBAesEncryptHex(json);
    if (!enc) return nil;
    NSString *src = XBSignTpl ?: @"123[data]456[key]789";
    src = [src stringByReplacingOccurrencesOfString:@"[data]" withString:enc];
    src = [src stringByReplacingOccurrencesOfString:@"[key]" withString:(XBSkey ?: @"")];
    return @{ @"soft": XBSoft ?: @"", @"data": enc, @"sign": XBMD5Hex(src) };
}

static NSDictionary *XBHttpPostSync(NSString *url, NSDictionary *body) {
    NSError *err = nil;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
    if (!payload) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 12.0;
    [req setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"okhttp/4.9.0" forHTTPHeaderField:@"User-Agent"];
    req.HTTPBody = payload;

    __block NSData *respData = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            respData = d;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(14.0 * NSEC_PER_SEC)));
    if (!respData) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:respData options:0 error:&err];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

static NSDictionary *XBPostFirst(NSArray *urls, NSDictionary *body) {
    for (NSString *u in urls) {
        if ([u isKindOfClass:[NSString class]] && u.length > 0) {
            NSDictionary *root = XBHttpPostSync(u, body);
            if (root) return root;
        }
    }
    return nil;
}

static NSDictionary *XBParseRoot(NSDictionary *root, XbResult *res) {
    if (!root) { res.success = NO; res.code = -1; res.msg = @"网络连接失败"; return nil; }
    if (![root[@"status"] isEqual:@"success"]) {
        res.success = NO; res.code = -1;
        NSString *m = root[@"msg"];
        res.msg = (m.length > 0) ? m : @"服务器拒绝";
        return nil;
    }
    NSString *hex = root[@"data"];
    if (![hex isKindOfClass:[NSString class]] || hex.length == 0) {
        res.success = NO; res.code = -1; res.msg = @"响应数据异常"; return nil;
    }
    NSData *dec = XBAesDecryptHex(hex);
    if (!dec) { res.success = NO; res.code = -1; res.msg = @"数据解密失败"; return nil; }
    id inner = [NSJSONSerialization JSONObjectWithData:dec options:0 error:nil];
    return [inner isKindOfClass:[NSDictionary class]] ? inner : nil;
}

static NSArray *XBHeartbeatURLs(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (id u in XBEndpoints()) {
        if (![u isKindOfClass:[NSString class]]) continue;
        NSString *s = u;
        if ([s rangeOfString:@"/api/login"].location != NSNotFound) {
            s = [s stringByReplacingOccurrencesOfString:@"/api/login" withString:@"/api/heartbeat"];
        }
        [out addObject:s];
    }
    return out;
}

static XbResult *XBLogin(NSString *card) {
    XbResult *res = [XbResult new];
    NSDictionary *body = XBPostBody(XBBaseData(card));
    res.success = NO; res.code = -1; res.msg = @"验证失败";
    if (!body) { res.msg = @"本地加密失败"; return res; }
    NSDictionary *root = XBPostFirst(XBEndpoints(), body);
    NSDictionary *inner = XBParseRoot(root, res);
    if (!inner) { if (res.msg.length == 0) res.msg = @"验证失败"; return res; }
    res.code = [inner[@"code"] integerValue];
    NSString *m = inner[@"msg"];
    if (m.length > 0) res.msg = m;
    res.success = (res.code == 200);
    id cookie = inner[@"cookie"];
    if (!cookie) {
        id result = inner[@"result"];
        if ([result isKindOfClass:[NSDictionary class]]) cookie = result[@"cookie"];
    }
    if ([cookie isKindOfClass:[NSString class]]) res.cookie = cookie;
    if (res.success && (res.msg.length == 0)) res.msg = @"验证成功";
    return res;
}

static XbResult *XBHeartbeat(NSString *card, NSString *cookie) {
    XbResult *res = [XbResult new];
    NSMutableDictionary *data = [XBBaseData(card) mutableCopy];
    if (cookie.length > 0) data[@"cookie"] = cookie;
    NSDictionary *body = XBPostBody(data);
    res.success = NO; res.code = -1; res.msg = @"验证失败";
    if (!body) return res;
    NSDictionary *root = XBPostFirst(XBHeartbeatURLs(), body);
    NSDictionary *inner = XBParseRoot(root, res);
    if (!inner) return res;
    res.code = [inner[@"code"] integerValue];
    NSString *m = inner[@"msg"];
    if (m.length > 0) res.msg = m;
    res.success = (res.code == 200);
    return res;
}

#pragma mark - Heartbeat

static NSUserDefaults *XBPrefs(void) { return [NSUserDefaults standardUserDefaults]; }

static void XBDie(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ exit(0); });
    exit(0);
}

static NSObject *gHeartLock = nil;
static NSString *gHeartCard = nil;
static NSString *gHeartCookie = nil;
static BOOL gHeartRunning = NO;

static void XBStartHeartbeat(NSString *card, NSString *cookie) {
    if (!XBHeartEnabled) return;
    if (!gHeartLock) gHeartLock = [NSObject new];
    @synchronized(gHeartLock) {
        gHeartCard = [card copy];
        gHeartCookie = [cookie copy];
        if (gHeartRunning) return;
        gHeartRunning = YES;
    }
    NSInteger sec = XBHeartSeconds;
    if (sec < 10) sec = 150;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [NSThread sleepForTimeInterval:sec];
        while (YES) {
            @autoreleasepool {
                NSString *useCard = nil;
                NSString *useCookie = nil;
                @synchronized(gHeartLock) {
                    useCard = gHeartCard;
                    useCookie = gHeartCookie;
                }
                BOOL ok = NO;
                if (useCard.length > 0) {
                    if (useCookie.length > 0) {
                        XbResult *r = XBHeartbeat(useCard, useCookie);
                        if (r.success) {
                            ok = YES;
                        } else {
                            XbResult *re = XBLogin(useCard);
                            if (re.success) {
                                ok = YES;
                                if (re.cookie.length > 0) {
                                    @synchronized(gHeartLock) { gHeartCookie = [re.cookie copy]; }
                                }
                            }
                        }
                    } else {
                        XbResult *r = XBLogin(useCard);
                        ok = r.success;
                        if (r.success && r.cookie.length > 0) {
                            @synchronized(gHeartLock) { gHeartCookie = [r.cookie copy]; }
                        }
                    }
                }
                if (!ok) { XBDie(); return; }
            }
            [NSThread sleepForTimeInterval:sec];
        }
    });
}

#pragma mark - Web Login UI

static NSString *XBShimJS(void) {
    return @"(function(){if(window.Android)return;"
            "window.Android={"
            "verifyCardKey2:function(soft,url,card,cb){window.webkit.messageHandlers.Android.postMessage({action:'verify',soft:String(soft||''),url:String(url||''),card:String(card||''),cb:String(cb||'onCardVerify')});},"
            "writeSP:function(k,v){window.webkit.messageHandlers.Android.postMessage({action:'writeSP',key:String(k||''),value:String(v||'')});},"
            "getSP:function(k){return '';},"
            "Toast:function(m){window.webkit.messageHandlers.Android.postMessage({action:'toast',msg:String(m||'')});},"
            "close:function(){window.webkit.messageHandlers.Android.postMessage({action:'close'});},"
            "openUrl:function(u){window.webkit.messageHandlers.Android.postMessage({action:'openUrl',url:String(u||'')});}"
            "};})();";
}

static NSString *XBFallbackHTML(void) {
    return @"<!doctype html><html><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no'>"
            "<style>body{margin:0;background:#f4f6fb;font-family:-apple-system,'PingFang SC',sans-serif;display:flex;align-items:center;justify-content:center;height:100vh}"
            ".c{width:88%;max-width:360px;background:#fff;border-radius:16px;padding:24px;box-shadow:0 8px 30px rgba(0,0,0,.12)}"
            "h2{margin:0 0 16px;font-size:19px;color:#222}input{width:100%;box-sizing:border-box;padding:12px;border:1px solid #dcdfe6;border-radius:8px;font-size:15px}"
            "button{width:100%;margin-top:14px;padding:13px;border:0;border-radius:10px;color:#fff;font-size:16px;background:linear-gradient(90deg,#007aff,#00aaff)}"
            "p{color:#999;font-size:13px;text-align:center;margin-top:12px;min-height:18px}</style></head><body>"
            "<div class='c'><h2>授权验证</h2><input id='k' placeholder='请输入卡密' autocomplete='off'/>"
            "<button id='b'>立即验证 →</button><p id='s'></p></div>"
            "<script>var b=document.getElementById('b'),k=document.getElementById('k'),s=document.getElementById('s');"
            "b.onclick=function(){var c=k.value.trim();if(!c){s.textContent='请输入卡密';return;}b.disabled=true;b.textContent='验证中...';"
            "window.Android.verifyCardKey2('', '', c, 'onCardVerify');};"
            "function onCardVerify(ok,code,body){b.disabled=false;b.textContent='立即验证 →';if(ok&&body==='ok'){s.textContent='验证成功';window.Android.close();}else{s.textContent=body||'验证失败';}}"
            "</script></body></html>";
}

static NSString *XBLoadHTML(void) {
    NSString *p = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html" inDirectory:@"kami"];
    if (!p) p = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html"];
    if (p) {
        NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (s.length > 0) return s;
    }
    return XBFallbackHTML();
}

@class XbLoginViewController;
static XbLoginViewController *gLoginVC = nil;

@interface XbLoginViewController : UIViewController <WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) UILabel *toast;
@property (nonatomic, strong) NSString *pendingCB;
@property (nonatomic) BOOL busy;
@end

@implementation XbLoginViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.956 green:0.965 blue:0.984 alpha:1.0];

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.userContentController = [[WKUserContentController alloc] init];
    [cfg.userContentController addScriptMessageHandler:self name:@"Android"];
    [cfg.userContentController addUserScript:[[WKUserScript alloc] initWithSource:XBShimJS()
                                                                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                                 forMainFrameOnly:YES]];

    WKWebView *web = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
    web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    web.opaque = NO;
    web.backgroundColor = [UIColor clearColor];
    web.scrollView.bounces = NO;
    [self.view addSubview:web];
    self.web = web;

    [web loadHTMLString:XBLoadHTML() baseURL:[NSURL fileURLWithPath:[[NSBundle mainBundle] bundlePath]]];

    self.toast = [[UILabel alloc] initWithFrame:CGRectZero];
    self.toast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    self.toast.textColor = [UIColor whiteColor];
    self.toast.font = [UIFont systemFontOfSize:14];
    self.toast.textAlignment = NSTextAlignmentCenter;
    self.toast.layer.cornerRadius = 16;
    self.toast.clipsToBounds = YES;
    self.toast.alpha = 0;
    [self.view addSubview:self.toast];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.web.frame = self.view.bounds;
    self.toast.frame = CGRectMake((self.view.bounds.size.width - 200) / 2, self.view.bounds.size.height - 110, 200, 36);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 每次启动都必须手动输入卡密验证，不做任何静默自动登录。
}

- (void)showToast:(NSString *)msg {
    if (msg.length == 0) return;
    self.toast.text = msg;
    self.toast.alpha = 1;
    [UIView animateWithDuration:0.25 delay:1.2 options:0 animations:^{
        self.toast.alpha = 0;
    } completion:nil];
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"Android"]) return;
    id body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *d = (NSDictionary *)body;
    NSString *action = d[@"action"];
    if ([action isEqualToString:@"verify"]) {
        NSString *card = d[@"card"];
        NSString *cb = d[@"cb"];
        self.pendingCB = (cb.length > 0) ? cb : @"onCardVerify";
        card = [card stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (card.length == 0) { [self showToast:@"请输入卡密"]; [self callJS:NO code:-1 msg:@"请输入卡密"]; return; }
        [self doVerify:card silent:NO];
    } else if ([action isEqualToString:@"writeSP"]) {
        NSString *k = d[@"key"]; NSString *v = d[@"value"];
        // 卡密绝不落地：忽略对 kami 的写入，其他普通键仍可保存
        if (k.length > 0 && ![k isEqualToString:@"kami"]) {
            [XBPrefs() setObject:(v ?: @"") forKey:[@"xb_sp_" stringByAppendingString:k]];
        }
    } else if ([action isEqualToString:@"toast"]) {
        [self showToast:d[@"msg"]];
    } else if ([action isEqualToString:@"close"]) {
        [self dismissLogin];
    } else if ([action isEqualToString:@"openUrl"]) {
        NSString *u = d[@"url"];
        NSURL *url = [NSURL URLWithString:u];
        if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)callJS:(BOOL)ok code:(NSInteger)code msg:(NSString *)msg {
    NSString *cb = self.pendingCB.length > 0 ? self.pendingCB : @"onCardVerify";
    NSString *js = [NSString stringWithFormat:@"(function(){try{var f=window.%@;if(typeof f==='function'){f(%@,%ld,%@,'');}}catch(e){}})();",
                    cb, ok ? @"true" : @"false", (long)code, XBJSString(msg ?: @"")];
    [self.web evaluateJavaScript:js completionHandler:nil];
}

- (void)doVerify:(NSString *)card silent:(BOOL)silent {
    if (self.busy) return;
    self.busy = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        XbResult *r = XBLogin(card);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [self callJS:r.success code:r.code msg:(r.success ? @"ok" : r.msg)];
            if (r.success) {
                [self showToast:@"验证成功"];
                XBStartHeartbeat(card, r.cookie);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self dismissLogin];
                });
            } else if (!silent) {
                [self showToast:(r.msg.length > 0 ? r.msg : @"验证失败")];
            }
        });
    });
}

- (void)dismissLogin {
    if (gLoginVC != self && gLoginVC != nil) { return; }
    gLoginVC = nil;
    [self dismissViewControllerAnimated:NO completion:nil];
}

@end

static UIWindow *XBKeyWindow(void) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) return w;
    }
    return [UIApplication sharedApplication].keyWindow;
}

static void XBTryPresent(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gLoginVC) return;
        UIWindow *win = XBKeyWindow();
        UIViewController *root = win.rootViewController;
        if (!root) return;
        if (root.presentedViewController) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                XBTryPresent();
            });
            return;
        }
        XbLoginViewController *vc = [XbLoginViewController new];
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        gLoginVC = vc;
        [root presentViewController:vc animated:NO completion:nil];
    });
}

__attribute__((constructor))
static void XBInit(void) {
    @autoreleasepool {
        // 清理旧版本可能保存过的卡密/会话，确保升级后也不会自动登录
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d removeObjectForKey:@"xb_kami"];
        [d removeObjectForKey:@"xb_cookie"];
        [d removeObjectForKey:@"xb_sp_kami"];
        [d synchronize];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                XBTryPresent();
            });
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            XBTryPresent();
        }];
    }
}
