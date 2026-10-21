/*
 Copyright (c) 2013, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OEWiiSystemController.h"
#import "OEWiiSystemResponder.h"
#import "OEWiiSystemResponderClient.h"

@implementation OEWiiSystemController

// Read header to detect Wii ISO, WBFS & CISO
- (OEFileSupport)canHandleFile:(__kindof OEFile *)file
{
        // wbfs/wad are Wii-only container formats.
        if([file.fileExtension isEqualToString:@"wbfs"] || [file.fileExtension isEqualToString:@"wad"])
            return OEFileSupportYes;

    NSRange dataRange = NSMakeRange(0x018, 4);

    // Handle ciso file and set the offset for the Magicword in compressed iso.
    if ([file.fileExtension isEqualToString:@"ciso"])
        dataRange.location = 0x8018;
    // RVZ/WIA keep the disc's first 0x80 bytes uncompressed in WIAHeader2 (file 0x58), so the
    // Wii magic sits at disc offset 0x18 -> file 0x70. Reading it tells a Wii .rvz apart from a
    // GameCube .rvz, which the old blanket extension match could not.
    else if ([file.fileExtension isEqualToString:@"rvz"])
        dataRange.location = 0x70;

    // Wii Magicword 0x5D1C9EA3
    NSData *dataBuffer = [file readDataInRange:dataRange];
    NSData *comparisonData = [[NSData alloc] initWithBytes:(const uint8_t[]){ 0x5D, 0x1C, 0x9E, 0xA3 } length:4];

    if ([dataBuffer isEqualToData:comparisonData])
        return OEFileSupportYes;

    return OEFileSupportNo;

}

// A Wii disc stores its 6-character game ID (e.g. "RMCE01") at the start of the disc header; the
// file offset of that header depends on the container format. A WiiWare .wad has no disc header —
// its 4-character game code lives in the TMD's title ID. Used to match the bundled Dolphin
// GameSettings/<ID>.ini.
- (NSString *)serialLookupForFile:(__kindof OEFile *)file
{
    NSString *ext = file.fileExtension.lowercaseString;

    if ([ext isEqualToString:@"wad"])
        return [self gameCodeFromWAD:file];

    NSUInteger discStart = 0x0;
    if ([ext isEqualToString:@"ciso"])
        discStart = 0x8000;
    else if ([ext isEqualToString:@"rvz"] || [ext isEqualToString:@"wia"])
        discStart = 0x58;
    else if ([ext isEqualToString:@"wbfs"])
        discStart = 0x200;

    NSString *gameID = [file readASCIIStringInRange:NSMakeRange(discStart, 6)];

    // A real game ID is 6 uppercase letters/digits; reject anything else (e.g. a format whose
    // header offset we didn't decode) so we never produce a bogus serial.
    if (![self isValidGameCode:gameID])
        return nil;

    // Disc number and version bytes follow the ID, matching the GameCube controller's suffixing.
    NSData *discData = [file readDataInRange:NSMakeRange(discStart + 0x6, 1)];
    uint8_t discByte = discData.length ? ((const uint8_t *)discData.bytes)[0] : 0;
    NSData *versionData = [file readDataInRange:NSMakeRange(discStart + 0x7, 1)];
    uint8_t versionByte = versionData.length ? ((const uint8_t *)versionData.bytes)[0] : 0;

    if (discByte > 0)
        gameID = [gameID stringByAppendingFormat:@"-DISC%d", discByte + 1];
    if (versionByte > 0)
        gameID = [gameID stringByAppendingFormat:@"-REV%d", versionByte];

    return gameID;
}

// Game codes are uppercase letters and digits only.
- (BOOL)isValidGameCode:(NSString *)code
{
    if (code.length < 3)
        return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"] invertedSet];
    return [code rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

// Reads a big-endian uint32 at the given file offset.
static uint32_t OEWiiReadBE32(__kindof OEFile *file, NSUInteger offset)
{
    NSData *data = [file readDataInRange:NSMakeRange(offset, 4)];
    if (data.length < 4)
        return 0;
    const uint8_t *b = data.bytes;
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | (uint32_t)b[3];
}

// Extracts the 4-character WiiWare game code from a .wad's TMD title ID. The WAD header lists the
// size of each section (cert chain, CRL, ticket, TMD), every section padded to a 0x40 boundary; the
// title ID's low 4 bytes (the game code) sit at TMD offset 0x190 (after a 0x140 RSA-2048 signature).
- (NSString *)gameCodeFromWAD:(__kindof OEFile *)file
{
    uint32_t headerSize = OEWiiReadBE32(file, 0x00);
    if (headerSize != 0x20)
        return nil;

    uint32_t certSize   = OEWiiReadBE32(file, 0x08);
    uint32_t crlSize    = OEWiiReadBE32(file, 0x0C);
    uint32_t ticketSize = OEWiiReadBE32(file, 0x10);

    NSUInteger (^align)(NSUInteger) = ^NSUInteger(NSUInteger value) {
        return (value + 0x3F) & ~(NSUInteger)0x3F;
    };
    NSUInteger tmdOffset = align(headerSize) + align(certSize) + align(crlSize) + align(ticketSize);

    NSString *gameCode = [file readASCIIStringInRange:NSMakeRange(tmdOffset + 0x190, 4)];
    return [self isValidGameCode:gameCode] ? gameCode : nil;
}
@end
