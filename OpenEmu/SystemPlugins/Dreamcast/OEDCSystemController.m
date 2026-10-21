/*
 Copyright (c) 2015, OpenEmu Team
 
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

#import "OEDCSystemController.h"

@implementation OEDCSystemController

- (OEFileSupport)canHandleFile:(__kindof OEFile *)file
{
    // gdi/cdi are Dreamcast-exclusive container formats.
    if ([file.fileExtension isEqualToString:@"gdi"] || [file.fileExtension isEqualToString:@"cdi"])
        return OEFileSupportYes;

    // cue is shared with other CD systems — disambiguate by the Dreamcast IP.BIN signature. It
    // sits at 0x0 in a cooked dump, 0x10 in a MODE1/2352 data track, and 0x18 in a MODE2/2352
    // track (which adds an 8-byte subheader after the 16-byte sync/header).
    if (![file isKindOfClass:[OEDiscDescriptor class]])
        return OEFileSupportNo;

    if ([[file readASCIIStringInRange:NSMakeRange(0, 16)] isEqualToString:@"SEGA SEGAKATANA "])
        return OEFileSupportYes;

    if ([[file readASCIIStringInRange:NSMakeRange(0x10, 16)] isEqualToString:@"SEGA SEGAKATANA "])
        return OEFileSupportYes;

    if ([[file readASCIIStringInRange:NSMakeRange(0x18, 16)] isEqualToString:@"SEGA SEGAKATANA "])
        return OEFileSupportYes;

    return OEFileSupportNo;
}

@end
