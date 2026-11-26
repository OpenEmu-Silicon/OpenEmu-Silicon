// Standalone test for OEPS2ChooseBIOS. Run with Scripts/test-ps2-bios-selection.sh.
#import "../OEPS2BIOSSelection.h"

static int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); failures++; } else { printf("ok:   %s\n", msg); } } while (0)

/// A fake dump: `size` bytes, optionally with a real-looking ROMDIR (RESET ... ROMVER) at `romdirOffset`.
static void WriteFake(NSString *dir, NSString *name, size_t size, BOOL withRomdir, size_t romdirOffset)
{
	NSMutableData *data = [NSMutableData dataWithLength:size];
	if (withRomdir) {
		// 16-byte entries: 10-byte name, u16 extinfo size, u32 file size.
		const char *entries[] = {"RESET", "ROMDIR", "EXTINFO", "ROMVER", "IOPBOOT"};
		uint8_t *p = (uint8_t *)data.mutableBytes + romdirOffset;
		for (int i = 0; i < 5; i++) {
			memcpy(p + i * 16, entries[i], strlen(entries[i]));
			uint32_t fileSize = 0x10;
			memcpy(p + i * 16 + 12, &fileSize, 4);
		}
	}
	[data writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
}

int main(void)
{
	@autoreleasepool {
		NSArray *preferred = @[@"scph39001.bin", @"scph70004.bin"];
		NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
		[NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

		WriteFake(dir, @"dc_boot.bin", 2 * 1024 * 1024, NO, 0);      // Dreamcast, 2 MB
		WriteFake(dir, @"panafz10.bin", 1 * 1024 * 1024, NO, 0);     // 3DO, 1 MB
		WriteFake(dir, @"ps1-scph1001.bin", 512 * 1024, NO, 0);      // PS1, 512 KB
		WriteFake(dir, @"ps2-custom.bin", 4 * 1024 * 1024, YES, 0x2750);
		CHECK([OEPS2ChooseBIOS(dir, preferred) isEqualToString:@"ps2-custom.bin"],
			  "fallback skips dc_boot.bin, panafz10.bin and the PS1 file, picks ps2-custom.bin");

		// A preferred name that has a plausible PS2 BIOS wins over the fallback.
		WriteFake(dir, @"scph70004.bin", 4 * 1024 * 1024, YES, 0x2750);
		CHECK([OEPS2ChooseBIOS(dir, preferred) isEqualToString:@"scph70004.bin"], "preferred name wins");

		// A preferred name holding some other 4 MB file is not taken.
		WriteFake(dir, @"scph39001.bin", 4 * 1024 * 1024, NO, 0);
		CHECK([OEPS2ChooseBIOS(dir, preferred) isEqualToString:@"scph70004.bin"], "preferred name without ROMVER is skipped");

		// Nothing qualifies.
		NSString *dir2 = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
		[NSFileManager.defaultManager createDirectoryAtPath:dir2 withIntermediateDirectories:YES attributes:nil error:nil];
		WriteFake(dir2, @"dc_boot.bin", 2 * 1024 * 1024, NO, 0);
		CHECK(OEPS2ChooseBIOS(dir2, preferred) == nil, "only a Dreamcast BIOS gives nil");

		[NSFileManager.defaultManager removeItemAtPath:dir error:nil];
		[NSFileManager.defaultManager removeItemAtPath:dir2 error:nil];
	}
	printf(failures ? "%d FAILED\n" : "all passed\n", failures);
	return failures ? 1 : 0;
}
