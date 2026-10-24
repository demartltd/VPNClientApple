#import "OpenFluxNative.h"

#if (TARGET_OS_IOS && !TARGET_OS_SIMULATOR) || TARGET_OS_OSX
#import "liboflux.h"
#define DEMAR_HAS_LIBOFLUX 1
#else
#define DEMAR_HAS_LIBOFLUX 0
#endif

@implementation OpenFluxNative

+ (nullable NSString *)startBoardsWithURL:(NSString *)boardsURL
                                   secret:(NSString *)secret
                                socksHost:(NSString *)socksHost
                                socksPort:(int)socksPort
                              cookieStore:(NSString *)cookieStorePath {
#if DEMAR_HAS_LIBOFLUX
  if (boardsURL.length == 0 || secret.length == 0) {
    return @"openflux: missing boards url or secret";
  }
  NSString *host = socksHost.length ? socksHost : @"127.0.0.1";
  int port = socksPort > 0 ? socksPort : 11080;
  NSString *socks = [NSString stringWithFormat:@"%@:%d", host, port];

  OpenFluxStop();
  OpenFluxSetEncryption((char *)secret.UTF8String);
  if (cookieStorePath.length > 0) {
    OpenFluxSetCookieStore((char *)cookieStorePath.UTF8String);
  }

  int rc = OpenFluxStartClient(
      (char *)"boards",
      (char *)boardsURL.UTF8String,
      (char *)socks.UTF8String,
      (char *)"",
      (char *)"");
  switch (rc) {
    case 0: return nil;
    case 1: return @"openflux already running";
    case 2: return @"openflux unknown transport";
    case 3: return @"openflux transport failed";
    case 4: return [NSString stringWithFormat:@"openflux socks busy (%@)", socks];
    case 6: return @"openflux bad encryption key";
    default: return [NSString stringWithFormat:@"openflux start failed (code %d)", rc];
  }
#else
  (void)boardsURL; (void)secret; (void)socksHost; (void)socksPort; (void)cookieStorePath;
  return @"openflux lib not linked on this platform";
#endif
}

+ (void)stop {
#if DEMAR_HAS_LIBOFLUX
  OpenFluxStop();
#endif
}

+ (BOOL)isRunning {
#if DEMAR_HAS_LIBOFLUX
  return OpenFluxIsRunning() != 0;
#else
  return NO;
#endif
}

@end
