/*
 Copyright (c) 2018, OpenEmu Team

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

#import "OEM3UFile.h"

#import "OEDiscDescriptor_Internal.h"
#import "OECHDFile.h"

NSString *const OEM3UFileErrorDomain = @"org.openemu.OEM3UFile.ErrorDomain";

@implementation OEM3UFile {
    // The first disc, when it is a CHD: detection reads it through OECHDFile, not as a raw file.
    OECHDFile *_firstCHD;
}

- (BOOL)_setUpFileReferencesWithError:(NSError **)error
{
    NSString *fileContent = [self _fileContentWithError:error];
    if (!fileContent)
        return NO;

    fileContent = [fileContent stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSURL *directoryURL = self.fileURL.URLByDeletingLastPathComponent;

    NSMutableArray<NSURL *> *referencedFileURLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *allReferencedFileURLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *referencedBinaryFileURLs = [NSMutableArray array];
    NSMutableArray<OEDiscDescriptor *> *referencedDiscDescriptors = [NSMutableArray array];

    __block NSError *localError;
    __block BOOL failedToValidateContainedFiles = NO;
    [fileContent enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSURL *url = [NSURL fileURLWithPath:line isDirectory:NO relativeToURL:directoryURL].absoluteURL;

        __kindof OEFile *referencedFile = [OEFile fileWithURL:url error:&localError];

        // A CHD is a whole disc in one file: it is both the disc and its only data file.
        if ([referencedFile isKindOfClass:[OECHDFile class]]) {
            if (referencedFileURLs.count == 0)
                self->_firstCHD = referencedFile;
            [referencedFileURLs addObject:url];
            [allReferencedFileURLs addObject:url];
            [referencedBinaryFileURLs addObject:url];
            return;
        }

        if (![referencedFile isKindOfClass:[OEDiscDescriptor class]]) {
            // Don't import the m3u if it contains invalid referenced files (unreachable or non-OEDiscDescriptor).
            failedToValidateContainedFiles = YES;
            return;
        }

        OEDiscDescriptor *referencedDiscDescriptor = referencedFile;

        [referencedFileURLs addObject:url];
        [allReferencedFileURLs addObject:url];
        [allReferencedFileURLs addObjectsFromArray:referencedDiscDescriptor.allReferencedFileURLs];
        [referencedBinaryFileURLs addObjectsFromArray:referencedDiscDescriptor.referencedBinaryFileURLs];
        [referencedDiscDescriptors addObject:referencedDiscDescriptor];
    }];

    if (failedToValidateContainedFiles) {
        if (error != nil)
            *error = localError;

        return NO;
    }

    self.dataTrackFileURL = referencedBinaryFileURLs.firstObject;
    self.referencedFileURLs = referencedFileURLs;
    self.allReferencedFileURLs = allReferencedFileURLs;
    self.referencedBinaryFileURLs = referencedBinaryFileURLs;

    return YES;
}

- (BOOL)moveToURL:(NSURL *)destinationURL error:(NSError **)error;
{
    // Rewrite the file in case there are relative paths in the original file.
    if (![self.fileContentWithRelativeFilePaths writeToURL:destinationURL atomically:YES encoding:NSUTF8StringEncoding error:error])
        return NO;

    if (![[NSFileManager defaultManager] removeItemAtURL:self.fileURL error:error])
        return NO;

    return [self moveReferencedFilesToDirectoryAtURL:destinationURL.URLByDeletingLastPathComponent error:error];
}

- (BOOL)copyToURL:(NSURL *)destinationURL error:(NSError *__autoreleasing *)error
{
    // Rewrite the file in case there are relative paths in the original file.
    if (![self.fileContentWithRelativeFilePaths writeToURL:destinationURL atomically:YES encoding:NSUTF8StringEncoding error:error])
        return NO;

    return [self copyReferencedFilesToDirectoryAtURL:destinationURL.URLByDeletingLastPathComponent error:error];
}

- (NSData *)readDataInRange:(NSRange)dataRange
{
    if (_firstCHD != nil)
        return [_firstCHD readDataInRange:dataRange];
    return [super readDataInRange:dataRange];
}

- (NSString *)fileContentWithRelativeFilePaths
{
    return [[self.referencedFileURLs valueForKey:@"lastPathComponent"] componentsJoinedByString:@"\n"];
}

@end
