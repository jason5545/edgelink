#import "MiTrustCryptoBridge.h"
#import <CommonCrypto/CommonCryptor.h>

@implementation MiTrustCryptoBridge

+ (nullable NSData *)aes256ECBCrypt:(NSData *)input
                                key:(NSData *)key
                            encrypt:(BOOL)encrypt
                              error:(NSError **)error {
    size_t outCapacity = input.length + kCCBlockSizeAES128;
    NSMutableData *output = [NSMutableData dataWithLength:outCapacity];
    size_t outMoved = 0;
    CCCryptorStatus status = CCCrypt(
        encrypt ? kCCEncrypt : kCCDecrypt,
        kCCAlgorithmAES,
        kCCOptionPKCS7Padding | kCCOptionECBMode,
        key.bytes,
        key.length,
        NULL,
        input.bytes,
        input.length,
        output.mutableBytes,
        outCapacity,
        &outMoved
    );
    if (status != kCCSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:@"MiTrustCryptoBridge"
                                         code:status
                                     userInfo:@{NSLocalizedDescriptionKey: @"CCCrypt failed"}];
        }
        return nil;
    }
    output.length = outMoved;
    return output;
}

+ (nullable NSData *)aes256ECBEncrypt:(NSData *)plaintext key:(NSData *)key error:(NSError **)error {
    return [self aes256ECBCrypt:plaintext key:key encrypt:YES error:error];
}

+ (nullable NSData *)aes256ECBDecrypt:(NSData *)ciphertext key:(NSData *)key error:(NSError **)error {
    return [self aes256ECBCrypt:ciphertext key:key encrypt:NO error:error];
}

@end
