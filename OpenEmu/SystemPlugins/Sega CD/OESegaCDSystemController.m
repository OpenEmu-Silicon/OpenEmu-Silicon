/*
 Copyright (c) 2012, OpenEmu Team
 
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

#import "OESegaCDSystemController.h"

@implementation OESegaCDSystemController

// A disc comes as a CUE sheet, or as a CHD, which reads as its first data track's .bin.
static BOOL OESCDIsDisc(OEFile *file)
{
    return [file isKindOfClass:[OECUESheet class]] || [file.fileExtension isEqualToString:@"chd"];
}

- (OEFileSupport)canHandleFile:(__kindof OEFile *)file
{
    if (!OESCDIsDisc(file))
        return OEFileSupportNo;

    if ([file isKindOfClass:[OECUESheet class]])
        NSLog(@"SCD data track: %@", [(OECUESheet *)file dataTrackFileURL]);

    NSString *dataTrackString = [file readASCIIStringInRange:NSMakeRange(0, 16)];
    NSString *otherDataTrackString = [file readASCIIStringInRange:NSMakeRange(0x10, 16)];
    NSLog(@"'%@'", dataTrackString);
    NSLog(@"'%@'", otherDataTrackString);
    NSArray *dataTrackList = @[ @"SEGADISCSYSTEM  ", @"SEGABOOTDISC    ", @"SEGADISC        ", @"SEGADATADISC    " ];

    for(NSString *d in dataTrackList)
    {
        if([dataTrackString isEqualToString:d] || [otherDataTrackString isEqualToString:d])
            return OEFileSupportYes;
    }

    return OEFileSupportNo;
}

- (unsigned long long)_headerOffsetForFile:(__kindof OEFile *)file
{
    NSString *dataTrackString = [file readASCIIStringInRange:NSMakeRange(0x100, 16)];
    NSString *otherDataTrackString = [file readASCIIStringInRange:NSMakeRange(0x110, 16)];

    NSArray *dataTrackList = @[ @"SEGA GENESIS    ", @"SEGA MEGA DRIVE " ];

    for(NSString *d in dataTrackList)
    {
        if([dataTrackString isEqualToString:d])
            return 0x0100;
        if([otherDataTrackString isEqualToString:d])
            return 0x0110;
    }
    return 0;
}

- (NSString *)headerLookupForFile:(__kindof OEFile *)file
{
    if (!OESCDIsDisc(file))
        return nil;

    unsigned long long offsetFound = [self _headerOffsetForFile:file];

    NSData *headerDataTrackBuffer = [file readDataInRange:NSMakeRange(offsetFound, 256)];
    NSString *hex = [headerDataTrackBuffer oe_hexStringRepresentation];

    return hex;
}

- (NSString *)serialLookupForFile:(__kindof OEFile *)file
{
    if (!OESCDIsDisc(file))
        return nil;

    unsigned long long offsetFound = [self _headerOffsetForFile:file];
    if (offsetFound == 0)
        return nil;

    // Product serial is 12 bytes at offset 0x82 from header start (ROMPRODUCT in GenPlusGX)
    NSString *serial = [file readASCIIStringInRange:NSMakeRange(offsetFound + 0x82, 12)];
    serial = [serial stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    return serial.length > 0 ? serial : nil;
}

@end
