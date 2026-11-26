#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Picks the PS2 BIOS file in a BIOS folder. Tries `preferredNames` in order, then falls back to the
/// first other `.bin` (alphabetical) that looks like a PS2 BIOS. Returns the file name, or nil.
/// Standalone (Foundation only) so it can be tested without the engine.
NSString *_Nullable OEPS2ChooseBIOS(NSString *folderPath, NSArray<NSString *> *preferredNames);

NS_ASSUME_NONNULL_END
