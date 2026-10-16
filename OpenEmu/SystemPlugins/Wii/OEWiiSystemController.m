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
@end
