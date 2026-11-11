import Foundation
import OpenEmuSystem

/// OpenEmu's system registration entry point. This class intentionally has no
/// emulator or input-dispatch logic: OpenEmu instantiates the Objective-C
/// OE3DSSystemResponder for UI/key handling, and the separate Azahar core
/// handles CPU/GPU emulation. There is deliberately no custom registration
/// behavior to maintain in this class. Keep its principal-class name stable because
/// Nintendo3DS-Info.plist uses $(PRODUCT_MODULE_NAME).OE3DSSystemController.
final class OE3DSSystemController: OESystemController {
}
