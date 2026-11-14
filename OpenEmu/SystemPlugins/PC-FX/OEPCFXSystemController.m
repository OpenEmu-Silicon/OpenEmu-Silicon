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

#import "OEPCFXSystemController.h"

@implementation OEPCFXSystemController

// Whether a data track holds the PC-FX boot header.
static BOOL OEPCFXHasHeader(NSData *dataTrackBuffer, NSURL *dataTrackURL)
{
    NSString *dataTrackString = @"PC-FX:Hu_CD-ROM ";
    NSData *dataSearch = [dataTrackString dataUsingEncoding:NSUTF8StringEncoding];
    // this still slows import down but we need to scan the disc as there's no common offset
    NSRange indexOfData = [dataTrackBuffer rangeOfData: dataSearch options:0 range:NSMakeRange(0, [dataTrackBuffer length])];

    if(indexOfData.length == 0)
        return NO;

    NSLog(@"PC-FX data track: %@", dataTrackURL);
    NSLog (@"'%@' at offset = 0x%lX", dataTrackString, indexOfData.location);
    return YES;
}

- (OEFileSupport)canHandleFile:(__kindof OEFile *)file
{
    // A .m3u is a PC-FX game when its first disc is. Only that disc is checked: the check reads
    // whole data tracks, and every other system's playlists come through here too.
    if ([file.fileExtension isEqualToString:@"m3u"] && [file isKindOfClass:[OEDiscDescriptor class]]) {
        NSURL *firstDiscURL = [(OEDiscDescriptor *)file referencedFileURLs].firstObject;
        OEFile *firstDisc = firstDiscURL != nil ? [OEFile fileWithURL:firstDiscURL error:nil] : nil;
        return firstDisc != nil ? [self canHandleDisc:firstDisc] : OEFileSupportNo;
    }

    return [self canHandleDisc:file];
}

- (OEFileSupport)canHandleDisc:(OEFile *)file
{
    // A CHD reads as its first data track's .bin. The header is in the track's first sector, after
    // the pregap Redump dumps keep at the start of the track (usually 3 seconds, 225 sectors), so the
    // first 2 MB hold it without decompressing the whole track.
    if ([file.fileExtension isEqualToString:@"chd"])
        return OEPCFXHasHeader([file readDataInRange:NSMakeRange(0, 2 * 1024 * 1024)], file.fileURL) ? OEFileSupportYes : OEFileSupportNo;

    if (![file isKindOfClass:[OEDiscDescriptor class]])
        return OEFileSupportNo;

    OEDiscDescriptor *descriptor = (OEDiscDescriptor *)file;
    for(NSURL *dataTrack in descriptor.referencedBinaryFileURLs)
    {
        // Mapped, not read: every CUE and CCD the app imports is checked here, whatever its system.
        NSError *error = nil;
        NSData *dataTrackBuffer = [NSData dataWithContentsOfURL:dataTrack options:NSDataReadingMappedIfSafe | NSDataReadingUncached error:&error];

        if(OEPCFXHasHeader(dataTrackBuffer, dataTrack))
            return OEFileSupportYes;
    }

    return OEFileSupportNo;
}

@end
