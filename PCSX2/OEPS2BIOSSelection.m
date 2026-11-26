#import "OEPS2BIOSSelection.h"

/// The engine (pcsx2/ps2/BiosTools.cpp, LoadBiosVersion) finds a table of 16-byte entries (10-byte name,
/// u16, u32) that starts with an entry named "RESET", and reads the version from the "ROMVER" entry in
/// it. Use the same rule: a file is a PS2 BIOS only if that table has a ROMVER entry. A Dreamcast or
/// 3DO BIOS of a similar size has no such table.
static BOOL HasPS2RomdirWithROMVER(NSData *data)
{
	const uint8_t *bytes = data.bytes;
	NSUInteger length = data.length;
	for (NSUInteger offset = 0; offset + 16 <= length; offset += 16) {
		if (memcmp(bytes + offset, "RESET\0\0\0\0\0", 10) != 0) {
			continue;
		}
		// Walk the entries until the empty one that ends the table.
		for (NSUInteger entry = offset; entry + 16 <= length && bytes[entry] != 0; entry += 16) {
			if (memcmp(bytes + entry, "ROMVER\0\0\0\0", 10) == 0) {
				return YES;
			}
		}
		return NO;
	}
	return NO;
}

/// Cheap size check first (a PS2 BIOS is a few MB; a PS1 BIOS is 512 KB), then the content check.
static BOOL IsPlausiblePS2BIOS(NSString *path)
{
	NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
	unsigned long long size = [attributes fileSize];
	if (size < 1024 * 1024 || size > 8 * 1024 * 1024) {
		return NO;
	}
	NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
	return data != nil && HasPS2RomdirWithROMVER(data);
}

NSString *OEPS2ChooseBIOS(NSString *folderPath, NSArray<NSString *> *preferredNames)
{
	for (NSString *name in preferredNames) {
		if (IsPlausiblePS2BIOS([folderPath stringByAppendingPathComponent:name])) {
			return name;
		}
	}
	NSArray<NSString *> *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:folderPath error:nil]
		sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
	for (NSString *name in names) {
		if ([name.pathExtension caseInsensitiveCompare:@"bin"] == NSOrderedSame
			&& IsPlausiblePS2BIOS([folderPath stringByAppendingPathComponent:name])) {
			return name;
		}
	}
	return nil;
}
