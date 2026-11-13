/*
 Copyright (c) 2026, OpenEmu Team
 Author: Leonardo Kasperavičius

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

#import "OECHDFile.h"
#import "OECHDReader.h"

@implementation OECHDFile {
    OECHDReader *_reader;
    BOOL _triedToOpen;
}

- (void)dealloc
{
    OECHDReaderClose(_reader);
}

- (NSData *)readDataInRange:(NSRange)dataRange
{
    @synchronized(self) {
        // Opened on first read: an Arcade CHD is never read, so it never pays for decoding the CHD's map.
        if(!_triedToOpen) {
            _triedToOpen = YES;
            OECHDReaderOpenDVD(self.fileURL.fileSystemRepresentation, &_reader);
        }

        if(_reader == NULL || dataRange.length == 0)
            return [NSData data];

        NSMutableData *data = [NSMutableData dataWithLength:dataRange.length];
        if(data == nil)
            return [NSData data];
        data.length = OECHDReaderRead(_reader, dataRange.location, data.mutableBytes, dataRange.length);
        return data;
    }
}

@end
