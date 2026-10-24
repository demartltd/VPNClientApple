#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// In-process OpenFlux SOCKS in the **host app** (liboflux).
/// Not used in Packet Tunnel — that process already hosts Libbox's Go runtime.
@interface OpenFluxNative : NSObject

+ (nullable NSString *)startBoardsWithURL:(NSString *)boardsURL
                                   secret:(NSString *)secret
                                socksHost:(NSString *)socksHost
                                socksPort:(int)socksPort
                              cookieStore:(NSString *)cookieStorePath;

+ (void)stop;
+ (BOOL)isRunning;

@end

NS_ASSUME_NONNULL_END
