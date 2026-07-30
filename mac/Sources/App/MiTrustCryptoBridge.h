#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MiTrustCryptoBridge : NSObject

+ (nullable NSData *)aes256ECBEncrypt:(NSData *)plaintext key:(NSData *)key error:(NSError **)error;
+ (nullable NSData *)aes256ECBDecrypt:(NSData *)ciphertext key:(NSData *)key error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
