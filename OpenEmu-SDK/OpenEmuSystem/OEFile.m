//
//  OEFile.m
//  OpenEmu-SDK
//
//  Created by Remy Demarest on 28/08/2016.
//
//

#import "OEFile.h"

@implementation OEFile {
    NSFileHandle *_fileHandle;
    NSUInteger _fileSize;
}

static NSMutableDictionary<NSString *, Class> *extensionToSubclassDictionary;

+ (void)initialize
{
    if (self != [OEFile class])
        return;

    extensionToSubclassDictionary = [NSMutableDictionary dictionary];

    [self registerClass:NSClassFromString(@"OECUESheet") forFileExtension:@"cue"];
    [self registerClass:NSClassFromString(@"OECloneCD") forFileExtension:@"ccd"];
    [self registerClass:NSClassFromString(@"OEDreamcastGDI") forFileExtension:@"gdi"];
    [self registerClass:NSClassFromString(@"OEM3UFile") forFileExtension:@"m3u"];
    [self registerClass:NSClassFromString(@"OECHDFile") forFileExtension:@"chd"];
    [self registerClass:NSClassFromString(@"OEGCZFile") forFileExtension:@"gcz"];
    [self registerClass:NSClassFromString(@"OECSOFile") forFileExtension:@"cso"];
}

+ (__kindof OEFile *)fileWithURL:(NSURL *)fileURL error:(NSError **)error
{
    Class discDescriptorClass = extensionToSubclassDictionary[fileURL.pathExtension.lowercaseString];
    if (discDescriptorClass != Nil)
        return [[discDescriptorClass alloc] initWithFileURL:fileURL error:error];

    return [[OEFile alloc] initWithFileURL:fileURL error:error];
}

+ (void)registerClass:(Class)cls forFileExtension:(NSString *)fileExtension
{
    NSAssert([cls isSubclassOfClass:[OEFile class]], @"Subclass of OEFile required.");
    extensionToSubclassDictionary[fileExtension] = cls;
}

- (nullable instancetype)initWithFileURL:(NSURL *)fileURL error:(NSError **)error
{
    if (!(self = [super init]))
        return nil;

    _fileURL = [fileURL copy];
    _fileExtension = _fileURL.pathExtension.lowercaseString;

    return self;
}

- (void)dealloc
{
    [_fileHandle closeFile];
}

- (NSArray<NSURL *> *)allFileURLs
{
    return @[ _fileURL ];
}

- (NSUInteger)fileSize
{
    if (_fileSize == 0) {
        NSNumber *fileSize;
        [_fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
        _fileSize = fileSize.unsignedIntegerValue;
    }

    return _fileSize;
}

- (NSURL *)dataTrackFileURL
{
    return _fileURL;
}

- (NSData *)readDataInRange:(NSRange)dataRange
{
    if (_fileHandle == nil)
        _fileHandle = [NSFileHandle fileHandleForReadingFromURL:self.dataTrackFileURL error:nil];

    if (_fileHandle == nil)
        return [NSData data];

    if (@available(macOS 10.15, *))
    {
        if (![_fileHandle seekToOffset:dataRange.location error:nil])
            return [NSData data];

        return [_fileHandle readDataUpToLength:dataRange.length error:nil];
    }

    @try {
        [_fileHandle seekToFileOffset:dataRange.location];
    }
    @catch (...) {
        return [NSData data];
    }

    return [_fileHandle readDataOfLength:dataRange.length];
}

- (NSString *)readASCIIStringInRange:(NSRange)dataRange
{
    return [[NSString alloc] initWithData:[self readDataInRange:dataRange] encoding:NSASCIIStringEncoding] ?: @"";
}

- (nullable instancetype)fileByMovingFileToURL:(NSURL *)destinationURL error:(NSError **)error
{
    if (![self moveToURL:destinationURL error:error])
        return nil;

    return [[self.class alloc] initWithFileURL:destinationURL error:error];
}

- (nullable instancetype)fileByCopyingFileToURL:(NSURL *)destinationURL error:(NSError **)error
{
    if (![self copyToURL:destinationURL error:error])
        return nil;

    return [[self.class alloc] initWithFileURL:destinationURL error:error];
}

- (BOOL)moveToURL:(NSURL *)destinationURL error:(NSError **)error
{
    return [[NSFileManager defaultManager] moveItemAtURL:_fileURL toURL:destinationURL error:error];
}

- (BOOL)copyToURL:(NSURL *)destinationURL error:(NSError **)error
{
    return [[NSFileManager defaultManager] copyItemAtURL:_fileURL toURL:destinationURL error:error];
}

@end
